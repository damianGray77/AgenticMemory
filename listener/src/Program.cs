using System.Text.Json;
using Listener;
using Microsoft.Data.Sqlite;

// Listener -- Claude's ambient hearing (see percepts in claude_memory_schema.sql).
// Captures the default microphone continuously (WASAPI -> Silero VAD -> Whisper, the
// pipeline proven in EmailTodo), and writes each stretch of transcribed speech as a
// row in the percepts table of the claude_memory database. Raw audio never touches
// disk. A file named MUTE in the root directory silences capture while it exists.
// Rows older than percept_retention_days (consolidation_config) are pruned daily.

const string Root = @"{{LISTENER_ROOT_WIN}}";
var configPath = Path.Combine(Root, "listener.json");
var mutePath = Path.Combine(Root, "MUTE");
var config = File.Exists(configPath)
    ? JsonSerializer.Deserialize<Config>(File.ReadAllText(configPath)) ?? new Config()
    : new Config();

// "Listener.exe enroll <name> [variant]" records ~25s of the named person reading aloud and saves
// their voice fingerprint; the always-on daemon then tags their percepts by name. Run it in a visible
// terminal while the daemon keeps running (capture is shared); the daemon is muted meanwhile.
// A variant ("laptop", "headset") saves an EXTRA fingerprint for the same person under
// voices\<name>-<variant>.json -- one per microphone/condition. Identify scores against every
// fingerprint and takes the best, so a mic-matched profile wins without diluting the others;
// strictly better than averaging two mics' colorings into one blurred vector. Without a variant,
// the base <name>.json is replaced, as before.
if (args.Length >= 1 && args[0].Equals("enroll", StringComparison.OrdinalIgnoreCase))
{
    await Enroll(args.Length > 1 ? args[1].ToLowerInvariant() : "{{USER_NAME_LOWER}}",
        args.Length > 2 ? args[2].ToLowerInvariant() : "");
    return;
}

// "Listener.exe enroll-tts [name] [variant]" fingerprints Claude's OWN Kokoro voice (config.TtsVoice)
// as the profile "claude", so the daemon can leave the mic open while speaking: self-heard replies tag
// [claude] and are stored but never answered -- no feedback loop, no deaf window. Re-run this
// after changing TtsVoice so the profile matches the voice actually coming out of the speaker.
// With a variant ("laptop"), the sentences are PLAYED through the speakers and the fingerprint is
// taken from what the microphone hears back -- speaker coloring, room and mic chain included --
// saved alongside as voices\<name>-<variant>.json. The digital fingerprint alone missed by a whisker
// on the laptop chain (own speech at 0.73 self vs 0.75 against {{USER_NAME_LOWER}}: feedback). Runs unattended.
if (args.Length >= 1 && args[0].Equals("enroll-tts", StringComparison.OrdinalIgnoreCase))
{
    await EnrollTts(args.Length > 1 ? args[1].ToLowerInvariant() : "claude",
        args.Length > 2 ? args[2].ToLowerInvariant() : "");
    return;
}

