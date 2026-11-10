---
name: consolidate-memory-db
description: Run the autonomous consolidation pass over the claude_memory SQLite database — promote durable session notes to memories, dismiss ephemeral ones, normalize category drift, merge duplicate memories, stamp provenance back-pointers, check every new memory against the transcript it came from (correcting it if it is not faithful) and confirm it, resolve the behaviours derived from memories (current guidance, with newer statements superseding older ones), and write the recent-work digest that session boot prints (one line per finished session, rolled up into older blocks). Every mutation goes through rail-enforcing procedures (run by memdb) that honor the enabled kill switch, dry_run, confidence thresholds, a per-run blast-radius cap, and a reversible audit log. Use for scheduled or manual memory consolidation.
---

# Memory Consolidation Pass

You are running the consolidation pass over the `claude_memory` database. **Your job is judgment; the procedures enforce safety.** Never write to `memories`, `session_notes`, `memory_sources`, `behaviours`, `behaviour_evidence`, `behaviour_source_reviews`, `digest_lines` or `digest_session_reviews` directly — only via the `sp_*` procedures below. They read the `enabled` kill switch, `dry_run`, thresholds, and the per-run cap from `consolidation_config`, and log every action (proposed or applied) to `consolidation_log` for reversibility.

Database CLI (SQLite; memdb runs `CALL sp_...` itself, one transaction per call):
`"{{MEMDB_POSIX}}" -e "<SQL>"`

**Mechanics — avoid shell-escaping bugs.** Note titles/content contain apostrophes, quotes, and backslashes. For any `sp_promote_note` call (free-text content), write the `CALL` statements to a temp file `{{CONSOLIDATOR_ROOT_WIN}}\runs\<RUN>.sql` (`{{CONSOLIDATOR_ROOT_POSIX}}/runs/<RUN>.sql` in Bash) and execute it with `"{{MEMDB_POSIX}}" -f {{CONSOLIDATOR_ROOT_POSIX}}/runs/<RUN>.sql`. Not under `~/.claude`: Claude Code protects that folder, so a headless run is denied there whatever the allow rules say. Inside SQL string literals escape `'` as `''`; backslashes are ordinary characters, so Windows paths need no escaping. Do not hand-build fragile `-e` strings for free text.

**`confirm-only`:** when this skill is invoked with the argument `confirm-only`, run step 0, step 5 and step 8 only.

## 0. Preflight
- `SELECT cfg_key,cfg_value FROM consolidation_config;` — if `enabled=0`, STOP. Note whether `dry_run=1` (propose-only) or `0` (applies).
- Generate a run id: `RUN="auto-$(date +%Y%m%d-%H%M)"`. Use this exact run_id for **every** proc call this pass.
- `SELECT * FROM v_consolidation_backlog;` — get the lay of the land.

## 1. Mechanical tier
`CALL sp_consolidate_mechanical('<RUN>');`
Decays stale observations and expires past-TTL memories (logged; throttled to once/day).

## 2. Normalize category drift
- `SELECT category, COUNT(*) FROM memories WHERE is_active=1 GROUP BY category ORDER BY 2 DESC;`
- Identify redundant/near-duplicate labels and pick one canonical name (e.g. `conventions`→`convention`; collapse the `planned_work`/`pending_work`/`deferred`/`future_work`/`in_progress_plan` cluster).
- For each: `CALL sp_normalize_category('<from>','<to>','<RUN>');`

## 3. Promote / dismiss the note backlog
- Pull a batch oldest-first, **skipping notes you already reviewed-and-kept recently**: `SELECT id,session_id,note_type,title,content FROM session_notes WHERE is_consolidated=0 AND (last_reviewed IS NULL OR last_reviewed < datetime(now(), '-' || (SELECT cfg_value FROM consolidation_config WHERE cfg_key='review_interval_days') || ' days')) ORDER BY created_at ASC LIMIT 60;` (the `last_reviewed` filter keeps you from re-reading notes already triaged as "leave"; ordering by `created_at` matches `ix_notes_consolidation`, no sort step).
- For each note, judge:
  - **Durable** (decision, preference, completed work, limitation, requirement, architecture, reusable discovery) → `CALL sp_promote_note(<note_id>,'<memory_type>','<category>','<title>','<content>','<RUN>');`. Choose `memory_type` ∈ (user|feedback|project|reference), a canonical `category`, a crisp `title`, and self-contained `content`. Provenance + back-pointer are stamped automatically.
  - **Ephemeral** (transient status, superseded progress, one-off chatter) → `CALL sp_dismiss_note(<note_id>,'<why>','<RUN>');`
  - **Uncertain** → `CALL sp_defer_note(<note_id>,'<why>','<RUN>');` — records that you reviewed it and chose to keep it for now, so it drops out of the batch for `review_interval_days` (default 30) instead of being re-read every run. Use this for genuinely ambiguous notes; promote the clear keepers and dismiss the clear chaff so the backlog actually shrinks.
