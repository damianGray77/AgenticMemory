using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;
using SherpaOnnx;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace Listener;

/// <summary>
/// Turns speech into text as it's heard. Audio goes in as it arrives (16 kHz mono, from the microphone or, for testing,
/// a file), and text comes out a stretch at a time, each time a few seconds of speech has ended in a pause. Silero VAD
/// finds the speech, so silence never reaches Whisper. The speech is kept in memory, never on disk, so that once
/// recording stops it can be gone over again with a better model (<see cref="CleanUpAsync"/>).
/// </summary>
public sealed class Transcriber
{
    public const int SampleRate = 16000;
    /// <summary>The Whisper model in <see cref="AppPaths.ModelsDirectory"/> used unless another is picked.</summary>
    public const string DefaultModel = "ggml-large-v3-turbo-q5_0.bin";
    /// <summary>
    /// The model a recording is cleaned up with unless another is picked: the same as live, going over the whole recording
    /// with a wider search. On a 15-minute test, large-v3 took three times as long and dropped two of eight turns.
    /// </summary>
    public const string CleanUpModel = DefaultModel;
    /// <summary>The Silero VAD model in <see cref="AppPaths.ModelsDirectory"/> that finds the speech.</summary>
    public const string VadModel = "ggml-silero-v6.2.0.bin";

    // Between the pieces of speech in a stretch, in place of the silence taken out.
    const int GapSamples = SampleRate / 5;
    // Whisper's word timings run early: a new speaker's first word kept going to whoever spoke before (14 of 33 turns in a
    // 15-minute test). Taken this much later, 3 of 33 did; 0.4 seconds did about as well, 0.6 as badly as none.
    const double WordLag = 0.2;
    // A speaker who never pauses is split into pieces no longer than this.
    static readonly TimeSpan LongestSpeech = TimeSpan.FromSeconds(30);
    // Lifting quiet speech: measured 20 ms at a time, raised toward this level (RMS) but by no more than MaxGain, and
    // the level heard falls to about a third in a second once it goes quiet.
    const int FrameSamples = SampleRate / 50;
    const float TargetLevel = 0.1f;
    const float MaxGain = 10;
    const float LevelFall = 0.98f;

    readonly Channel<float[]> _audio = Channel.CreateUnbounded<float[]>(new UnboundedChannelOptions { SingleReader = true });
    readonly TaskCompletionSource _loaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly Task<float[]> _work;

    /// <summary>Loads the models and starts listening for audio, on a background task.</summary>
    /// <param name="prompt">Names and words to expect (people, projects, jargon), so Whisper spells them right. May be empty.</param>
    /// <param name="onText">Each stretch of text with its speech audio (for speaker ID), in order, as it's ready. Called on a background thread.</param>
    /// <param name="stretchSeconds">
    /// How much speech builds up before it's written up. Whisper reads 30 seconds at a time however little it's given, so
    /// shorter stretches show text sooner but cost more: about a second each on a GPU, half a minute on a CPU.
    /// </param>
    /// <param name="pauseSeconds">How long speech has to stop for before a stretch can end there without cutting off a word.</param>
    /// <param name="liftQuietSpeech">Raise quiet speech (a speakerphone across the room) toward the level of speech at the mic.</param>
    /// <param name="flushSeconds">
    /// Ambient use: speech waiting to be transcribed is written up once this long passes with no new speech,
    /// instead of waiting for a full stretch to build (sparse speech would otherwise sit for hours). 0 = off.
    /// </param>
    /// <param name="splitTurns">
    /// Diarization-lite: given a stretch and its VAD pieces (start/end sample offsets), returns the sample offsets at
    /// which a different VOICE takes over -- empty for one voice. The stretch is then transcribed and emitted as one
    /// piece per voice turn, so a fast back-and-forth (replies quicker than the pause threshold) isn't glued into one
    /// utterance under one name. Null = off.
    /// </param>
    public Transcriber(string modelPath, string vadModelPath, string prompt, Action<string, float[]> onText, Action<string>? log,
        double stretchSeconds, double pauseSeconds, bool liftQuietSpeech, bool keepSpeech = true, double flushSeconds = 0,
        Func<float[], IReadOnlyList<(int Start, int End)>, int[]>? splitTurns = null, CancellationToken ct = default)
    {
        foreach (var path in new[] { modelPath, vadModelPath })
            if (!File.Exists(path) && !Directory.Exists(path)) throw new FileNotFoundException($"The speech model \"{path}\" isn't there.", path);
        _work = Task.Run(() => RunAsync(modelPath, vadModelPath, prompt.Trim(), onText, log, stretchSeconds, pauseSeconds, liftQuietSpeech, keepSpeech, flushSeconds, splitTurns, ct), ct);
    }

