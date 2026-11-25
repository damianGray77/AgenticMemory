using System.Diagnostics;
using System.Text.Json;

namespace Listener;

/// <summary>
/// The hands behind a [TASK] hand-off. Each queued voice task gets its own one-shot headless
/// Claude session (claude -p in auto permission mode with prompts auto-denied: it reads, queries
/// and uses the todo skills on its own, and anything that would need {{USER_NAME}}'s approval is refused
/// rather than left hanging). The run claims the voice_tasks row, saves the result and session id
/// on it, and speaks a short summary at the next quiet moment. Every run is a real resumable
/// transcript: `claude --desktop --resume &lt;session id&gt;` pulls it into the desktop app.
/// </summary>
public sealed class Worker
{
    readonly string _claude;
    readonly string _model;
    readonly string _settings;
    readonly TimeSpan _timeout;
    readonly bool _adopt;                            // surface each finished run in the desktop app
    readonly Action<string, (string Name, object Value)[]> _exec;
    readonly Func<string, bool> _speak;              // Responder.AskAloud: false while the room is mid-conversation
    readonly Action<string>? _log;
    readonly SemaphoreSlim _oneAtATime = new(1, 1);  // serial: two unattended workers racing helps nobody

    public Worker(string claudePath, string model, string settingsPath, int timeoutMinutes, bool adopt,
        Action<string, (string Name, object Value)[]> exec, Func<string, bool> speak, Action<string>? log)
    {
        _claude = claudePath;
        _model = model;
        _settings = settingsPath;
        _timeout = TimeSpan.FromMinutes(timeoutMinutes);
        _adopt = adopt;
        _exec = exec;
        _speak = speak;
        _log = log;
    }

    /// <summary>Run one queued task in the background; returns immediately. Tasks run one at a time.</summary>
    public void Run(long id, string request) => _ = Task.Run(async () =>
    {
        await _oneAtATime.WaitAsync();
        try { await RunAsync(id, request); }
        catch (Exception ex)
        {
            _log?.Invoke($"Worker crashed on task {id}: {ex.Message}");
            Finish(id, $"FAILED before completion: {ex.Message}");
        }
        finally { _oneAtATime.Release(); }
    });

