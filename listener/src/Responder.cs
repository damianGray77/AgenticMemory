using System.Diagnostics;
using System.Media;
using System.Speech.Synthesis;
using System.Text.RegularExpressions;
using SherpaOnnx;

namespace Listener;

/// <summary>
/// The mouth. Decides which utterances are FOR Claude -- a wake word (matched phonetically, since
/// Whisper renders "Claude" as Claud/clawed/clod/clot/cloud), an utterance inside the rolling
/// conversation window after any exchange, or a direct hand-off from the addressee detector -- and
/// sends just those to a headless Claude on a small fast model, speaking the reply aloud.
/// Engagement is a rolling state, not a countdown from the wake word: a bare "Claude." buys a long
/// think-time window for the question, and every spoken reply re-opens a follow-up window, so
/// dialogue flows without re-waking. Single-flight: one spoken exchange at a time, and while Claude
/// is speaking the microphone is gated off (see Program) so the reply is not transcribed back.
/// </summary>
public sealed partial class Responder : IDisposable
{
    /// <summary>How an utterance was (or wasn't) taken as addressed to Claude.</summary>
    public enum Took { No, Wake, BareWake, Conversation, Disengaged, Correction }

    // The phonetic shape of "Claude" as Whisper mishears it: cl + vowels + optional w + vowels +
    // d/t, with optional trailing e/d ("clawed"). Catches claude/claud/clawed/clod/clot/cloud
    // without listing them; "close"/"cloth"/"cold" don't fit the shape.
    [GeneratedRegex("^cl[aeou]{1,2}w?[aeou]{0,2}[dt][ed]?$", RegexOptions.IgnoreCase)]
    private static partial Regex WakeShape();

    /// <summary>True when any word of the utterance is phonetically "Claude" -- also an addressee-detector feature.</summary>
    public static bool MentionsClaude(string text) =>
        text.Split(' ', ',', '.', ':', ';', '!', '?').Any(w => w.Length > 0 && WakeShape().IsMatch(w));

    /// <summary>The request without its leading wake word ("" for a bare wake), or null when none leads.
    /// What the addressee detector trains on: the sentence as it would sound with no name said.</summary>
    public static string? StripWake(string text) => MatchWake(text);

    readonly Brain _brain;                         // the persistent headless Claude session
    readonly Func<string> _context;
    readonly Action<bool> _speaking;
    readonly Action? _exchanged;                   // tells the addressee detector an exchange happened
    readonly Action<string>? _misfire;             // negative feedback: "not_for_me" self-judgment
    readonly Action<string>? _queueTask;           // [TASK] hand-off: insert into voice_tasks
    readonly Action<string>? _log;
    readonly SemaphoreSlim _oneAtATime = new(1, 1);
    DateTime _lastAsked = DateTime.MinValue;       // ambient context goes along only when stale
    readonly double _awaitSeconds;                 // think time after a bare "Claude." -> "Yes?"
    readonly double _conversationSeconds;          // follow-up window after each spoken reply (rolling)
    DateTime _engagedUntil = DateTime.MinValue;
    static readonly string[] Disengagers = ["never mind", "nevermind", "that's all", "thats all", "stop listening", "go to sleep"];
    // "I'm sorry, I wasn't talking to you" -- gold-standard negative feedback. The misfire that
    // provoked it gets retro-labeled as a hard negative (see Program), and Claude bows out.
    static readonly string[] Corrections =
    [
        "wasn't talking to you", "not talking to you", "wasn't asking you", "not asking you",
        "wasn't for you", "not for you", "didn't mean you", "not you, claude", "wasn't talking to claude",
    ];
    readonly SpeechSynthesizer _sapi = new();      // the fallback voice
    readonly OfflineTts? _kokoro;                  // the voice with personality (sherpa-onnx), when its model is there
    PronunciationLexicon? _lexicon;                // pre-TTS word lookup; unknown words get a guess added
    int _kokoroVoice;
    float _kokoroSpeed;

