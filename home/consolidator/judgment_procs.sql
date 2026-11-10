-- judgment_procs.sql -- rail-enforcing mutation API for the consolidation pass.
-- The autonomous LLM pass NEVER writes to memories/session_notes directly; it
-- calls ONLY these procedures, which enforce the rails mechanically:
--   * honor enabled (kill switch) and dry_run (log-only) from consolidation_config
--   * cap real mutations per run at max_actions_per_run (blast radius)
--   * soft operations only (is_active=0 / is_consolidated=1; never hard DELETE)
--   * write before/after JSON to consolidation_log for full reversibility
-- Procedures: sp_backpoint_memory, sp_promote_note (calls backpoint),
--             sp_normalize_category, sp_merge_memory.

USE {{DB_NAME}};

DROP PROCEDURE IF EXISTS sp_backpoint_memory;
DROP PROCEDURE IF EXISTS sp_promote_note;
DROP PROCEDURE IF EXISTS sp_normalize_category;
DROP PROCEDURE IF EXISTS sp_merge_memory;
DROP PROCEDURE IF EXISTS sp_dismiss_note;
DROP PROCEDURE IF EXISTS sp_defer_note;

DELIMITER //

-- Stamp a coarse session-span back-pointer for a memory: memory -> the
-- transcript of its origin session, spanning that transcript's messages.
-- Skips gracefully if the session's transcript isn't archived yet.
CREATE PROCEDURE sp_backpoint_memory(
  IN p_memory_id  INT UNSIGNED,
  IN p_session_id INT UNSIGNED,
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_tid     INT UNSIGNED DEFAULT NULL;
  DECLARE v_start   VARCHAR(64)  DEFAULT NULL;
  DECLARE v_end     VARCHAR(64)  DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  IF v_enabled = 0 OR p_session_id IS NULL THEN LEAVE proc; END IF;

  -- resolve the transcript for this session (direct fk first, then via uuid)
  SELECT id INTO v_tid FROM transcripts WHERE session_id = p_session_id ORDER BY id LIMIT 1;
  IF v_tid IS NULL THEN
    SELECT t.id INTO v_tid FROM transcripts t
      JOIN sessions s ON s.session_uuid = t.session_uuid
      WHERE s.id = p_session_id ORDER BY t.id LIMIT 1;
  END IF;
  IF v_tid IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'backpoint_skipped','memories',p_memory_id,CONCAT('no archived transcript for session ',p_session_id),v_dry);
    LEAVE proc;
  END IF;

  -- already linked? avoid duplicate provenance rows
  IF EXISTS (SELECT 1 FROM memory_sources WHERE memory_id = p_memory_id AND transcript_id = v_tid) THEN
    LEAVE proc;
  END IF;

  SELECT message_uuid INTO v_start FROM transcript_messages WHERE transcript_id = v_tid ORDER BY seq ASC  LIMIT 1;
  SELECT message_uuid INTO v_end   FROM transcript_messages WHERE transcript_id = v_tid ORDER BY seq DESC LIMIT 1;
  IF v_start IS NULL THEN LEAVE proc; END IF;

  IF v_dry = 0 THEN
    INSERT INTO memory_sources(source_type,memory_id,transcript_id,start_message_uuid,end_message_uuid,rationale)
      VALUES('memory',p_memory_id,v_tid,v_start,v_end,'coarse session-span back-pointer (auto)');
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,after_json,reason,dry_run)
    VALUES(p_run_id,'add_backpointer','memories',p_memory_id,
      JSON_OBJECT('transcript_id',v_tid,'start',v_start,'end',v_end),
      CONCAT('link memory ',p_memory_id,' -> transcript ',v_tid), v_dry);
END //

