# MANDATORY RULES — Read and follow these every response

## Rule 1: The Database Is Your Memory
Your memory lives in the SQLite database `claude_memory` ({{DB_PATH_WIN}}), driven by `memdb.exe`. NEVER store notes, preferences, context, or memories in `.md` files or any other flat files. ALWAYS write to the database. This file (CLAUDE.md) and MEMORY.md are the ONLY exceptions — they exist solely to point you at the database and enforce these rules. Do NOT add content to them.

**WRITES** go through the `memory` skill, never hand-written SQL — see Rules 4-7:
`powershell -NoProfile -ExecutionPolicy Bypass -File "{{CLAUDE_HOME_WIN}}\skills\memory\scripts\mem.ps1" -Action <note|memory|observe|close|source> ...`
Pass prose with `-ContentFile <absolute path>`, never inline. `-DryRun` prints the SQL without running it.

**READS** use memdb directly (tab-separated output; `-E` for one field per line): `"{{MEMDB_POSIX}}" -e "<QUERY>"`
It is SQLite: `||` or `concat()` for strings, `datetime(now(), '-7 days')` for date arithmetic, and full-text search through the `<table>_fts` tables (Rule 3). memdb adds `now()` (local time), `LEFT()`, `DATE_FORMAT()`, `TIMESTAMPDIFF()`, `uncompress()` and `fts_any()`.
**Schema**: `{{CLAUDE_HOME_WIN}}\claude_memory_schema.sql`

*Why writes are wrapped:* hand-built INSERTs broke on ordinary prose (apostrophes, em dashes, Windows paths), and Claude Code freezes each approved literal command into `permissions.allow` — hundreds of single-use rules before the script existed. The script also fixes a silent corruption: PowerShell 5.1 pipes non-ASCII to a native process as `?` unless `$OutputEncoding` is set, so em dashes were being stored as question marks.

## Rule 2: Session Boot (runs automatically)
A `SessionStart` hook (matcher `startup`) runs `bash ~/.claude/session_boot.sh` automatically at the start of every new conversation, so booting is no longer a step you must remember. It closes orphaned sessions, creates this session's row (linked to the transcript via `CLAUDE_CODE_SESSION_ID`), runs the daily mechanical consolidation, and prints the session ID, project, recent work, behaviours, consolidation status, and these rules into your context. Do NOT run `session_boot.sh` yourself on startup — a second run creates a duplicate session row and orphans the first.

Boot is **slim by default**: it does NOT load the full memories/observations/limitations dump. Query the DB per Rule 3 for the detail you need, or run `bash ~/.claude/session_boot.sh --full` to load everything at once. If the automatic boot output is somehow absent from your context, run the slim boot manually — but expect it to already be there.