- The per-run cap (`max_actions_per_run`) bounds applied actions; the backlog drains over successive daily runs. **Do not try to clear it all at once.**

## 4. Merge duplicate memories
- `SELECT id,category,title FROM memories WHERE is_active=1 ORDER BY category,title;`
- When two memories clearly state the same thing, pick the better/more-complete one as the survivor: `CALL sp_merge_memory(<keep_id>,<drop_id>,<confidence 0.00-1.00>,'<why>','<RUN>');`
- Be conservative — only true duplicates. Below `min_merge_confidence` the proc refuses. Distinct-but-related memories are NOT duplicates; leave them.

## 5. Confirm memories against their transcripts
Every new memory starts unconfirmed (`memories.confirmed = 0`). This step checks each one against the conversation it came from, corrects it if it is not faithful, and confirms it. **A confirmed memory is the append-only record and is never edited again; this step is the only place an unconfirmed one may change, and only to make it faithful.** Procedure and view: `~/.claude/consolidator/confirm.sql`; its header explains the model. It exists because a conditional finding ("the admin page would expose customer card numbers *if* the web server allowed anonymous access") lost its "if" in the session's own notes, was copied faithfully into memories, and was later repeated as fact to a client. So **never check a memory against its note**: the note is where that kind of error happens.

- **Gate:** `SELECT cfg_value FROM consolidation_config WHERE cfg_key='confirm_enabled';` If `0`, skip this step. When `confirm_dry_run=1` the calls only log proposals.
- **Worklist** (oldest first): `SELECT memory_id, status, transcript_id, from_note_id, origin_at, memory_type, category, title, content FROM v_confirm_worklist WHERE status IN ('ready','no_source') ORDER BY created_at LIMIT 20;` (`waiting` rows are skipped: their transcript is not archived that far yet.)
- **`no_source`:** `CALL sp_confirm_memory(<id>, 'no_source', NULL, NULL, '<why>', '<RUN>');` It stays unconfirmed and session boot shows it.
- **Find the discussion** in the transcript (`origin_at` is local time; transcript `ts` is UTC):
  - Search: `SELECT seq, role, ts, LEFT(msg_text, 300) FROM transcript_messages WHERE transcript_id = <tid> AND id IN (SELECT rowid FROM transcript_messages_fts WHERE transcript_messages_fts MATCH fts_any('<distinctive terms from the memory>')) ORDER BY seq LIMIT 15;` then read around each hit: `SELECT seq, role, ts, msg_text FROM transcript_messages WHERE transcript_id = <tid> AND seq BETWEEN <a> AND <b> ORDER BY seq;`
  - Messages {{USER_NAME}} typed while Claude was working (mid-turn `queued_command` attachments) are indexed as `role = 'user'` messages, so the search above finds them.
  - `msg_text` holds {{USER_NAME}}'s messages, Claude's text to {{USER_NAME}} and subagent reports. Tool calls show only as `[tool_use: Name]` and tool results are not indexed. When a central claim rests on what a tool returned, read that message raw: `SELECT CAST(substr(uncompress(t.raw_jsonl), m.byte_offset + 1, m.byte_length) AS TEXT) FROM transcript_messages m JOIN transcripts t ON t.id = m.transcript_id WHERE m.transcript_id = <tid> AND m.seq = <seq>;`
