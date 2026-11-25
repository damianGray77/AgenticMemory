using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Listener;

/// <summary>
/// The persistent mind behind the voice: ONE headless Claude process kept alive all day in
/// stream-json mode, instead of a cold CLI start per question (which cost 7-9s; the API turn
/// itself is under a second). Persistence buys three things at once: latency, conversational
/// memory across spoken exchanges (it is one session, not amnesiac one-shots), and tools --
/// the --settings allow list gives it read-only memdb over the claude_memory database, so
/// "what did we work on this morning?" is a query, not an apology. The session is recycled
/// quietly after enough turns or hours so its context never grows without bound.
/// </summary>
public sealed class Brain : IDisposable
{
    readonly string _claude;
    readonly string _model;
    readonly string _settings;
    readonly string _instructions;
    readonly Action<string>? _log;
    readonly object _gate = new();

    Process? _proc;
    TaskCompletionSource<string>? _turn;
    Action<string>? _onText;                 // live text deltas for the current turn (streamed TTS)
    readonly StringBuilder _texts = new();   // assistant text accumulated for the current turn
    int _turns;
    DateTime _born;

    const int RecycleTurns = 120;
    static readonly TimeSpan RecycleAge = TimeSpan.FromHours(10);

    public Brain(string claudePath, string model, string settingsPath, string instructions, Action<string>? log)
    {
        _claude = claudePath;
        _model = model;
        _settings = settingsPath;
        _instructions = instructions;
        _log = log;
    }

    /// <summary>Spawn the session now (first reply is slow otherwise) -- safe to call again.</summary>
    public async Task WarmUpAsync()
    {
        try { await EnsureStartedAsync(); }
        catch (Exception ex) { _log?.Invoke($"Brain warm-up failed: {ex.Message}"); }
    }

    /// <summary>One spoken turn: send the utterance, get the reply text. onText receives the raw
    /// text deltas as the model produces them (for speaking sentences before the turn finishes).
    /// Null on timeout/failure (the session is recycled, so the next ask starts clean).</summary>
    public async Task<string?> AskAsync(string message, TimeSpan patience, Action<string>? onText = null)
    {
        try
        {
            await EnsureStartedAsync();
            var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate) { _turn = tcs; _texts.Clear(); _onText = onText; }
            await SendAsync(message);
            var done = await Task.WhenAny(tcs.Task, Task.Delay(patience));
            if (done != tcs.Task)
            {
                _log?.Invoke($"Brain turn exceeded {patience.TotalSeconds:0}s; recycling the session.");
                Kill();
                return null;
            }
            _turns++;
            return await tcs.Task;
        }
        catch (Exception ex)
        {
            _log?.Invoke($"Brain failed: {ex.Message}");
            Kill();
            return null;
        }
        finally { lock (_gate) { _turn = null; _onText = null; } }
    }

    async Task EnsureStartedAsync()
    {
        if (_proc is { HasExited: false } && _turns < RecycleTurns && DateTime.Now - _born < RecycleAge) return;
        Kill();
        var psi = new ProcessStartInfo("cmd.exe")
        {
            ArgumentList = { "/c", _claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--include-partial-messages", "--model", _model, "--settings", _settings },
            WorkingDirectory = @"{{LISTENER_ROOT_WIN}}",
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        psi.Environment["CLAUDE_MEMORY_SKIP_BOOT"] = "1";   // a voice, not a work session: no boot
        var clock = Stopwatch.StartNew();
        _proc = Process.Start(psi)!;
        // The ears outrank the mouth: a brain spawn (node startup) or a busy turn must never starve
        // Whisper of CPU. Children inherit the class, so the whole cmd->claude->node chain rides along.
        try { _proc.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { /* best effort */ }
        _born = DateTime.Now;
        _turns = 0;
        _ = Task.Run(() => ReadLoop(_proc));
        _ = Task.Run(() => DrainErrors(_proc));
        // The first turn carries the standing instructions; its reply ("ready") is discarded.
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) { _turn = tcs; _texts.Clear(); }
        await SendAsync(_instructions);
        var done = await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromSeconds(60)));
        lock (_gate) _turn = null;
        if (done != tcs.Task) { Kill(); throw new InvalidOperationException("Voice session never answered its setup message."); }
        _log?.Invoke($"Brain session up ({_model}) in {clock.Elapsed.TotalSeconds:0.0}s.");
    }

    async Task SendAsync(string text)
    {
        var line = JsonSerializer.Serialize(new { type = "user", message = new { role = "user", content = text } });
        await _proc!.StandardInput.WriteLineAsync(line);
        await _proc.StandardInput.FlushAsync();
    }

    void ReadLoop(Process proc)
    {
        try
        {
            while (proc.StandardOutput.ReadLine() is { } line)
            {
                if (line.Length == 0) continue;
                try { Handle(line); }
                catch { /* one unparseable event is not worth the session */ }
            }
        }
        catch { }
        _log?.Invoke("Brain session ended.");
    }

    void Handle(string line)
    {
        using var doc = JsonDocument.Parse(line);
        var root = doc.RootElement;
        if (!root.TryGetProperty("type", out var typeEl)) return;
        var type = typeEl.GetString();
        if (type == "stream_event")
        {
            // A raw API delta: the text arrives word-by-word, which is what lets the mouth start
            // speaking sentence one while sentence three is still being thought up.
            if (root.TryGetProperty("event", out var ev)
                && ev.TryGetProperty("type", out var et) && et.GetString() == "content_block_delta"
                && ev.TryGetProperty("delta", out var delta)
                && delta.TryGetProperty("type", out var dt) && dt.GetString() == "text_delta")
            {
                Action<string>? onText;
                lock (_gate) onText = _onText;
                onText?.Invoke(delta.GetProperty("text").GetString() ?? "");
            }
        }
        else if (type == "assistant")
        {
            // Accumulate text blocks; a turn with tool use has several assistant messages and the
            // final text is what gets spoken (the result event's result field is authoritative).
            if (root.TryGetProperty("message", out var msg) && msg.TryGetProperty("content", out var content))
                lock (_gate)
                    foreach (var block in content.EnumerateArray())
                        if (block.TryGetProperty("type", out var bt) && bt.GetString() == "text")
                            _texts.Append(block.GetProperty("text").GetString());
        }
        else if (type == "result")
        {
            string? final = null;
            if (root.TryGetProperty("result", out var r) && r.ValueKind == JsonValueKind.String) final = r.GetString();
            lock (_gate)
            {
                final ??= _texts.ToString();
                _turn?.TrySetResult(final.Trim());
            }
        }
    }

    void DrainErrors(Process proc)
    {
        try
        {
            while (proc.StandardError.ReadLine() is { } line)
                if (line.Trim().Length > 0) _log?.Invoke($"Brain stderr: {line.Trim()}");
        }
        catch { }
    }

    void Kill()
    {
        try { _proc?.Kill(entireProcessTree: true); } catch { }
        try { _proc?.Dispose(); } catch { }
        _proc = null;
    }

    public void Dispose() => Kill();
}
