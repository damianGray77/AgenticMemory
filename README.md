# AgenticMemory

Database-backed long-term memory for Claude Code. Every session boots from a local MySQL database
and writes back to it as it works; every raw transcript is archived losslessly and indexed for
full-text search; and a scheduled consolidation pass distils session notes into memories, checks
each memory against the conversation it came from, works out the current guidance ("behaviours"),
and keeps a per-project digest of recent work that each new session opens with.

This repo is the whole system as it runs on the original machine: scripts, skills, global rules,
schema, stored procedures, seed data and the scheduled runner. It holds **no memories or
transcripts** (see [Bringing your data along](#bringing-your-data-along)).

## How it works

```
 Claude Code session
 ├─ SessionStart ─► archive_transcripts.ps1   sweep ~/.claude/projects/**/*.jsonl into `transcripts`
 │                                            (verbatim, compressed) + `transcript_messages` (FULLTEXT)
 ├─ SessionStart ─► session_boot.sh           match project (SVN UUID or path), open a `sessions` row,
 │  (startup)                                 print recent-work digest, behaviours, status, rules
 ├─ during work ──► memory skill / mem.ps1    session notes, memories, observations, back-pointers
 │                  recall skill              search transcripts + notes + memories, cite verbatim
 │                  claude_scanner.sh         code index: files, entities, dependencies
 └─ SessionEnd ───► archive_transcripts.ps1   capture the finished transcript
                    session_close.sh          (optional) mark the session row completed

 In the background
 ├─ MySQL event ev_consolidate_mechanical    hourly; real work once a day: decay stale observations,
 │                                           expire past-TTL memories. Pure SQL, no Claude.
 └─ Task ClaudeMemoryConsolidation           every 3 h: `claude -p /consolidate-memory-db` promotes or
                                             dismisses notes, merges duplicates, confirms memories
                                             against transcripts, resolves behaviours, writes the digest
```

The judgment tier never writes tables directly. It calls stored procedures (`sp_*`) that enforce
a kill switch, dry-run mode, confidence thresholds and per-run caps from `consolidation_config`,
and log every action with before/after JSON to `consolidation_log`, so any run can be reverted.

`CLAUDE.md` holds the rules that make Claude use all of this. Read it before installing: it is
the original global instruction file, so it also carries a couple of rules that are not about
memory (Rule 10 plays a sound at the end of long responses).

## What's in the repo

| Path | Installs to | What it is |
|---|---|---|
| `home/CLAUDE.md` | `~/.claude/CLAUDE.md` | The global rules (Rules 1-11) |
| `home/session_boot.sh` | `~/.claude/` | SessionStart boot: project match, session row, digest, behaviours |
| `home/session_close.sh` | `~/.claude/` | SessionEnd close of this session's row (opt-in) |
| `home/archive_transcripts.ps1` | `~/.claude/` | Lossless transcript archive + message index |
| `home/claude_scanner.sh`, `scanner_awk.sh` | `~/.claude/` | Code index scanner (C#, PHP, JS/TS, Python, C++) |
| `home/claude_memory_schema.sql` | `~/.claude/` | All tables. CLAUDE.md's Schema Maintenance rule keeps it in step with the live DB |
| `home/consolidator/*.sql` | `~/.claude/consolidator/` | Views + stored procedures for each consolidation stage |
| `home/skills/memory/` | `~/.claude/skills/memory/` | `/memory` skill + `mem.ps1`, the only write path |
| `home/skills/recall/` | `~/.claude/skills/recall/` | `/recall` skill |
| `home/skills/consolidate-memory-db/` | `~/.claude/skills/consolidate-memory-db/` | The consolidation pass the scheduled task runs |
| `consolidator-runner/` | `C:\Tools\consolidator\` | Headless runner + its scoped permissions |
| `db/server-settings.sql` | MySQL | `event_scheduler = ON`, `max_allowed_packet = 1G` (persisted) |
| `db/seed.sql` | MySQL | Reference queries, consolidation config, evidence weight scale |
| `db/event.sql` | MySQL | The hourly mechanical-consolidation event |
| `install.ps1` | | Renders the templates and installs everything |
| `tools/export-from-live.ps1` | | Refreshes this repo from a live install |
| `manifest.psd1` | | The file list both scripts share |

Files under `home/`, `consolidator-runner/` and `db/seed.sql` are **templates**: paths, MySQL
credentials, the database name and the user's name appear as `{{TOKENS}}` that `install.ps1`
fills in.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in)
- **MySQL Server 8.0** running locally (tested on 8.0.33), and an account that can create databases,
  procedures and events and `SET PERSIST` server variables. The original uses `root`.
- **Git for Windows**, for Git Bash: the boot hook and the scanner are bash scripts
- **Claude Code**
- Optional: `svn` on the PATH, so boot can match projects by repository UUID wherever they are checked out

The MySQL password ends up in the installed scripts in plain text, as on the original machine, and
the installer accepts only letters, digits and `_ . @ # % ^ + = ~ , : -` because the password goes
into bash and PowerShell commands unquoted. Use an account that only listens on localhost.

## Install

1. Install the requirements above and make sure MySQL is running.
2. Clone this repo anywhere:
   ```
   git clone https://github.com/damianGray77/AgenticMemory.git
   cd AgenticMemory
   ```
3. Run the installer from a normal PowerShell window (not from inside a sandboxed app):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName "Damian"
   ```
   It asks for the MySQL password (or pass `-MysqlPassword`, or set `CLAUDE_MEMORY_PASSWORD`).
4. Start a **new** Claude Code session. Its context should open with `=== SESSION: <n> ===` and
   the boot sections. If it doesn't, see [Troubleshooting](#troubleshooting).
5. Register your projects so boot can recognise them and the code index gets built:
   ```
   bash ~/.claude/claude_scanner.sh onboard <slug> '<Name>' 'C:/path/to/project'
   bash ~/.claude/claude_scanner.sh deps <slug>
   ```
6. Optional, recommended: turn on the 3-hourly consolidation pass (step below).

### Installer options

| Option | Default | |
|---|---|---|
| `-UserName` | (required) | Your name as the skills refer to you |
| `-MysqlUser` / `-MysqlPassword` | `root` / prompt | MySQL account |
| `-MysqlExe` | newest `C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe` | |
| `-DbName` | `claude_memory` | |
| `-ClaudeHome` | `%USERPROFILE%\.claude` | |
| `-ConsolidatorRoot` | `C:\Tools\consolidator` | Where the scheduled runner lives |
| `-ClaudeCli` | `claude` on the PATH | CLI the scheduled runner calls |
| `-WireSessionClose` | off | Also add `session_close.sh` as a SessionEnd hook |
| `-RegisterConsolidationTask` | off | Register the 3-hourly scheduled task |
| `-SkipFiles` `-SkipDatabase` `-SkipServerSettings` `-SkipSettings` | | Run only part of the install |

### What the installer changes

- **Files**: writes the rendered templates. Any existing file it would change is first copied to
  `~/.claude/backups/claude-memory-install-<timestamp>/`.
- **`CLAUDE.md`**: if you already have one with your own instructions, they are kept and the
  rules are appended inside a `<!-- BEGIN claude-memory rules -->` block that a re-install
  replaces in place.
- **`settings.json`**: adds the hooks (skipping any that are already there), leaves everything
  else alone, and sets `"autoMemoryEnabled": false` so Claude Code's own file-based memory does
  not compete with the database (Rule 1).
- **MySQL**: persists `event_scheduler = ON` and `max_allowed_packet = 1G`, creates the database
  if missing, creates missing tables, inserts the seed rows, replaces the procedures, views and
  event.

Re-running it is safe and is how you upgrade: unchanged files are left alone, existing tables and
rows are kept, existing `consolidation_config` values are not overwritten, and procedures, views
and the event are replaced with the repo's versions. Re-running does **not** alter existing tables:
if a new version adds a column, apply that `ALTER` by hand (the schema file shows the target).

### Turning on scheduled consolidation

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName "Damian" -SkipFiles -SkipDatabase -SkipSettings -RegisterConsolidationTask -ClaudeCli "C:\Tools\npm\claude.cmd"
```

This registers `ClaudeMemoryConsolidation`, running every 3 hours while you are logged on (missed
runs catch up), with a 30-minute limit. It calls `claude -p "/consolidate-memory-db"` with the
narrow permissions in `runner-settings.json` and sets `CLAUDE_MEMORY_SKIP_BOOT=1` so the run does
not open a session row of its own. Logs go to `C:\Tools\consolidator\logs\`.

Two things to know:

- **The CLI must be reachable from a scheduled task.** The Claude desktop app virtualizes
  `AppData\Roaming` for tools run inside it, so a CLI installed from there may not exist for a
  scheduled task. The original machine installs a separate CLI outside AppData:
  `npm install -g @anthropic-ai/claude-code --prefix C:\Tools\npm`, then uses
  `-ClaudeCli C:\Tools\npm\claude.cmd`. That CLI must be logged in once
  (`C:\Tools\npm\claude.cmd` in a terminal).
- **It runs live.** `db/seed.sql` carries the original machine's settings, where every stage is on
  and `dry_run = 0`. To watch a few runs first:
  `UPDATE consolidation_config SET cfg_value = '1' WHERE cfg_key IN ('dry_run', 'confirm_dry_run');`
  Proposals then land in `consolidation_log` without changing anything. The kill switch is
  `enabled = 0`.

## Installing with Claude's help

On the new machine, Claude Code can do most of this. Clone the repo, open Claude Code in the
clone, and ask it to "install this following the README". Give it the MySQL password when it asks
(or set `CLAUDE_MEMORY_PASSWORD` first). The hooks and rules take effect from the next new
session, not the one that ran the install.

## Bringing your data along

The repo ships the system, not the contents. A new install starts empty, which is fine: the boot,
archive and consolidation fill it as you work. To carry existing memories across, copy the whole
database. A partial copy breaks things: `memory_sources` back-pointers reference `transcripts` rows
by id, memory confirmation reads the source transcript, and the digest is keyed by session.

`mysql` and `mysqldump` live in `C:\Program Files\MySQL\MySQL Server 8.0\bin`; use the full path
if that folder is not on the PATH.

On the old machine (any shell; `--result-file` avoids PowerShell re-encoding the output, and the
packet size has to fit the largest transcript):

```
mysqldump -u root -p --single-transaction --routines --events --hex-blob --max-allowed-packet=1G --result-file=C:\Temp\claude_memory_full.sql claude_memory
```

Add `--ignore-table=claude_memory.<name>` for each `*_bak_*` table you don't need. List them with
`SHOW TABLES LIKE '%bak%'`. The original machine has a few from one-off repairs, including a
137 MB one. With `transcripts` included, the dump is large (about 1 GB on the original machine).

On the new machine, after `install.ps1` and **before** starting any Claude session:

```
mysql -u root -p -e "DROP DATABASE claude_memory; CREATE DATABASE claude_memory CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
mysql -u root -p --max-allowed-packet=1G claude_memory -e "SOURCE C:/Temp/claude_memory_full.sql"
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName "Damian" -SkipFiles -SkipSettings
```

The last line brings the procedures, views and event to the repo's version. Then point each
project at its folder on this machine:
`UPDATE claude_memory.projects SET root_path = 'D:\\Code\\X' WHERE slug = 'x';`

## Keeping this repo up to date

The live system changes as it is worked on. To pull the live versions back into the repo, from a
clone on the original machine:

```
$env:CLAUDE_MEMORY_PASSWORD = '<mysql password>'
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\export-from-live.ps1 -UserName Damian
git diff
```

The export applies the reverse substitutions, regenerates `db/seed.sql` from the live seed tables,
and then scans every exported file for anything still machine-specific (your Windows user name,
the password, any of the real paths). It exits 1 if it finds one, so a missed pattern never reaches
a commit silently. To add a file to the system, list it in `manifest.psd1`, re-export, commit.

## Troubleshooting

- **No `=== SESSION` block at startup**: run `bash ~/.claude/session_boot.sh` in a terminal and
  read the error. The usual causes are `bash` not on the PATH, a wrong mysql path, or a wrong
  password. The boot hook only fires on a fresh `startup`, not on resume.
- **First sessions are slow to start**: the first transcript sweep on a machine with a lot of
  history can exceed the hook's 120 s timeout. It is incremental, so it finishes over the next
  few starts.
- **`mem.ps1` is blocked**: always call it with `-ExecutionPolicy Bypass`, as the rules do.
- **Em dashes stored as `?`**: something wrote through the console code page. All writes should go
  through `mem.ps1`, which pins UTF-8 end to end (see its header).

## Known limits

- Windows only as written: Windows PowerShell 5.1, Git Bash, Windows paths.
- Some comments and skill text cite memory and session ids from the original database
  (for example "memories 2137 and 2140") to explain why a rule exists. Those ids don't exist in a
  new install; the explanations still hold.
- `claude_scanner.sh migrate-history` needs `migrate_history.py`, a one-off legacy migration that
  is not included.
- The schema file defines `ix_notes_unconsolidated` on `session_notes`, which the original
  database no longer has. It's a harmless extra index on a new install.
- Not part of this bundle: the secret-scan and delete-guard hooks, the JIRA and SVN skills, the
  console-window janitor task, and the Codex integration (`~/.codex/AGENTS.md` and `hooks.json`
  call the same boot and close scripts).
