-- behaviours.sql -- the behaviours layer: current guidance derived from memories.
-- Tables live in claude_memory_schema.sql (behaviours, behaviour_evidence,
-- behaviour_evidence_kinds, behaviour_source_reviews). This file holds their
-- seed rows, the views that compute strength, and the rail-enforcing procedures
-- the consolidation pass calls. Same rails as judgment_procs.sql:
--   * honor enabled (kill switch) and dry_run (log-only) from consolidation_config
--   * honor behaviours_enabled, a second switch for this layer alone: it stays 0
--     until the supervised backfill has been reviewed and applied, so the
--     unattended 3-hourly run cannot start the backfill on its own
--   * cap real mutations per run at max_behaviour_actions_per_run (its own budget,
--     so behaviour work never starves note promotion, and vice versa)
--   * soft operations only; memories are never touched, evidence is superseded
--     rather than deleted, behaviours are retired rather than deleted
--   * write before/after JSON to consolidation_log for full reversibility
-- Re-runnable: procedures are dropped and recreated, views replaced, and seed
-- rows inserted with INSERT IGNORE so a tuned anchor weight survives a re-run.
--
-- Procedures: sp_upsert_behaviour, sp_link_evidence, sp_supersede_evidence,
--             sp_retire_behaviour (all capped); sp_resolve_behaviour,
--             sp_refresh_behaviours, sp_mark_reviewed (bookkeeping, not capped).
--
-- DRY RUN CAVEAT: under dry_run=1 nothing is inserted, so a later call that
-- needs a row an earlier call would have created (link to a new subject,
-- supersede a new evidence row) can only log what it would do. For a full
-- preview with computed strengths, run the calls live inside
-- START TRANSACTION ... ROLLBACK and read the results before rolling back.
--
-- REVERTING A RUN: every mutation is in consolidation_log under its run_id.
--   link_evidence      -> DELETE FROM behaviour_evidence WHERE id = target_id
--   supersede_evidence -> UPDATE behaviour_evidence SET superseded_by = NULL WHERE id = target_id
--   upsert_behaviour   -> restore before_json.statement / before_json.status, or
--                         DELETE the behaviour when after_json.created = 1
--   retire_behaviour   -> restore before_json.status
--   mark_reviewed      -> DELETE the behaviour_source_reviews row, or restore before_json
-- then CALL sp_refresh_behaviours('<revert-run>') to recompute.

USE {{DB_NAME}};

-- ---------- seed rows ----------

-- The weight scale. Anchors are reference points, not the only legal values:
-- a link may move off its anchor by behaviour_weight_tolerance for emphasis.
INSERT IGNORE INTO behaviour_evidence_kinds (kind, anchor_weight, description) VALUES
  ('requirement',            1.00, '{{USER_NAME}} stated it as a hard requirement, or it is enforced by a hook or deny rule'),
  ('stated_preference',      0.90, '{{USER_NAME}} stated it as a preference and it was saved with approval'),
  ('correction',             0.85, '{{USER_NAME}} stopped or redirected me partway through a task'),
  ('approved_proposal',      0.75, '{{USER_NAME}} approved a rule I proposed'),
  ('output_fix',             0.65, '{{USER_NAME}} fixed or rejected my work afterward without stating a rule'),
  ('cross_session_pattern',  0.55, '{{USER_NAME}}''s own behaviour shows the pattern across several sessions'),
  ('silent_acceptance',      0.45, '{{USER_NAME}} accepted my approach without comment'),
  ('single_session_pattern', 0.35, 'A pattern seen in only one session'),
  ('project_convention',     0.25, 'Inferred from the project''s conventions, not from {{USER_NAME}}'),
  ('own_default',            0.15, 'My own default, never confirmed');