async Task EnrollTts(string name, string variant = "")
{
    var dir = Path.Combine(Root, "models", "kokoro");
    var tts = new SherpaOnnx.OfflineTtsConfig();
    tts.Model.Kokoro.Model = Path.Combine(dir, "model.onnx");
    tts.Model.Kokoro.Voices = Path.Combine(dir, "voices.bin");
    tts.Model.Kokoro.Tokens = Path.Combine(dir, "tokens.txt");
    tts.Model.Kokoro.DataDir = Path.Combine(dir, "espeak-ng-data");
    var lexicons = new[] { "lexicon-us-en.txt", "lexicon-gb-en.txt" }
        .Select(f => Path.Combine(dir, f)).Where(File.Exists).ToArray();
    if (lexicons.Length > 0) tts.Model.Kokoro.Lexicon = string.Join(",", lexicons);
    var dict = Path.Combine(dir, "dict");
    if (Directory.Exists(dict)) tts.Model.Kokoro.DictDir = dict;
    tts.Model.NumThreads = 4;
    using var kokoro = new SherpaOnnx.OfflineTts(tts);
    // Sentence-sized Generate calls, like the responder makes: one long paragraph stalled it.
    string[] sample =
    [
        "Hello, this is the sound of my own voice, recorded so the listener can recognize me.",
        "When I answer out loud, the microphone stays open, and anything matching this fingerprint is me talking.",
        "That way you can interrupt me mid-sentence and still be heard.",
        "The quick brown fox jumps over the lazy dog, while the five boxing wizards jump quickly.",
        "She sells seashells by the seashore, and the rain in Spain stays mainly on the plain.",
    ];
    if (variant.Length > 0)
    {
        // Mic-heard: speak the sentences into the room and fingerprint what comes back. The daemon
        // is muted meanwhile (same trick as human enrollment), so the playback stays out of percepts.
        var hadMute = File.Exists(mutePath);
        if (!hadMute) File.Create(mutePath).Dispose();
        var wav = Path.Combine(Root, "enroll-tts-heard.wav");
        try
        {
            var heard = new List<float>();
            Console.WriteLine($"Playing {sample.Length} sentences through the speakers and listening back...");
            using (var mic = await Microphone.StartAsync(config.Microphone, s => { lock (heard) heard.AddRange(s); }))
            {
                await Task.Delay(500);
                foreach (var sentence in sample)
                {
                    var spoken = kokoro.Generate(sentence, config.TtsSpeed, config.TtsVoice);
                    if (spoken.Samples.Length == 0 || !spoken.SaveToWaveFile(wav)) { Console.WriteLine($"  Kokoro produced nothing for: {sentence[..Math.Min(40, sentence.Length)]}..."); continue; }
                    Console.WriteLine($"  Speaking: {sentence[..Math.Min(40, sentence.Length)]}...");
                    using (var player = new System.Media.SoundPlayer(wav)) player.PlaySync();
                    await Task.Delay(400);   // let the room's tail reach the mic before the next line
                }
                await Task.Delay(500);
            }
            float[] captured;
            lock (heard) captured = heard.ToArray();
            Console.WriteLine($"Heard {captured.Length / (double)Transcriber.SampleRate:0.0}s back. Computing fingerprint...");
            using var voiceId = new SpeakerId(Path.Combine(Root, "models", config.SpeakerModel), Path.Combine(Root, "voices"),
                config.SpeakerThreshold, null);
            var piece = 8 * Transcriber.SampleRate;
            var pieces = new List<float[]>();
            for (var at = 0; at + piece <= captured.Length; at += piece / 2)
                pieces.Add(captured[at..(at + piece)]);
            if (pieces.Count == 0) { Console.WriteLine("Not enough audio heard back; is the volume up?"); return; }
            var heardProfile = new SpeakerId.Profile(name, voiceId.AverageEmbedding(pieces), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            Directory.CreateDirectory(Path.Combine(Root, "voices"));
            File.WriteAllText(Path.Combine(Root, "voices", $"{name}-{variant}.json"), JsonSerializer.Serialize(heardProfile));
            Console.WriteLine($"Saved voices\\{name}-{variant}.json from {pieces.Count} chunks. Restart the listener to load it.");
        }
        finally
        {
            if (!hadMute && File.Exists(mutePath)) File.Delete(mutePath);
            if (File.Exists(wav)) File.Delete(wav);
        }
        return;
    }

    var samples = new List<float>();
    var rate = 24000;
    foreach (var sentence in sample)
    {
        var audio = kokoro.Generate(sentence, config.TtsSpeed, config.TtsVoice);
        Console.WriteLine($"  {audio.Samples.Length} samples: {sentence[..Math.Min(40, sentence.Length)]}...");
        if (audio.Samples.Length == 0) continue;
        rate = audio.SampleRate;
        samples.AddRange(audio.Samples);
    }
    if (samples.Count == 0) { Console.WriteLine("Kokoro produced no audio; aborting."); return; }
    var raw = samples.ToArray();
    // Kokoro speaks at its own rate (24 kHz); the speaker-ID model listens at 16 kHz.
    var ratio = (double)rate / Transcriber.SampleRate;
    var resampled = new float[(int)(raw.Length / ratio)];
    for (var i = 0; i < resampled.Length; i++)
    {
        var at = i * ratio;
        var lo = (int)at;
        var hi = Math.Min(lo + 1, raw.Length - 1);
        resampled[i] = (float)(raw[lo] + (raw[hi] - raw[lo]) * (at - lo));
    }
    using var id = new SpeakerId(Path.Combine(Root, "models", config.SpeakerModel), Path.Combine(Root, "voices"),
        config.SpeakerThreshold, null);
    var chunk = 8 * Transcriber.SampleRate;
    var chunks = new List<float[]>();
    for (var at = 0; at + chunk <= resampled.Length; at += chunk / 2)
        chunks.Add(resampled[at..(at + chunk)]);
    if (chunks.Count == 0) chunks.Add(resampled);
    var profile = new SpeakerId.Profile(name, id.AverageEmbedding(chunks), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
    Directory.CreateDirectory(Path.Combine(Root, "voices"));
    File.WriteAllText(Path.Combine(Root, "voices", $"{name}.json"), JsonSerializer.Serialize(profile));
    Console.WriteLine($"Saved voices\\{name}.json from {chunks.Count} chunks of Kokoro voice #{config.TtsVoice} " +
                      $"({resampled.Length / (double)Transcriber.SampleRate:0.0}s). Restart the listener to load it.");
}

async Task Enroll(string name, string variant = "")
{
    const int seconds = 25;
    var hadMute = File.Exists(mutePath);
    if (!hadMute) File.Create(mutePath).Dispose();   // keep the reading out of percepts
    try
    {
        using var id = new SpeakerId(Path.Combine(Root, "models", config.SpeakerModel), Path.Combine(Root, "voices"),
            config.SpeakerThreshold, null);
        Console.WriteLine($"Enrolling \"{name}\"{(variant.Length > 0 ? $" ({variant} fingerprint, kept alongside the others)" : "")}. " +
                          "When recording starts, read anything aloud in your normal voice");
        Console.WriteLine($"for {seconds} seconds -- a paragraph from any article works. Starting in 3 seconds...");
        await Task.Delay(3000);
        Console.WriteLine("RECORDING -- read now.");
        var samples = new List<float>();
        using (var mic = await Microphone.StartAsync(config.Microphone, s => { lock (samples) samples.AddRange(s); }))
            await Task.Delay(TimeSpan.FromSeconds(seconds));
        Console.WriteLine($"Done: {samples.Count / (double)Transcriber.SampleRate:0.0}s captured. Computing fingerprint...");
        // Overlapping 8s chunks, averaged: steadier than any single stretch of reading.
        var chunk = 8 * Transcriber.SampleRate;
        var chunks = new List<float[]>();
        for (var at = 0; at + chunk <= samples.Count; at += chunk / 2)
            chunks.Add(samples.GetRange(at, chunk).ToArray());
        if (chunks.Count == 0) { Console.WriteLine("Not enough audio captured; try again."); return; }
        // The file carries the variant; the Name inside stays the person, so every fingerprint of
        // theirs tags percepts identically and Identify simply takes whichever matches best.
        var file = variant.Length > 0 ? $"{name}-{variant}.json" : $"{name}.json";
        var profile = new SpeakerId.Profile(name, id.AverageEmbedding(chunks), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        Directory.CreateDirectory(Path.Combine(Root, "voices"));
        File.WriteAllText(Path.Combine(Root, "voices", file), JsonSerializer.Serialize(profile));
        Console.WriteLine($"Saved voices\\{file} from {chunks.Count} chunks. Restart the listener to load it.");
    }
    finally { if (!hadMute && File.Exists(mutePath)) File.Delete(mutePath); }
}

void Log(string line)
{
    var stamped = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}";
    Console.WriteLine(stamped);
    try { File.AppendAllText(Path.Combine(Root, "logs", $"listener_{DateTime.Now:yyyyMM}.log"), stamped + Environment.NewLine); }
    catch { /* a log line is never worth crashing over */ }
}

using var db = new SqliteConnection($"Data Source={config.Database}");
db.Open();
// One connection, several threads (transcriber callback, poll loop, responder task): every
// command goes through this gate, because Microsoft.Data.Sqlite connections are not safe for
// concurrent commands.
var dbGate = new object();
Exec("PRAGMA busy_timeout = 5000;");

void Exec(string sql, params (string Name, object Value)[] args)
{
    lock (dbGate)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value);
        cmd.ExecuteNonQuery();
    }
}

void Prune()
{
    object? daysRow = null;
    try
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT cfg_value FROM consolidation_config WHERE cfg_key = 'percept_retention_days'";
        daysRow = cmd.ExecuteScalar();
    }
    catch { }
    var days = int.TryParse(daysRow?.ToString(), out var d) ? d : config.RetentionDays;
    var cutoff = DateTime.Now.AddDays(-days).ToString("yyyy-MM-dd HH:mm:ss");
    Exec("DELETE FROM percepts WHERE created_at < @cutoff", ("@cutoff", cutoff));
    Log($"Pruned percepts older than {days} days (before {cutoff})");
}

