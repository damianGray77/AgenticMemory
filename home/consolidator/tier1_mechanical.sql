-- tier1_mechanical.sql -- the safe, deterministic consolidation tier.
--
-- Two read-only worklist views. The procedure itself, CALL sp_consolidate_mechanical('<run_id>'),
-- lives in memdb (memdb/src/Procs.Mechanical.cs): it decays observations not seen for
-- observation_decay_days by observation_decay_step, and expires memories past expires_at. It logs
-- every proposed action to consolidation_log, mutates only when consolidation_config.dry_run = 0,
-- honours the enabled kill switch, and does real work at most once per calendar day.
--
-- Under MySQL an hourly EVENT called it. SQLite has no scheduler, so session_boot.sh calls it on
-- every start (the daily throttle makes all but the first call of the day a no-op), and the
-- consolidation skill calls it at the start of each pass. Re-runnable.

DROP VIEW IF EXISTS v_consolidation_backlog;
CREATE VIEW v_consolidation_backlog AS
SELECT
  (SELECT COUNT(*)                   FROM session_notes WHERE is_consolidated = 0) AS unconsolidated_notes,
  (SELECT COUNT(DISTINCT session_id) FROM session_notes WHERE is_consolidated = 0) AS unconsolidated_sessions,
  (SELECT MIN(created_at)            FROM session_notes WHERE is_consolidated = 0) AS oldest_unconsolidated,
  (SELECT COUNT(*)                   FROM memories      WHERE is_active = 1)       AS active_memories,
  (SELECT COUNT(*)                   FROM memories      WHERE is_active = 1 AND expires_at IS NOT NULL AND expires_at < now()) AS memories_due_expiry,
  (SELECT COUNT(*)                   FROM user_observations
        WHERE is_active = 1 AND confidence > 0
          AND last_seen < datetime(now(), '-' || (SELECT CAST(cfg_value AS INTEGER) FROM consolidation_config
                                                  WHERE cfg_key = 'observation_decay_days') || ' days')) AS observations_due_decay,
  (SELECT COUNT(DISTINCT category)   FROM memories      WHERE is_active = 1)       AS distinct_categories;

DROP VIEW IF EXISTS v_unconsolidated_by_session;
CREATE VIEW v_unconsolidated_by_session AS
SELECT session_id, COUNT(*) AS notes, MIN(created_at) AS oldest, MAX(created_at) AS newest
FROM session_notes
WHERE is_consolidated = 0
GROUP BY session_id
ORDER BY notes DESC;