## Rule 3: Query Before You Decide
Before making any architectural decision, choosing an approach, or starting significant work:
```sql
SELECT m.id, m.title, m.content FROM memories_fts f JOIN memories m ON m.id = f.rowid
WHERE memories_fts MATCH fts_any('<relevant keywords>') AND m.is_active = 1 ORDER BY f.rank;
```
(`fts_any` matches ANY of the words, best match first — like MySQL's natural-language mode.)
Check for existing preferences, past decisions, known limitations, and completed work that may be relevant. Do NOT rely on what you "remember" from earlier in the conversation — query the database.

## Rule 4: Write As You Work
Log notes in real time — do not batch them or save them for later:
```
mem.ps1 -Action note -SessionId <sid> -Type <type> -Title "<title>" -ContentFile <path>
```
Note types: `decision`, `attempt`, `discovery`, `blocker`, `context`, `milestone`, or free-form.
Write the detail to a scratchpad file and pass its ABSOLUTE path — the script's working directory
is not the shell's. Record the reasoning, not just the outcome: "chose X" is worth little later;
"chose X over Y because Y breaks Z" is what a future session needs.

After editing code, update the database:
- Changed a function signature → `UPDATE code_entities SET signature = '...' WHERE id = <id>`
- Understood a function's purpose → `UPDATE code_entities SET purpose = '...' WHERE id = <id>`
- Understood a file's purpose → `UPDATE source_files SET purpose = '...' WHERE id = <id>`
- Found a dependency → `INSERT INTO entity_dependencies (caller_id, callee_id, dependency_type) VALUES (...) ON CONFLICT DO NOTHING`
  with `dependency_type` one of `calls`, `imports`, `extends`, `implements`, `uses`, `hooks`, `overrides` (anything else is rejected — and `INSERT OR IGNORE` would drop the row silently)

## Rule 5: Store Memories Correctly
All three use `mem.ps1 -Action memory` with `-ContentFile <absolute path>`:
- **User preferences/feedback**: ask permission FIRST, then `-Type user` (or `feedback`) `-Category <cat>`
- **Completed work**: `-Type project -Category completed_work -ProjectId <pid>`
- **Limitations**: `-Type feedback -Category limitation` (omit `-ProjectId`; it defaults to NULL = global)
- `-Type` is an enum: `user` | `feedback` | `project` | `reference`. Titles are at most 255 characters.
- NEVER write memories to flat files. NEVER update MEMORY.md with content. The database is the ONLY destination.

## Rule 6: Observe the User Passively
Silently record patterns about communication, decisions, and work style — without asking permission:
```
mem.ps1 -Action observe -Category <category> -Title "<title>" -ContentFile <path>
```
The script upserts on the unique title — re-observing the same pattern bumps `observed_count` and
raises `confidence` toward 1.00. So re-record a repeat observation under the SAME title rather than
inventing a near-duplicate; that is what makes confidence mean anything.
Categories are free-form: `rapport`, `workstyle`, `communication`, `decision-making`, `domain-knowledge`, `interests`, `problem-solving`, etc.

## Rule 7: Close Sessions and Consolidate
When a session ends or context compresses:
```
mem.ps1 -Action close -SessionId <sid> -Summary "<brief summary>" -Files '<json>' -Topics '<json>'
```
Review session_notes — promote lasting insights to `memories` or `user_observations`. The scheduled consolidation pass (skill `consolidate-memory-db`) does this routinely through rail-enforcing procedures; when you promote by hand, mark the notes: `UPDATE session_notes SET is_consolidated = 1 WHERE id IN (...)`

**Daily mechanical consolidation** (decay stale observations, expire old memories) runs automatically from session boot, once a day.

## Rule 8: Plan Files Are Temporary
Plan files contain ONLY the current active plan. When a plan is completed, record a summary in memories as `completed_work`, then delete the completed content from the plan file.

## Rule 9: Detect Preferences
When the user expresses something preferential (how things should work, style choices, conventions, workflow preferences), ask permission to save it, then store it in memories. This applies to ALL projects, not just the current one.

## Rule 10: Notifications
Run `powershell -NoProfile -Command "[System.Media.SystemSounds]::Asterisk.Play()"` at the end of substantial responses. Do NOT install notification software without express permission.

## Rule 11: Transcript Retention & Back-Pointers
Raw Claude Code session transcripts are archived losslessly in the `transcripts` table (verbatim JSONL, compressed with `compress()`), with each message indexed in `transcript_messages` (its `uuid`, byte offset/length into the uncompressed bytes, and extracted `msg_text`, full-text searchable through `transcript_messages_fts`). This raw archive is the lossless record beneath the lossy `memories`/`session_notes`. Capture runs automatically via the transcript-retention sweep at session start and end — do NOT assume Claude Code keeps transcripts on disk (they rotate and disappear).
- **RECALL before you reconstruct.** When the user references past work (a prior discussion, decision, or session), use the `recall` skill (`/recall <topic>`) — it full-text searches the transcript archive + `session_notes` and returns the verbatim exchange with back-pointers. Don't re-derive from a lossy summary or guess; this lookup is the whole point of the archive.
- **Attach back-pointer(s) whenever you promote or compress a note/memory.** A topic usually spans several places, so a memory may have MANY `memory_sources` rows — each a contiguous span (`start_message_uuid`..`end_message_uuid`) or a single message (`end_message_uuid` NULL), and different rows may point to different transcripts/sessions. Write each span with `mem.ps1 -Action source -MemoryId <id>` (or `-NoteId`) `-TranscriptId <id> -StartUuid <u> [-EndUuid <u>]` — call it once per span, it appends rather than replaces. Inline, cite as `[[transcript:<id>#<start>..<end>]]`; list multiple spans (`#a..b,f,k..m`) or use several tokens. This guarantees a compressed memory traces back to every verbatim exchange it came from.
- **Resolve** back-pointers with the `resolve-memory-sources` / `resolve-note-sources` reference_query (aggregates all of a memory's spans): each `message_uuid` → `transcript_messages` (`byte_offset`/`byte_length`) → slice `uncompress(transcripts.raw_jsonl)`.

## Schema Maintenance
For the `claude_memory` database: apply schema changes directly to the live database and mirror them into `claude_memory_schema.sql` in place — do NOT create sequential migration files for it. Copying the database file is the cross-device mechanism. (A deliberate exception for this database; other projects' databases may still want migration files.)

## Reference Queries
Search for pre-built queries: `SELECT name, sql_template FROM reference_queries WHERE name = '<name>';`
Or by keyword: `SELECT r.name, r.description FROM reference_queries_fts f JOIN reference_queries r ON r.id = f.rowid WHERE reference_queries_fts MATCH fts_any('<keyword>') ORDER BY f.rank;`

## Tools
- **Session boot**: `bash ~/.claude/session_boot.sh [working_directory]`
- **Scanner**: `bash ~/.claude/claude_scanner.sh <command>` (scan, scan-all, onboard, deps, enrich, status, reset)
- **memdb**: `"{{MEMDB_POSIX}}" [-N] [-E] (-e "SQL" | -f file.sql)`; `CALL sp_name(...)` runs a consolidation procedure