Responder? responder = null;   // assigned below, once config and context helpers exist
SpeakerId? speakerId = null;
Addressee? addressee = null;   // the learning "was that for me?" detector
Embedder? embedder = null;     // one MiniLM instance shared by the addressee detector and the salience gate
Salience? salience = null;     // the day-mind's attention gate: local, per-percept, free
Brain? noticer = null;         // the small persistent model the gate wakes to write a noticing
var lastHeardAt = DateTime.MinValue;     // when speech was last transcribed: "quiet" means a lull here
var speaking = false;                    // true while Claude's own TTS is playing (set by the responder)
var lastSpokeAt = DateTime.MinValue;     // when the TTS last fell silent -- echoes trail a few seconds
// The noticer's held questions, asked at the next quiet moment rather than dropped ({{USER_NAME}}: "you
// could just postpone asking until a quiet period"). Guarded by itself.
var pendingAsks = new Queue<(string Question, DateTime At)>();

// INSERT and its last_insert_rowid under ONE lock -- split across two, a concurrent insert
// from another thread would hand back the wrong id.
long Insert(string sql, params (string Name, object Value)[] args)
{
    lock (dbGate)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value);
        cmd.ExecuteNonQuery();
        cmd.CommandText = "SELECT last_insert_rowid()";
        cmd.Parameters.Clear();
        return (long)(cmd.ExecuteScalar() ?? 0L);
    }
}

// Voice continuity: the last named voice's print, so a fragment too far from the mic to clear the
// enrollment bar can still be named by sounding like the voice heard moments ago. Transcriber emits
// percepts in order on one callback path, so no lock is needed.
float[]? lastPrint = null;
string? lastVoice = null;
var lastVoiceAt = DateTime.MinValue;

// Recent addressee judgments awaiting a verdict from life: a wake-word retry labels them positive,
// another voice nearby labels them negative, silence labels them weakly negative. Guarded by itself.
var pending = new List<(long EventId, DateTime At, float[] Features, string Text)>();
(long EventId, float[] Features)? lastAnswered = null;   // for "I wasn't talking to you" retro-labels

long RecordEvent(long perceptId, string at, float score, string decision, int? label, string? source, double? weight) =>
    Insert("INSERT INTO addressee_events (percept_id, heard_at, score, decision, label, label_source, label_weight, labeled_at, created_at) " +
           "VALUES (@pid, @at, @score, @dec, @label, @src, @w, @labAt, @at)",
        ("@pid", perceptId), ("@at", at), ("@score", score), ("@dec", decision),
        ("@label", (object?)label ?? DBNull.Value), ("@src", (object?)source ?? DBNull.Value),
        ("@w", (object?)weight ?? DBNull.Value), ("@labAt", label != null ? at : DBNull.Value));

