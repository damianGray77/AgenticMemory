-- tier1_mechanical.sql -- safe, deterministic consolidation tier.
-- Defines two read-only worklist views and a config-aware stored procedure.
-- The procedure logs every proposed action to consolidation_log and only
-- mutates when consolidation_config.dry_run = 0. Honors the enabled kill switch.
-- Source of truth for the mechanical tier; re-runnable (idempotent).

USE {{DB_NAME}};

-- ---------- worklist views (read-only; surfaced at SessionStart) ----------
CREATE OR REPLACE VIEW v_consolidation_backlog AS
SELECT
  (SELECT COUNT(*)                 FROM session_notes   WHERE is_consolidated = 0) AS unconsolidated_notes,
  (SELECT COUNT(DISTINCT session_id) FROM session_notes WHERE is_consolidated = 0) AS unconsolidated_sessions,
  (SELECT MIN(created_at)          FROM session_notes   WHERE is_consolidated = 0) AS oldest_unconsolidated,
  (SELECT COUNT(*)                 FROM memories        WHERE is_active = 1)       AS active_memories,
  (SELECT COUNT(*)                 FROM memories        WHERE is_active = 1 AND expires_at IS NOT NULL AND expires_at < NOW()) AS memories_due_expiry,
  (SELECT COUNT(*)                 FROM user_observations
        WHERE is_active = 1 AND confidence > 0
          AND last_seen < NOW() - INTERVAL (SELECT CAST(cfg_value AS UNSIGNED) FROM consolidation_config WHERE cfg_key='observation_decay_days') DAY) AS observations_due_decay,
  (SELECT COUNT(DISTINCT category) FROM memories        WHERE is_active = 1)       AS distinct_categories;

CREATE OR REPLACE VIEW v_unconsolidated_by_session AS
SELECT session_id, COUNT(*) AS notes, MIN(created_at) AS oldest, MAX(created_at) AS newest
FROM session_notes
WHERE is_consolidated = 0
GROUP BY session_id
ORDER BY notes DESC;

-- ---------- mechanical consolidation procedure ----------
DROP PROCEDURE IF EXISTS sp_consolidate_mechanical;
DELIMITER //
CREATE PROCEDURE sp_consolidate_mechanical(IN p_run_id VARCHAR(40))
proc: BEGIN
  DECLARE v_enabled INT           DEFAULT 0;
  DECLARE v_dry     INT           DEFAULT 1;
  DECLARE v_days    INT           DEFAULT 30;
  DECLARE v_step    DECIMAL(3,2)  DEFAULT 0.05;

  SELECT CAST(cfg_value AS SIGNED)       INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_days    FROM consolidation_config WHERE cfg_key='observation_decay_days';
  SELECT CAST(cfg_value AS DECIMAL(3,2)) INTO v_step    FROM consolidation_config WHERE cfg_key='observation_decay_step';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log (run_id, action, reason, dry_run)
    VALUES (p_run_id, 'skipped', 'enabled=0 (kill switch)', v_dry);
  ELSE
    -- daily throttle: at most one real mechanical run per calendar day,
    -- so the event + the skill + any manual call cannot stack decays.
    IF p_run_id NOT LIKE 'test-%'
       AND EXISTS (SELECT 1 FROM consolidation_log
                   WHERE action='mechanical_run' AND created_at >= CURDATE()
                     AND run_id NOT LIKE 'test-%') THEN
      LEAVE proc;
    END IF;
    INSERT INTO consolidation_log (run_id, action, reason, dry_run)
      VALUES (p_run_id, 'mechanical_run', CONCAT('mechanical tier; dry_run=', v_dry), v_dry);

    -- (1) decay stale observations (log first, then apply if not dry)
    INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, after_json, reason, dry_run)
    SELECT p_run_id, 'decay_observation', 'user_observations', id,
           JSON_OBJECT('confidence', confidence),
           JSON_OBJECT('confidence', GREATEST(0, confidence - v_step)),
           CONCAT('unseen since ', DATE(last_seen)), v_dry
    FROM user_observations
    WHERE is_active = 1 AND confidence > 0 AND last_seen < NOW() - INTERVAL v_days DAY;

    IF v_dry = 0 THEN
      UPDATE user_observations
      SET confidence = GREATEST(0, confidence - v_step)
      WHERE is_active = 1 AND confidence > 0 AND last_seen < NOW() - INTERVAL v_days DAY;
    END IF;

    -- (2) expire past-TTL memories (soft delete: is_active=0)
    INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, after_json, reason, dry_run)
    SELECT p_run_id, 'expire_memory', 'memories', id,
           JSON_OBJECT('is_active', is_active),
           JSON_OBJECT('is_active', 0),
           CONCAT('expires_at ', expires_at, ' < now'), v_dry
    FROM memories
    WHERE is_active = 1 AND expires_at IS NOT NULL AND expires_at < NOW();

    IF v_dry = 0 THEN
      UPDATE memories SET is_active = 0
      WHERE is_active = 1 AND expires_at IS NOT NULL AND expires_at < NOW();
    END IF;
  END IF;
END //
DELIMITER ;