INSERT IGNORE INTO consolidation_config (cfg_key, cfg_value, note) VALUES
  ('behaviour_rule_threshold',       '0.75', 'Evidence at or above this base weight makes a rule: it never decays, and only it can supersede older evidence'),
  ('behaviour_habit_half_life_days', '120',  'Half-life in days of evidence below the rule threshold'),
  ('behaviour_weight_tolerance',     '0.05', 'How far a link may move off the anchor weight of its kind, for emphasis'),
  ('behaviour_boot_min_strength',    '0.50', 'Session boot lists active behaviours at or above this strength; conflicts are always listed'),
  ('max_behaviour_actions_per_run',  '50',   'Per-run cap on behaviour mutations (upsert, link, supersede, retire); separate from max_actions_per_run'),
  ('behaviours_enabled',             '0',    'Switch for the behaviours layer alone; 0 until the supervised backfill is reviewed and applied');

-- ---------- views ----------

CREATE OR REPLACE VIEW v_behaviour_config AS
SELECT
  MAX(CASE WHEN cfg_key = 'behaviour_rule_threshold'       THEN CAST(cfg_value AS DECIMAL(3,2)) END) AS rule_threshold,
  MAX(CASE WHEN cfg_key = 'behaviour_habit_half_life_days' THEN CAST(cfg_value AS UNSIGNED)     END) AS half_life_days,
  MAX(CASE WHEN cfg_key = 'behaviour_boot_min_strength'    THEN CAST(cfg_value AS DECIMAL(4,3)) END) AS boot_min_strength
FROM consolidation_config;

-- Evidence that still counts: not superseded, and its source still active
-- (an expired or merged-away memory stops counting; a session note always
-- counts). An observation seen again since it was linked is dated by its
-- latest sighting. Evidence below the rule threshold decays by half-life;
-- evidence at or above it keeps its full weight.
CREATE OR REPLACE VIEW v_behaviour_evidence_live AS
SELECT x.*,
       CASE WHEN x.weight >= c.rule_threshold THEN x.weight
            ELSE ROUND(x.weight * POW(0.5, GREATEST(0, TIMESTAMPDIFF(DAY, x.occurred_at, NOW())) / c.half_life_days), 4)
       END AS weight_eff
FROM (
  SELECT e.id, e.behaviour_id, e.source_type, e.source_id, e.evidence_kind, e.weight, e.stance, e.event_key,
         CASE WHEN e.source_type = 'observation' AND o.last_seen > e.occurred_at THEN o.last_seen
              ELSE e.occurred_at END AS occurred_at
  FROM behaviour_evidence e
  LEFT JOIN memories          m ON e.source_type = 'memory'      AND m.id = e.source_id
  LEFT JOIN user_observations o ON e.source_type = 'observation' AND o.id = e.source_id
  WHERE e.superseded_by IS NULL
    AND (   (e.source_type = 'memory'      AND m.is_active = 1)
         OR (e.source_type = 'observation' AND o.is_active = 1)
         OR  e.source_type = 'session_note')
) x
CROSS JOIN v_behaviour_config c;

-- One row per real-world event: a correction recorded as a note, a memory and
-- an observation is still one correction, so it counts once, at its best weight.
CREATE OR REPLACE VIEW v_behaviour_events AS
SELECT behaviour_id, event_key, stance,
       MAX(weight)      AS weight,
       MAX(weight_eff)  AS weight_eff,
       MAX(occurred_at) AS occurred_at,
       COUNT(*)         AS source_rows
FROM v_behaviour_evidence_live
GROUP BY behaviour_id, event_key, stance;

-- strength = 1 - PRODUCT(1 - w) over supporting events, done as a sum of logs.
-- The 0.0001 floor keeps LN finite for a 1.00 requirement (rounds to 1.000).
CREATE OR REPLACE VIEW v_behaviour_strength AS
SELECT b.id AS behaviour_id,
       CAST(ROUND(1 - EXP(COALESCE(SUM(CASE WHEN ev.stance = 'supports'
                                            THEN LN(GREATEST(1 - ev.weight_eff, 0.0001)) END), 0)), 3)
            AS DECIMAL(4,3)) AS strength,
       CASE WHEN MAX(CASE WHEN ev.stance = 'supports' AND ev.weight >= c.rule_threshold THEN 1 ELSE 0 END) = 1
            THEN 'rule' ELSE 'habit' END AS kind,
       COALESCE(SUM(ev.stance = 'supports'), 0) AS supporting_events,
       COALESCE(SUM(ev.stance = 'opposes'), 0)  AS opposing_events,
       MAX(CASE WHEN ev.stance = 'opposes' THEN ev.weight_eff END) AS max_opposing_weight
