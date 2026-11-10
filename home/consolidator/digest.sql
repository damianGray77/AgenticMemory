-- digest.sql -- the recent-work digest: an OptMem-style merge tree over sessions.
-- Tables live in claude_memory_schema.sql (digest_lines, digest_session_reviews).
-- This file holds the config rows, the views, the procedures the consolidation
-- pass writes through, and sp_digest_cover, which session boot calls.
--
-- THE TREE (one per project, plus one for sessions with no project):
--   * a LEAF (level 0) is one line for one finished session, numbered 0,1,2,...
--     per project in the order the pass writes them; leaves are append-only
--   * a BLOCK at level k rolls up the 2^k leaves from seq_lo (a multiple of 2^k)
--     into one line, written once both halves exist; blocks up to
--     digest_raw_max_level are summarised from their leaf lines, bigger ones
--     from their two halves (OptMem's RAW_MAX = 16)
--   * blocks are a cache: sp_digest_forget drops one and every block built on
--     it, and the next pass rebuilds them
-- THE BOOT VIEW (sp_digest_cover): sessions with notes that have no leaf yet,
-- shown as their raw note titles, then a cover of the tree that fits the line
-- budget. A block is kept whole when it is built and its size is at most
-- alpha x its age in leaves; alpha is binary-searched to fit, and spare lines go
-- to the newest blocks. A block that is not built yet is split, so boot never
-- waits on the pass.
--
-- Rails, as in judgment_procs.sql and behaviours.sql:
--   * honor enabled (kill switch) and dry_run (log-only) from consolidation_config
--   * honor digest_enabled, a switch for this layer alone: it stays 0 until the
--     supervised preview has been reviewed, so the unattended 3-hourly run cannot
--     start the backfill on its own
--   * cap real mutations per run at max_digest_actions_per_run
--   * log every action, with the row it wrote or dropped, to consolidation_log
-- Re-runnable: procedures are dropped and recreated, views replaced, and config
-- rows inserted with INSERT IGNORE so a tuned value survives a re-run.
--
-- Procedures: sp_digest_put_leaf, sp_digest_skip, sp_digest_put_block,
--             sp_digest_forget (all capped); sp_digest_cover and sp_digest_tile
--             (read-only, for boot).
--
-- TIME: sessions and notes are local time; transcripts are UTC. The views move
-- transcript times to local with the current UTC offset, so a time near a DST
-- change can be an hour out; nothing here needs better.
--
-- REVERTING A RUN: every mutation is in consolidation_log under its run_id.
--   digest_leaf / digest_block -> DELETE FROM digest_lines WHERE id = target_id
--                                 (leaves: only the newest of a project, or the
--                                 positions after it shift; revert newest first)
--   digest_leaf / digest_skip  -> also restore or DELETE the session's
--                                 digest_session_reviews row from before_json
--   digest_forget              -> re-INSERT the row in before_json, or let the
--                                 next pass rebuild it

USE {{DB_NAME}};

-- ---------- config rows ----------

INSERT IGNORE INTO consolidation_config (cfg_key, cfg_value, note) VALUES
  ('digest_enabled',             '0',   'Switch for the recent-work digest alone; 0 until the supervised preview is reviewed'),
  ('digest_boot_lines',          '16',  'Lines session boot prints for the digest; a no-project boot splits them between project heads and the no-project stream'),
  ('digest_line_chars',          '200', 'Longest digest line, in characters'),
  ('digest_quiet_hours',         '2',   'A session is digested once it has had no notes or transcript messages for this many hours'),
  ('digest_raw_max_level',       '4',   'Blocks up to this level (2^4 = 16 sessions) are summarised from leaf lines; bigger ones from their two halves'),
  ('max_digest_actions_per_run', '40',  'Per-run cap on digest mutations (leaf, skip, block, forget); separate from max_actions_per_run');

-- ---------- views ----------

CREATE OR REPLACE VIEW v_digest_config AS
SELECT
  MAX(CASE WHEN cfg_key = 'digest_boot_lines'    THEN CAST(cfg_value AS UNSIGNED) END) AS boot_lines,
  MAX(CASE WHEN cfg_key = 'digest_line_chars'    THEN CAST(cfg_value AS UNSIGNED) END) AS line_chars,
  MAX(CASE WHEN cfg_key = 'digest_quiet_hours'   THEN CAST(cfg_value AS UNSIGNED) END) AS quiet_hours,
  MAX(CASE WHEN cfg_key = 'digest_raw_max_level' THEN CAST(cfg_value AS UNSIGNED) END) AS raw_max_level
FROM consolidation_config;

-- Every session with notes, and when it was last active: its newest note or its
-- newest archived transcript message, whichever is later. Sessions without
-- notes are left out; in practice they are boot artifacts and probes.
-- note_titles holds the newest four titles, newest first: enough for a 200-char
-- line, and under GROUP_CONCAT's 1024-byte default, which strict mode turns into
-- an error inside INSERT ... SELECT.
CREATE OR REPLACE VIEW v_digest_sessions AS
SELECT s.id AS session_id, s.project_id, IFNULL(s.project_id, 0) AS scope_project_id, s.started_at,
       n.note_count, n.note_titles,
       GREATEST(s.started_at, n.last_note_at, IFNULL(tx.last_message_at, s.started_at)) AS last_activity_at,
       r.reviewed_until
FROM sessions s
JOIN (SELECT session_id, COUNT(*) AS note_count, MAX(created_at) AS last_note_at,
             GROUP_CONCAT(IF(newest <= 4, title, NULL) ORDER BY id DESC SEPARATOR ' | ') AS note_titles
      FROM (SELECT session_id, id, title, created_at,
                   ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY id DESC) AS newest
            FROM session_notes) sn
      GROUP BY session_id) n ON n.session_id = s.id
