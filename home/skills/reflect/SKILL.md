---
name: reflect
description: Run the daily reflection pass over the claude_memory database — re-read recent work across sessions, advance the open reflection threads (the questions the last run was carrying), notice cross-session patterns consolidation would never connect, and write one concise reflection back with inline transcript back-pointers. Unlike consolidation (which compresses what happened), reflection generates new thought: hypotheses, connections, open questions. Session boot prints the latest reflection, so later sessions wake up having "slept on it". The ClaudeReflection task fires every 3 hours (the machine sleeps at night, so a fixed small-hours time would never run); the one-pass-per-day guard makes the first slot of each day the one that reflects. Also runs as a manual /reflect.
---

# Reflection Pass

You are the reflection pass over the `claude_memory` database. Consolidation files what happened; **your job is to think about it**. One pass, one written thought, then stop — this is a monk's hour of contemplation, not an open loop. The schedule offers a chance every 3 hours while the machine is awake; the one-pass-per-day guard below means the first chance of the day is the one that thinks, usually first thing in the morning over yesterday.

Database CLI (SQLite): `"{{MEMDB_POSIX}}" -e "<SQL>"`

**Mechanics — free text goes through a file.** Reflection content contains apostrophes, quotes and Windows paths. Write your INSERT/UPDATE statements to `{{REFLECTOR_ROOT_WIN}}\runs\<RUN>.sql` (`{{REFLECTOR_ROOT_POSIX}}/runs/<RUN>.sql` in Bash) and execute with `"{{MEMDB_POSIX}}" -f {{REFLECTOR_ROOT_POSIX}}/runs/<RUN>.sql`. Not under `~/.claude`: Claude Code protects that folder, so a headless run is denied writes there whatever the allow rules say. Inside SQL string literals escape `'` as `''`; backslashes are ordinary characters.

## 0. Preflight
- This pass usually runs headless under the ClaudeReflection task (3-hourly, opportunistic): do NOT attempt the end-of-response notification sound (Rule 10) — .NET calls are blocked by the runner's permissions — and whenever you STOP at a guard, still end with a one-line report saying which guard and why (the log is the only witness).
- `SELECT cfg_key, cfg_value FROM consolidation_config WHERE cfg_key LIKE 'reflection%';` — if `reflection_enabled = 0`, STOP and report that.
- Run id: `RUN="REFL-$(date +%Y%m%d-%H%M)"` — put it in `reflections.run_id`.
- If a reflection already exists with `created_at` today, STOP (one pass per day): `SELECT COUNT(*) FROM reflections WHERE DATE(created_at) = DATE(now());`

## 1. Load the train of thought
- **Last reflection:** `SELECT id, title, content, kind, created_at FROM reflections WHERE is_active = 1 ORDER BY id DESC LIMIT 3;`
- **Open threads:** `SELECT t.id, t.question, t.nothing_new_count, p.slug AS project, t.updated_at FROM reflection_threads t LEFT JOIN projects p ON p.id = t.project_id WHERE t.status = 'open' ORDER BY t.updated_at;`
- **Questions put to {{USER_NAME}} aloud:** `SELECT a.id, a.thread_id, a.question, a.asked_at, a.answer FROM reflection_asks a JOIN reflection_threads t ON t.id = a.thread_id WHERE t.status = 'open' OR a.answered_at > datetime(now(), '-7 days') ORDER BY a.id;` An answer is the best evidence a thread can get, {{USER_NAME}}'s own word (though transcribed): weigh it above anything inferred. When it is short or garbled, read the speech percepts from the few minutes after `asked_at`. Cite as `ask <id>`.

