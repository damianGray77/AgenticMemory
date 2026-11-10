-- judgment_procs.sql -- the rail-enforcing mutation API for the judgment tier.
--
-- The consolidation pass (skill consolidate-memory-db) NEVER writes memories or session_notes
-- directly. It calls only these procedures, which enforce the rails mechanically:
--   * honour enabled (kill switch) and dry_run (log-only) from consolidation_config
--   * cap real mutations per run at max_actions_per_run (blast radius); promote, merge,
--     normalize and dismiss share the cap, defer does not
--   * soft operations only (is_active = 0 / is_consolidated = 1; never a hard DELETE)
--   * before/after JSON in consolidation_log for full reversibility
--
-- SQLite has no stored procedures: these are implemented in memdb (memdb/src/Procs.Judgment.cs)
-- and run when a script says CALL. Each CALL is one transaction.
--
--   CALL sp_promote_note(note_id, 'memory_type', 'category', 'title', 'content', 'run_id');
--        note -> memory (source_session = the note's session), note marked consolidated, and a
--        coarse back-pointer stamped via sp_backpoint_memory
--   CALL sp_dismiss_note(note_id, 'why', 'run_id');           ephemeral note: consolidated, not promoted
--   CALL sp_defer_note(note_id, 'why', 'run_id');             reviewed and kept: skipped for review_interval_days
--   CALL sp_normalize_category('from', 'to', 'run_id');       rename a drifted category on active memories
--   CALL sp_merge_memory(keep_id, drop_id, confidence, 'why', 'run_id');
--        soft-delete a duplicate and move its back-pointers; refused below min_merge_confidence
--   CALL sp_backpoint_memory(memory_id, session_id, 'run_id');
--        memory -> its session's transcript, spanning all its messages (skipped if not archived)
--
-- String arguments use SQL quoting: double any single quote ('it''s'). Backslashes are literal.
--
-- REVERTING a run: every action is in consolidation_log (run_id, before_json, after_json).
-- Reactivate merged rows (is_active = 1), un-consolidate notes (is_consolidated = 0), delete promoted
-- memories by after_json.new_memory_id, and delete the memory_sources rows added that run.

-- Speeds up v_confirm_worklist's lookup of the note a memory was promoted from.
CREATE INDEX IF NOT EXISTS ix_log_promoted_memory
  ON consolidation_log (CAST(json_extract(after_json, '$.new_memory_id') AS INTEGER))
  WHERE action = 'promote_note';
