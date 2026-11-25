using System;

namespace Listener;

/// <summary>
/// The day-mind's attention gate. Every percept passes through here and is scored
/// locally, for free: embedding novelty against a running centroid of recent speech,
/// speaker changes, re-engagement after long silence, scene changes. The scores
/// accumulate; when the pot crosses the threshold (and enough time has passed since
/// the last notice) the gate fires once, handing back the percept window so the
/// caller can wake the noticer brain. Pure state machine — no I/O, no LLM, no DB.
/// </summary>
public class Salience
{
    readonly float threshold;
    readonly double minGapMinutes;

    // Running centroid of recent speech embeddings (EMA, alpha 0.15): "what today
    // sounds like so far". Novelty is distance from this — a new topic scores high,
    // the fortieth sentence about the same bug scores near zero.
    float[]? centroid;
    const float Alpha = 0.15f;

    float pot;                      // accumulated salience since the last notice
    long windowFrom = -1;           // first percept id in the current window
    long windowTo = -1;             // last percept id in the current window
    string? lastSpeaker;
    DateTime lastSpeechAt = DateTime.MinValue;
    DateTime lastNoticeAt = DateTime.MinValue;

    public Salience(float threshold, double minGapMinutes)
    {
        this.threshold = threshold;
        this.minGapMinutes = minGapMinutes;
    }

    /// <summary>
    /// Score one speech percept. Returns a (from, to, score) window when the gate
    /// fires, null otherwise. Claude's own voice should not reach here.
    /// </summary>
    public (long From, long To, float Score)? AddSpeech(float[]? embedding, string? speaker, long perceptId)
    {
        var now = DateTime.UtcNow;
        float score = 0f;

        // Novelty: how far this utterance sits from the running centroid.
        if (embedding != null)
        {
            if (centroid == null)
            {
                centroid = (float[])embedding.Clone();
                score += 0.5f; // first speech of the day is mildly notable by definition
            }
            else
            {
                score += 1f - Cosine(embedding, centroid);
                for (int i = 0; i < centroid.Length; i++)
                    centroid[i] = (1 - Alpha) * centroid[i] + Alpha * embedding[i];
                Normalize(centroid);
            }
        }

        // A different voice than last time: the room changed shape.
        if (speaker != null && lastSpeaker != null && speaker != lastSpeaker)
            score += 0.3f;

        // Speech after a long quiet stretch: something resumed.
        if (lastSpeechAt != DateTime.MinValue && (now - lastSpeechAt).TotalMinutes > 10)
            score += 0.5f;

        lastSpeaker = speaker ?? lastSpeaker;
        lastSpeechAt = now;

        return Accumulate(score, perceptId, now);
    }

    /// <summary>Score a scene-change percept (webcam or desktop context shift).</summary>
    public (long From, long To, float Score)? AddScene(long perceptId)
        => Accumulate(0.4f, perceptId, DateTime.UtcNow);

    (long From, long To, float Score)? Accumulate(float score, long perceptId, DateTime now)
    {
        if (windowFrom < 0) windowFrom = perceptId;
        windowTo = perceptId;
        pot += score;

        if (pot < threshold) return null;
        if ((now - lastNoticeAt).TotalMinutes < minGapMinutes) return null; // keep simmering

        var fired = (windowFrom, windowTo, pot);
        pot = 0f;
        windowFrom = windowTo = -1;
        lastNoticeAt = now;
        return fired;
    }

    static float Cosine(float[] a, float[] b)
    {
        float dot = 0;
        for (int i = 0; i < a.Length; i++) dot += a[i] * b[i];
        return dot; // embeddings are L2-normalized, so dot == cosine
    }

    static void Normalize(float[] v)
    {
        float norm = 0;
        for (int i = 0; i < v.Length; i++) norm += v[i] * v[i];
        norm = MathF.Sqrt(norm);
        if (norm > 1e-6f)
            for (int i = 0; i < v.Length; i++) v[i] /= norm;
    }
}