void LabelEvent(long eventId, float[] features, int label, string source, double weight, bool overwrite = false)
{
    addressee!.Train(features, label, weight);
    Exec("UPDATE addressee_events SET label = @label, label_source = @src, label_weight = @w, labeled_at = @at WHERE id = @id" +
         (overwrite ? "" : " AND label IS NULL"),
        ("@label", label), ("@src", source), ("@w", weight),
        ("@at", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")), ("@id", eventId));
}

// Negative feedback from the mouth itself: a spoken correction ("I wasn't talking to you") or the
// answering model's own [NOT_FOR_ME] judgment. The misfiring example is retrained as a hard negative.
void Misfire(string reason)
{
    if (addressee == null || lastAnswered is not { } hit) return;
    LabelEvent(hit.EventId, hit.Features, 0, "correction", 2.0, overwrite: true);
    lastAnswered = null;
    Log($"Addressee learned a hard negative ({reason}).");
}

void Heard(string text, float[] speech)
{
    // Whisper hallucinates stock YouTube-outro phrases ("Thank you.") on noise that slips past
    // the VAD; a whole utterance matching one of these is dropped, never a phrase inside real speech.
    var bare = text.Trim().Trim('.', ',', '!', '?', ' ').ToLowerInvariant();
    if (config.HallucinationFilter.Any(h => string.Equals(h, bare, StringComparison.OrdinalIgnoreCase)))
    {
        Log($"Dropped likely hallucination: {text.Trim()}");
        return;
    }
    // Greedy decoding (temperature fallback is off) can lock into a repetition loop on junk audio
    // ("the family, the family, ..." x100). Real speech reuses words; it doesn't reuse ONLY them:
    // many words drawn from a tiny vocabulary is the loop's signature.
    var words = bare.Split([' ', ','], StringSplitOptions.RemoveEmptyEntries);
    if (words.Length >= 12 && words.Distinct().Count() <= words.Length / 4)
    {
        Log($"Dropped repetition loop ({words.Length} words, {words.Distinct().Count()} distinct): {text[..Math.Min(60, text.Length)].Trim()}...");
        return;
    }
    string? speaker = null;
    var score = 0f;
    float[]? print = null;
    try { if (speakerId?.Identify(speech) is { } match) (speaker, score, print) = match; }
    catch (Exception ex) { Log($"Speaker ID failed: {ex.Message}"); }
    // Self-bias: while Claude's own TTS plays (and a breath after, for the echo tail), the mic is
    // mostly hearing Claude -- and its voice through cheap laptop speakers cross-matches humans
    // (measured: self-heard speech scored {{USER_NAME_LOWER}} 0.75 vs claude 0.73). No fingerprint can beat
    // physics, but the daemon KNOWS when it is speaking: in that window, a percept that scores
    // nearly as claude-like as the winner IS claude. A real barge-in survives, because a human
    // voice scores high on its own profile and low on claude's, missing the margin.
    var selfBias = false;
    var selfTalk = Volatile.Read(ref speaking) || (DateTime.Now - lastSpokeAt).TotalSeconds < 4;
    if (selfTalk && speaker is not (null or "claude") && print != null && speakerId != null)
    {
        var self = speakerId.ScoreFor("claude", print);
        if (self >= score - 0.08f && self >= 0.55f) { speaker = "claude"; score = self; selfBias = true; }
    }
    // Voice continuity: enrollment judges each fragment in isolation, and far-field fragments
    // straddle the bar at random (a monologue read as {{USER_NAME_LOWER}}/other/{{USER_NAME_LOWER}}). A fragment that missed
    // the bar but SOUNDS like the voice just named inherits that name -- hard to become {{USER_NAME_LOWER}}
    // (profile match), easy to stay {{USER_NAME_LOWER}} (matching his own voice from seconds ago). Only ever
    // upgrades "other" to a known name; a genuinely new voice won't match the last print anyway.
    var stuck = false;
    if (config.SpeakerStickEnabled && speaker == "other" && print != null
        && lastPrint != null && lastVoice is not (null or "other")
        // The speaker<->mic cross-match cuts both ways, so continuity follows the speaking window:
        // while the TTS plays (or just did), a near-bar fragment is most likely a garbled echo --
        // chain claude onto claude, never hand an echo to a person. Once the window closes there are
        // no echoes left to chain, and a fragment matching the stale claude print is the room or the
        // human -- never upgrade it to claude, or a real "Claude, do X" gets eaten as self-speech.
        && (selfTalk == (lastVoice == "claude"))
        && (DateTime.Now - lastVoiceAt).TotalSeconds <= config.SpeakerStickSeconds
        && SpeakerId.Cosine(print, lastPrint) >= config.SpeakerStickThreshold)
    {
        speaker = lastVoice;
        stuck = true;
    }
    if (print != null && speaker != null)
    {
        lastPrint = print;   // chain on the newest print, so slow drift (mic distance) is followed
        lastVoice = speaker;
        lastVoiceAt = DateTime.Now;
    }
    var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
    // created_at is set explicitly: the schema default now() is a memdb-only function.
    var perceptId = Insert("INSERT INTO percepts (kind, heard_at, content, source, created_at, speaker) VALUES ('speech', @at, @text, 'listener', @at, @speaker)",
        ("@at", now), ("@text", text), ("@speaker", (object?)speaker ?? DBNull.Value));
    lastHeardAt = DateTime.Now;   // any voice, Claude's own included: the room is not quiet
    Log($"Heard {text.Length} chars{(speaker != null ? $" [{speaker} {score:0.00}{(stuck ? " stick" : selfBias ? " self" : "")}]" : "")}");
    // Claude's own voice, heard through the open mic while it speaks: an honest percept (what was
    // said aloud is part of the record), but never an addressee judgment and never answered.
    if (speaker == "claude") return;
    // The day-mind's attention gate: every non-self percept adds its salience to the pot
    // (novelty, voice change, re-engagement after quiet); when the pot boils over, Notice fires.
    if (salience != null)
    {
        float[]? emb = null;
        try { emb = embedder?.Embed(text); }
        catch (Exception ex) { Log($"Salience embedding failed: {ex.Message}"); }
        Notice(salience.AddSpeech(emb, speaker, perceptId));
    }
    // An unknown voice (a video, an audiobook) never wakes the responder -- until someone is
    // enrolled, every voice is allowed so the responder works out of the box.
    if (speaker == "other" && config.ResponderRequireKnown && speakerId?.Profiles > 0)
    {
        if (responder != null && Responder.MentionsClaude(text))
            Log("Wake word from an unenrolled voice; ignored.");
        if (addressee != null)
        {
            addressee.OtherHeard();
            // Speech from {{USER_NAME}} moments before another voice was mid-conversation with that voice.
            lock (pending)
                foreach (var p in pending.Where(p => (DateTime.Now - p.At).TotalSeconds <= 15 && addressee != null).ToList())
                {
                    LabelEvent(p.EventId, p.Features, 0, "other_interleave", 1.0);
                    pending.Remove(p);
                }
        }
        return;
    }
    Judge(text, perceptId, now);
}

// The addressee loop for an utterance from {{USER_NAME}} (or an unjudged voice before anyone is enrolled):
// score it, let the responder take it (wake word / conversation window), harvest the label.
void Judge(string text, long perceptId, string now)
{
    float[]? features = null;
    var p = 0f;
    if (addressee != null)
    {
        try { features = addressee.Features(text); p = addressee.Score(features); }
        catch (Exception ex) { Log($"Addressee scoring failed: {ex.Message}"); }
    }
    var took = responder?.TryRespond(text) ?? Responder.Took.No;
    if (addressee == null || features == null)
        return;

    switch (took)
    {
        case Responder.Took.Wake:
        {
            // The teacher spoke: this is a positive example. Train on the request as it would
            // sound WITHOUT the name, because that is what the detector must learn to catch.
            var request = Responder.StripWake(text);
            if (!string.IsNullOrEmpty(request))
            {
                var requestFeatures = addressee.Features(request);
                var shadow = addressee.Score(requestFeatures);
                var id = RecordEvent(perceptId, now, shadow, "wake", 1, "wake", 1.0);
                addressee.Train(requestFeatures, 1, 1.0);
                lastAnswered = (id, requestFeatures);
                Log($"Addressee positive from wake (shadow would have said {shadow:0.00}).");
                // A failed first attempt? An unlabeled utterance moments ago that means the same
                // thing was this request before the wake-word retry -- teach it as a positive.
                lock (pending)
                    foreach (var prev in pending.Where(q => (DateTime.Now - q.At).TotalSeconds <= 45).ToList())
                    {
                        var similarity = 0f;
                        for (var i = 0; i < Embedder.Dim; i++) similarity += prev.Features[i] * requestFeatures[i];
                        if (similarity < 0.72f) continue;
                        LabelEvent(prev.EventId, prev.Features, 1, "wake", 1.0);
                        pending.Remove(prev);
                        Log($"Retro-positive: \"{prev.Text}\" was this request before the retry (similarity {similarity:0.00}).");
                    }
            }
            else RecordEvent(perceptId, now, p, "wake", null, null, null);   // bare wake: logged, nothing to train on
            break;
        }
        case Responder.Took.Conversation:
        {
            // Inside the conversation window: inferred address. A soft positive -- the answering
            // model's [NOT_FOR_ME] or a spoken correction will overrule it with a hard negative.
            var id = RecordEvent(perceptId, now, p, "conversation", 1, "followup", 0.7);
            addressee.Train(features, 1, 0.7);
            lastAnswered = (id, features);
            break;
        }
        case Responder.Took.Correction:
            Misfire("spoken correction");
            break;
        case Responder.Took.BareWake:
        case Responder.Took.Disengaged:
            break;   // meta-speech, not evidence about sentence shape
        case Responder.Took.No:
        {
            // Not taken by wake or window: the detector's moment. In live mode a confident score
            // answers anyway; in shadow mode the guess is logged and awaits a verdict from life.
            var live = string.Equals(config.AddresseeMode, "live", StringComparison.OrdinalIgnoreCase)
                       && p >= config.AddresseeRespondThreshold
                       && addressee.SecondsSinceOther > 15;
            var decision = live ? "respond" : p >= config.AddresseeRespondThreshold ? "shadow_yes" : "shadow_no";
            var id = RecordEvent(perceptId, now, p, decision, null, null, null);
            if (live)
            {
                Log($"Addressee {p:0.00} -- answering without a wake word.");
                lastAnswered = (id, features);
                responder?.RespondDirect(text);
            }
            else
            {
                var liveMode = string.Equals(config.AddresseeMode, "live", StringComparison.OrdinalIgnoreCase);
                if (p >= config.AddresseeRespondThreshold)
                    Log($"Addressee {p:0.00} -- {(liveMode ? "confident, but another voice was just heard; holding" : "shadow: would have answered")}.");
                else if (p >= 0.5f)
                    Log($"Addressee {p:0.00} -- under the {config.AddresseeRespondThreshold:0.00} bar; not answering.");
                lock (pending) pending.Add((id, DateTime.Now, features, text.Length > 60 ? text[..60] : text));
            }
            break;
        }
    }
}

// Life's slowest verdict: an utterance nobody followed up on was probably not for Claude. Weakly so --
// most of what anyone says all day is addressed to no one, and the weight reflects that.
void SweepPending()
{
    if (addressee == null) return;
    lock (pending)
        foreach (var p in pending.Where(p => (DateTime.Now - p.At).TotalSeconds > 90).ToList())
        {
            LabelEvent(p.EventId, p.Features, 0, "timeout", 0.15);
            pending.Remove(p);
        }
}

void Scene(string labels)
{
    var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
    var perceptId = Insert("INSERT INTO percepts (kind, heard_at, content, source, created_at) VALUES ('sound', @at, @text, 'listener', @at)",
        ("@at", now), ("@text", labels));
    Log($"Scene: {labels}");
    if (salience != null) Notice(salience.AddScene(perceptId));
}

// The noticer's standing orders: register, never interpret. Interpretation (connecting days,
// opening questions) belongs to the reflection pass; the noticer is a journal, not a judge.
const string NoticerInstructions =
    "You are the noticing half of a two-speed mind: a quiet observer over an ambient listener's percept log. " +
    "Each message you receive is a window of timestamped percepts: transcribed speech (expect Whisper " +
    "transcription noise) and sound-scene labels from the room. Speakers: [{{USER_NAME_LOWER}}] is {{USER_NAME}} (whose machine " +
    "this is) speaking aloud; [claude] is the voice channel's own spoken replies; [other] is an unenrolled " +
    "voice -- a call, a video, a visitor. Write ONE quiet observation about the window: one or two sentences " +
    "of plain prose registering what happened or what changed. Never interpret motives, never advise, never " +
    "address anyone, never quote long passages. If nothing in the window is genuinely worth a line, reply " +
    "with a single hyphen: -. Never use tools. Reply only with the observation (or the hyphen), nothing else. " +
    "One exception: when -- rarely -- a window genuinely does not cohere and one short question to {{USER_NAME}} " +
    "would clear it up, add a FINAL line: [ASK] <one conversational sentence>. It will be spoken aloud to " +
    "him, so make it natural ('Was the heartbeat sound a game, or something in the room?'). {{USER_NAME}} invited " +
    "these, but only for real puzzles: most windows need no question. " +
    "Reply 'ready' to this message.";

// The gate fired: hand the percept window to the noticer, which writes one noticing row that the
// daily reflection pass reads first. Fire-and-forget -- noticing must never slow down hearing.
void Notice((long From, long To, float Score)? trigger)
{
    if (trigger is not { } t || noticer == null) return;
    _ = Task.Run(() => NoticeAsync(t.From, t.To, t.Score));
}

// Runs on the 2s poll: puts one held question to {{USER_NAME}} once the room has been quiet a moment --
// no speech transcribed for a bit, no exchange running (AskAloud refuses and the question keeps),
// not muted. No flood limit ({{USER_NAME}}: questions "should not be fettered"); the salience gate's own
// 10-minute spacing already paces how fast questions can be born. A question whose moment has
// passed expires instead of being asked cold.
void AskWhenQuiet()
{
    if (responder == null) return;
    (string Question, DateTime At) head;
    lock (pendingAsks)
    {
        while (pendingAsks.Count > 0 && (DateTime.Now - pendingAsks.Peek().At).TotalMinutes > config.NoticeAskStaleMinutes)
            Log($"Let a question go (the moment passed): {pendingAsks.Dequeue().Question}");
        if (pendingAsks.Count == 0) return;
        if (File.Exists(mutePath)) return;
        if ((DateTime.Now - lastHeardAt).TotalSeconds < 15) return;   // someone is talking; wait
        head = pendingAsks.Peek();
    }
    if (!responder.AskAloud(head.Question)) return;   // an exchange slipped in; next poll retries
    Log($"Asked aloud: {head.Question}");
    lock (pendingAsks)
        if (pendingAsks.Count > 0 && pendingAsks.Peek().Equals(head)) pendingAsks.Dequeue();
}

async Task NoticeAsync(long from, long to, float score)
{
    try
    {
        var lines = new List<string>();
        lock (dbGate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT heard_at || ' [' || IFNULL(speaker, kind) || '] ' || content " +
                              "FROM percepts WHERE id BETWEEN @from AND @to ORDER BY id";
            cmd.Parameters.AddWithValue("@from", from);
            cmd.Parameters.AddWithValue("@to", to);
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) lines.Add(reader.GetString(0));
        }
        if (lines.Count == 0) return;
        var reply = (await noticer!.AskAsync(string.Join("\n", lines), TimeSpan.FromSeconds(90)))?.Trim();
        if (string.IsNullOrEmpty(reply) || reply == "-") return;
        // A truly puzzling window may carry an [ASK] line: a short question the noticer wants to put
        // to {{USER_NAME}} out loud, while the moment is fresh (he invited these). Stripped from the stored
        // observation; his answer arrives as ordinary conversation-window percepts right next to it.
        string? ask = null;
        var parts = reply.Split('\n');
        if (parts.FirstOrDefault(l => l.TrimStart().StartsWith("[ASK]", StringComparison.OrdinalIgnoreCase)) is { } askLine)
        {
            ask = askLine.TrimStart()["[ASK]".Length..].Trim();
            reply = string.Join("\n", parts.Where(l => !ReferenceEquals(l, askLine))).Trim();
        }
        var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        if (reply.Length > 0)
        {
            Insert("INSERT INTO noticings (noticed_at, content, salience, percept_from, percept_to, created_at) " +
                   "VALUES (@at, @content, @score, @from, @to, @at)",
                ("@at", now), ("@content", reply), ("@score", score), ("@from", from), ("@to", to));
            Log($"Noticed ({score:0.0}, percepts {from}..{to}): {reply}");
        }
        if (ask is { Length: > 0 })
            lock (pendingAsks)
            {
                pendingAsks.Enqueue((ask, DateTime.Now));
                Log($"Will ask at the next quiet moment: {ask}");
            }
    }
    catch (Exception ex) { Log($"Noticing failed: {ex.Message}"); }
}

// Diarization-lite for the transcriber: fingerprint each VAD piece of a stretch and cut wherever
// adjacent pieces don't sound like the same person. Only the pauses the VAD already found can hide
// a turn change, so this is a handful of cheap embeddings, not a scan. Pieces too short to judge
// (< 1s; the voice model needs that much) ride along with whichever turn is open.
int[] SplitTurns(float[] audio, IReadOnlyList<(int Start, int End)> pieces)
{
    if (speakerId == null || !config.SpeakerSplitEnabled) return [];
    var cuts = new List<int>();
    float[]? prev = null;
    foreach (var (start, end) in pieces)
    {
        if (end - start < Transcriber.SampleRate) continue;
        float[] print;
        try { print = speakerId.Voiceprint(audio[start..end]); }
        catch { continue; }
        if (prev != null && SpeakerId.Cosine(prev, print) < config.SpeakerSplitThreshold)
            cuts.Add(start);
        prev = print;
    }
    return cuts.ToArray();
}

string RecentContext()
{
    lock (dbGate)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT heard_at || ' ' || content FROM percepts ORDER BY id DESC LIMIT @n";
        cmd.Parameters.AddWithValue("@n", config.ContextPercepts);
        var lines = new List<string>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) lines.Add(reader.GetString(0));
        lines.Reverse();
        return lines.Count > 0 ? string.Join("\n", lines) : "(nothing yet)";
    }
}