- **What counts as evidence:** {{USER_NAME}}'s messages, what tools returned, and what Claude told {{USER_NAME}}. **Not evidence:** the session's own note- and memory-writing (Write calls to note files, `mem.ps1` commands — reading them would let a bad memory confirm itself), `session_notes` rows, other memories. A subagent report is model output: a claim, not a verified fact.
- **Faithful means, checked in this order:**
  1. **Conditions and uncertainty survive.** Every "if", "unless", "depends on", "only when", "unverified", "likely", "unconfirmed", "from the code only" that the discussion attached to a claim is still attached in the memory, **title included**. A title that drops it is unfaithful even when the body keeps it.
  2. **A combined conclusion keeps the conditions of everything it combines** (joining "the databases are production restores" with a code review's findings must not lose the review's "if").
  3. **Who said or decided it.** "{{USER_NAME}} decided X" must be {{USER_NAME}}'s words; Claude's inference or a subagent's report must not read as {{USER_NAME}}'s decision or as verified fact.
  4. **Status is not further along than it was:** proposed vs approved vs built vs committed vs sent.
  5. **Numbers, names, ids, paths and dates match.**
  6. **A correction made earlier in the same discussion is reflected.**
  Not a fidelity problem: wording, brevity, a minor detail left out, or a detail from tool output you could not locate. Do not correct what you cannot show to be wrong.
- **Faithful:** `CALL sp_confirm_memory(<id>, 'faithful', NULL, NULL, '<what you checked, with transcript seq numbers>', '<RUN>');`
- **Not faithful:** make the smallest change that makes it faithful (put the condition back, fix the attribution, the status or the number) and keep everything else word for word. Pass the full corrected title and/or content, `NULL` for whichever is unchanged: `CALL sp_confirm_memory(<id>, 'corrected', '<title or NULL>', '<content or NULL>', '<what was wrong, citing transcript seq numbers>', '<RUN>');` Free text goes through the `runs/<RUN>.sql` file, as for promotions.
- **Genuinely unsure:** make no call; it comes back next run. Name it in the report.
- **Check the log:** `SELECT action, LEFT(reason,150) FROM consolidation_log WHERE run_id='<RUN>' AND action IN ('error','capped') AND target_table = 'memories' ORDER BY id;` Fix and retry an `error`. After `capped`, stop this step.

## 6. Resolve behaviours
Behaviours are the current guidance worked out from memories. **Memories are an append-only record of what happened: never edit or deactivate one to change behaviour.** (Only confirmed memories reach the worklist below; step 5 is the one place an unconfirmed memory is corrected, and only for fidelity.) When {{USER_NAME}}'s guidance changes, the newer memory supersedes the older one *here*, in the evidence, and the older memory stays exactly as it was. Procedures and views are in `~/.claude/consolidator/behaviours.sql`; its header explains the model.

- **Gate:** `SELECT cfg_value FROM consolidation_config WHERE cfg_key='behaviours_enabled';` If `0`, skip this whole step. It stays off until {{USER_NAME}} has reviewed the supervised backfill.
- **Refresh** (applies habit decay): `CALL sp_refresh_behaviours('<RUN>');`
- **Load the scale and the existing subjects:**
  - `SELECT kind, anchor_weight, description FROM behaviour_evidence_kinds ORDER BY anchor_weight DESC;`
  - `SELECT subject, kind, strength, status, statement FROM behaviours WHERE status <> 'retired' ORDER BY subject;`