LEFT JOIN (SELECT session_uuid,
                  MAX(last_message_at) + INTERVAL TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), NOW()) SECOND AS last_message_at
           FROM transcripts WHERE kind = 'main' GROUP BY session_uuid) tx ON tx.session_uuid = s.session_uuid
LEFT JOIN digest_session_reviews r ON r.session_id = s.id;

-- Sessions with work the digest has not covered yet: never read, or active
-- again since. is_quiet marks the ones the pass may digest now; boot shows all
-- of them. reviewed_until_utc is for filtering transcript messages (UTC) on a
-- resumed session.
CREATE OR REPLACE VIEW v_digest_session_worklist AS
SELECT d.session_id, d.project_id, d.scope_project_id, p.slug AS project, d.started_at,
       d.last_activity_at, d.note_count, d.note_titles, d.reviewed_until,
       d.reviewed_until - INTERVAL TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), NOW()) SECOND AS reviewed_until_utc,
       d.last_activity_at <= NOW() - INTERVAL c.quiet_hours HOUR AS is_quiet
FROM v_digest_sessions d
LEFT JOIN projects p ON p.id = d.project_id
CROSS JOIN v_digest_config c
WHERE d.reviewed_until IS NULL OR d.last_activity_at > d.reviewed_until;

-- Blocks ready to write (both halves exist, the block does not), one row per
-- input line: the block's leaves up to raw_max_level, its two halves above it.
CREATE OR REPLACE VIEW v_digest_pending AS
SELECT b.project_id, pr.slug AS project, b.block_level, b.block_seq_lo,
       b.block_seq_lo + (1 << b.block_level) - 1 AS block_seq_hi,
       i.level AS input_level, i.seq_lo AS input_seq_lo,
       i.first_session_id, i.last_session_id, i.first_at, i.last_at, i.line AS input_line
FROM (SELECT a.project_id, a.scope_project_id, a.level + 1 AS block_level, a.seq_lo AS block_seq_lo
      FROM digest_lines a
      JOIN digest_lines h ON h.scope_project_id = a.scope_project_id AND h.level = a.level
                         AND h.seq_lo = a.seq_lo + (1 << a.level)
      WHERE a.seq_lo % (1 << (a.level + 1)) = 0
        AND NOT EXISTS (SELECT 1 FROM digest_lines x
                         WHERE x.scope_project_id = a.scope_project_id
                           AND x.level = a.level + 1 AND x.seq_lo = a.seq_lo)) b