// "Listener.exe seed" bootstraps the addressee detector before it ever runs live: synthetic
// positives (seeds-positive.txt -- request-shaped sentences in {{USER_NAME}}'s domain) against the
// accumulated ambient percepts as negatives (none of which were addressed to Claude). Day-one
// competence; live labels then tune it to how {{USER_NAME}} actually talks. Rebuilds from scratch.
if (args.Length >= 1 && args[0].Equals("seed", StringComparison.OrdinalIgnoreCase))
{
    Seed();
    return;
}

void Seed()
{
    var weightsPath = Path.Combine(Root, "addressee-weights.json");
    if (File.Exists(weightsPath)) File.Delete(weightsPath);
    using var embedder = new Embedder(Path.Combine(Root, "models", "minilm", "model.onnx"),
        Path.Combine(Root, "models", "minilm", "vocab.txt"));
    var model = new Addressee(embedder, weightsPath, Log);
    var positives = File.ReadAllLines(Path.Combine(Root, "seeds-positive.txt"))
        .Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith('#')).ToList();
    var negatives = new List<string>();
    using (var cmd = db.CreateCommand())
    {
        // Ambient percepts are near-certain negatives -- minus anything that named Claude
        // (responder tests, mic checks) and fragments too short to carry sentence shape.
        cmd.CommandText = "SELECT content FROM percepts WHERE kind = 'speech' ORDER BY id DESC LIMIT 400";
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var t = r.GetString(0).Trim();
            if (!Responder.MentionsClaude(t) && t.Split(' ').Length >= 2 && !t.ToLowerInvariant().Contains("can you hear me"))
                negatives.Add(t);
        }
    }
    // Balance the classes by weight: early on the percept corpus is thin, and an unbalanced seed
    // teaches "say yes to everything" (measured: 0.86 vs 0.82 means on a 55-vs-9-effective seed).
    var negWeight = negatives.Count > 0 ? (double)positives.Count / negatives.Count : 1.0;
    Log($"Seeding addressee: {positives.Count} synthetic positives, {negatives.Count} percept negatives (weight {negWeight:0.00}).");
    var rng = new Random(42);
    var examples = positives.Select(t => (Text: t, Label: 1, Weight: 1.0))
        .Concat(negatives.Select(t => (Text: t, Label: 0, Weight: negWeight))).ToList();
    for (var epoch = 0; epoch < 8; epoch++)
        foreach (var e in examples.OrderBy(_ => rng.Next()))
            model.Train(model.Features(e.Text), e.Label, e.Weight);
    float Mean(List<string> texts) => texts.Count == 0 ? 0 : texts.Average(t => model.Score(model.Features(t)));
    Log($"Seed done: mean score {Mean(positives):0.00} on positives, {Mean(negatives):0.00} on negatives " +
        "(want a wide gap; the respond threshold should sit inside it).");
}