FROM behaviours b
LEFT JOIN v_behaviour_events ev ON ev.behaviour_id = b.id
CROSS JOIN v_behaviour_config c
GROUP BY b.id, c.rule_threshold;

-- What session boot prints: open conflicts first, then rules, then habits.
CREATE OR REPLACE VIEW v_behaviours_boot AS
SELECT b.id, b.subject, p.slug AS project, b.kind, b.strength, b.status,
       b.statement, b.conflict_note, b.resolved_at
FROM behaviours b
LEFT JOIN projects p ON p.id = b.project_id
CROSS JOIN v_behaviour_config c
WHERE b.status = 'conflict'
   OR (b.status = 'active' AND b.strength >= c.boot_min_strength)
ORDER BY (b.status = 'conflict') DESC, (b.kind = 'rule') DESC, b.strength DESC, b.subject;

-- What the behaviour step still has to read, oldest first so that a newer
-- statement is always handled after the evidence it may supersede. Scope:
-- user/feedback memories (limitations are facts about tools, not behaviour, and
-- are left out for now) and active observations. Queued again when a memory is
-- edited, or an observation is seen again, after its review.
CREATE OR REPLACE VIEW v_behaviour_worklist AS
SELECT 'memory' AS source_type, m.id AS source_id, m.memory_type AS type, m.category,
       m.title, m.content, m.created_at AS dated, r.reviewed_at
FROM memories m
LEFT JOIN behaviour_source_reviews r ON r.source_type = 'memory' AND r.source_id = m.id
WHERE m.is_active = 1
  AND m.confirmed = 1          -- only memories checked against their transcript (confirm.sql)
  AND m.memory_type IN ('user','feedback')
  AND IFNULL(m.category, '') <> 'limitation'
  AND (r.reviewed_at IS NULL OR m.updated_at > r.reviewed_at)
UNION ALL
SELECT 'observation', o.id, 'observation', o.category,
       o.title, o.content, o.last_seen, r.reviewed_at
FROM user_observations o
LEFT JOIN behaviour_source_reviews r ON r.source_type = 'observation' AND r.source_id = o.id
WHERE o.is_active = 1
  AND (r.reviewed_at IS NULL OR o.last_seen > r.reviewed_at)
ORDER BY dated;

-- ---------- procedures ----------

DROP PROCEDURE IF EXISTS sp_resolve_behaviour;
DROP PROCEDURE IF EXISTS sp_refresh_behaviours;
DROP PROCEDURE IF EXISTS sp_upsert_behaviour;
DROP PROCEDURE IF EXISTS sp_link_evidence;
DROP PROCEDURE IF EXISTS sp_supersede_evidence;
DROP PROCEDURE IF EXISTS sp_retire_behaviour;
DROP PROCEDURE IF EXISTS sp_mark_reviewed;

DELIMITER //

