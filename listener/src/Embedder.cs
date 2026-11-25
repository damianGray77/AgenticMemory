using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Listener;

/// <summary>
/// Turns a sentence into a 384-dimension meaning vector (all-MiniLM-L6-v2, the workhorse
/// sentence-transformer). Two utterances that mean similar things land near each other, which is
/// what lets a tiny logistic regression on top learn "sentences shaped like requests to Claude"
/// from a few dozen examples. Tokenization is BERT WordPiece, implemented here directly: lowercase,
/// split punctuation, then greedy longest-match against vocab.txt with ## continuations.
/// </summary>
public sealed class Embedder : IDisposable
{
    public const int Dim = 384;
    const int MaxTokens = 128;   // utterances, not documents

    readonly InferenceSession _session;
    readonly Dictionary<string, int> _vocab = new(StringComparer.Ordinal);
    readonly int _unk, _cls, _sep;

    public Embedder(string modelPath, string vocabPath)
    {
        if (!File.Exists(modelPath)) throw new FileNotFoundException($"The embedding model \"{modelPath}\" isn't there.", modelPath);
        // Quiet threading, as in SoundTagger: ORT's default per-core spinning pool is waste for a
        // model this small, run once per utterance. Two parked threads keep the latency fine.
        using var options = new SessionOptions { IntraOpNumThreads = 2, InterOpNumThreads = 1 };
        options.AddSessionConfigEntry("session.intra_op.allow_spinning", "0");
        _session = new InferenceSession(modelPath, options);
        var id = 0;
        foreach (var line in File.ReadLines(vocabPath)) _vocab[line.Trim()] = id++;
        _unk = _vocab["[UNK]"]; _cls = _vocab["[CLS]"]; _sep = _vocab["[SEP]"];
    }

    /// <summary>The L2-normalized embedding of this text (mean-pooled over tokens).</summary>
    public float[] Embed(string text)
    {
        var ids = new List<long> { _cls };
        foreach (var word in Words(text))
        {
            foreach (var piece in WordPiece(word))
            {
                ids.Add(piece);
                if (ids.Count >= MaxTokens - 1) break;
            }
            if (ids.Count >= MaxTokens - 1) break;
        }
        ids.Add(_sep);

        var n = ids.Count;
        var inputIds = new DenseTensor<long>(ids.ToArray(), [1, n]);
        var mask = new DenseTensor<long>(Enumerable.Repeat(1L, n).ToArray(), [1, n]);
        var types = new DenseTensor<long>(new long[n], [1, n]);
        using var results = _session.Run(
        [
            NamedOnnxValue.CreateFromTensor("input_ids", inputIds),
            NamedOnnxValue.CreateFromTensor("attention_mask", mask),
            NamedOnnxValue.CreateFromTensor("token_type_ids", types),
        ]);
        var hidden = results.First().AsTensor<float>();   // [1, n, 384]

        var pooled = new float[Dim];
        for (var t = 0; t < n; t++)
            for (var d = 0; d < Dim; d++)
                pooled[d] += hidden[0, t, d];
        var norm = MathF.Sqrt(pooled.Sum(v => v * v));
        if (norm > 0) for (var d = 0; d < Dim; d++) pooled[d] /= norm;
        return pooled;
    }

    /// <summary>BERT basic tokenization: lowercase, strip accents, punctuation becomes its own token.</summary>
    static IEnumerable<string> Words(string text)
    {
        var current = new System.Text.StringBuilder();
        foreach (var raw in text.ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormD))
        {
            var cat = System.Globalization.CharUnicodeInfo.GetUnicodeCategory(raw);
            if (cat == System.Globalization.UnicodeCategory.NonSpacingMark) continue;   // accents
            if (char.IsWhiteSpace(raw) || char.IsControl(raw))
            {
                if (current.Length > 0) { yield return current.ToString(); current.Clear(); }
            }
            else if (char.IsPunctuation(raw) || char.IsSymbol(raw))
            {
                if (current.Length > 0) { yield return current.ToString(); current.Clear(); }
                yield return raw.ToString();
            }
            else current.Append(raw);
        }
        if (current.Length > 0) yield return current.ToString();
    }

    /// <summary>Greedy longest-match WordPiece: "pondering" -> ponder + ##ing. Unmatchable -> [UNK].</summary>
    IEnumerable<int> WordPiece(string word)
    {
        if (word.Length > 50) { yield return _unk; yield break; }
        var at = 0;
        while (at < word.Length)
        {
            var end = word.Length;
            var found = -1;
            while (end > at)
            {
                var piece = (at > 0 ? "##" : "") + word[at..end];
                if (_vocab.TryGetValue(piece, out var id)) { found = id; break; }
                end--;
            }
            if (found < 0) { yield return _unk; yield break; }   // whole word becomes [UNK], per BERT
            yield return found;
            at = end;
        }
    }

    public void Dispose() => _session.Dispose();
}