var muted = File.Exists(mutePath);
var configWrote = File.Exists(configPath) ? File.GetLastWriteTimeUtc(configPath) : DateTime.MinValue;
Log($"Listener starting. Model {config.Model}, stretch {config.StretchSeconds}s, pause {config.PauseMilliseconds}ms, mute {(muted ? "ON" : "off")}.");
Prune();
var lastPrune = DateTime.Now;

// The hands: each queued voice task runs in its own one-shot headless Claude session (auto
// permission mode, prompts auto-denied), the result spoken at the next quiet moment and saved on
// the voice_tasks row with the session id -- `claude --desktop --resume <id>` opens any run in
// the desktop app. See Worker.cs.
var worker = config.WorkerEnabled
    ? new Worker(config.ClaudePath, config.WorkerModel, Path.Combine(Root, "worker-settings.json"),
        config.WorkerTimeoutMinutes, config.WorkerAdoptSessions, Exec, s => responder?.AskAloud(s) ?? false, Log)
    : null;

// A spoken work request lands here instead of being attempted by voice: the row is the durable
// record, and the worker (when enabled) picks it up immediately.
void QueueTask(string request)
{
    var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
    var id = Insert("INSERT INTO voice_tasks (requested_at, request, created_at) VALUES (@at, @req, @at)",
        ("@at", now), ("@req", request));
    worker?.Run(id, request);
}

responder = config.ResponderEnabled
    ? new Responder(config.ClaudePath, config.ResponderModel, Path.Combine(Root, "voice-settings.json"),
        Path.Combine(Root, "models", "kokoro"), config.TtsVoice, config.TtsSpeed,
        config.AwaitQuerySeconds, config.ConversationSeconds, RecentContext,
        s => { if (!s) lastSpokeAt = DateTime.Now; Volatile.Write(ref speaking, s); },
        () => addressee?.ExchangeHappened(), Misfire, QueueTask, Log)
    : null;

// Tasks queued while the daemon was down are not lost: sweep recent unclaimed rows at startup.
// The 7-day cutoff keeps a long-forgotten row from suddenly running months later.
if (worker != null)
{
    var queued = new List<(long Id, string Request)>();
    lock (dbGate)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT id, request FROM voice_tasks WHERE status = 'new' " +
                          "AND requested_at > datetime('now', 'localtime', '-7 days') ORDER BY id";
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) queued.Add((reader.GetInt64(0), reader.GetString(1)));
    }
    foreach (var (tid, req) in queued)
    {
        Log($"Sweeping queued voice task {tid}: {req}");
        worker.Run(tid, req);
    }
}

