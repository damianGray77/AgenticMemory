-- confirm.sql -- memory confirmation: every new memory starts unconfirmed, and the consolidation
-- pass checks it against the conversation it came from before confirming it.
--
-- WHY: a conversation concluded that a system "would expose customer card numbers IF the web server
-- allowed anonymous access". The session's notes dropped the "if"; consolidation copied the notes
-- faithfully into memories; and the unconditional version was later repeated as fact to a client.
-- Checking a memory against its note proves nothing. It has to be checked against the discussion.
--
-- MODEL:
--   memories.confirmed = 0  draft: the pass may correct it, only to make it faithful to its transcript
--   memories.confirmed = 1  the append-only record: never edited again (sp_confirm_memory refuses)
--   confirm_outcome         backfill | faithful | corrected | no_source (no_source stays unconfirmed)
--   confirm_checked_at      when the check ran
--
-- RAILS (consolidation_config): enabled and dry_run as everywhere, plus confirm_enabled (kill switch
-- for this step), confirm_dry_run (log-only for this step) and max_confirm_actions_per_run.
--
-- THE PROCEDURE lives in memdb (memdb/src/Procs.Confirm.cs):
--   CALL sp_confirm_memory(memory_id, 'faithful' | 'corrected' | 'no_source',
--                          'new title' or NULL, 'new content' or NULL, 'what was checked', 'run_id');
-- 'faithful' and 'no_source' keep updated_at, so they do not requeue the memory for behaviours;
-- 'corrected' bumps it, so the behaviours step re-reads the corrected text. A confirmed memory with
-- a session gets a back-pointer to its transcript.
--
-- REVERTING: every confirm_memory row in consolidation_log carries before_json (title, content,
-- confirmed, confirm_outcome, confirm_checked_at, updated_at). Restore those columns from it.

-- Unconfirmed memories with where to check them and whether they can be checked yet.
--   ready      the source session's main transcript is archived past the point the memory was made
--   waiting    the transcript is not archived that far yet (session still running, or not swept)
--   no_source  no session and no back-pointer, or a session with no transcript after 2 days
-- origin_at is when the memory's content was written: the source note's time for a promoted memory
-- (promotion can run hours after the session), else the memory's own created_at.
-- Memory and note times are local; transcript times are UTC, hence to_utc().
DROP VIEW IF EXISTS v_confirm_worklist;
CREATE VIEW v_confirm_worklist AS
SELECT w.memory_id, w.memory_type, w.category, w.title, w.content, w.created_at, w.source_session,
       w.from_note_id, w.origin_at, w.transcript_id, tt.last_message_at AS transcript_last_utc,
       w.confirm_outcome,
       CASE
         WHEN w.transcript_id IS NULL AND w.source_session IS NULL THEN 'no_source'
         WHEN w.transcript_id IS NULL AND w.session_started_at < datetime(now(), '-2 days') THEN 'no_source'
         WHEN w.transcript_id IS NULL THEN 'waiting'
         WHEN tt.last_message_at IS NULL OR tt.last_message_at < to_utc(w.origin_at) THEN 'waiting'
         ELSE 'ready'
       END AS status
FROM (
  SELECT m.id AS memory_id, m.memory_type, m.category, m.title, m.content, m.created_at,
         m.source_session, m.confirm_outcome, s.started_at AS session_started_at,
         n.id AS from_note_id, COALESCE(n.created_at, m.created_at) AS origin_at,
         COALESCE(
           (SELECT MIN(t.id) FROM transcripts t WHERE t.session_uuid = s.session_uuid AND t.kind = 'main'),
           (SELECT MIN(ms.transcript_id) FROM memory_sources ms WHERE ms.memory_id = m.id)) AS transcript_id
  FROM memories m
  LEFT JOIN sessions s ON s.id = m.source_session
  LEFT JOIN consolidation_log cl
         ON cl.action = 'promote_note' AND cl.dry_run = 0 AND cl.reverted = 0
        AND CAST(json_extract(cl.after_json, '$.new_memory_id') AS INTEGER) = m.id
  LEFT JOIN session_notes n ON n.id = cl.target_id
  WHERE m.is_active = 1 AND m.confirmed = 0
) w
LEFT JOIN transcripts tt ON tt.id = w.transcript_id;
