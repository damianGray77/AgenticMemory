-- confirm.sql -- memory confirmation (S1663, 2026-11-02): every new memory starts unconfirmed, and
-- the consolidation pass checks it against the conversation it came from before confirming it.
--
-- WHY: S1656 wrote "MealPlan Admin would expose meal card numbers and PINs IF IIS allowed anonymous
-- access" in the conversation, but the notes it saved dropped the "if" (note 2775's combined
-- "consequence" sentence, note 2771's title). Consolidation copied the notes faithfully into memories
-- 2137 and 2140, and the unconditional version reached a client email. Checking a memory against its
-- note proves nothing; it has to be checked against the discussion itself.
--
-- MODEL:
--   memories.confirmed = 0  draft: the pass may correct it, only to make it faithful to its transcript
--   memories.confirmed = 1  the append-only record: never edited again (sp_confirm_memory refuses)
--   confirm_outcome         backfill | faithful | corrected | no_source (no_source stays unconfirmed)
--   confirm_checked_at      when the check ran
-- Memories older than 48 hours at setup were backfilled as confirmed (runs/confirm-setup-20261102.sql).
--
-- RAILS (consolidation_config): enabled and dry_run as everywhere, plus confirm_enabled (kill switch
-- for this step), confirm_dry_run (log-only for this step) and max_confirm_actions_per_run.
--
-- REVERTING: every confirm_memory row in consolidation_log carries before_json (title, content,
-- confirmed, confirm_outcome, confirm_checked_at, updated_at). Restore those columns from it.
-- The backfill is one confirm_backfill row: UPDATE memories SET confirmed = 0, confirm_outcome = NULL,
-- confirm_checked_at = NULL, updated_at = updated_at WHERE confirm_outcome = 'backfill'.

USE {{DB_NAME}};

-- Unconfirmed memories with where to check them and whether they can be checked yet.
--   ready      the source session's main transcript is archived past the point the memory was made
--   waiting    the transcript is not archived that far yet (session still running, or not swept)
--   no_source  no session and no back-pointer, or a session with no transcript after 2 days
-- origin_at is when the memory's content was written: the source note's time for a promoted
-- memory (promotion can run hours after the session), else the memory's own created_at.
-- Transcript times are UTC; memory and note times are local, hence the offset.
CREATE OR REPLACE VIEW v_confirm_worklist AS
SELECT w.memory_id, w.memory_type, w.category, w.title, w.content, w.created_at, w.source_session,
       w.from_note_id, w.origin_at, w.transcript_id, tt.last_message_at AS transcript_last_utc,
       w.confirm_outcome,
       CASE
         WHEN w.transcript_id IS NULL AND w.source_session IS NULL THEN 'no_source'
         WHEN w.transcript_id IS NULL AND w.session_started_at < NOW() - INTERVAL 2 DAY THEN 'no_source'
         WHEN w.transcript_id IS NULL THEN 'waiting'
         WHEN tt.last_message_at IS NULL
           OR tt.last_message_at < w.origin_at - INTERVAL TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW()) MINUTE
           THEN 'waiting'
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
        AND CAST(JSON_UNQUOTE(JSON_EXTRACT(cl.after_json, '$.new_memory_id')) AS UNSIGNED) = m.id
  LEFT JOIN session_notes n ON n.id = cl.target_id
  WHERE m.is_active = 1 AND m.confirmed = 0
) w
LEFT JOIN transcripts tt ON tt.id = w.transcript_id;

DROP PROCEDURE IF EXISTS sp_confirm_memory;

DELIMITER //