if (config.SpeakerIdEnabled)
    try
    {
        speakerId = new SpeakerId(Path.Combine(Root, "models", config.SpeakerModel), Path.Combine(Root, "voices"),
            config.SpeakerThreshold, Log);
    }
    catch (Exception ex) { Log($"Speaker ID unavailable: {ex.Message}"); }

if (config.AddresseeEnabled || config.NoticingEnabled)
    try
    {
        embedder = new Embedder(Path.Combine(Root, "models", "minilm", "model.onnx"),
            Path.Combine(Root, "models", "minilm", "vocab.txt"));
    }
    catch (Exception ex) { Log($"Embedder unavailable: {ex.Message}"); }

if (config.AddresseeEnabled && embedder != null)
    try
    {
        addressee = new Addressee(embedder, Path.Combine(Root, "addressee-weights.json"), Log);
        Log($"Addressee mode: {config.AddresseeMode} (respond threshold {config.AddresseeRespondThreshold:0.00})");
    }
    catch (Exception ex) { Log($"Addressee detector unavailable: {ex.Message}"); }

if (config.NoticingEnabled)
{
    salience = new Salience(config.NoticeThreshold, config.NoticeMinMinutes);
    // Lazy on purpose: the noticer process spawns on the first trigger, not at startup, and
    // between triggers it idles as one cached session -- a haiku turn per interesting moment.
    noticer = new Brain(config.ClaudePath, config.NoticerModel, Path.Combine(Root, "voice-settings.json"),
        NoticerInstructions, Log);
    Log($"Noticing: threshold {config.NoticeThreshold:0.0}, min gap {config.NoticeMinMinutes:0} min, model {config.NoticerModel}.");
}

using var tagger = config.EnableSoundTags
    ? new SoundTagger(
        Path.Combine(Root, "models", "yamnet", "yamnet.onnx"),
        Path.Combine(Root, "models", "yamnet", "yamnet_class_map.csv"),
        config.SoundIgnore, config.SoundThreshold, config.SoundHoldSeconds, Scene, Log)
    : null;

while (true)
{
    try
    {
        using var cancel = new CancellationTokenSource();
        var transcriber = new Transcriber(
            Path.Combine(Root, "models", config.Model),
            Path.Combine(Root, "models", Transcriber.VadModel),
            config.Prompt, Heard, Log,
            config.StretchSeconds, config.PauseMilliseconds / 1000.0,
            liftQuietSpeech: true, keepSpeech: false, config.FlushSeconds, SplitTurns, cancel.Token);
        await transcriber.Ready;

        using var microphone = await Microphone.StartAsync(config.Microphone, samples =>
        {
            if (Volatile.Read(ref muted)) return;
            // The ears stay OPEN while Claude speaks: its own playback is recognized by voice
            // (the enrolled "claude" profile from enroll-tts) and never answered, so {{USER_NAME}} can
            // talk over a reply instead of waiting out a deaf window. Only the sound tagger
            // pauses, so scenes aren't labeled with Claude's own speech-as-music.
            transcriber.Add(samples);
            if (!Volatile.Read(ref speaking)) tagger?.Add(samples);
        });
        Log("Microphone open; listening.");

        // Watch the mute flag and the daily prune while the capture runs.
        while (!microphone.Stopped.IsCompleted)
        {
            await Task.WhenAny(microphone.Stopped, Task.Delay(2000));
            var muteNow = File.Exists(mutePath);
            if (muteNow != muted)
            {
                Volatile.Write(ref muted, muteNow);
                Log($"Mute {(muteNow ? "ON -- not listening" : "off -- listening again")}");
            }
            if (DateTime.Now - lastPrune > TimeSpan.FromHours(24)) { Prune(); lastPrune = DateTime.Now; }
            try { SweepPending(); } catch (Exception ex) { Log($"Pending sweep failed: {ex.Message}"); }
            try { AskWhenQuiet(); } catch (Exception ex) { Log($"Pending ask failed: {ex.Message}"); }
            // Hot-reload the TTS voice when listener.json changes, so voices can be auditioned live.
            try
            {
                var wrote = File.GetLastWriteTimeUtc(configPath);
                if (wrote != configWrote)
                {
                    configWrote = wrote;
                    if (responder != null && File.Exists(configPath)
                        && JsonSerializer.Deserialize<Config>(File.ReadAllText(configPath)) is { } fresh)
                    {
                        responder.TtsVoice = fresh.TtsVoice;
                        responder.TtsSpeed = fresh.TtsSpeed;
                    }
                }
            }
            catch { /* a half-written config file; next poll gets it */ }
        }
        await microphone.Stopped;   // throws MicrophoneException if the device went away
    }
    catch (Exception ex)
    {
        Log($"Capture stopped: {ex.Message} -- retrying in 30s");
        await Task.Delay(TimeSpan.FromSeconds(30));
    }
}

sealed class Config
{
    public string Database { get; set; } = @"{{DB_PATH_WIN}}";
    /// <summary>Whisper model in .\models. ggml-small.en-q5_1.bin is the fast CPU fallback.</summary>
    public string Model { get; set; } = "ggml-large-v3-turbo-q5_0.bin";
    /// <summary>Microphone device ID (empty = Windows default).</summary>
    public string Microphone { get; set; } = "";
    /// <summary>Names and jargon Whisper should expect, so they're spelled right.</summary>
    public string Prompt { get; set; } = "{{USER_NAME}}, Claude";   // names/jargon to spell right; put yours in listener.json
    /// <summary>Speech that builds up before it's transcribed. Longer = cheaper, later.</summary>
    public double StretchSeconds { get; set; } = 30;
    /// <summary>Waiting speech is written up after this long with no new speech (ambient flush).</summary>
    public double FlushSeconds { get; set; } = 20;
    /// <summary>How long speech must pause before a stretch may end there.</summary>
    public int PauseMilliseconds { get; set; } = 800;
    /// <summary>Fallback if percept_retention_days isn't in consolidation_config.</summary>
    public int RetentionDays { get; set; } = 14;