-- Recompute kind, strength and status from live evidence. Derived bookkeeping:
-- not counted against the cap, and logged only when something changed.
CREATE PROCEDURE sp_resolve_behaviour(
  IN p_behaviour_id INT UNSIGNED,
  IN p_run_id       VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled     INT          DEFAULT 0;
  DECLARE v_dry         INT          DEFAULT 1;
  DECLARE v_kind_old    VARCHAR(10)  DEFAULT NULL;
  DECLARE v_str_old     DECIMAL(4,3) DEFAULT NULL;
  DECLARE v_status_old  VARCHAR(10)  DEFAULT NULL;
  DECLARE v_note_old    VARCHAR(500) DEFAULT NULL;
  DECLARE v_kind        VARCHAR(10)  DEFAULT 'habit';
  DECLARE v_str         DECIMAL(4,3) DEFAULT 0;
  DECLARE v_status      VARCHAR(10)  DEFAULT 'active';
  DECLARE v_note        VARCHAR(500) DEFAULT NULL;
  DECLARE v_opp         INT          DEFAULT 0;
  DECLARE v_opp_w       DECIMAL(6,4) DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  IF v_enabled = 0 THEN LEAVE proc; END IF;

  SELECT kind, strength, status, conflict_note INTO v_kind_old, v_str_old, v_status_old, v_note_old
    FROM behaviours WHERE id = p_behaviour_id;
  IF v_status_old IS NULL THEN LEAVE proc; END IF;

  SELECT kind, strength, opposing_events, max_opposing_weight INTO v_kind, v_str, v_opp, v_opp_w
    FROM v_behaviour_strength WHERE behaviour_id = p_behaviour_id;

  -- retired stays retired until sp_upsert_behaviour revives it; any live
  -- opposing evidence is a conflict for {{USER_NAME}} to settle, never a silent win
  IF v_status_old = 'retired' THEN
    SET v_status = 'retired', v_note = v_note_old;
  ELSEIF v_opp > 0 THEN
    SET v_status = 'conflict',
        v_note   = CONCAT(v_opp, ' opposing event(s), strongest at ', ROUND(v_opp_w, 2),
                          '; only a newer statement from {{USER_NAME}} can settle it');
  ELSE
    SET v_status = 'active', v_note = NULL;
  END IF;

  IF v_kind = v_kind_old AND v_str = v_str_old AND v_status = v_status_old AND (v_note <=> v_note_old) THEN
    IF v_dry = 0 THEN
      UPDATE behaviours SET resolved_at = NOW(), resolved_run_id = p_run_id WHERE id = p_behaviour_id;
    END IF;
    LEAVE proc;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'resolve_behaviour','behaviours',p_behaviour_id,
      JSON_OBJECT('kind',v_kind_old,'strength',v_str_old,'status',v_status_old,'conflict_note',v_note_old),
      JSON_OBJECT('kind',v_kind,'strength',v_str,'status',v_status,'conflict_note',v_note),
      'recomputed from live evidence', v_dry);

  IF v_dry = 0 THEN
    UPDATE behaviours
       SET kind = v_kind, strength = v_str, status = v_status, conflict_note = v_note,
           resolved_at = NOW(), resolved_run_id = p_run_id
     WHERE id = p_behaviour_id;
  END IF;
END //