    /// <summary>The Kokoro speaker id, hot-reloadable: edit TtsVoice in listener.json and the next
    /// reply speaks with the new voice (the daemon's poll loop pushes changes here). No restart.
    /// NOTE: after settling on a voice, re-run Listener.exe enroll-tts so the "claude" self-voice
    /// profile matches what actually comes out of the speaker.</summary>
    public int TtsVoice
    {
        get => _kokoroVoice;
        set { if (value != _kokoroVoice) { _kokoroVoice = value; _log?.Invoke($"TTS voice -> {value}"); } }
    }

    /// <summary>Speech rate, hot-reloadable like TtsVoice (0.9 = a touch slower and often clearer).</summary>
    public float TtsSpeed
    {
        get => _kokoroSpeed;
        set { if (Math.Abs(value - _kokoroSpeed) > 0.001f) { _kokoroSpeed = value; _log?.Invoke($"TTS speed -> {value:0.00}"); } }
    }

    // The standing instructions the voice session gets once, at spawn -- not per query.
    const string Instructions =
        "You are Claude, {{USER_NAME}}'s always-on voice assistant on his work machine. Every later message in this " +
        "conversation is one utterance picked up by the room microphone and transcribed by Whisper, so expect " +
        "occasional garbling; some messages carry recent ambient room context too. You answer out loud through " +
        "text-to-speech: one to three short conversational sentences of plain text. No markdown, no lists, no " +
        "code blocks, no stage directions.\n\n" +
        "You have read-only tools: memdb (SQLite CLI over the claude_memory database at " +
        "\"{{MEMDB_POSIX}}\" -e \"<SQL>\") with tables memories, session_notes, sessions, " +
        "percepts (what you've heard in the room), reflections, reflection_threads, digest_lines; full-text " +
        "search via <table>_fts with fts_any('words'). Use a lookup when the question needs one, keep it to a " +
        "couple of quick LIMITed queries, and never write to the database. The schema is at " +
        @"{{CLAUDE_HOME_WIN}}\claude_memory_schema.sql" + " if you need it.\n\n" +
        "When you are about to use a tool, FIRST write one short sentence saying what you're checking (\"Let me " +
        "check the notes.\") -- it is spoken aloud while the lookup runs, so {{USER_NAME}} isn't left in silence.\n\n" +
        "Control outputs -- when one applies it must be the VERY FIRST characters of the reply:\n" +
        "[NOT_FOR_ME] -- alone, ONLY when the message is explicitly marked as picked up without a wake word " +
        "AND it clearly was not addressed to you (overheard conversation, muttering at the screen, media). " +
        "Nothing else. NEVER use it for an unmarked message: those carried your wake word, so they are for " +
        "you even when they talk ABOUT you or your plumbing -- answer them.\n" +
        "[TASK] <one-line restatement of the request> -- when {{USER_NAME}} asks for real WORK: changing code or " +
        "files, commits, running or scheduling jobs, tickets, emails, anything beyond conversation and quick " +
        "lookups. Do not attempt the work; that line hands it to a background worker session that starts on " +
        "it immediately, speaks its result here when done, and appears in {{USER_NAME}}'s Claude desktop app. The " +
        "marker and restatement must be your FIRST line (never at the end); anything you put on the lines " +
        "AFTER it is spoken aloud to {{USER_NAME}} as your acknowledgment.\n\n" +
        "Reply with just: ready";