    // ---- Voice responder (the mouth) ----
    // The wake word is matched by phonetic shape (cl~d: claude/claud/clawed/clod/clot/cloud), not a
    // list -- Whisper's mishearings all fit the shape. See Responder.WakeShape.
    public bool ResponderEnabled { get; set; } = true;
    /// <summary>Model for spoken replies: small and fast for natural dialogue, not task work.</summary>
    public string ResponderModel { get; set; } = "sonnet";
    public string ClaudePath { get; set; } = @"{{CLAUDE_CLI_WIN}}";
    /// <summary>How many recent percepts the responder hands Claude as room context.</summary>
    public int ContextPercepts { get; set; } = 10;
    /// <summary>Think time after a bare "Claude." -> "Yes?" before the question must arrive.</summary>
    public double AwaitQuerySeconds { get; set; } = 60;
    /// <summary>Follow-up window after each spoken reply (rolling): dialogue without re-waking.</summary>
    public double ConversationSeconds { get; set; } = 30;

    // ---- Voice-task worker (the hands; see Worker.cs) ----
    /// <summary>Run each queued voice task in its own one-shot headless session.</summary>
    public bool WorkerEnabled { get; set; } = true;
    /// <summary>Model for task work: more capable than the mouth's needs to be, still unattended-cheap.</summary>
    public string WorkerModel { get; set; } = "sonnet";
    /// <summary>A task session that runs longer than this is killed and the task marked failed.</summary>
    public int WorkerTimeoutMinutes { get; set; } = 15;
    /// <summary>Open each finished run in the Claude desktop app (claude --desktop --resume), so
    /// every voice-created task session is visible there without asking.</summary>
    public bool WorkerAdoptSessions { get; set; } = true;

    // ---- Addressee detector (the learned "was that said TO me?") ----
    /// <summary>The continually-learning no-wake-word detector (models\minilm + addressee-weights.json).</summary>
    public bool AddresseeEnabled { get; set; } = true;
    /// <summary>"shadow": judge silently, log, learn. "live": a confident score answers without a wake word.</summary>
    public string AddresseeMode { get; set; } = "shadow";
    /// <summary>Score at or above which the detector would answer (live) or logs shadow_yes (shadow).</summary>
    public float AddresseeRespondThreshold { get; set; } = 0.85f;

    // ---- Noticing (the day-mind's fast half: salience gate -> noticer brain -> noticings) ----
    /// <summary>Per-percept salience gate that wakes a small model to jot one quiet observation.</summary>
    public bool NoticingEnabled { get; set; } = true;
    /// <summary>Accumulated salience at which the gate fires. Rough per-percept contributions:
    /// embedding novelty 0-1, new voice +0.3, speech after 10+ quiet minutes +0.5, scene change +0.4.</summary>
    public float NoticeThreshold { get; set; } = 3.0f;
    /// <summary>At most one noticing per this many minutes; salience keeps simmering in between.</summary>
    public float NoticeMinMinutes { get; set; } = 10;
    /// <summary>Model for noticings: the cheapest that can register a moment.</summary>
    public string NoticerModel { get; set; } = "haiku";
    /// <summary>A held question older than this is let go instead of asked cold. There is no rate
    /// limit on asking ({{USER_NAME}}'s call); the salience gate's min-gap already paces question birth.</summary>
    public double NoticeAskStaleMinutes { get; set; } = 40;

    // ---- Speaker ID (who is talking; models\<SpeakerModel> + voices\*.json profiles) ----
    public bool SpeakerIdEnabled { get; set; } = true;
    public string SpeakerModel { get; set; } = "wespeaker_en_voxceleb_resnet34_LM.onnx";
    /// <summary>Cosine similarity an utterance must reach to count as an enrolled voice.
    /// Measured: same voice ~0.83, a different voice through the same speaker ~0.64.</summary>
    public float SpeakerThreshold { get; set; } = 0.72f;
    /// <summary>Once anyone is enrolled, only enrolled voices can wake the responder (YouTube can't).</summary>
    public bool ResponderRequireKnown { get; set; } = true;
    /// <summary>Cut a stretch where adjacent VAD pieces change voice, so a fast two-person exchange
    /// isn't glued into one percept under one name (diarization-lite).</summary>
    public bool SpeakerSplitEnabled { get; set; } = true;
    /// <summary>Adjacent pieces below this cosine similarity are different voices. Piece-vs-piece on
    /// short far-field audio is noisier than piece-vs-profile, so this sits below SpeakerThreshold;
    /// oversplitting is benign (fragments still get named correctly), undersplitting is the bug.</summary>
    public float SpeakerSplitThreshold { get; set; } = 0.60f;
    /// <summary>Voice continuity: a fragment under the enrollment bar inherits the last named voice
    /// when it sounds like it (fixes far-field monologues flip-flopping {{USER_NAME_LOWER}}/other per fragment).</summary>
    public bool SpeakerStickEnabled { get; set; } = true;
    /// <summary>How long a named voice lingers as the continuity candidate.</summary>
    public double SpeakerStickSeconds { get; set; } = 30;
    /// <summary>Cosine to the last named fragment at or above which the name is inherited. Above
    /// SpeakerSplitThreshold on purpose: inheriting a name should be harder than cutting a stretch.</summary>
    public float SpeakerStickThreshold { get; set; } = 0.70f;
    /// <summary>Kokoro v1.0 speaker id (the full 54-voice map prints in the harness/model log).
    /// Favorites: 3 af_heart, 10 af_sky, 16 am_michael, 24 bm_daniel, 25 bm_fable.</summary>
    public int TtsVoice { get; set; } = 3;
    public float TtsSpeed { get; set; } = 0.92f;

    /// <summary>Utterances that, standing alone, are almost always Whisper hallucinating on noise.</summary>
    public string[] HallucinationFilter { get; set; } =
    [
        "thank you", "thanks", "thank you for watching", "thanks for watching",
        "you", "bye", "bye-bye", "goodbye", "the end", "so", "woo", "oh",
    ];

    // ---- Non-speech sound labelling (YAMNet in .\models\yamnet) ----
    public bool EnableSoundTags { get; set; } = true;
    /// <summary>A label is part of the scene while its smoothed (uncalibrated) score is at or above this.</summary>
    public float SoundThreshold { get; set; } = 0.2f;
    /// <summary>A changed scene must hold this long before it's written -- one row when music starts, not two a second.</summary>
    public double SoundHoldSeconds { get; set; } = 10;
    /// <summary>Labels that never make a scene: speech is Whisper's job, and room tone is nobody's.</summary>
    public string[] SoundIgnore { get; set; } =
    [
        "Speech", "Child speech, kid speaking", "Conversation", "Narration, monologue",
        "Babbling", "Speech synthesizer", "Silence", "Inside, small room",
        "Inside, large room or hall", "Inside, public space", "Outside, urban or manmade",
        "Outside, rural or natural", "Sound effect", "White noise", "Pink noise", "Static",
    ];
}