    async Task RunAsync(long id, string request)
    {
        _exec("UPDATE voice_tasks SET status = 'picked_up', picked_up_by = 'voice-worker' WHERE id = @id",
            [("@id", id)]);
        _log?.Invoke($"Worker starting task {id}: {request}");

        var psi = new ProcessStartInfo("cmd.exe")
        {
            ArgumentList = { "/c", _claude, "-p", "--output-format", "json", "--model", _model,
                             "--settings", _settings, "--permission-mode", "auto", "--permission-prompts", "none",
                             "--name", TitleFor(request) },
            WorkingDirectory = @"{{LISTENER_ROOT_WIN}}",
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
        };
        psi.Environment["CLAUDE_MEMORY_SKIP_BOOT"] = "1";   // a task run, not a work session: its own boot would mint an orphan DB session
        var clock = Stopwatch.StartNew();
        using var proc = Process.Start(psi)!;
        // The ears outrank the hands: Parakeet must never be starved of CPU by a busy worker.
        try { proc.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { /* best effort */ }

        // The prompt goes over stdin, not the command line: no cmd.exe quoting hazards, no 8K limit.
        await proc.StandardInput.WriteAsync(
            "This task was dispatched by voice through {{USER_NAME}}'s ambient listener; you are an unattended worker " +
            "session on his work machine. The spoken request, restated by the voice assistant:\n\n" +
            $"\"{request}\"\n\n" +
            "Do the work now. Ground rules:\n" +
            "- Tools you are set up for: the todo skills (/todo, /todo-task, /todo-recent) for {{USER_NAME}}'s EmailTodo " +
            "task list; read-only SQL over the claude_memory database " +
            "(\"{{MEMDB_POSIX}}\" -e \"<SQL>\", schema at " +
            @"{{CLAUDE_HOME_WIN}}\claude_memory_schema.sql" + "); reading files; and session notes through the " +
            "memory skill's mem.ps1. Write to the database no other way, and never touch the voice_tasks table " +
            "-- the listener owns your task's row.\n" +
            "- You run unattended in auto permission mode: anything needing interactive approval is denied " +
            "automatically. If a denial blocks the heart of the task, stop and say plainly what needs {{USER_NAME}}.\n" +
            "- Never act on production systems, send anything externally, or push to remotes.\n" +
            "- Your FINAL message is read ALOUD to {{USER_NAME}} by text-to-speech and saved on the task row: one to " +
            "three short conversational sentences of plain text. No markdown, no lists, no file paths.");
        proc.StandardInput.Close();
        var output = proc.StandardOutput.ReadToEndAsync();
        var errors = proc.StandardError.ReadToEndAsync();

        using var cts = new CancellationTokenSource(_timeout);
        try { await proc.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            Finish(id, $"FAILED: timed out after {_timeout.TotalMinutes:0} minutes");
            Say($"Sorry, that task timed out after {_timeout.TotalMinutes:0} minutes. It's noted on the task row.");
            return;
        }

        string? sessionId = null, result = null;
        var isError = false;
        var raw = (await output).Trim();
        try
        {
            // --output-format json prints one result object; anything a wrapper printed before it is noise.
            using var doc = JsonDocument.Parse(raw[raw.IndexOf('{')..]);
            var root = doc.RootElement;
            sessionId = root.TryGetProperty("session_id", out var sid) ? sid.GetString() : null;
            result = root.TryGetProperty("result", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString() : null;
            isError = root.TryGetProperty("is_error", out var e) && e.GetBoolean();
        }
        catch (Exception ex)
        {
            isError = true;
            result = $"unparseable claude output ({ex.Message}): {(await errors).Trim()}";
        }

        var note = (sessionId != null ? $"session {sessionId}\n" : "") +
                   (isError ? "FAILED: " : "") + (result ?? "(no result text)");
        Finish(id, note.Length > 4000 ? note[..4000] : note);
        _log?.Invoke($"Worker task {id} {(isError ? "FAILED" : "done")} in {clock.Elapsed.TotalMinutes:0.0}m " +
                     $"(exit {proc.ExitCode}, session {sessionId ?? "none"}): {result ?? "(no result)"}");

        // Surface the finished run as a session in the Claude desktop app ({{USER_NAME}}: a voice-created
        // task session should ALWAYS be visible there). `--desktop` refuses redirected output, so
        // the child keeps its own hidden console and all we learn is the exit code.
        if (_adopt && sessionId != null)
            try
            {
                using var adopt = Process.Start(new ProcessStartInfo("cmd.exe")
                {
                    ArgumentList = { "/c", _claude, "--desktop", "--resume", sessionId },
                    WorkingDirectory = @"{{LISTENER_ROOT_WIN}}",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                })!;
                using var adoptCts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                await adopt.WaitForExitAsync(adoptCts.Token);
                _log?.Invoke($"Desktop adoption of session {sessionId}: exit {adopt.ExitCode}");
            }
            catch (Exception ex) { _log?.Invoke($"Desktop adoption of session {sessionId} failed: {ex.Message}"); }

        var line = result is { Length: > 0 } ? result : "I couldn't get a result for that task.";
        // The reply is written to be spoken, but an unattended model can still ramble: cut at a
        // sentence boundary rather than reading an essay into the room; the row keeps the whole text.
        if (line.Length > 400)
        {
            var cut = line.IndexOfAny(['.', '!', '?'], 350);
            line = cut > 0 ? line[..(cut + 1)] : line[..400];
        }
        Say((isError ? "That task hit a problem. " : "") + line);
    }

    // Desktop-app session title: the restated request, one line, cut at a word boundary. Quotes are
    // stripped because the name travels through cmd.exe /c.
    static string TitleFor(string request)
    {
        var t = string.Join(' ', request.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            .Replace("\"", "").Replace("&", "and").Replace("|", " ").Replace("<", "").Replace(">", "").Replace("%", "").Replace("^", "");
        if (t.Length > 80)
        {
            var sp = t.LastIndexOf(' ', 80);
            t = t[..(sp > 40 ? sp : 80)] + "...";
        }
        return t.Length > 0 ? t : "Voice task";
    }

    void Finish(long id, string notes) =>
        _exec("UPDATE voice_tasks SET status = 'done', completed_at = @at, notes = @n WHERE id = @id",
            [("@at", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")), ("@n", notes), ("@id", id)]);

    // AskAloud declines while an exchange is running or the room is mid-conversation, so a finished
    // task waits for a quiet moment instead of talking over people -- and gives up after 10 minutes
    // (the result is on the row either way).
    void Say(string text) => _ = Task.Run(async () =>
    {
        for (var i = 0; i < 10; i++)
        {
            if (_speak(text)) return;
            await Task.Delay(TimeSpan.FromSeconds(60));
        }
        _log?.Invoke($"Never found a quiet moment to speak: {text}");
    });
}