-- Promote a session note into a curated memory; coarse provenance via
-- source_session, and a precise back-pointer stamped as a byproduct.
CREATE PROCEDURE sp_promote_note(
  IN p_note_id     INT UNSIGNED,
  IN p_memory_type VARCHAR(20),
  IN p_category    VARCHAR(100),
  IN p_title       VARCHAR(255),
  IN p_content     TEXT,
  IN p_run_id      VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_max     INT          DEFAULT 50;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_session INT UNSIGNED DEFAULT NULL;
  DECLARE v_title   VARCHAR(255) DEFAULT NULL;
  DECLARE v_new_id  INT UNSIGNED DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_actions_per_run';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;

  SELECT title, session_id INTO v_title, v_session FROM session_notes WHERE id = p_note_id;
  IF v_title IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','session_notes',p_note_id,'note not found',v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('promote_note','merge_memory','normalize_category','dismiss_note');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','session_notes',p_note_id,CONCAT('max_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    INSERT INTO memories(memory_type,category,title,content,source_session,is_active)
      VALUES(p_memory_type,p_category,p_title,p_content,v_session,1);
    SET v_new_id = LAST_INSERT_ID();
    UPDATE session_notes SET is_consolidated = 1 WHERE id = p_note_id;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'promote_note','session_notes',p_note_id,
      JSON_OBJECT('note_id',p_note_id,'title',v_title,'session_id',v_session),
      JSON_OBJECT('new_memory_id',v_new_id,'memory_type',p_memory_type,'category',p_category,'title',p_title,'source_session',v_session),
      'promote session note to curated memory', v_dry);

  -- back-pointer as a byproduct (only when a memory was actually created)
  IF v_dry = 0 AND v_new_id IS NOT NULL THEN
    CALL sp_backpoint_memory(v_new_id, v_session, p_run_id);
  END IF;
END //

-- Collapse a drifted category label into a canonical one across active memories.
CREATE PROCEDURE sp_normalize_category(
  IN p_from   VARCHAR(100),
  IN p_to     VARCHAR(100),
  IN p_run_id VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT DEFAULT 0;
  DECLARE v_dry     INT DEFAULT 1;
  DECLARE v_count   INT DEFAULT 0;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;

  SELECT COUNT(*) INTO v_count FROM memories WHERE category = p_from AND is_active = 1;

  INSERT INTO consolidation_log(run_id,action,target_table,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'normalize_category','memories',
      JSON_OBJECT('from',p_from,'affected',v_count),
      JSON_OBJECT('to',p_to),
      CONCAT('rename category "',p_from,'" -> "',p_to,'" across ',v_count,' active memories'), v_dry);

  IF v_dry = 0 THEN
    UPDATE memories SET category = p_to WHERE category = p_from AND is_active = 1;
  END IF;
END //

-- Merge a duplicate memory into a survivor. Soft-deletes the duplicate and
-- transfers its back-pointers; gated by min_merge_confidence. No content
-- machine-merge -- the dropped row is preserved (inactive) and recoverable.
CREATE PROCEDURE sp_merge_memory(
  IN p_keep_id    INT UNSIGNED,
  IN p_drop_id    INT UNSIGNED,
  IN p_confidence DECIMAL(3,2),
  IN p_reason     VARCHAR(500),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_max     INT          DEFAULT 50;
  DECLARE v_min     DECIMAL(3,2) DEFAULT 0.85;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_keep_t  VARCHAR(255) DEFAULT NULL;
  DECLARE v_drop_t  VARCHAR(255) DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED)       INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_max     FROM consolidation_config WHERE cfg_key='max_actions_per_run';
  SELECT CAST(cfg_value AS DECIMAL(3,2)) INTO v_min     FROM consolidation_config WHERE cfg_key='min_merge_confidence';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;

  IF p_keep_id = p_drop_id THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_drop_id,'keep_id == drop_id',v_dry);
    LEAVE proc;
  END IF;

  SELECT title INTO v_keep_t FROM memories WHERE id = p_keep_id AND is_active = 1;
  SELECT title INTO v_drop_t FROM memories WHERE id = p_drop_id AND is_active = 1;
  IF v_keep_t IS NULL OR v_drop_t IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','memories',p_drop_id,'keep or drop memory not found / inactive',v_dry);
    LEAVE proc;
  END IF;

  -- confidence rail
  IF p_confidence < v_min THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,reason,dry_run)
      VALUES(p_run_id,'merge_skipped_low_confidence','memories',p_drop_id,
        JSON_OBJECT('keep_id',p_keep_id,'drop_id',p_drop_id,'confidence',p_confidence,'threshold',v_min),
        p_reason, v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('promote_note','merge_memory','normalize_category','dismiss_note');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','memories',p_drop_id,CONCAT('max_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'merge_memory','memories',p_drop_id,
      JSON_OBJECT('keep_id',p_keep_id,'keep_title',v_keep_t,'drop_id',p_drop_id,'drop_title',v_drop_t,'drop_was_active',1),
      JSON_OBJECT('survivor',p_keep_id,'dropped',p_drop_id,'confidence',p_confidence),
      p_reason, v_dry);

  IF v_dry = 0 THEN
    UPDATE memories SET is_active = 0 WHERE id = p_drop_id;
    UPDATE memory_sources SET memory_id = p_keep_id WHERE memory_id = p_drop_id;
  END IF;
END //

-- Mark an ephemeral note consolidated WITHOUT promoting it, so the backlog
-- drains. Shares the per-run mutation cap; fully reversible (is_consolidated=0).
CREATE PROCEDURE sp_dismiss_note(
  IN p_note_id INT UNSIGNED,
  IN p_reason  VARCHAR(500),
  IN p_run_id  VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_max     INT          DEFAULT 50;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_title   VARCHAR(255) DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_actions_per_run';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;

  SELECT title INTO v_title FROM session_notes WHERE id = p_note_id AND is_consolidated = 0;
  IF v_title IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','session_notes',p_note_id,'note not found or already consolidated',v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('promote_note','merge_memory','normalize_category','dismiss_note');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','session_notes',p_note_id,CONCAT('max_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    UPDATE session_notes SET is_consolidated = 1 WHERE id = p_note_id;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'dismiss_note','session_notes',p_note_id,
      JSON_OBJECT('note_id',p_note_id,'title',v_title,'is_consolidated',0),
      JSON_OBJECT('is_consolidated',1),
      p_reason, v_dry);
END //

-- Defer a note: the pass reviewed it and chose to keep it for now (neither
-- promote nor dismiss). Stamps last_reviewed so the batch query skips it for
-- review_interval_days, sparing the LLM from re-reading the same "leave" notes
-- every run. Benign bookkeeping -- NOT counted against the per-run cap.
CREATE PROCEDURE sp_defer_note(
  IN p_note_id INT UNSIGNED,
  IN p_reason  VARCHAR(500),
  IN p_run_id  VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_title   VARCHAR(255) DEFAULT NULL;
  DECLARE v_prev    DATETIME     DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;

  SELECT title, last_reviewed INTO v_title, v_prev FROM session_notes WHERE id = p_note_id AND is_consolidated = 0;
  IF v_title IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','session_notes',p_note_id,'note not found or already consolidated',v_dry);
    LEAVE proc;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'defer_note','session_notes',p_note_id,
      JSON_OBJECT('note_id',p_note_id,'title',v_title,'last_reviewed',v_prev),
      JSON_OBJECT('last_reviewed','set to now'),
      p_reason, v_dry);

  IF v_dry = 0 THEN
    UPDATE session_notes SET last_reviewed = NOW() WHERE id = p_note_id;
  END IF;
END //

DELIMITER ;