- **Worklist** (oldest first, so a newer statement is always handled after the evidence it may supersede): `SELECT source_type, source_id, type, category, title, content, dated FROM v_behaviour_worklist LIMIT 40;`
- **For each source,** decide which subjects it bears on. It can be none, one or several: one memory can be both a "don't use language X for helper scripts" statement and a record of two corrections about how files get edited, and those belong to different subjects.
  - **Subject:** reuse an existing one whenever it fits; create a new one only when nothing covers it. Dotted lowercase, area first: `tooling.scripting-languages`, `workflow.file-edits`, `communication.reasoning`. Pass a `project_id` only when the guidance is specific to one project.
  - **Kind and weight:** pick the kind from the scale. Pass `NULL` for the weight to use its anchor; move off the anchor (±0.05 at most, enforced) only for emphasis, such as "REQUIREMENT" or "never".
  - **`event_key`:** when one real event is recorded in several places (a note, a memory and an observation of the same correction), give all of them the same key, `event:<yyyy-mm-dd>:<short-slug>`, so it counts once. Otherwise pass `NULL`.
  - **`occurred_at`:** pass the date it happened when the source records an earlier one (a memory written on 09-17 that describes a correction on 08-28). Otherwise `NULL`.
  - **It agrees with the current statement:** `CALL sp_link_evidence('<subject>', NULL, '<source_type>', <id>, '<kind>', NULL, NULL, NULL, NULL, '<rationale>', '<RUN>');`
  - **No behaviour yet:** `CALL sp_upsert_behaviour('<subject>', NULL, '<statement>', '<reason>', '<RUN>');`, then link it.
  - **It is a newer statement from {{USER_NAME}} (kind at or above the rule threshold) that changes the guidance:** rewrite the statement with `sp_upsert_behaviour`, link the new evidence, then `CALL sp_supersede_evidence(<old_evidence_id>, <new_evidence_id>, '<reason>', '<RUN>');` for **each** older evidence row the change replaces, and only those. Evidence that still holds stays live. Find ids with `SELECT id, source_type, source_id, evidence_kind, weight, occurred_at, superseded_by FROM behaviour_evidence WHERE behaviour_id = <id>;`
  - **It is weaker and disagrees** (an inference or pattern against something {{USER_NAME}} said): link it with stance `'opposes'`. The behaviour becomes a `conflict` and is shown to {{USER_NAME}} at the next session boot. **Never resolve a conflict yourself, and never rewrite a statement on weaker evidence.**
  - **Finished with the source** (all of its links went in, or it bears on no behaviour): `CALL sp_mark_reviewed('<source_type>', <id>, '<outcome, e.g. linked to workflow.file-edits / no behaviour>', '<RUN>');`
- **Statements:** one or two sentences, imperative, self-contained, saying what to do *now* (not the history). For a rule with exceptions, name them.
- **Check the log before marking a source reviewed.** The procedures log problems instead of raising them: `SELECT action, LEFT(reason,150) FROM consolidation_log WHERE run_id='<RUN>' AND action IN ('error','capped','supersede_refused','review_deferred_capped') ORDER BY id;` Fix and retry an `error`. `supersede_refused` means the replacement was too weak or older, so link it as opposing instead. After `capped`, stop this step; the remaining sources stay queued for the next run.
- **Retire** a behaviour only when its subject no longer applies at all (a change goes through `sp_upsert_behaviour`): `CALL sp_retire_behaviour('<subject>', NULL, '<reason>', '<RUN>');`