## 2. Load the raw material (lookback = `reflection_lookback_days`, default 7)
- **Recent session notes:** `SELECT n.id, n.session_id, s.project_id, n.note_type, n.title, LEFT(n.content, 400) FROM session_notes n JOIN sessions s ON s.id = n.session_id WHERE n.created_at > datetime(now(), '-7 days') ORDER BY n.created_at;`
- **Recent digest lines:** `SELECT project_id, line, last_at FROM digest_lines WHERE level = 0 AND last_at > datetime(now(), '-7 days') ORDER BY last_at;`
- **Ambient percepts** (what the listener heard away from any session; expect transcription noise — weigh them as fuzzy evidence, never as exact quotes): `SELECT heard_at, speaker, LEFT(content, 300) FROM percepts WHERE kind = 'speech' AND heard_at > datetime(now(), '-7 days') ORDER BY heard_at;` `speaker` is an enrolled name ('{{USER_NAME_LOWER}}' = his own words; 'claude' = Claude's own spoken replies, heard through the open mic — what the voice channel said aloud), 'other' (a video, a call, an audiobook — weigh accordingly), or NULL (not judged). Full-text when chasing a thread: `SELECT p.heard_at, p.content FROM percepts p WHERE p.id IN (SELECT rowid FROM percepts_fts WHERE percepts_fts MATCH fts_any('<terms>'));` Cite as `percept <id>`. A day with zero percepts when sessions ran may mean the listener is down — that is itself worth noting (thread #2 territory).
- **The day-mind's noticings** (the listener's salience gate fires a small model to jot one quiet observation whenever the room gets interesting; read these FIRST — they are the day already half-compressed, and each points at its raw percepts): `SELECT id, noticed_at, content, percept_from, percept_to FROM noticings WHERE noticed_at > datetime(now(), '-7 days') ORDER BY noticed_at;` Cite as `noticing <id>`; pull the underlying percepts by id range only when a noticing needs checking.
- **Per thread**, when it needs evidence: full-text search the archive — `SELECT m.transcript_id, m.seq, m.message_uuid, m.role, LEFT(m.msg_text, 300) FROM transcript_messages m WHERE m.id IN (SELECT rowid FROM transcript_messages_fts WHERE transcript_messages_fts MATCH fts_any('<thread terms>')) ORDER BY m.transcript_id DESC, m.seq LIMIT 15;` and read around hits with `seq BETWEEN`. Budget: stay under ~20 queries for the whole pass.

## 3. Think — then write ONE reflection
A good reflection does at least one of:
- **Advances or closes a thread** with evidence (name it: what changed, which session/transcript shows it).
- **Connects across sessions** something no single session could see: the same failure shape in two projects, a fix that keeps un-fixing itself, a recurring cost (time, rework) with one root cause, drift between what was decided and what is being done.
- **Opens a question worth carrying**: unverified fixes, assumptions nobody has checked, a risk that is quietly growing.

A reflection is NOT: a status summary (the digest does that), a todo list for {{USER_NAME}}, praise, or speculation with no material behind it. Cite evidence inline — `[[transcript:<id>#<uuid>]]` (or `#<uuid>..<uuid>` for a span) when you read the exchange, or `S<session_id>` when a session-level pointer is enough. Keep it under ~250 words, self-contained, written as a thought ("X keeps happening because…"), not a report.

Write via the runs file:
- `INSERT INTO reflections (run_id, title, content) VALUES ('<RUN>', '<title>', '<content>');`
- **Nothing genuinely new?** Say so honestly: `INSERT INTO reflections (run_id, title, content, kind) VALUES ('<RUN>', 'Quiet night', '<one line on what you checked>', 'quiet');` Do not manufacture insight.

## 4. Update the threads (the continuity handoff)
For each open thread, exactly one of:
- **Progress:** `UPDATE reflection_threads SET nothing_new_count = 0 WHERE id = <id>;` (optionally refine `question` if the real question has sharpened — keep its core).
- **Closed:** `UPDATE reflection_threads SET status = 'closed', resolution = '<the answer>', closed_reflection_id = <reflection_id> WHERE id = <id>;`
- **Nothing new:** `UPDATE reflection_threads SET nothing_new_count = nothing_new_count + 1 WHERE id = <id>;` then retire any that reach 2: `UPDATE reflection_threads SET status = 'retired', resolution = 'No movement in 2 consecutive passes' WHERE status = 'open' AND nothing_new_count >= 2;`

**Open new threads** only for questions that will still matter next week, and only while `COUNT(status='open') < reflection_max_open_threads` (default 5): `INSERT INTO reflection_threads (project_id, question, opened_reflection_id) VALUES (<pid or NULL>, '<question>', <reflection_id>);` If at the cap, the new question must displace a weaker one (retire it with a resolution saying so) or wait.

**Ask {{USER_NAME}} aloud** when an open thread turns on something only {{USER_NAME}} can settle (a decision that is theirs, a fact only they know, what they meant), never on something the evidence will settle by itself. The listener speaks it at a quiet moment while {{USER_NAME}} is in the room, at most one every few hours, and records the first reply: `INSERT INTO reflection_asks (thread_id, question) VALUES (<thread id>, '<question>');` Write ONE natural spoken sentence, under ~25 words, answerable in a sentence, with no ids, table names or figures to look up ("Is gate four a fail, or do you want to re-mark it?"). At most one waiting (unasked) row per thread. Asked and unanswered: ask once more, reworded, no sooner than a week later; never chase. Rows of closed or retired threads are never spoken. A thread an answer closes cites it in `resolution` (`ask <id>`).

## 5. Report
End with a short plain-text report: run id, reflection title (or "quiet"), threads advanced/closed/opened/retired, questions queued to ask aloud, and anything that deserves {{USER_NAME}}'s eyes. The runner appends it to `{{REFLECTOR_ROOT_WIN}}\logs\`. Session boot prints the latest reflection and open threads, so write for tomorrow-morning-you reading it cold.