-- Re-resolve every behaviour that is not retired, so habit decay is applied
-- even when no new evidence arrived. Walks ids with MIN() rather than a cursor:
-- a NOT FOUND raised inside the called procedure would otherwise trip the
-- cursor's handler and end the loop early.
CREATE PROCEDURE sp_refresh_behaviours(
  IN p_run_id VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_last    INT UNSIGNED DEFAULT 0;
  DECLARE v_next    INT UNSIGNED DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;

  walk: LOOP
    SET v_next = NULL;
    SELECT MIN(id) INTO v_next FROM behaviours WHERE id > v_last AND status <> 'retired';
    IF v_next IS NULL THEN LEAVE walk; END IF;
    CALL sp_resolve_behaviour(v_next, p_run_id);
    SET v_last = v_next;
  END LOOP;
END //

-- Create a behaviour, or rewrite its statement when {{USER_NAME}}'s guidance has
-- changed. Reviving a retired behaviour also goes through here.
CREATE PROCEDURE sp_upsert_behaviour(
  IN p_subject    VARCHAR(100),
  IN p_project_id INT UNSIGNED,      -- NULL = global
  IN p_statement  TEXT,
  IN p_reason     VARCHAR(500),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled    INT          DEFAULT 0;
  DECLARE v_dry        INT          DEFAULT 1;
  DECLARE v_max        INT          DEFAULT 50;
  DECLARE v_acted      INT          DEFAULT 0;
  DECLARE v_id         INT UNSIGNED DEFAULT NULL;
  DECLARE v_old        TEXT         DEFAULT NULL;
  DECLARE v_old_status VARCHAR(10)  DEFAULT NULL;
  DECLARE v_beh        INT          DEFAULT 0;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_behaviour_actions_per_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_beh     FROM consolidation_config WHERE cfg_key='behaviours_enabled';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_beh = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','behaviours_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  -- one naming scheme, so subjects cannot drift the way memory categories did
  -- ('c' = case-sensitive; the column collation would otherwise accept capitals)
  IF p_subject IS NULL OR NOT REGEXP_LIKE(p_subject, '^[a-z0-9-]+([.][a-z0-9-]+)+$', 'c') THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviours',
        CONCAT('bad subject "', IFNULL(p_subject,'NULL'), '": want dotted lowercase, e.g. tooling.scripting-languages'), v_dry);
    LEAVE proc;
  END IF;
  IF p_statement IS NULL OR TRIM(p_statement) = '' THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviours',CONCAT('empty statement for ', p_subject), v_dry);
    LEAVE proc;
  END IF;

  SELECT id, statement, status INTO v_id, v_old, v_old_status
    FROM behaviours WHERE subject = p_subject AND scope_project_id = IFNULL(p_project_id, 0);
  IF v_id IS NOT NULL AND v_old = p_statement AND v_old_status <> 'retired' THEN
    LEAVE proc;   -- nothing to change
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('upsert_behaviour','link_evidence','supersede_evidence','retire_behaviour');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','behaviours',v_id,CONCAT('max_behaviour_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    IF v_id IS NULL THEN
      INSERT INTO behaviours(subject, project_id, statement, resolved_run_id)
        VALUES(p_subject, p_project_id, p_statement, p_run_id);
      SET v_id = LAST_INSERT_ID();
    ELSE
      UPDATE behaviours
         SET statement = p_statement,
             status    = IF(status = 'retired', 'active', status)
       WHERE id = v_id;
    END IF;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'upsert_behaviour','behaviours',v_id,
      IF(v_old IS NULL, NULL, JSON_OBJECT('statement',v_old,'status',v_old_status)),
      JSON_OBJECT('subject',p_subject,'project_id',p_project_id,'statement',p_statement,'created',v_old IS NULL),
      p_reason, v_dry);

  IF v_dry = 0 THEN
    CALL sp_resolve_behaviour(v_id, p_run_id);
  END IF;
END //

