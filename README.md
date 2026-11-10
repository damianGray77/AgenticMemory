# AgenticMemory

Database-backed long-term memory for Claude Code, in one SQLite file. Every session boots from
the database and writes back to it as it works; every raw transcript is archived losslessly and
indexed for full-text search; and a scheduled consolidation pass distils session notes into
memories, checks each memory against the conversation it came from, works out the current
guidance ("behaviours"), and keeps a per-project digest of recent work that each new session
opens with.

**No database server and nothing to download.** Windows 10 and 11 ship SQLite
(`winsqlite3.dll`, with full-text search) and a C# compiler (.NET Framework 4.8). The installer
compiles a small command-line tool, `memdb.exe`, from the source in this repo, and that is the
whole database stack.

The repo holds the system, not anyone's data: the database it creates starts empty apart from a
few rows of configuration (see [What's in the database](#whats-in-the-database)).

## How it works

```
 Claude Code session
 ├─ SessionStart ─► archive_transcripts.ps1   sweep ~/.claude/projects/**/*.jsonl into `transcripts`
 │                                            (verbatim, compressed) + `transcript_messages` (FTS5)
 ├─ SessionStart ─► session_boot.sh           match the project (SVN UUID or path), open a `sessions`
 │  (startup)                                 row, run the daily mechanical tier, print recent work,
 │                                            behaviours, status and the rules
 ├─ during work ──► memory skill / mem.ps1    session notes, memories, observations, back-pointers
 │                  recall skill              search transcripts + notes + memories, cite verbatim
 │                  claude_scanner.sh         code index: files, entities, dependencies
 └─ SessionEnd ───► archive_transcripts.ps1   capture the finished transcript
                    session_close.sh          (optional) mark the session row completed

 Scheduled (optional)
 └─ Task ClaudeMemoryConsolidation           every 3 h: `claude -p /consolidate-memory-db` promotes or
                                             dismisses notes, merges duplicates, confirms memories
                                             against transcripts, resolves behaviours, writes the digest
```

The consolidation pass never writes tables directly. It calls procedures (`CALL sp_promote_note(...)`
and 20 others) that `memdb` implements: each runs in one transaction and enforces a kill switch,
dry-run mode, confidence thresholds and per-run caps from `consolidation_config`, logging every
action with before/after JSON to `consolidation_log` so any run can be reverted. The mechanical
tier (decay stale observations, expire past-TTL memories) is pure SQL and runs from session boot,
at most once a day.

`CLAUDE.md` holds the rules that make Claude use all of this. Read it before installing: it is the
original author's global instruction file, so it also carries a rule that is not about memory
(Rule 10 plays a sound at the end of long responses).

### memdb

`memdb.exe` replaces a database server's command-line client:

```
memdb -e "SELECT ..."         run statements          -N  no header row
memdb -f script.sql           run a file              -r  raw values (no \t \n \\ escaping)
memdb < script.sql            run stdin               -E  one field per line
memdb --path | --procs | --version
```

It finds the database itself (`--db`, else `%CLAUDE_MEMORY_DB%`, else `bin\memdb.dbpath`, else
`claude_memory.db` beside `bin\`), turns on foreign keys, waits up to 30 s for a lock, and adds the
SQL functions the system relies on: `now()` (local time; the Windows SQLite build has no
`localtime`), `to_utc()` / `to_local()`, `fts_any()` (natural-language full-text queries),
`compress()` / `uncompress()` (MySQL's COMPRESS format, so archives from a MySQL-era install copy
across byte for byte), `sha256()`, `readfile()` / `writefile()`, math functions, and MySQL
compatibility helpers (`LEFT`, `LOCATE`, `DATE_FORMAT`, `TIMESTAMPDIFF`, `REGEXP`). It ignores
`USE <db>;` so old habits do not fail.

## What's in the repo

| Path | Installs to | What it is |
|---|---|---|
| `memdb/` | `~/.claude/bin/memdb.exe` | C# 5 source + build script for the database tool and the 21 procedures |
| `home/CLAUDE.md` | `~/.claude/CLAUDE.md` | The global rules (Rules 1-11) |
| `home/session_boot.sh` | `~/.claude/` | SessionStart boot |
| `home/session_close.sh` | `~/.claude/` | SessionEnd close of this session's row (opt-in) |
| `home/archive_transcripts.ps1` | `~/.claude/` | Lossless transcript archive + message index |
| `home/claude_scanner.sh`, `scanner_awk.sh` | `~/.claude/` | Code index scanner (C#, PHP, JS/TS, Python, C++) |
| `home/claude_memory_schema.sql` | `~/.claude/` | Tables, full-text indexes, triggers |
| `home/consolidator/*.sql` | `~/.claude/consolidator/` | Views for each consolidation stage, and the design notes for each |
| `home/skills/memory/` | `~/.claude/skills/memory/` | `/memory` skill + `mem.ps1`, the only write path |
| `home/skills/recall/` | `~/.claude/skills/recall/` | `/recall` skill |
| `home/skills/consolidate-memory-db/` | `~/.claude/skills/consolidate-memory-db/` | The consolidation pass |
| `consolidator-runner/` | `C:\Tools\consolidator\` | Headless runner for the scheduled task + its scoped permissions |
| `db/seed.sql` | the database | Reference queries, consolidation config, evidence weight scale |
| `install.ps1` | | Builds memdb, renders the templates, creates the database, wires the hooks |
| `tools/export-from-live.ps1` | | Refreshes this repo from a live install |
| `manifest.psd1` | | The file list both scripts share |

Files under `home/`, `consolidator-runner/` and `db/seed.sql` are **templates**: paths and the
user's name appear as `{{TOKENS}}` that `install.ps1` fills in.

## What's in the database

A new database contains the schema and three small configuration tables, nothing else:
`reference_queries` (15 query templates), `consolidation_config` (the rails: kill switch, dry-run,
caps, thresholds) and `behaviour_evidence_kinds` (the weight scale). Sessions, notes, memories,
observations, behaviours, the digest and the transcript archive all start empty and fill as you
work. The database file is never committed (`*.db` is git-ignored).

## Requirements

- Windows 10 (1903 or later) or Windows 11, with Windows PowerShell 5.1 (built in)
- **Git for Windows**, for Git Bash: the boot hook and the scanner are bash scripts
- **Claude Code**
- Optional: `svn` on the PATH, so boot can match projects by repository UUID wherever they are checked out

## Install

1. Install Git for Windows and Claude Code.
2. Clone this repo anywhere:
   ```
   git clone https://github.com/damianGray77/AgenticMemory.git
   cd AgenticMemory
   ```
3. Run the installer from a normal PowerShell window:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName "Alex"
   ```
4. Start a **new** Claude Code session. Its context should open with `=== SESSION: <n> ===` and
   the boot sections. If it doesn't, see [Troubleshooting](#troubleshooting).
5. Register your projects so boot can recognise them and the code index gets built:
   ```
   bash ~/.claude/claude_scanner.sh onboard <slug> '<Name>' 'C:/path/to/project'
   bash ~/.claude/claude_scanner.sh deps <slug>
   ```
6. Optional, recommended: turn on the 3-hourly consolidation pass (below).

### Installer options

| Option | Default | |
|---|---|---|
| `-UserName` | (required) | Your name as the skills refer to you |
| `-ClaudeHome` | `%USERPROFILE%\.claude` | |
| `-DbPath` | `<ClaudeHome>\claude_memory.db` | Anywhere local; written to `bin\memdb.dbpath` when not the default |
| `-ConsolidatorRoot` | `C:\Tools\consolidator` | Where the scheduled runner lives |
| `-ClaudeCli` | `claude` on the PATH | CLI the scheduled runner calls |
| `-WireSessionClose` | off | Also add `session_close.sh` as a SessionEnd hook |
| `-RegisterConsolidationTask` | off | Register the 3-hourly scheduled task |
| `-SkipFiles` `-SkipDatabase` `-SkipSettings` | | Run only part of the install |

### What the installer changes

- **memdb**: compiled into `~/.claude/bin/memdb.exe`.
- **Files**: writes the rendered templates. Any existing file it would change is first copied to
  `~/.claude/backups/claude-memory-install-<timestamp>/`.
- **`CLAUDE.md`**: if you already have one with your own instructions, they are kept and the rules
  are appended inside a `<!-- BEGIN claude-memory rules -->` block that a re-install replaces in place.
- **`settings.json`**: adds the hooks (skipping any already there), leaves everything else alone,
  and sets `"autoMemoryEnabled": false` so Claude Code's own file-based memory does not compete
  with the database (Rule 1).
- **Database**: creates the file if missing, otherwise first saves a consistent copy
  (`VACUUM INTO`) beside the file backups; then creates missing tables and indexes, refreshes the
  reference queries, adds missing config rows, and replaces the views.

Re-running it is safe and is how you upgrade. It does **not** alter existing tables: if a new
version adds a column, apply that `ALTER TABLE` by hand (the schema file shows the target).

### Turning on scheduled consolidation

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName "Alex" -SkipFiles -SkipDatabase -SkipSettings -RegisterConsolidationTask -ClaudeCli "C:\Tools\npm\claude.cmd"
```

This registers `ClaudeMemoryConsolidation`, running every 3 hours while you are logged on (missed
runs catch up), with a 30-minute limit. It calls `claude -p "/consolidate-memory-db"` with the
narrow permissions in `runner-settings.json` and sets `CLAUDE_MEMORY_SKIP_BOOT=1` so the run does
not open a session row of its own. Logs go to `C:\Tools\consolidator\logs\`.

- **The CLI must be reachable from a scheduled task.** The Claude desktop app virtualizes
  `AppData\Roaming` for tools run inside it, so a CLI installed from there may not exist for a
  scheduled task. Install one outside AppData, e.g.
  `npm install -g @anthropic-ai/claude-code --prefix C:\Tools\npm`, log it in once by running
  `C:\Tools\npm\claude.cmd`, and pass `-ClaudeCli C:\Tools\npm\claude.cmd`.
- **It runs live.** `db/seed.sql` carries settings where every stage is on and `dry_run = 0`. To
  watch a few runs first:
  `"%USERPROFILE%\.claude\bin\memdb.exe" -e "UPDATE consolidation_config SET cfg_value = '1' WHERE cfg_key IN ('dry_run', 'confirm_dry_run');"`
  Proposals then land in `consolidation_log` without changing anything. The kill switch is `enabled = 0`.

## Installing with Claude's help

On the new machine, Claude Code can do this. Clone the repo, open Claude Code in the clone, and ask
it to "install this following the README". The hooks and rules take effect from the next new
session, not the one that ran the install.

## Moving to another machine

The whole memory is one file. Close Claude Code sessions, copy `claude_memory.db` (plus any
`-wal`/`-shm` files beside it) to the new machine, install, and point projects at their new folders:
`memdb -e "UPDATE projects SET root_path = 'D:\Code\X' WHERE slug = 'x';"`.
The transcript archive makes the file large over time (about 1 GB after a few months of daily use).

## Keeping this repo up to date

The live system changes as it is worked on. To pull the live versions back into the repo:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\export-from-live.ps1 -UserName Alex
git diff
```

The export applies the reverse substitutions, regenerates `db/seed.sql` from the live configuration
tables (never from sessions, memories or transcripts), and then scans every exported file for
anything still machine- or work-specific: your Windows user name, your name, the real paths, and
every term in `tools/leak-terms.local.txt` (git-ignored; list client names, project names and ticket
prefixes there). It exits 1 if it finds one. To add a file to the system, list it in
`manifest.psd1`, re-export, commit. memdb's source lives only here, in `memdb/src`.

## Troubleshooting

- **No `=== SESSION` block at startup**: run `bash ~/.claude/session_boot.sh` in a terminal. A
  `claude_memory UNAVAILABLE` line names the problem (usually a missing database: re-run the
  installer). The boot hook only fires on a fresh `startup`, not on resume.
- **First sessions are slow to start**: the first transcript sweep on a machine with a lot of
  history can exceed the hook's 120 s timeout. It is incremental and finishes over the next starts.
- **`database is locked`**: memdb waits 30 s for another writer. A long transcript ingest can hold
  the lock longer on a first sweep; the failed write is retried by the next hook.
- **`mem.ps1` is blocked**: always call it with `-ExecutionPolicy Bypass`, as the rules do.

## Known limits

- Windows only as written: Windows PowerShell 5.1, Git Bash, Windows paths, Windows' own SQLite.
- One transcript must be under ~900 MB (SQLite's value size limit); larger ones are skipped with a warning.
- `claude_scanner.sh migrate-history` needs a Python helper that is not included.
- Not part of this bundle: secret-scanning and delete-guard hooks, ticket-system skills, and
  integrations for other agents (the boot and close scripts work for any agent that runs
  SessionStart/SessionEnd hooks with `CLAUDE_CODE_SESSION_ID` set).
