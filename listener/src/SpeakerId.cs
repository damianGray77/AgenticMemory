using System.Text.Json;
using SherpaOnnx;

namespace Listener;

/// <summary>
/// Puts a name to a voice. WeSpeaker's ResNet34 (the model EmailTodo uses for diarization) turns a
/// stretch of speech into an embedding -- a voice fingerprint -- and enrolled fingerprints live as
/// JSON files in .\voices. Each transcribed stretch is tagged with the closest enrolled name, or
/// "other" when nothing is close enough: that is how a percept from {{USER_NAME}} is told apart from a
/// percept from YouTube or an audiobook. Enrollment: Listener.exe enroll &lt;name&gt;.
/// </summary>
public sealed class SpeakerId : IDisposable
{
    readonly SpeakerEmbeddingExtractor _extractor;
    readonly List<(string Name, float[] Embedding)> _profiles = [];
    readonly float _threshold;

    public int Profiles => _profiles.Count;

    public SpeakerId(string modelPath, string voicesDir, float threshold, Action<string>? log)
    {
        if (!File.Exists(modelPath)) throw new FileNotFoundException($"The voice model \"{modelPath}\" isn't there.", modelPath);
        var config = new SpeakerEmbeddingExtractorConfig { Model = modelPath, NumThreads = 2 };
        _extractor = new SpeakerEmbeddingExtractor(config);
        _threshold = threshold;
        if (Directory.Exists(voicesDir))
            foreach (var file in Directory.GetFiles(voicesDir, "*.json"))
            {
                var profile = JsonSerializer.Deserialize<Profile>(File.ReadAllText(file));
                if (profile?.Embedding is not { Length: > 0 }) continue;
                _profiles.Add((profile.Name, Normalize(profile.Embedding)));
            }
        var voices = _profiles.Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        log?.Invoke($"Speaker ID ready: {Profiles} fingerprint(s) for {voices} voice(s), threshold {threshold:0.00}");
    }

    /// <summary>
    /// The enrolled name this speech matches with its cosine similarity, ("other", bestScore) for an
    /// unknown voice, or null when too short to judge. The score makes thresholds tunable from the
    /// log; the voiceprint lets the caller compare this utterance to a recent one directly (voice
    /// continuity: a near-bar fragment that sounds like the voice just heard IS that voice).
    /// </summary>
    public (string Name, float Score, float[] Print)? Identify(float[] speech)
    {
        if (speech.Length < Transcriber.SampleRate || _profiles.Count == 0) return null;
        var embedding = Normalize(Embed(speech));
        var best = ("other", -1f);
        foreach (var (name, enrolled) in _profiles)
        {
            var score = 0f;
            for (var i = 0; i < embedding.Length; i++) score += embedding[i] * enrolled[i];
            if (score > best.Item2) best = (name, score);
        }
        return best.Item2 >= _threshold ? (best.Item1, best.Item2, embedding) : ("other", best.Item2, embedding);
    }

    static float[] Normalize(float[] v)
    {
        var norm = MathF.Sqrt(v.Sum(x => x * x));
        if (norm > 0) for (var i = 0; i < v.Length; i++) v[i] /= norm;
        return v;
    }

    /// <summary>A voice fingerprint for this speech (16 kHz mono).</summary>
    public float[] Embed(float[] speech)
    {
        using var stream = _extractor.CreateStream();
        stream.AcceptWaveform(Transcriber.SampleRate, speech);
        stream.InputFinished();
        return _extractor.Compute(stream);
    }

    /// <summary>A unit-length fingerprint, so two of them compare by plain dot product.</summary>
    public float[] Voiceprint(float[] speech) => Normalize(Embed(speech));

    /// <summary>This print's best similarity to ONE enrolled name's fingerprints (-1 if not enrolled).
    /// For the self-bias check: "how claude-like was that?", whoever won the overall match.</summary>
    public float ScoreFor(string name, float[] print)
    {
        var best = -1f;
        foreach (var (profileName, enrolled) in _profiles)
            if (string.Equals(profileName, name, StringComparison.OrdinalIgnoreCase))
                best = Math.Max(best, Cosine(print, enrolled));
        return best;
    }

    /// <summary>Cosine similarity of two unit-length fingerprints.</summary>
    public static float Cosine(float[] a, float[] b)
    {
        var dot = 0f;
        for (var i = 0; i < a.Length; i++) dot += a[i] * b[i];
        return dot;
    }

    /// <summary>Averages fingerprints from several chunks of enrollment speech into one stable profile.</summary>
    public float[] AverageEmbedding(IReadOnlyList<float[]> chunks)
    {
        var sum = new float[_extractor.Dim];
        foreach (var chunk in chunks)
        {
            var embedding = Embed(chunk);
            for (var i = 0; i < sum.Length; i++) sum[i] += embedding[i];
        }
        var norm = MathF.Sqrt(sum.Sum(v => v * v));
        if (norm > 0) for (var i = 0; i < sum.Length; i++) sum[i] /= norm;
        return sum;
    }

    public void Dispose() => _extractor.Dispose();

    public sealed record Profile(string Name, float[] Embedding, string? EnrolledAt = null);
}