-- Link one piece of evidence (a memory, observation or session note) to a
-- behaviour, then re-resolve it. The weight must sit within tolerance of the
-- anchor for its kind, which keeps scoring consistent from one run to the next.
CREATE PROCEDURE sp_link_evidence(
  IN p_subject     VARCHAR(100),
  IN p_project_id  INT UNSIGNED,     -- NULL = global
  IN p_source_type VARCHAR(20),      -- memory | observation | session_note
  IN p_source_id   INT UNSIGNED,
  IN p_kind        VARCHAR(40),      -- a behaviour_evidence_kinds.kind
  IN p_weight      DECIMAL(3,2),     -- NULL = the anchor weight for p_kind
  IN p_stance      VARCHAR(10),      -- supports | opposes; NULL = supports
  IN p_occurred_at DATETIME,         -- NULL = taken from the source row
  IN p_event_key   VARCHAR(100),     -- NULL = one event per source row
  IN p_rationale   VARCHAR(500),
  IN p_run_id      VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_max     INT          DEFAULT 50;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_tol     DECIMAL(3,2) DEFAULT 0.05;
  DECLARE v_anchor  DECIMAL(3,2) DEFAULT NULL;
  DECLARE v_weight  DECIMAL(3,2) DEFAULT NULL;
  DECLARE v_stance  VARCHAR(10)  DEFAULT 'supports';
  DECLARE v_src_ok  INT          DEFAULT 0;
  DECLARE v_when    DATETIME     DEFAULT NULL;
  DECLARE v_key     VARCHAR(100) DEFAULT NULL;
  DECLARE v_bid     INT UNSIGNED DEFAULT NULL;
  DECLARE v_new_id  INT UNSIGNED DEFAULT NULL;
  DECLARE v_beh     INT          DEFAULT 0;

  SELECT CAST(cfg_value AS SIGNED)       INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_max     FROM consolidation_config WHERE cfg_key='max_behaviour_actions_per_run';
  SELECT CAST(cfg_value AS DECIMAL(3,2)) INTO v_tol     FROM consolidation_config WHERE cfg_key='behaviour_weight_tolerance';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_beh     FROM consolidation_config WHERE cfg_key='behaviours_enabled';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_beh = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','behaviours_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  SELECT anchor_weight INTO v_anchor FROM behaviour_evidence_kinds WHERE kind = p_kind;
  IF v_anchor IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',CONCAT('unknown evidence kind "', IFNULL(p_kind,'NULL'), '"'), v_dry);
    LEAVE proc;
  END IF;
  SET v_weight = IFNULL(p_weight, v_anchor);
  IF ABS(v_weight - v_anchor) > v_tol OR v_weight < 0 OR v_weight > 1 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',
        CONCAT('weight ', v_weight, ' is outside the ', p_kind, ' band ', v_anchor, ' +/- ', v_tol), v_dry);
    LEAVE proc;
  END IF;
  SET v_stance = IFNULL(p_stance, 'supports');
  IF v_stance NOT IN ('supports','opposes') THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',CONCAT('bad stance "', v_stance, '"'), v_dry);
    LEAVE proc;
  END IF;

  -- the source must exist and still be live; its own date is the default
  -- "when it happened" (an observation is dated by its latest sighting)
  IF p_source_type = 'memory' THEN
    SELECT 1, created_at INTO v_src_ok, v_when FROM memories WHERE id = p_source_id AND is_active = 1;
  ELSEIF p_source_type = 'observation' THEN
    SELECT 1, last_seen INTO v_src_ok, v_when FROM user_observations WHERE id = p_source_id AND is_active = 1;
  ELSEIF p_source_type = 'session_note' THEN
    SELECT 1, created_at INTO v_src_ok, v_when FROM session_notes WHERE id = p_source_id;
  END IF;
  IF v_src_ok = 0 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',
        CONCAT(IFNULL(p_source_type,'NULL'), ' ', IFNULL(p_source_id,'NULL'), ' not found, inactive, or not a valid source type'), v_dry);
    LEAVE proc;
  END IF;
  SET v_when = IFNULL(p_occurred_at, v_when);
  SET v_key  = IFNULL(NULLIF(TRIM(p_event_key), ''), CONCAT(p_source_type, ':', p_source_id));

  SELECT id INTO v_bid FROM behaviours
    WHERE subject = p_subject AND scope_project_id = IFNULL(p_project_id, 0);
  -- in a dry run the subject may exist only in this run's log, so carry on and log it
  IF v_bid IS NULL AND v_dry = 0 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',
        CONCAT('no behaviour "', IFNULL(p_subject,'NULL'), '"; call sp_upsert_behaviour first'), v_dry);
    LEAVE proc;
  END IF;

  IF v_bid IS NOT NULL AND EXISTS (
       SELECT 1 FROM behaviour_evidence
        WHERE behaviour_id = v_bid AND event_key = v_key
          AND source_type = p_source_type AND source_id = p_source_id) THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'link_skipped_duplicate','behaviours',v_bid,
        CONCAT(p_source_type,' ',p_source_id,' already linked as ',v_key), v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('upsert_behaviour','link_evidence','supersede_evidence','retire_behaviour');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','behaviours',v_bid,CONCAT('max_behaviour_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    INSERT INTO behaviour_evidence(behaviour_id,source_type,source_id,evidence_kind,weight,stance,occurred_at,event_key,rationale,run_id)
      VALUES(v_bid,p_source_type,p_source_id,p_kind,v_weight,v_stance,v_when,v_key,p_rationale,p_run_id);
    SET v_new_id = LAST_INSERT_ID();
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,after_json,reason,dry_run)
    VALUES(p_run_id,'link_evidence','behaviour_evidence',v_new_id,
      JSON_OBJECT('behaviour_id',v_bid,'subject',p_subject,'source_type',p_source_type,'source_id',p_source_id,
                  'kind',p_kind,'weight',v_weight,'stance',v_stance,'occurred_at',v_when,'event_key',v_key),
      p_rationale, v_dry);

  IF v_dry = 0 THEN
    CALL sp_resolve_behaviour(v_bid, p_run_id);
  END IF;
END //