CROSS JOIN v_digest_config c
JOIN digest_lines i ON i.scope_project_id = b.scope_project_id
 AND (   (b.block_level <= c.raw_max_level AND i.level = 0
          AND i.seq_lo BETWEEN b.block_seq_lo AND b.block_seq_lo + (1 << b.block_level) - 1)
      OR (b.block_level >  c.raw_max_level AND i.level = b.block_level - 1
          AND i.seq_lo IN (b.block_seq_lo, b.block_seq_lo + (1 << (b.block_level - 1)))))
LEFT JOIN projects pr ON pr.id = b.project_id;

-- What a no-project boot lists first: each project's newest work, either its
-- newest session not digested yet (raw note titles) or its newest leaf.
CREATE OR REPLACE VIEW v_digest_project_heads AS
SELECT CONCAT(h.project, '  S', h.session_id, ' ',
              IF(YEAR(h.at) = YEAR(CURDATE()), DATE_FORMAT(h.at, '%b %e'), DATE_FORMAT(h.at, '%b %e %Y')),
              '  ', h.line) AS display,
       h.project, h.at
FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.project ORDER BY x.at DESC, x.session_id DESC) AS rn
      FROM (SELECT w.project, w.session_id, w.last_activity_at AS at,
                   CONCAT('(not digested yet) ', LEFT(w.note_titles, 200)) AS line
            FROM v_digest_session_worklist w WHERE w.project_id IS NOT NULL
            UNION ALL
            SELECT p.slug, l.session_id, l.last_at, l.line
            FROM digest_lines l JOIN projects p ON p.id = l.project_id
            WHERE l.level = 0) x) h
WHERE h.rn = 1
ORDER BY h.at DESC;

-- ---------- procedures ----------

DROP PROCEDURE IF EXISTS sp_digest_put_leaf;
DROP PROCEDURE IF EXISTS sp_digest_skip;
DROP PROCEDURE IF EXISTS sp_digest_put_block;
DROP PROCEDURE IF EXISTS sp_digest_forget;
DROP PROCEDURE IF EXISTS sp_digest_tile;
DROP PROCEDURE IF EXISTS sp_digest_cover;

DELIMITER //

