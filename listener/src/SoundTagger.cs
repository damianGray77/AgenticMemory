using System.Threading.Channels;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Listener;

/// <summary>
/// Labels non-speech sound with YAMNet (Google's AudioSet classifier, 521 classes), the gap Whisper
/// leaves: typing, music, a phone ringing. The ONNX export has the mel frontend baked in, so raw
/// 16 kHz mono samples go in and per-frame class scores come out. Scores are uncalibrated, so they
/// are thresholded and smoothed, never treated as probabilities. A line like "Music; Computer keyboard"
/// is emitted only when the smoothed scene CHANGES and has held still long enough -- the point is one
/// percept when the music starts, not two per second while it plays.
/// </summary>
public sealed class SoundTagger : IDisposable
{
    const int WindowSamples = 2 * Transcriber.SampleRate;   // run inference on 2 s of audio at a time
    const float Smoothing = 0.4f;                           // EMA weight of the newest window's scores
    const int MostLabels = 3;                               // a scene is at most this many labels

    readonly InferenceSession _session;
    readonly string[] _labels;
    readonly HashSet<string> _ignore;
    readonly float _threshold;
    readonly TimeSpan _hold;
    readonly Channel<float[]> _audio = Channel.CreateUnbounded<float[]>(new UnboundedChannelOptions { SingleReader = true });
    readonly Task _work;

    public SoundTagger(string modelPath, string classMapPath, IEnumerable<string> ignore, float threshold,
        double holdSeconds, Action<string> onScene, Action<string>? log)
    {
        foreach (var path in new[] { modelPath, classMapPath })
            if (!File.Exists(path)) throw new FileNotFoundException($"The sound model \"{path}\" isn't there.", path);
        // ONNX Runtime's defaults are built for latency: a thread per physical core, busy-spinning
        // between tasks. For a tiny model run every 2s forever, that pool never parks -- measured
        // 13 threads at ~30% each, ~4 cores of pure spin. Two quiet threads are plenty.
        using var options = new SessionOptions { IntraOpNumThreads = 2, InterOpNumThreads = 1 };
        options.AddSessionConfigEntry("session.intra_op.allow_spinning", "0");
        _session = new InferenceSession(modelPath, options);
        _labels = LoadClassMap(classMapPath);
        _ignore = new HashSet<string>(ignore, StringComparer.OrdinalIgnoreCase);
        _threshold = threshold;
        _hold = TimeSpan.FromSeconds(holdSeconds);
        _work = Task.Run(() => RunAsync(onScene, log));
        log?.Invoke($"Loaded {Path.GetFileName(modelPath)} ({_labels.Length} sound classes)");
    }

    /// <summary>Adds audio that was just heard: 16 kHz mono samples. Returns at once.</summary>
    public void Add(float[] samples) => _audio.Writer.TryWrite(samples);

    public void Dispose()
    {
        _audio.Writer.TryComplete();
        try { _work.Wait(TimeSpan.FromSeconds(5)); } catch { }
        _session.Dispose();
    }

    async Task RunAsync(Action<string> onScene, Action<string>? log)
    {
        var buffer = new List<float>(WindowSamples * 2);
        float[]? smoothed = null;
        var lastScene = "";
        var sceneSince = DateTime.MinValue;   // when the current candidate scene was first seen
        var candidate = "";
        var lastDebug = DateTime.MinValue;

        await foreach (var block in _audio.Reader.ReadAllAsync())
        {
            buffer.AddRange(block);
            if (buffer.Count < WindowSamples) continue;
            var window = buffer.ToArray();
            buffer.Clear();

            float[] scores;
            try { scores = Score(window); }
            catch (Exception ex) { log?.Invoke($"Sound tagging failed: {ex.Message}"); continue; }

            if (smoothed == null) smoothed = scores;
            else for (var i = 0; i < smoothed.Length; i++) smoothed[i] += (scores[i] - smoothed[i]) * Smoothing;

            var scene = string.Join("; ", Enumerable.Range(0, smoothed.Length)
                .Where(i => smoothed[i] >= _threshold && !_ignore.Contains(_labels[i]))
                .OrderByDescending(i => smoothed[i])
                .Take(MostLabels)
                .Select(i => _labels[i]));

            // Tuning visibility: what YAMNet is scoring highest right now, at most twice a minute,
            // and only when something non-ignored is at least stirring (scores are uncalibrated).
            if (log != null && DateTime.Now - lastDebug > TimeSpan.FromSeconds(30))
            {
                var top = Enumerable.Range(0, smoothed.Length)
                    .Where(i => !_ignore.Contains(_labels[i]))
                    .OrderByDescending(i => smoothed[i])
                    .Take(3)
                    .Where(i => smoothed[i] >= 0.08f)
                    .Select(i => $"{_labels[i]} {smoothed[i]:0.00}")
                    .ToList();
                if (top.Count > 0) { log($"Top sounds: {string.Join("; ", top)}"); lastDebug = DateTime.Now; }
            }

            // A new scene must hold through _hold before it's worth a row; flapping back resets nothing.
            if (scene != candidate) { candidate = scene; sceneSince = DateTime.Now; }
            if (candidate != lastScene && DateTime.Now - sceneSince >= _hold)
            {
                lastScene = candidate;
                if (candidate.Length > 0) onScene(candidate);   // silence returning isn't an event
            }
        }
    }

    float[] Score(float[] window)
    {
        var input = new DenseTensor<float>(window, [window.Length]);
        using var results = _session.Run([NamedOnnxValue.CreateFromTensor("waveform", input)]);
        var frames = (DenseTensor<float>)results[0].Value;        // [frames, 521]
        var count = frames.Dimensions[0];
        var scores = new float[frames.Dimensions[1]];
        for (var f = 0; f < count; f++)
            for (var c = 0; c < scores.Length; c++)
                scores[c] += frames[f, c] / count;                // mean over the window's frames
        return scores;
    }

    // index,mid,display_name -- display_name may be quoted and contain commas.
    static string[] LoadClassMap(string path)
    {
        var labels = new List<string>();
        foreach (var line in File.ReadLines(path).Skip(1))
        {
            var second = line.IndexOf(',', line.IndexOf(',') + 1);
            if (second < 0) continue;
            labels.Add(line[(second + 1)..].Trim().Trim('"'));
        }
        return labels.ToArray();
    }
}