-- Replace older evidence with a newer statement from {{USER_NAME}}. The old row is
-- kept and points at its replacement. Refused unless the replacement is at or
-- above the rule threshold and no older than what it replaces: an inference
-- can never override something {{USER_NAME}} said, it can only raise a conflict.
CREATE PROCEDURE sp_supersede_evidence(
  IN p_old_id INT UNSIGNED,
  IN p_new_id INT UNSIGNED,
  IN p_reason VARCHAR(500),
  IN p_run_id VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled  INT          DEFAULT 0;
  DECLARE v_dry      INT          DEFAULT 1;
  DECLARE v_max      INT          DEFAULT 50;
  DECLARE v_acted    INT          DEFAULT 0;
  DECLARE v_rule     DECIMAL(3,2) DEFAULT 0.75;
  DECLARE v_old_b    INT UNSIGNED DEFAULT NULL;
  DECLARE v_new_b    INT UNSIGNED DEFAULT NULL;
  DECLARE v_old_when DATETIME     DEFAULT NULL;
  DECLARE v_new_when DATETIME     DEFAULT NULL;
  DECLARE v_old_sup  INT UNSIGNED DEFAULT NULL;
  DECLARE v_new_sup  INT UNSIGNED DEFAULT NULL;
  DECLARE v_new_w    DECIMAL(3,2) DEFAULT NULL;
  DECLARE v_beh      INT          DEFAULT 0;

  SELECT CAST(cfg_value AS SIGNED)       INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_max     FROM consolidation_config WHERE cfg_key='max_behaviour_actions_per_run';
  SELECT CAST(cfg_value AS DECIMAL(3,2)) INTO v_rule    FROM consolidation_config WHERE cfg_key='behaviour_rule_threshold';
  SELECT CAST(cfg_value AS SIGNED)       INTO v_beh     FROM consolidation_config WHERE cfg_key='behaviours_enabled';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_beh = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','behaviours_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  SELECT behaviour_id, occurred_at, superseded_by INTO v_old_b, v_old_when, v_old_sup
    FROM behaviour_evidence WHERE id = p_old_id;
  SELECT behaviour_id, occurred_at, superseded_by, weight INTO v_new_b, v_new_when, v_new_sup, v_new_w
    FROM behaviour_evidence WHERE id = p_new_id;

  IF v_old_b IS NULL OR v_new_b IS NULL OR p_old_id = p_new_id OR v_old_b <> v_new_b THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',p_old_id,
        CONCAT('supersede ', IFNULL(p_old_id,'NULL'), ' by ', IFNULL(p_new_id,'NULL'),
               ': need two different existing evidence rows on the same behaviour'), v_dry);
    LEAVE proc;
  END IF;
  IF v_old_sup IS NOT NULL OR v_new_sup IS NOT NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_evidence',p_old_id,
        CONCAT('supersede ', p_old_id, ' by ', p_new_id, ': one of them is already superseded'), v_dry);
    LEAVE proc;
  END IF;
  IF v_new_w < v_rule OR v_new_when < v_old_when THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,reason,dry_run)
      VALUES(p_run_id,'supersede_refused','behaviour_evidence',p_old_id,
        JSON_OBJECT('old_id',p_old_id,'old_occurred_at',v_old_when,'new_id',p_new_id,
                    'new_occurred_at',v_new_when,'new_weight',v_new_w,'rule_threshold',v_rule),
        'only a newer statement from {{USER_NAME}} (at or above the rule threshold) can supersede; link it as opposing evidence instead',
        v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('upsert_behaviour','link_evidence','supersede_evidence','retire_behaviour');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','behaviour_evidence',p_old_id,CONCAT('max_behaviour_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    UPDATE behaviour_evidence SET superseded_by = p_new_id WHERE id = p_old_id;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'supersede_evidence','behaviour_evidence',p_old_id,
      JSON_OBJECT('superseded_by',NULL),
      JSON_OBJECT('superseded_by',p_new_id,'behaviour_id',v_old_b),
      p_reason, v_dry);

  IF v_dry = 0 THEN
    CALL sp_resolve_behaviour(v_old_b, p_run_id);
  END IF;
END //