-- Write one session's line as the next leaf of its project. A session that was
-- resumed after its first leaf gets a second leaf for the new work.
CREATE PROCEDURE sp_digest_put_leaf(
  IN p_session_id INT UNSIGNED,
  IN p_line       VARCHAR(255),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled  INT          DEFAULT 0;
  DECLARE v_dry      INT          DEFAULT 1;
  DECLARE v_digest   INT          DEFAULT 0;
  DECLARE v_max      INT          DEFAULT 40;
  DECLARE v_chars    INT          DEFAULT 200;
  DECLARE v_acted    INT          DEFAULT 0;
  DECLARE v_project  INT UNSIGNED DEFAULT NULL;
  DECLARE v_started  DATETIME     DEFAULT NULL;
  DECLARE v_until    DATETIME     DEFAULT NULL;
  DECLARE v_reviewed DATETIME     DEFAULT NULL;
  DECLARE v_outcome  VARCHAR(255) DEFAULT NULL;
  DECLARE v_seq      INT UNSIGNED DEFAULT NULL;
  DECLARE v_id       INT UNSIGNED DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_digest  FROM consolidation_config WHERE cfg_key='digest_enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_digest_actions_per_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_chars   FROM consolidation_config WHERE cfg_key='digest_line_chars';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_digest = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','digest_enabled=0',v_dry);
    LEAVE proc;
  END IF;
  IF p_line IS NULL OR TRIM(p_line) = '' OR p_line REGEXP '[\r\n]' OR CHAR_LENGTH(p_line) > v_chars THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',p_session_id,
        CONCAT('bad line for session ', p_session_id, ': want one line of 1-', v_chars, ' characters, got ',
               IFNULL(CHAR_LENGTH(p_line), 0)), v_dry);
    LEAVE proc;
  END IF;

  SELECT project_id, started_at, last_activity_at, reviewed_until
    INTO v_project, v_started, v_until, v_reviewed
    FROM v_digest_sessions WHERE session_id = p_session_id;
  IF v_started IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',p_session_id,'no such session, or it has no notes',v_dry);
    LEAVE proc;
  END IF;
  IF v_reviewed IS NOT NULL AND v_until <= v_reviewed THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',p_session_id,
        CONCAT('session already covered up to ', v_reviewed),v_dry);
    LEAVE proc;
  END IF;
  SELECT outcome INTO v_outcome FROM digest_session_reviews WHERE session_id = p_session_id;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('digest_leaf','digest_skip','digest_block','digest_forget');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','digest_lines',p_session_id,CONCAT('max_digest_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    -- next position; the unique key refuses a second writer that read the same MAX
    SELECT COALESCE(MAX(seq_lo) + 1, 0) INTO v_seq FROM digest_lines
      WHERE scope_project_id = IFNULL(v_project, 0) AND level = 0;
    INSERT INTO digest_lines(project_id, level, seq_lo, session_id, first_session_id, last_session_id,
                             session_count, first_at, last_at, line, run_id)
      VALUES(v_project, 0, v_seq, p_session_id, p_session_id, p_session_id,
             1, IFNULL(v_reviewed, v_started), v_until, p_line, p_run_id);
    SET v_id = LAST_INSERT_ID();
    INSERT INTO digest_session_reviews(session_id, reviewed_until, outcome, run_id)
      VALUES(p_session_id, v_until, CONCAT('leaf ', v_seq), p_run_id)
      ON DUPLICATE KEY UPDATE reviewed_until = VALUES(reviewed_until), outcome = VALUES(outcome), run_id = VALUES(run_id);
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'digest_leaf','digest_lines',v_id,
      IF(v_reviewed IS NULL, NULL, JSON_OBJECT('session_id',p_session_id,'reviewed_until',v_reviewed,'outcome',v_outcome)),
      JSON_OBJECT('session_id',p_session_id,'project_id',v_project,'seq_lo',v_seq,'reviewed_until',v_until,'line',p_line),
      NULL, v_dry);
END //