    /// <summary>
    /// Completes once the models have loaded, or throws why they couldn't. Audio added before then waits, so recording can
    /// start straight away; this says whether it'll be heard.
    /// </summary>
    public Task Ready => Task.WhenAny(_loaded.Task, _work).Unwrap();

    /// <summary>Adds audio that was just heard: 16 kHz mono samples. Returns at once. The array is kept, so don't change it after.</summary>
    public void Add(float[] samples) => _audio.Writer.TryWrite(samples);

    /// <summary>
    /// Says there's no more audio and waits for the rest to be transcribed. Returns all the speech heard, with the silence
    /// taken out, for <see cref="CleanUpAsync"/>. Throws whatever stopped the work, like a model that wouldn't load, or
    /// <see cref="OperationCanceledException"/> if it was cancelled.
    /// </summary>
    public async Task<float[]> CompleteAsync()
    {
        _audio.Writer.TryComplete();
        return await _work;
    }

    // (EmailTodo's CleanUpAsync re-pass is not carried over: an always-on listener keeps no
    // recording to clean up, which is also why keepSpeech is false here.)

    async Task<float[]> RunAsync(string modelPath, string vadModelPath, string prompt, Action<string, float[]> onText, Action<string>? log,
        double stretchSeconds, double pauseSeconds, bool liftQuietSpeech, bool keepSpeech, double flushSeconds,
        Func<float[], IReadOnlyList<(int Start, int End)>, int[]>? splitTurns, CancellationToken ct)
    {
        var clock = Stopwatch.StartNew();
        // Two speech engines behind one recognize() seam. A DIRECTORY is a sherpa-onnx NeMo
        // transducer (Parakeet TDT: encoder/decoder/joiner + tokens) -- a transducer can only emit
        // tokens aligned to actual audio frames, so the Whisper failure class (invented "Thank you."s,
        // repetition loops on junk) is impossible by construction. A .bin FILE is a Whisper GGML model.
        using var whisperFactory = Directory.Exists(modelPath) ? null : WhisperFactory.FromPath(modelPath);
        // TemperatureInc 0 disables whisper.cpp's fallback ladder (retry a failed window at ever
        // higher temperatures, up to 5 extra decodes). An ambient mic feeds plenty of junk -- music,
        // rumble, far-off TV -- and junk fails the quality checks EVERY time, so the ladder turns a
        // 2s stretch into a 25s decode just to produce a hallucination the filter drops anyway.
        // Real speech passes on the first try; hard audio gets one honest attempt.
        await using var whisper = whisperFactory == null ? null : BuildWhisper();
        using var parakeet = whisperFactory != null ? null : BuildParakeet();
        Func<float[], Task<string>> recognize = whisper != null
            ? async audio =>
            {
                var text = new StringBuilder();
                await foreach (var segment in whisper.ProcessAsync(audio, ct)) text.Append(segment.Text);
                return text.ToString();
            }
            : audio => Task.Run(() =>
            {
                using var stream = parakeet!.CreateStream();
                stream.AcceptWaveform(SampleRate, audio);
                parakeet.Decode(stream);
                return stream.Result.Text;
            }, ct);
        using var vadFactory = WhisperVadFactory.FromPath(vadModelPath);
        using var vad = vadFactory.CreateBuilder().WithMaxSpeechDuration(LongestSpeech).Build();
        log?.Invoke(whisper != null
            ? $"Loaded {Path.GetFileName(modelPath)} on {RuntimeOptions.LoadedLibrary} in {clock.Elapsed.TotalSeconds:0.0}s"
            : $"Loaded {Path.GetFileName(modelPath)} (NeMo transducer, no hallucination by construction) in {clock.Elapsed.TotalSeconds:0.0}s");
        _loaded.SetResult();

        WhisperProcessor BuildWhisper()
        {
            var builder = whisperFactory!.CreateBuilder().WithLanguage("en").WithTemperatureInc(0);
            if (prompt.Length > 0) builder = builder.WithPrompt(prompt);   // (Parakeet has no prompt: proper nouns ride on its own vocabulary)
            return builder.Build();
        }

        OfflineRecognizer BuildParakeet()
        {
            var config = new OfflineRecognizerConfig();
            config.ModelConfig.Transducer.Encoder = Path.Combine(modelPath, "encoder.int8.onnx");
            config.ModelConfig.Transducer.Decoder = Path.Combine(modelPath, "decoder.int8.onnx");
            config.ModelConfig.Transducer.Joiner = Path.Combine(modelPath, "joiner.int8.onnx");
            config.ModelConfig.Tokens = Path.Combine(modelPath, "tokens.txt");
            config.ModelConfig.ModelType = "nemo_transducer";
            config.ModelConfig.NumThreads = 2;   // same restraint as the other ONNX sessions: the ears must stay cheap
            config.ModelConfig.Provider = "cpu";
            config.DecodingMethod = "greedy_search";
            return new OfflineRecognizer(config);
        }

        // Heard but not yet in a stretch: speech still going on, or the last moment of quiet.
        var pending = new List<float>();
        // Speech that has ended, waiting to be transcribed.
        var stretch = new List<float>();
        // Where each VAD piece sits inside the stretch -- the only places a turn change can hide.
        var pieces = new List<(int Start, int End)>();
        // The stretches transcribed so far, for the clean-up.
        var stretches = new List<float[]>();
        // How much of pending the VAD has looked at.
        var looked = 0;
        var level = TargetLevel;
        var gain = 1f;
        var stretchGrewAt = TimeSpan.Zero;
        // Eager transcription: the stretch is parsed WHILE the flush clock decides whether the
        // speaker is done, so the finalized text is ready the moment the utterance is declared
        // over, instead of only starting then. Whisper runs are serialized: a new eager pass only
        // starts once the previous finished, and the emit path awaits any in-flight pass.
        Task<string>? eager = null;
        float[]? eagerAudio = null;

        await foreach (var block in _audio.Reader.ReadAllAsync(ct))
        {
            // The gain follows the level of the last moment: it drops at once when it gets loud and rises over a second
            // or two when it goes quiet. Loud speech is left as it is.
            if (liftQuietSpeech)
                for (var from = 0; from < block.Length; from += FrameSamples)
                {
                    var frame = block.AsSpan(from, Math.Min(FrameSamples, block.Length - from));
                    var sum = 0f;
                    foreach (var sample in frame) sum += sample * sample;
                    // (The microphone's packets are 10 ms, so a frame can be shorter than FrameSamples.)
                    level = Math.Max(MathF.Sqrt(sum / frame.Length), level * MathF.Pow(LevelFall, frame.Length / (float)FrameSamples));
                    var next = Math.Clamp(TargetLevel / level, 1, MaxGain);
                    for (var i = 0; i < frame.Length; i++)
                        frame[i] = Math.Clamp(frame[i] * (gain + (next - gain) * i / frame.Length), -1, 1);
                    gain = next;
                }
            pending.AddRange(block);
            if (pending.Count - looked < SampleRate) continue;   // look again once there's another second
            var had = stretch.Count;
            var speechGoing = TakeSpeech(all: false);
            looked = pending.Count;
            if (stretch.Count > had) stretchGrewAt = clock.Elapsed;
            // Eager passes only run while WAITING for the speaker to be declared done -- never while
            // speech is still coming in. During a continuous conversation each pass would re-parse the
            // whole growing stretch just to be superseded: measured 4+ cores saturated and real runs
            // queuing up to 55s behind the churn. Idle-wait parsing is the whole eager idea anyway.
            if (!speechGoing && stretch.Count > 0 && (eager == null || eager.IsCompleted) && eagerAudio?.Length != stretch.Count)
            {
                eagerAudio = stretch.ToArray();
                eager = recognize(eagerAudio);
            }
            if (stretch.Count >= stretchSeconds * SampleRate ||
                (flushSeconds > 0 && stretch.Count > 0 && (clock.Elapsed - stretchGrewAt).TotalSeconds > flushSeconds))
                await TranscribeAsync();
        }
        TakeSpeech(all: true);
        if (stretch.Count > 0) await TranscribeAsync();

        // All of it in one piece, the stretches apart as their pieces are.
        var whole = new float[stretches.Sum(s => s.Length) + Math.Max(0, stretches.Count - 1) * GapSamples];
        var at = 0;
        foreach (var piece in stretches)
        {
            piece.CopyTo(whole, at);
            at += piece.Length + GapSamples;
        }
        return whole;

        // Moves speech from pending to the stretch: the speech that has ended, or at the end, all of it.
        // Returns whether someone is still mid-speech (the VAD sees speech running into the lookahead).
        bool TakeSpeech(bool all)
        {
            var heard = pending.Count / (double)SampleRate;
            var taken = 0;
            int? going = null;
            foreach (var speech in vad.DetectSpeech(CollectionsMarshal.AsSpan(pending)))
            {
                // Pre-roll: the VAD latches onto speech a beat late on a far-field mic, clipping the
                // first word's head -- a one-syllable wake word ("Claude") can vanish entirely. Reach
                // back 0.4s before the detected onset; the buffer keeps a trailing second for exactly this.
                var start = Math.Clamp((int)(speech.Start.TotalSeconds * SampleRate) - (SampleRate * 2 / 5), taken, pending.Count);
                if (!all && speech.End.TotalSeconds > heard - pauseSeconds)
                {
                    going = start;
                    break;
                }
                var end = Math.Clamp((int)(speech.End.TotalSeconds * SampleRate), start, pending.Count);
                if (stretch.Count > 0) stretch.AddRange(new float[GapSamples]);
                var pieceStart = stretch.Count;
                stretch.AddRange(CollectionsMarshal.AsSpan(pending)[start..end]);
                pieces.Add((pieceStart, stretch.Count));
                taken = end;
            }
            // What's before speech still going on is done with. With none going on, the last second is kept in case some is starting.
            pending.RemoveRange(0, going ?? Math.Max(taken, pending.Count - SampleRate));
            return going != null;
        }

        async Task TranscribeAsync()
        {
            var started = clock.Elapsed;
            var audio = stretch.ToArray();
            var turns = pieces.ToArray();
            pieces.Clear();
            // An always-on listener (keepSpeech false) never cleans up afterward, so keeping
            // every stretch would grow without bound; a bounded recording keeps them for CleanUpAsync.
            if (keepSpeech) stretches.Add(audio);
            stretch.Clear();
            // Diarization-lite: a voice change inside the stretch means two turns got glued together
            // (the reply came quicker than the pause threshold). Cut at the changes and transcribe
            // each voice's run separately, so each percept carries one voice and one name.
            var cuts = Array.Empty<int>();
            if (splitTurns != null && turns.Length > 1)
                try { cuts = splitTurns(audio, turns); }
                catch (Exception ex) { log?.Invoke($"Turn split failed: {ex.Message}"); }
            if (cuts.Length > 0)
            {
                // The eager pass parsed the glued stretch; let it finish (one Whisper run at a time) and discard it.
                if (eager != null) try { await eager; } catch { /* superseded */ }
                eager = null;
                eagerAudio = null;
                var bounds = new List<int> { 0 };
                bounds.AddRange(cuts.Where(c => c > 0 && c < audio.Length));
                bounds.Add(audio.Length);
                var spoke = 0;
                for (var i = 0; i + 1 < bounds.Count; i++)
                {
                    var part = audio[bounds[i]..bounds[i + 1]];
                    var partText = await recognize(part);
                    if (partText.Trim() is { Length: > 0 } said) { onText(said, part); spoke++; }
                }
                log?.Invoke($"Transcribed {audio.Length / (double)SampleRate:0.0}s of speech in {(clock.Elapsed - started).TotalSeconds:0.0}s, " +
                            $"split into {bounds.Count - 1} voice turns ({spoke} spoke)");
                return;
            }
            string text;
            if (eager != null && eagerAudio?.Length == audio.Length)
            {
                // The eager pass covered the whole utterance: usually already done, so the text
                // was ready before the flush clock even declared the utterance over.
                var wasDone = eager.IsCompleted;
                text = await eager;
                log?.Invoke($"Transcribed {audio.Length / (double)SampleRate:0.0}s of speech " +
                            (wasDone ? "during the wait (0.0s after flush)" : $"in {(clock.Elapsed - started).TotalSeconds:0.0}s (eager, still finishing)"));
            }
            else
            {
                // The stretch grew after the last eager pass started: let it finish (one Whisper
                // run at a time), discard it, and parse the full stretch.
                if (eager != null) try { await eager; } catch { /* superseded */ }
                text = await recognize(audio);
                log?.Invoke($"Transcribed {audio.Length / (double)SampleRate:0.0}s of speech in {(clock.Elapsed - started).TotalSeconds:0.0}s");
            }
            eager = null;
            eagerAudio = null;
            if (text.Trim() is { Length: > 0 } heardText) onText(heardText, audio);
        }

    }
}
