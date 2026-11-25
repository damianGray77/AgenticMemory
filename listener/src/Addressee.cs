using System.Text.Json;

namespace Listener;

/// <summary>
/// The continually-learning answer to "was that said TO Claude, or just near Claude?" -- the thing
/// that eventually retires the wake word. An online logistic regression over a sentence embedding
/// (Embedder) plus a handful of context signals: who else has been talking, how recently Claude and
/// {{USER_NAME}} last exchanged words, whether the utterance is question-shaped. It trains from life, not
/// a dataset: wake-worded utterances are positives, speech interleaved with another voice (a call,
/// a meeting) is a negative, speech that drew no response and no retry is a weak negative. Weights
/// persist to addressee-weights.json after every update, so learning survives restarts. Inspect it:
/// the weights file is plain JSON, and every judgment is a row in addressee_events.
/// </summary>
public sealed class Addressee : IDisposable
{
    // Handcrafted features appended to the 384-dim embedding. Order is the contract with the
    // weights file: changing it invalidates saved weights (bump Model.Version if you do).
    const int Handcrafted = 7;
    public const int Dim = Embedder.Dim + Handcrafted;

    readonly Embedder _embedder;
    readonly string _weightsPath;
    readonly object _gate = new();
    readonly Action<string>? _log;
    Model _model;

    // Context clocks: what the room has been doing lately, fed by the listener as it happens.
    DateTime _lastOther = DateTime.MinValue;      // another voice (video, call, audiobook)
    DateTime _lastExchange = DateTime.MinValue;   // Claude last spoke with {{USER_NAME}}
    DateTime _lastDamian = DateTime.MinValue;     // {{USER_NAME}} last said anything

    public Addressee(Embedder embedder, string weightsPath, Action<string>? log)
    {
        _embedder = embedder;
        _weightsPath = weightsPath;
        _log = log;
        _model = Load(weightsPath) ?? Model.Fresh();
        log?.Invoke($"Addressee detector ready: {_model.Updates} training updates so far" +
                    (_model.Updates == 0 ? " (blank slate -- shadow mode is how it learns)" : ""));
    }

    public void OtherHeard() { lock (_gate) _lastOther = DateTime.Now; }
    public void ExchangeHappened() { lock (_gate) _lastExchange = DateTime.Now; }

    /// <summary>Seconds since another (unenrolled) voice was last heard; big when never.</summary>
    public double SecondsSinceOther { get { lock (_gate) return (DateTime.Now - _lastOther).TotalSeconds; } }

    /// <summary>Features for this utterance given the room's current state. Call before updating clocks.</summary>
    public float[] Features(string text)
    {
        var f = new float[Dim];
        _embedder.Embed(text).CopyTo(f, 0);
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var lower = " " + text.ToLowerInvariant() + " ";
        double sinceOther, sinceExchange, sinceDamian;
        lock (_gate)
        {
            var now = DateTime.Now;
            sinceOther = (now - _lastOther).TotalSeconds;
            sinceExchange = (now - _lastExchange).TotalSeconds;
            sinceDamian = (now - _lastDamian).TotalSeconds;
            _lastDamian = now;
        }
        var h = Embedder.Dim;
        f[h + 0] = Responder.MentionsClaude(text) ? 1 : 0;
        f[h + 1] = text.TrimEnd().EndsWith('?') ? 1 : 0;
        f[h + 2] = lower.Contains(" you ") || lower.Contains(" your ") || lower.Contains(" we ") ? 1 : 0;
        f[h + 3] = (float)Math.Exp(-Math.Max(0, sinceOther) / 30);      // ~1 mid-conversation with someone else
        f[h + 4] = (float)Math.Exp(-Math.Max(0, sinceExchange) / 60);   // ~1 just after talking with Claude
        f[h + 5] = (float)Math.Exp(-Math.Max(0, sinceDamian) / 30);     // ~1 mid-monologue, ~0 after silence
        f[h + 6] = Math.Min(words.Length, 20) / 20f;
        return f;
    }

    /// <summary>P(addressed to Claude) for these features.</summary>
    public float Score(float[] features)
    {
        lock (_gate)
        {
            var z = _model.Bias;
            for (var i = 0; i < Dim; i++) z += _model.Weights[i] * features[i];
            return 1f / (1f + MathF.Exp(-z));
        }
    }

    /// <summary>One SGD step: nudge the model toward this labeled example. Saves weights after.</summary>
    public void Train(float[] features, int label, double weight)
    {
        lock (_gate)
        {
            const float lr = 0.08f, l2 = 1e-4f;
            var z = _model.Bias;
            for (var i = 0; i < Dim; i++) z += _model.Weights[i] * features[i];
            var p = 1f / (1f + MathF.Exp(-z));
            var g = (p - label) * (float)weight;
            for (var i = 0; i < Dim; i++)
                _model.Weights[i] -= lr * (g * features[i] + l2 * _model.Weights[i]);
            _model.Bias -= lr * g;
            _model.Updates++;
            Save();
        }
    }

    void Save()
    {
        try { File.WriteAllText(_weightsPath, JsonSerializer.Serialize(_model)); }
        catch (Exception ex) { _log?.Invoke($"Couldn't save addressee weights: {ex.Message}"); }
    }

    static Model? Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var model = JsonSerializer.Deserialize<Model>(File.ReadAllText(path));
            return model?.Weights?.Length == Dim && model.Version == Model.CurrentVersion ? model : null;
        }
        catch { return null; }
    }

    public void Dispose() { }

    public sealed class Model
    {
        public const int CurrentVersion = 1;
        public int Version { get; set; } = CurrentVersion;
        public float[] Weights { get; set; } = [];
        public float Bias { get; set; }
        public int Updates { get; set; }

        /// <summary>Zero weights, bias at a ~10% prior: born cautious, learns from there.</summary>
        public static Model Fresh() => new() { Weights = new float[Dim], Bias = -2.2f };
    }
}