    public Responder(string claudePath, string model, string settingsPath, string kokoroDir, int kokoroVoice, float kokoroSpeed,
        double awaitSeconds, double conversationSeconds,
        Func<string> context, Action<bool> speaking, Action? exchanged, Action<string>? misfire, Action<string>? queueTask, Action<string>? log)
    {
        _brain = new Brain(claudePath, model, settingsPath, Instructions, log);
        _awaitSeconds = awaitSeconds;
        _conversationSeconds = conversationSeconds;
        _context = context;
        _speaking = speaking;
        _exchanged = exchanged;
        _misfire = misfire;
        _queueTask = queueTask;
        _log = log;
        _ = _brain.WarmUpAsync();   // first question shouldn't pay the spawn cost
        _kokoroVoice = kokoroVoice;
        _kokoroSpeed = kokoroSpeed;
        _sapi.SetOutputToDefaultAudioDevice();
        if (File.Exists(Path.Combine(kokoroDir, "model.onnx")))
        {
            var config = new OfflineTtsConfig();
            config.Model.Kokoro.Model = Path.Combine(kokoroDir, "model.onnx");
            config.Model.Kokoro.Voices = Path.Combine(kokoroDir, "voices.bin");
            config.Model.Kokoro.Tokens = Path.Combine(kokoroDir, "tokens.txt");
            config.Model.Kokoro.DataDir = Path.Combine(kokoroDir, "espeak-ng-data");
            // The multi-lang v1.0 layout: sherpa-onnx 2.x tokenizes English through these lexicons.
            // lexicon-custom.txt (auto-grown by PronunciationLexicon) goes last so its entries win.
            var lexicons = new[] { "lexicon-us-en.txt", "lexicon-gb-en.txt", PronunciationLexicon.CustomFileName }
                .Select(f => Path.Combine(kokoroDir, f)).Where(File.Exists).ToArray();
            _lexicon = new PronunciationLexicon(kokoroDir, log);
            if (lexicons.Length > 0) config.Model.Kokoro.Lexicon = string.Join(",", lexicons);
            var dict = Path.Combine(kokoroDir, "dict");
            if (Directory.Exists(dict)) config.Model.Kokoro.DictDir = dict;
            config.Model.NumThreads = 4;
            _kokoro = new OfflineTts(config);
        }
        log?.Invoke($"Responder ready (wake shape: cl~d phonetic match; model {model}; " +
                    $"voice {(_kokoro != null ? $"Kokoro #{kokoroVoice}" : "SAPI fallback")})");
    }

    /// <summary>Whether the room is mid-conversation with Claude (an utterance now would be taken as dialogue).</summary>
    public bool Engaged => DateTime.Now <= _engagedUntil;

    /// <summary>
    /// Takes the utterance if it is for Claude: a wake word starts an exchange, a bare wake word
    /// answers "Yes?" and waits generously for the question, and anything said while engaged is
    /// conversation. Returns how it was taken, so the caller can label the training example.
    /// </summary>
    public Took TryRespond(string utterance)
    {
        var (query, how) = (MatchWake(utterance), Took.Wake);
        if (query == null && Engaged) (query, how) = (utterance.Trim(), Took.Conversation);
        if (query == null) return Took.No;
        var bare = query.ToLowerInvariant().Trim('.', ',', '!', '?', ' ');
        if (Corrections.Any(bare.Contains))
        {
            _engagedUntil = DateTime.MinValue;
            _log?.Invoke($"Corrected -- that reply was a misfire: {utterance.Trim()}");
            Speak("Sorry about that.");
            return Took.Correction;
        }
        if (Disengagers.Any(d => bare == d || bare.EndsWith(" " + d)))
        {
            _engagedUntil = DateTime.MinValue;
            _log?.Invoke($"Disengaged by: {utterance.Trim()}");
            return Took.Disengaged;
        }
        if (query.Length == 0)
        {
            // A bare "Claude." -- acknowledge, then leave a generous rolling window for the
            // question itself. People pause to think after saying the name; the old fixed 15s
            // raced them. The window also survives the idle flush splitting name from question.
            _engagedUntil = DateTime.Now.AddSeconds(_awaitSeconds);
            Speak("Yes?");
            _log?.Invoke($"Bare wake; listening for the question for {_awaitSeconds:0}s (rolling).");
            return Took.BareWake;
        }
        // A wake word is explicit address; conversation-window speech is inferred, so the answering
        // model double-checks it and declines overheard speech with [NOT_FOR_ME] (negative feedback).
        Launch(query, selfJudge: how == Took.Conversation, utterance);
        return how;
    }

    /// <summary>The addressee detector's entry: respond to this utterance although no wake word was
    /// heard. Inferred address, so the answering model gets the [NOT_FOR_ME] escape hatch.</summary>
    public void RespondDirect(string query) => Launch(query.Trim(), selfJudge: true, query);

    /// <summary>The day-mind's voice: a short clarifying question about something just noticed,
    /// spoken aloud with the conversation window left open, so the answer is heard without a wake
    /// word. {{USER_NAME}} invited these ("feel free to ask"); the caller keeps them rare. Returns false
    /// without speaking when an exchange is running or a conversation is live -- curiosity never
    /// interrupts.</summary>
    public bool AskAloud(string question)
    {
        if (Engaged || !_oneAtATime.Wait(0)) return false;
        try { Answered(question); }
        finally
        {
            _oneAtATime.Release();
            if (Interlocked.Exchange(ref _held, null) is { } held) TryRespond(held);
        }
        return true;
    }

    string? _held;   // speech that arrived mid-exchange: answered next, not dropped

    void Launch(string query, bool selfJudge, string utterance)
    {
        if (!_oneAtATime.Wait(0))
        {
            // Mid-exchange speech is usually a follow-up or a correction -- hold the latest one
            // and run it through the full pipeline once this exchange finishes.
            Volatile.Write(ref _held, utterance);
            _log?.Invoke($"Busy; holding for after this exchange: {utterance.Trim()}");
            return;
        }
        _ = Task.Run(async () =>
        {
            try { await RespondAsync(query, selfJudge); }
            catch (Exception ex) { _log?.Invoke($"Responder failed: {ex.Message}"); }
            finally
            {
                _oneAtATime.Release();
                if (Interlocked.Exchange(ref _held, null) is { } held) TryRespond(held);
            }
        });
    }

    /// <summary>The query after the wake word, "" for a bare wake word, or null when no wake word starts the utterance.</summary>
    static string? MatchWake(string text)
    {
        var t = text.Trim();
        foreach (var lead in new[] { "hey ", "ok ", "okay " })
            if (t.StartsWith(lead, StringComparison.OrdinalIgnoreCase)) { t = t[lead.Length..].TrimStart(); break; }
        var end = t.IndexOfAny([' ', ',', '.', ':', ';', '!', '?']);
        var first = end < 0 ? t : t[..end];
        if (!WakeShape().IsMatch(first)) return null;
        return (end < 0 ? "" : t[end..]).TrimStart(',', '.', ':', ';', '!', '?', ' ').Trim();
    }

    async Task RespondAsync(string query, bool selfJudge)
    {
        _log?.Invoke($"Asking Claude: {query}");
        // The session is persistent, so instructions were sent once at spawn. Ambient room context
        // rides along only when the conversation has been quiet a while (or on inferred address).
        var stale = (DateTime.Now - _lastAsked).TotalMinutes > 5;
        _lastAsked = DateTime.Now;
        var message =
            (selfJudge ? "(picked up with NO wake word -- may not be addressed to you)\n" : "") +
            (stale || selfJudge ? "Recent room context (rough transcription):\n" + _context() + "\n\n" : "") +
            $"{{USER_NAME}} said: \"{query}\"";

        var clock = Stopwatch.StartNew();
        // Speech streams: the mouth starts on sentence one while the brain is still writing.
        var stream = new SpokenStream(this);
        var reply = await _brain.AskAsync(message, TimeSpan.FromSeconds(60), stream.OnText);
        await stream.FinishAsync();

        if (stream.NotForMe)
        {
            if (selfJudge)
            {
                // The answering model judged the utterance overheard, not addressed. Say nothing,
                // close the conversation, and hand the learner a negative example.
                _log?.Invoke($"Self-judged not addressed to Claude ({clock.Elapsed.TotalSeconds:0.0}s); staying quiet.");
                _engagedUntil = DateTime.MinValue;
                _misfire?.Invoke("not_for_me");
                return;
            }
            // A wake-worded query is explicitly addressed -- declining it is not the brain's call
            // (it happened once: {{USER_NAME}} complained ABOUT the system TO the system and got silence).
            _log?.Invoke("Brain declined an explicitly-addressed query; retrying with a nudge.");
            stream = new SpokenStream(this);
            reply = await _brain.AskAsync(
                "That message WAS addressed to you -- {{USER_NAME}} used your wake word. Answer it now, with no control marker.",
                TimeSpan.FromSeconds(60), stream.OnText);
            await stream.FinishAsync();
            if (stream.NotForMe || (!stream.SpokeAnything && string.IsNullOrEmpty(reply)))
            {
                Answered("Sorry, I lost that one. Say it again?");
                return;
            }
        }
        if (stream.TaskLine is { Length: > 0 } request)
        {
            // Real work: hand it to the main working session instead of attempting it by voice.
            _log?.Invoke($"Task queued for the main session ({clock.Elapsed.TotalSeconds:0.0}s): {request}");
            _queueTask?.Invoke(request);
            Answered(stream.TaskTail is { Length: > 0 } tail ? tail : "Got it. I've queued that for the main session.");
            return;
        }
        if (stream.SpokeAnything)
        {
            // Already spoken, sentence by sentence; just roll the conversation window forward.
            _log?.Invoke($"Reply in {clock.Elapsed.TotalSeconds:0.0}s (streamed): {reply ?? "(no final text)"}");
            _engagedUntil = DateTime.Now.AddSeconds(_conversationSeconds);
            _exchanged?.Invoke();
            return;
        }
        // Nothing streamed (no partial events, or an empty turn): fall back to the whole reply.
        if (string.IsNullOrEmpty(reply)) { Answered("Sorry, I couldn't come up with an answer."); return; }
        if (reply.StartsWith("[NOT_FOR_ME]", StringComparison.OrdinalIgnoreCase)) { _engagedUntil = DateTime.MinValue; if (selfJudge) _misfire?.Invoke("not_for_me"); return; }
        if (reply.StartsWith("[TASK]", StringComparison.OrdinalIgnoreCase))
        {
            var req = reply["[TASK]".Length..].Trim();
            _queueTask?.Invoke(req.Split('\n')[0].Trim());
            Answered("Got it. I've queued that for the main session.");
            return;
        }
        _log?.Invoke($"Reply in {clock.Elapsed.TotalSeconds:0.0}s: {reply}");
        Answered(reply);
    }

    /// <summary>Speak a reply and keep the conversation open: the engagement window rolls forward
    /// from the END of speaking, so a follow-up never needs the wake word again.</summary>
    void Answered(string reply)
    {
        Speak(reply);
        _engagedUntil = DateTime.Now.AddSeconds(_conversationSeconds);
        _exchanged?.Invoke();
    }

    void Speak(string text)
    {
        _speaking(true);
        try { PlayChunk(TryGenerateWav(text, 0), text); }
        finally { _speaking(false); }
    }

    /// <summary>Synthesize one chunk to its own wav (null = Kokoro unavailable/failed; SAPI will cover).</summary>
    string? TryGenerateWav(string text, int n)
    {
        if (_kokoro == null) return null;
        try
        {
            // Kokoro drops words on long or symbol-heavy input, so feed it short, normalized pieces
            // and stitch the audio back together with a short pause between them.
            var samples = new List<float>();
            var rate = 24000;
            var normalized = NormalizeForTts(text);
            _lexicon?.EnsureWords(normalized);
            foreach (var piece in SplitForTts(normalized))
            {
                var audio = _kokoro.Generate(piece, _kokoroSpeed, _kokoroVoice);
                if (audio.Samples.Length == 0) continue;
                rate = audio.SampleRate;
                samples.AddRange(audio.Samples);
                samples.AddRange(new float[rate / 12]);   // ~80 ms gap
            }
            var wav = $@"{{LISTENER_ROOT_WIN}}\reply{(n > 0 ? "-" + n : "")}.wav";
            if (samples.Count == 0 || !WritePcm16Wav(wav, samples, rate))
                throw new InvalidOperationException($"Kokoro produced {samples.Count} samples; save failed");
            return wav;
        }
        catch (Exception ex)
        {
            _log?.Invoke($"Kokoro failed ({ex.Message}); using SAPI for: {text}");
            return null;
        }
    }

    const int MaxTtsChunk = 140;   // chars; beyond this Kokoro starts skipping words

    /// <summary>Replace tokens the phonemizer mangles (markdown, URLs, symbols, odd punctuation) with speakable text.</summary>
    static string NormalizeForTts(string text)
    {
        var s = text;
        s = System.Text.RegularExpressions.Regex.Replace(s, @"https?://\S+", "a link");
        s = System.Text.RegularExpressions.Regex.Replace(s, @"[`*_#>~|^]+", " ");
        s = s.Replace('‘', '\'').Replace('’', '\'').Replace('“', '"').Replace('”', '"')
             .Replace("…", ".").Replace("—", ", ").Replace("–", ", ").Replace(" - ", ", ")
             .Replace("&", " and ").Replace("%", " percent").Replace("+", " plus ").Replace("=", " equals ")
             .Replace("@", " at ").Replace("/", " slash ").Replace("\\", " ").Replace("\"", "")
             .Replace("(", ", ").Replace(")", ", ").Replace("[", " ").Replace("]", " ")
             .Replace("{", " ").Replace("}", " ").Replace("<", " ").Replace(";", ",").Replace(":", ",");
        s = System.Text.RegularExpressions.Regex.Replace(s, @"(?<=\w)_(?=\w)", " ");
        s = System.Text.RegularExpressions.Regex.Replace(s, @"[^ -~À-ɏ]", " ");   // emoji, control chars
        s = System.Text.RegularExpressions.Regex.Replace(s, @"\s*,(\s*,)+", ",");
        s = System.Text.RegularExpressions.Regex.Replace(s, @"\s+", " ").Trim();
        return s;
    }

    /// <summary>Cut text into short pieces at sentence ends, then commas, then spaces.</summary>
    static IEnumerable<string> SplitForTts(string text)
    {
        var parts = System.Text.RegularExpressions.Regex.Split(text, @"(?<=[.!?])\s+");
        foreach (var part in parts)
        {
            var rest = part.Trim();
            while (rest.Length > MaxTtsChunk)
            {
                var cut = rest.LastIndexOf(", ", MaxTtsChunk, StringComparison.Ordinal);
                if (cut < MaxTtsChunk / 3) cut = rest.LastIndexOf(' ', MaxTtsChunk);
                if (cut < 1) cut = MaxTtsChunk;
                yield return rest[..(cut + 1)].Trim();
                rest = rest[(cut + 1)..].Trim();
            }
            if (rest.Length > 0 && rest.Any(char.IsLetterOrDigit)) yield return rest;
        }
    }

    static bool WritePcm16Wav(string path, List<float> samples, int rate)
    {
        try
        {
            using var w = new BinaryWriter(File.Create(path));
            var bytes = samples.Count * 2;
            w.Write("RIFF"u8); w.Write(36 + bytes); w.Write("WAVEfmt "u8);
            w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write("data"u8); w.Write(bytes);
            foreach (var f in samples) w.Write((short)(Math.Clamp(f, -1f, 1f) * 32767));
            return true;
        }
        catch { return false; }
    }

    void PlayChunk(string? wav, string text)
    {
        try
        {
            _log?.Invoke($"Speaking ({(wav != null ? "Kokoro" : "SAPI")}): {text}");
            if (wav != null) { using var player = new SoundPlayer(wav); player.PlaySync(); }
            else _sapi.Speak(text);
        }
        catch (Exception ex)
        {
            _log?.Invoke($"Speaking failed ({ex.Message}); falling back to SAPI");
            try { _sapi.Speak(text); } catch { }
        }
    }

    /// <summary>
    /// The streamed mouth: consumes raw text deltas from the brain, holds the first characters just
    /// long enough to rule out a control marker, then cuts complete sentences and runs them through
    /// a two-stage pipeline -- Kokoro synthesizes sentence N+1 while sentence N is still playing --
    /// so speech starts when the FIRST sentence is ready, not when the whole reply is.
    /// </summary>
    sealed class SpokenStream(Responder r)
    {
        const int MinChunk = 30;   // merge tiny fragments ("Ha.") into the next sentence
        readonly System.Collections.Concurrent.BlockingCollection<Task<(string? Wav, string Text)>> _queue = new();
        readonly System.Text.StringBuilder _buf = new();
        readonly object _gate = new();
        Task _synthTail = Task.CompletedTask;
        Task? _player;
        int _chunk;
        bool _decided, _silent;

        public bool NotForMe { get; private set; }
        public string? TaskLine { get; private set; }    // the [TASK] restatement (first line)
        public string? TaskTail { get; private set; }    // anything the brain said after it (spoken)
        public bool SpokeAnything { get; private set; }

        public void OnText(string delta)
        {
            lock (_gate)
            {
                _buf.Append(delta);
                if (!_decided)
                {
                    var s = _buf.ToString().TrimStart();
                    if (s.Length == 0) return;
                    if (s.StartsWith("[NOT_FOR_ME]", StringComparison.OrdinalIgnoreCase)) { NotForMe = true; _silent = true; _decided = true; return; }
                    if (s.StartsWith("[TASK]", StringComparison.OrdinalIgnoreCase)) { _silent = true; _decided = true; return; }
                    if (s[0] == '[' && s.Length < 13) return;   // could still become a marker; hold
                    _decided = true;
                }
                if (!_silent) EmitSentences(final: false);
            }
        }

        void EmitSentences(bool final)
        {
            while (true)
            {
                var text = _buf.ToString();
                var cut = -1;
                for (var i = 0; i < text.Length - 1; i++)
                    if (text[i] is '.' or '!' or '?' && char.IsWhiteSpace(text[i + 1]) && i + 1 >= MinChunk) { cut = i + 1; break; }
                if (cut < 0) break;
                Enqueue(text[..cut].Trim());
                _buf.Remove(0, cut);
            }
            if (final)
            {
                var rest = _buf.ToString().Trim();
                _buf.Clear();
                if (rest.Length > 0) Enqueue(rest);
            }
        }

        void Enqueue(string sentence)
        {
            SpokeAnything = true;
            _player ??= Task.Run(PlayLoop);
            var n = ++_chunk;
            // Chained, not parallel: one Kokoro at a time, but always one sentence ahead of playback.
            var synth = _synthTail.ContinueWith(_ => (r.TryGenerateWav(sentence, n), sentence),
                TaskContinuationOptions.ExecuteSynchronously);
            _synthTail = synth;
            _queue.Add(synth);
        }

        void PlayLoop()
        {
            r._speaking(true);
            try
            {
                foreach (var synth in _queue.GetConsumingEnumerable())
                {
                    var (wav, text) = synth.GetAwaiter().GetResult();
                    r.PlayChunk(wav, text);
                }
            }
            finally { r._speaking(false); }
        }

        /// <summary>Flush the tail, close the queue, wait for the last chunk to finish playing.</summary>
        public async Task FinishAsync()
        {
            lock (_gate)
            {
                if (_silent && !NotForMe)
                {
                    var s = _buf.ToString().TrimStart();
                    var body = s["[TASK]".Length..].Trim();
                    var lineEnd = body.IndexOf('\n');
                    TaskLine = (lineEnd < 0 ? body : body[..lineEnd]).Trim();
                    TaskTail = lineEnd < 0 ? null : body[(lineEnd + 1)..].Trim();
                    _buf.Clear();
                }
                else if (!_silent) EmitSentences(final: true);
            }
            _queue.CompleteAdding();
            if (_player is { } p) await p;
        }
    }

    public void Dispose()
    {
        _brain.Dispose();
        _kokoro?.Dispose();
        _sapi.Dispose();
        _oneAtATime.Dispose();
    }
}