-- Retire a behaviour that no longer applies at all (its subject is gone, not
-- merely changed: a change goes through sp_upsert_behaviour). Soft, revivable.
CREATE PROCEDURE sp_retire_behaviour(
  IN p_subject    VARCHAR(100),
  IN p_project_id INT UNSIGNED,
  IN p_reason     VARCHAR(500),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_max     INT          DEFAULT 50;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_id      INT UNSIGNED DEFAULT NULL;
  DECLARE v_status  VARCHAR(10)  DEFAULT NULL;
  DECLARE v_beh     INT          DEFAULT 0;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_behaviour_actions_per_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_beh     FROM consolidation_config WHERE cfg_key='behaviours_enabled';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_beh = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','behaviours_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  SELECT id, status INTO v_id, v_status FROM behaviours
    WHERE subject = p_subject AND scope_project_id = IFNULL(p_project_id, 0);
  IF v_id IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviours',CONCAT('no behaviour "', IFNULL(p_subject,'NULL'), '"'), v_dry);
    LEAVE proc;
  END IF;
  IF v_status = 'retired' THEN LEAVE proc; END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('upsert_behaviour','link_evidence','supersede_evidence','retire_behaviour');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','behaviours',v_id,CONCAT('max_behaviour_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    UPDATE behaviours SET status = 'retired', resolved_at = NOW(), resolved_run_id = p_run_id WHERE id = v_id;
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'retire_behaviour','behaviours',v_id,
      JSON_OBJECT('status',v_status), JSON_OBJECT('status','retired'), p_reason, v_dry);
END //

-- Record that the pass has finished with a source, whatever it decided
-- (including "bears on no behaviour"), so it leaves v_behaviour_worklist.
-- Bookkeeping, not counted against the cap. Refused once this run has hit the
-- cap: a link that never went in must leave its source queued for the next run.
CREATE PROCEDURE sp_mark_reviewed(
  IN p_source_type VARCHAR(20),      -- memory | observation | session_note
  IN p_source_id   INT UNSIGNED,
  IN p_outcome     VARCHAR(255),
  IN p_run_id      VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled  INT          DEFAULT 0;
  DECLARE v_dry      INT          DEFAULT 1;
  DECLARE v_beh      INT          DEFAULT 0;
  DECLARE v_prev_at  DATETIME     DEFAULT NULL;
  DECLARE v_prev_out VARCHAR(255) DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_beh     FROM consolidation_config WHERE cfg_key='behaviours_enabled';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_beh = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','behaviours_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  IF p_source_type IS NULL OR p_source_type NOT IN ('memory','observation','session_note') THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','behaviour_source_reviews',CONCAT('bad source type "', IFNULL(p_source_type,'NULL'), '"'), v_dry);
    LEAVE proc;
  END IF;

  IF EXISTS (SELECT 1 FROM consolidation_log
              WHERE run_id = p_run_id AND action = 'capped'
                AND target_table IN ('behaviours','behaviour_evidence')) THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'review_deferred_capped','behaviour_source_reviews',p_source_id,
        CONCAT(p_source_type,' ',p_source_id,' left queued: this run hit max_behaviour_actions_per_run'), v_dry);
    LEAVE proc;
  END IF;

  SELECT reviewed_at, outcome INTO v_prev_at, v_prev_out
    FROM behaviour_source_reviews WHERE source_type = p_source_type AND source_id = p_source_id;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'mark_reviewed','behaviour_source_reviews',p_source_id,
      IF(v_prev_at IS NULL, NULL, JSON_OBJECT('reviewed_at',v_prev_at,'outcome',v_prev_out)),
      JSON_OBJECT('source_type',p_source_type,'source_id',p_source_id,'outcome',p_outcome),
      p_outcome, v_dry);

  IF v_dry = 0 THEN
    INSERT INTO behaviour_source_reviews(source_type, source_id, reviewed_at, run_id, outcome)
      VALUES(p_source_type, p_source_id, NOW(), p_run_id, p_outcome)
      ON DUPLICATE KEY UPDATE reviewed_at = NOW(), run_id = p_run_id, outcome = p_outcome;
  END IF;
END //

DELIMITER ;