-- Record the outcome of checking one unconfirmed memory against its transcript.
--   faithful   confirm as is (p_title / p_content must be NULL)
--   corrected  replace title and/or content with the faithful version, then confirm
--   no_source  nothing to check against: stays unconfirmed, marked so it is not retried
-- A confirmed memory is refused: it is the append-only record from then on.
-- 'faithful' and 'no_source' keep updated_at, so they do not requeue the memory for behaviours;
-- 'corrected' bumps it, so the behaviours step re-reads the corrected text.
CREATE PROCEDURE sp_confirm_memory(
  IN p_memory_id INT UNSIGNED,
  IN p_outcome   VARCHAR(20),
  IN p_title     VARCHAR(255),
  IN p_content   TEXT,
  IN p_reason    VARCHAR(2000),
  IN p_run_id    VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled   INT          DEFAULT 0;
  DECLARE v_dry       INT          DEFAULT 1;
  DECLARE v_cdry      INT          DEFAULT 1;
  DECLARE v_cenabled  INT          DEFAULT 0;
  DECLARE v_max       INT          DEFAULT 30;
  DECLARE v_acted     INT          DEFAULT 0;
  DECLARE v_found     INT          DEFAULT 0;
  DECLARE v_confirmed INT          DEFAULT 0;
  DECLARE v_session   INT UNSIGNED DEFAULT NULL;
  DECLARE v_before    JSON         DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled  FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry      FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_cenabled FROM consolidation_config WHERE cfg_key='confirm_enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_cdry     FROM consolidation_config WHERE cfg_key='confirm_dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max      FROM consolidation_config WHERE cfg_key='max_confirm_actions_per_run';
  SET v_dry = GREATEST(v_dry, v_cdry);

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_cenabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','confirm_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  SELECT COUNT(*) INTO v_found FROM memories WHERE id = p_memory_id AND is_active = 1;
  IF v_found = 0 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_memory_id,'memory not found or inactive',v_dry);
    LEAVE proc;
  END IF;
  SELECT confirmed, source_session,
         JSON_OBJECT('title',title,'content',content,'confirmed',confirmed,'confirm_outcome',confirm_outcome,
                     'confirm_checked_at',confirm_checked_at,'updated_at',updated_at)
    INTO v_confirmed, v_session, v_before
    FROM memories WHERE id = p_memory_id;
  IF v_confirmed = 1 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_memory_id,'already confirmed: confirmed memories are append-only',v_dry);
    LEAVE proc;
  END IF;
  IF p_outcome NOT IN ('faithful','corrected','no_source') THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_memory_id,CONCAT('bad outcome: ',IFNULL(p_outcome,'NULL')),v_dry);
    LEAVE proc;
  END IF;
  IF p_outcome = 'corrected' AND p_title IS NULL AND p_content IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_memory_id,'corrected needs a new title or content',v_dry);
    LEAVE proc;
  END IF;
  IF p_outcome <> 'corrected' AND (p_title IS NOT NULL OR p_content IS NOT NULL) THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_memory_id,CONCAT(p_outcome,' takes no new title or content'),v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0 AND action = 'confirm_memory';
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','memories',p_memory_id,CONCAT('max_confirm_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;

    IF p_outcome = 'faithful' THEN
      UPDATE memories SET confirmed = 1, confirm_outcome = 'faithful', confirm_checked_at = NOW(),
                          updated_at = updated_at
       WHERE id = p_memory_id;
    ELSEIF p_outcome = 'corrected' THEN
      UPDATE memories SET title = COALESCE(p_title, title), content = COALESCE(p_content, content),
                          confirmed = 1, confirm_outcome = 'corrected', confirm_checked_at = NOW()
       WHERE id = p_memory_id;
    ELSE
      UPDATE memories SET confirm_outcome = 'no_source', confirm_checked_at = NOW(), updated_at = updated_at
       WHERE id = p_memory_id;
    END IF;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'confirm_memory','memories',p_memory_id,v_before,
      JSON_OBJECT('outcome',p_outcome,'title',p_title,'content',p_content),
      LEFT(CONCAT(p_outcome,': ',IFNULL(p_reason,'')),500), v_dry);

  -- a checked memory should point at what it was checked against
  IF v_dry = 0 AND p_outcome <> 'no_source' AND v_session IS NOT NULL THEN
    CALL sp_backpoint_memory(p_memory_id, v_session, p_run_id);
  END IF;
END //

DELIMITER ;