## 7. Digest recent work
Session boot prints a per-project digest of recent work: one line per finished session, older work rolled up into blocks of 2, 4, 8 ... sessions (OptMem's merge tree). This step writes those lines. Procedures and views are in `~/.claude/consolidator/digest.sql`; its header explains the tree.

- **Gate:** `SELECT cfg_value FROM consolidation_config WHERE cfg_key='digest_enabled';` If `0`, skip this whole step.
- **Sessions first, oldest first** (positions follow the order leaves are written, so keep them chronological):
  `SELECT session_id, project, started_at, last_activity_at, note_count, reviewed_until, reviewed_until_utc FROM v_digest_session_worklist WHERE is_quiet = 1 ORDER BY started_at LIMIT 20;`
- **Read each session.** Its notes: `SELECT note_type, title, content FROM session_notes WHERE session_id = <id> ORDER BY id;` What {{USER_NAME}} asked: `SELECT LEFT(tm.msg_text, 800) FROM transcript_messages tm JOIN transcripts t ON t.id = tm.transcript_id JOIN sessions s ON s.session_uuid = t.session_uuid WHERE s.id = <id> AND t.kind = 'main' AND tm.role = 'user' AND tm.msg_text IS NOT NULL ORDER BY tm.seq;` (skip skill expansions that start "Base directory for this skill"). When `reviewed_until` is set, the session was resumed after its first line: read only notes with `created_at > reviewed_until` and messages with `tm.ts > reviewed_until_utc`, and describe only the new work.
- **Write one line** (`digest_line_chars`, 200 at most, one line): `CALL sp_digest_put_leaf(<session_id>, '<line>', '<RUN>');`
  - Lead with the ticket key(s), then what was built, decided or found, then where it stands: committed rN / uncommitted on branch X / waiting on {{USER_NAME}} or a named person / dropped. End with what was left open, if anything.
  - When it does not all fit, keep in this order: (1) {{USER_NAME}}'s decisions and corrections, with the reason when one was given, close to the words used; (2) what has lasting effect: what was built or changed, and what failed and why; (3) findings and open questions; (4) last, process: what was read, run or tried on the way.
  - Never make anything look further along than it was: a go-ahead is not a commit, a draft is not sent, a spec is not built, a diagnosis is not a fix. If the notes and messages do not say it was committed, do not say it was. Invent nothing.
  - Name a minor item in a word or two rather than drop it: the line is all boot shows of the session, and what it leaves out can only be found again with /recall.
  - No session id or date (boot adds both), no project name when the project is obvious, no filler ("worked on", "various"). Plain words; keep exact identifiers (branch names, revisions, procedure names).
  - Example: `PROJ-123 quarterly report: shared SQL fn + report proc refactor proven identical, totals fix; built on branch 20261016_quarterly, uncommitted; label wording flagged`
- **Nothing of lasting effect** (a probe, a test boot, a question with no outcome, a resume that changed nothing): `CALL sp_digest_skip(<session_id>, '<why>', '<RUN>');`
- **Then the blocks, smallest first.** `SELECT project_id, project, block_level, block_seq_lo, block_seq_hi, input_seq_lo, first_session_id, last_session_id, first_at, last_at, input_line FROM v_digest_pending ORDER BY block_level, project_id, block_seq_lo, input_seq_lo LIMIT 200;` returns one row per input line of each block that is ready. Write one line per block: `CALL sp_digest_put_block(<project_id or NULL>, <block_level>, <block_seq_lo>, '<line>', '<RUN>');`
  - Same 200-character limit and the same order of value as a leaf: {{USER_NAME}}'s decisions and corrections, then what shipped or changed, then what was still open at the end of the period; process last. Drop only what was superseded within the block (a bug found and fixed in the same block is one fix). Name tickets; keep a revision or branch only when it still matters.
  - Never further along than its lines say: "commit go-ahead" stays a go-ahead unless a later line in the block records the commit. Invent nothing.
  - A minor item gets a word or two rather than vanishing; the bigger the block, the more it is named by ticket or subject alone.
  - Writing a block can make its parent ready: query `v_digest_pending` again until it is empty or the run is capped.
- **A bad block line:** `CALL sp_digest_forget(<project_id or NULL>, <level>, <seq_lo>, '<why>', '<RUN>');` drops it and every block built on it; the next run rebuilds them. Leaves cannot be forgotten.
- **Check the log** after each batch: `SELECT action, LEFT(reason,150) FROM consolidation_log WHERE run_id='<RUN>' AND action IN ('error','capped') AND target_table IN ('digest_lines','digest_session_reviews') ORDER BY id;` Fix and retry an `error` (usually a line over 200 characters). After `capped`, stop this step; the rest stays queued.

## 8. Report
`SELECT action, COUNT(*) AS n, SUM(dry_run) AS proposed FROM consolidation_log WHERE run_id='<RUN>' GROUP BY action ORDER BY n DESC;`
Summarize what was applied (or, if `dry_run=1`, proposed — and remind that nothing was mutated; the proposals are in `consolidation_log` for review). List any behaviour that is now in `conflict`, or whose statement changed this run. List every memory corrected in step 5 (id, what was wrong), and any left unconfirmed because you were unsure.

## Reversibility
Every action is in `consolidation_log` (before/after JSON, keyed by `run_id`). To revert a run: reactivate merged/expired rows (`is_active=1`), un-consolidate notes (`is_consolidated=0`), delete promoted memories by `after_json.new_memory_id`, and remove the `memory_sources` rows added that run. For `confirm_memory` actions, restore title, content and the confirm columns from `before_json` (see `~/.claude/consolidator/confirm.sql`). For behaviour actions, follow the REVERTING list in the header of `~/.claude/consolidator/behaviours.sql`; for digest actions, the one in `~/.claude/consolidator/digest.sql`.