-- Mark a session read without a leaf: nothing of lasting effect happened (a
-- probe, a test boot, a question with no outcome, a resume that changed nothing).
CREATE PROCEDURE sp_digest_skip(
  IN p_session_id INT UNSIGNED,
  IN p_reason     VARCHAR(200),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled  INT          DEFAULT 0;
  DECLARE v_dry      INT          DEFAULT 1;
  DECLARE v_digest   INT          DEFAULT 0;
  DECLARE v_max      INT          DEFAULT 40;
  DECLARE v_acted    INT          DEFAULT 0;
  DECLARE v_started  DATETIME     DEFAULT NULL;
  DECLARE v_until    DATETIME     DEFAULT NULL;
  DECLARE v_reviewed DATETIME     DEFAULT NULL;
  DECLARE v_outcome  VARCHAR(255) DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_digest  FROM consolidation_config WHERE cfg_key='digest_enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_digest_actions_per_run';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_digest = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','digest_enabled=0',v_dry);
    LEAVE proc;
  END IF;

  SELECT started_at, last_activity_at, reviewed_until INTO v_started, v_until, v_reviewed
    FROM v_digest_sessions WHERE session_id = p_session_id;
  IF v_started IS NULL THEN
    INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
      VALUES(p_run_id,'error','digest_session_reviews',p_session_id,'no such session, or it has no notes',v_dry);
    LEAVE proc;
  END IF;
  SELECT outcome INTO v_outcome FROM digest_session_reviews WHERE session_id = p_session_id;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('digest_leaf','digest_skip','digest_block','digest_forget');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,target_id,reason,dry_run)
        VALUES(p_run_id,'capped','digest_session_reviews',p_session_id,CONCAT('max_digest_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    INSERT INTO digest_session_reviews(session_id, reviewed_until, outcome, run_id)
      VALUES(p_session_id, v_until, CONCAT('skipped: ', IFNULL(p_reason, '')), p_run_id)
      ON DUPLICATE KEY UPDATE reviewed_until = VALUES(reviewed_until), outcome = VALUES(outcome), run_id = VALUES(run_id);
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,after_json,reason,dry_run)
    VALUES(p_run_id,'digest_skip','digest_session_reviews',p_session_id,
      IF(v_reviewed IS NULL, NULL, JSON_OBJECT('session_id',p_session_id,'reviewed_until',v_reviewed,'outcome',v_outcome)),
      JSON_OBJECT('session_id',p_session_id,'reviewed_until',v_until),
      p_reason, v_dry);
END //

-- Write the rolled-up line for block (level, seq_lo) once both halves exist.
CREATE PROCEDURE sp_digest_put_block(
  IN p_project_id INT UNSIGNED,      -- NULL = the no-project stream
  IN p_level      TINYINT UNSIGNED,
  IN p_seq_lo     INT UNSIGNED,
  IN p_line       VARCHAR(255),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_digest  INT          DEFAULT 0;
  DECLARE v_max     INT          DEFAULT 40;
  DECLARE v_chars   INT          DEFAULT 200;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_scope   INT UNSIGNED DEFAULT IFNULL(p_project_id, 0);
  DECLARE v_halves  INT          DEFAULT 0;
  DECLARE v_id      INT UNSIGNED DEFAULT NULL;

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_digest  FROM consolidation_config WHERE cfg_key='digest_enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_digest_actions_per_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_chars   FROM consolidation_config WHERE cfg_key='digest_line_chars';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_digest = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','digest_enabled=0',v_dry);
    LEAVE proc;
  END IF;
  IF p_line IS NULL OR TRIM(p_line) = '' OR p_line REGEXP '[\r\n]' OR CHAR_LENGTH(p_line) > v_chars THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',
        CONCAT('bad line for block ', v_scope, '/', p_level, '/', p_seq_lo, ': want one line of 1-', v_chars,
               ' characters, got ', IFNULL(CHAR_LENGTH(p_line), 0)), v_dry);
    LEAVE proc;
  END IF;
  IF p_level < 1 OR p_seq_lo % (1 << p_level) <> 0 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',
        CONCAT('not a block: level ', p_level, ' at ', p_seq_lo, ' (want level >= 1, seq_lo a multiple of 2^level)'), v_dry);
    LEAVE proc;
  END IF;
  IF EXISTS (SELECT 1 FROM digest_lines WHERE scope_project_id = v_scope AND level = p_level AND seq_lo = p_seq_lo) THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',CONCAT('block ', v_scope, '/', p_level, '/', p_seq_lo, ' already exists'), v_dry);
    LEAVE proc;
  END IF;
  SELECT COUNT(*) INTO v_halves FROM digest_lines
    WHERE scope_project_id = v_scope AND level = p_level - 1
      AND seq_lo IN (p_seq_lo, p_seq_lo + (1 << (p_level - 1)));
  IF v_halves < 2 THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',CONCAT('block ', v_scope, '/', p_level, '/', p_seq_lo, ' is not ready: a half is missing'), v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('digest_leaf','digest_skip','digest_block','digest_forget');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
        VALUES(p_run_id,'capped','digest_lines',CONCAT('max_digest_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
    INSERT INTO digest_lines(project_id, level, seq_lo, session_id, first_session_id, last_session_id,
                             session_count, first_at, last_at, line, run_id)
      SELECT p_project_id, p_level, p_seq_lo, NULL, MIN(session_id), MAX(session_id),
             COUNT(DISTINCT session_id), MIN(first_at), MAX(last_at), p_line, p_run_id
      FROM digest_lines
      WHERE scope_project_id = v_scope AND level = 0
        AND seq_lo BETWEEN p_seq_lo AND p_seq_lo + (1 << p_level) - 1;
    SET v_id = LAST_INSERT_ID();
  END IF;

  INSERT INTO consolidation_log(run_id,action,target_table,target_id,after_json,reason,dry_run)
    VALUES(p_run_id,'digest_block','digest_lines',v_id,
      JSON_OBJECT('project_id',p_project_id,'level',p_level,'seq_lo',p_seq_lo,'line',p_line),
      NULL, v_dry);
END //

-- Drop a bad block and every block built on it; the next pass rebuilds them.
-- Leaves are the record and are never dropped.
CREATE PROCEDURE sp_digest_forget(
  IN p_project_id INT UNSIGNED,      -- NULL = the no-project stream
  IN p_level      TINYINT UNSIGNED,
  IN p_seq_lo     INT UNSIGNED,
  IN p_reason     VARCHAR(500),
  IN p_run_id     VARCHAR(40)
)
proc: BEGIN
  DECLARE v_enabled INT          DEFAULT 0;
  DECLARE v_dry     INT          DEFAULT 1;
  DECLARE v_digest  INT          DEFAULT 0;
  DECLARE v_max     INT          DEFAULT 40;
  DECLARE v_acted   INT          DEFAULT 0;
  DECLARE v_scope   INT UNSIGNED DEFAULT IFNULL(p_project_id, 0);

  SELECT CAST(cfg_value AS SIGNED) INTO v_enabled FROM consolidation_config WHERE cfg_key='enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_dry     FROM consolidation_config WHERE cfg_key='dry_run';
  SELECT CAST(cfg_value AS SIGNED) INTO v_digest  FROM consolidation_config WHERE cfg_key='digest_enabled';
  SELECT CAST(cfg_value AS SIGNED) INTO v_max     FROM consolidation_config WHERE cfg_key='max_digest_actions_per_run';

  IF v_enabled = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','enabled=0 (kill switch)',v_dry);
    LEAVE proc;
  END IF;
  IF v_digest = 0 THEN
    INSERT INTO consolidation_log(run_id,action,reason,dry_run) VALUES(p_run_id,'skipped','digest_enabled=0',v_dry);
    LEAVE proc;
  END IF;
  IF p_level < 1 OR NOT EXISTS (SELECT 1 FROM digest_lines
                                 WHERE scope_project_id = v_scope AND level = p_level AND seq_lo = p_seq_lo) THEN
    INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
      VALUES(p_run_id,'error','digest_lines',CONCAT('no block ', v_scope, '/', p_level, '/', p_seq_lo, ' (leaves cannot be forgotten)'), v_dry);
    LEAVE proc;
  END IF;

  IF v_dry = 0 THEN
    SELECT COUNT(*) INTO v_acted FROM consolidation_log
      WHERE run_id = p_run_id AND dry_run = 0
        AND action IN ('digest_leaf','digest_skip','digest_block','digest_forget');
    IF v_acted >= v_max THEN
      INSERT INTO consolidation_log(run_id,action,target_table,reason,dry_run)
        VALUES(p_run_id,'capped','digest_lines',CONCAT('max_digest_actions_per_run=',v_max,' reached'),0);
      LEAVE proc;
    END IF;
  END IF;

  -- the block, and each block above it: the one at every higher level that contains p_seq_lo
  INSERT INTO consolidation_log(run_id,action,target_table,target_id,before_json,reason,dry_run)
    SELECT p_run_id, 'digest_forget', 'digest_lines', id,
           JSON_OBJECT('project_id',project_id,'level',level,'seq_lo',seq_lo,'line',line),
           p_reason, v_dry
    FROM digest_lines
    WHERE scope_project_id = v_scope AND level >= p_level AND seq_lo = p_seq_lo - (p_seq_lo % (1 << level));
  IF v_dry = 0 THEN
    DELETE FROM digest_lines
      WHERE scope_project_id = v_scope AND level >= p_level AND seq_lo = p_seq_lo - (p_seq_lo % (1 << level));
  END IF;
END //

-- Tile leaves [0, p_t) of one tree into tmp_digest_cover, oldest first: at each
-- position, the largest aligned block that is built, ends inside the tree, and
-- is at most p_alpha times its age (in leaves); a leaf when nothing larger fits.
-- This is OptMem's cover rule, walked left to right instead of top down.
CREATE PROCEDURE sp_digest_tile(
  IN p_scope INT UNSIGNED,
  IN p_t     INT UNSIGNED,
  IN p_alpha DOUBLE
)
BEGIN
  DECLARE v_root_level INT          DEFAULT 0;
  DECLARE v_pos        INT UNSIGNED DEFAULT 0;
  DECLARE v_level      INT          DEFAULT 0;

  DELETE FROM tmp_digest_cover;
  WHILE (1 << v_root_level) < p_t DO
    SET v_root_level = v_root_level + 1;
  END WHILE;
  WHILE v_pos < p_t DO
    -- the largest alignment v_pos allows
    SET v_level = 0;
    IF v_pos = 0 THEN
      SET v_level = v_root_level;
    ELSE
      WHILE v_pos % (1 << (v_level + 1)) = 0 DO
        SET v_level = v_level + 1;
      END WHILE;
    END IF;
    WHILE v_level > 0
      AND NOT (v_pos + (1 << v_level) <= p_t
               AND (1 << v_level) <= p_alpha * (p_t - v_pos)
               AND EXISTS (SELECT 1 FROM digest_lines
                            WHERE scope_project_id = p_scope AND level = v_level AND seq_lo = v_pos)) DO
      SET v_level = v_level - 1;
    END WHILE;
    INSERT INTO tmp_digest_cover(seq_lo, level) VALUES(v_pos, v_level);
    SET v_pos = v_pos + (1 << v_level);
  END WHILE;
END //

-- What session boot prints for one tree (p_project_id NULL = the no-project
-- stream), newest first, in at most p_lines lines: sessions not digested yet
-- (up to half the budget, as raw note titles), then the cover of the tree.
CREATE PROCEDURE sp_digest_cover(
  IN p_project_id INT UNSIGNED,
  IN p_lines      INT UNSIGNED
)
BEGIN
  DECLARE v_scope   INT UNSIGNED DEFAULT IFNULL(p_project_id, 0);
  DECLARE v_waiting INT          DEFAULT 0;
  DECLARE v_shown   INT          DEFAULT 0;
  DECLARE v_budget  INT          DEFAULT 0;
  DECLARE v_t       INT UNSIGNED DEFAULT 0;
  DECLARE v_lo      DOUBLE       DEFAULT 0;
  DECLARE v_hi      DOUBLE       DEFAULT 1;
  DECLARE v_mid     DOUBLE       DEFAULT 0;
  DECLARE v_i       INT          DEFAULT 0;
  DECLARE v_split   INT UNSIGNED DEFAULT NULL;
  DECLARE v_level   INT          DEFAULT 0;
  DECLARE v_n       INT          DEFAULT 0;
  DECLARE v_blocks  INT          DEFAULT 0;

  DROP TEMPORARY TABLE IF EXISTS tmp_digest_cover;
  DROP TEMPORARY TABLE IF EXISTS tmp_digest_out;
  CREATE TEMPORARY TABLE tmp_digest_cover (seq_lo INT UNSIGNED NOT NULL PRIMARY KEY, level INT NOT NULL);
  CREATE TEMPORARY TABLE tmp_digest_out (grp INT NOT NULL, sort_key BIGINT NOT NULL, display TEXT NOT NULL);

  SELECT COUNT(*) INTO v_waiting FROM v_digest_session_worklist WHERE scope_project_id = v_scope;
  SET v_shown = LEAST(v_waiting, p_lines DIV 2);
  INSERT INTO tmp_digest_out(grp, sort_key, display)
    SELECT 0, UNIX_TIMESTAMP(w.last_activity_at),
           CONCAT('S', w.session_id, ' ',
                  IF(YEAR(w.started_at) = YEAR(CURDATE()), DATE_FORMAT(w.started_at, '%b %e'), DATE_FORMAT(w.started_at, '%b %e %Y')),
                  '  (not digested yet) ', LEFT(w.note_titles, 200))
    FROM v_digest_session_worklist w
    WHERE w.scope_project_id = v_scope
    ORDER BY w.last_activity_at DESC
    LIMIT v_shown;
  IF v_waiting > v_shown THEN
    INSERT INTO tmp_digest_out(grp, sort_key, display)
      VALUES(1, 0, CONCAT('... and ', v_waiting - v_shown, ' older sessions not digested yet'));
    SET v_shown = v_shown + 1;
  END IF;

  SET v_budget = CAST(p_lines AS SIGNED) - v_shown;
  SELECT COUNT(*) INTO v_t FROM digest_lines WHERE scope_project_id = v_scope AND level = 0;
  IF v_t > 0 AND v_budget > 0 THEN
    IF v_t <= v_budget THEN
      CALL sp_digest_tile(v_scope, v_t, 0);
    ELSE
      -- the smallest alpha whose cover fits the budget
      WHILE v_i < 24 DO
        SET v_mid = (v_lo + v_hi) / 2;
        CALL sp_digest_tile(v_scope, v_t, v_mid);
        SELECT COUNT(*) INTO v_n FROM tmp_digest_cover;
        IF v_n > v_budget THEN
          SET v_lo = v_mid;
        ELSE
          SET v_hi = v_mid;
        END IF;
        SET v_i = v_i + 1;
      END WHILE;
      CALL sp_digest_tile(v_scope, v_t, v_hi);
      -- block sizes jump in powers of two, so spend what is left on the newest
      -- blocks; their halves are always built, since a block is built from them.
      -- (Counted into variables: MySQL cannot open a temporary table twice in
      -- one statement.)
      SELECT COUNT(*), IFNULL(SUM(level > 0), 0) INTO v_n, v_blocks FROM tmp_digest_cover;
      WHILE v_n < v_budget AND v_blocks > 0 DO
        SELECT seq_lo, level INTO v_split, v_level FROM tmp_digest_cover
          WHERE level > 0 ORDER BY seq_lo DESC LIMIT 1;
        UPDATE tmp_digest_cover SET level = v_level - 1 WHERE seq_lo = v_split;
        INSERT INTO tmp_digest_cover(seq_lo, level) VALUES(v_split + (1 << (v_level - 1)), v_level - 1);
        SELECT COUNT(*), IFNULL(SUM(level > 0), 0) INTO v_n, v_blocks FROM tmp_digest_cover;
      END WHILE;
    END IF;

    INSERT INTO tmp_digest_out(grp, sort_key, display)
      SELECT 2, c.seq_lo,
             IF(l.level = 0,
                CONCAT('S', l.session_id, ' ',
                       IF(YEAR(l.first_at) = YEAR(CURDATE()), DATE_FORMAT(l.first_at, '%b %e'), DATE_FORMAT(l.first_at, '%b %e %Y')),
                       '  ', l.line),
                CONCAT('[', l.seq_lo, '-', l.seq_lo + (1 << l.level) - 1, '] S', l.first_session_id, '-S', l.last_session_id, ' ',
                       IF(YEAR(l.first_at) = YEAR(CURDATE()), DATE_FORMAT(l.first_at, '%b %e'), DATE_FORMAT(l.first_at, '%b %e %Y')),
                       ' to ',
                       IF(YEAR(l.last_at) = YEAR(CURDATE()), DATE_FORMAT(l.last_at, '%b %e'), DATE_FORMAT(l.last_at, '%b %e %Y')),
                       ' (', l.session_count, ' sessions)  ', l.line))
      FROM tmp_digest_cover c
      JOIN digest_lines l ON l.scope_project_id = v_scope AND l.level = c.level AND l.seq_lo = c.seq_lo;
  END IF;

  SELECT display FROM tmp_digest_out ORDER BY grp, sort_key DESC;
  DROP TEMPORARY TABLE tmp_digest_cover;
  DROP TEMPORARY TABLE tmp_digest_out;
END //

DELIMITER ;

-- ---------- reference query ----------

INSERT INTO reference_queries (name, description, sql_template) VALUES
  ('digest-zoom',
   'Open a recent-work digest block [lo-hi] from session boot into its two halves (project slug, or NULL project for the no-project stream)',
   'SELECT l.level, l.seq_lo, l.first_session_id, l.last_session_id, l.first_at, l.last_at, l.line\nFROM digest_lines l\nWHERE l.scope_project_id = IFNULL((SELECT id FROM projects WHERE slug = ''<slug>''), 0)\n  AND l.level = LOG2(<hi> - <lo> + 1) - 1\n  AND l.seq_lo IN (<lo>, <lo> + (<hi> - <lo> + 1) DIV 2)\nORDER BY l.seq_lo;')
ON DUPLICATE KEY UPDATE description = VALUES(description), sql_template = VALUES(sql_template);
