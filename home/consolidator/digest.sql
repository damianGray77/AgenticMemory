-- digest.sql -- the recent-work digest: an OptMem-style merge tree over sessions.
-- SQLite edition; run it through memdb (the views call memdb's now(), curdate(),
-- to_local(), to_utc() and date_format()).
-- Tables live in claude_memory_schema.sql (digest_lines, digest_session_reviews).
-- This file holds the config rows, the views and an index they need. The procedures
-- the consolidation pass writes through, and sp_digest_cover, which session boot
-- calls, are built into memdb.exe (memdb\src\Procs.Digest.cs) and run with CALL as before.
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
--   * honor digest_enabled, a switch for this layer alone. db/seed.sql (applied
--     first) turns it on; the '0' below only applies where the seed did not run,
--     so adding the digest to an existing history does not start a backfill until
--     a supervised preview has been reviewed
--   * cap real mutations per run at max_digest_actions_per_run
--   * log every action, with the row it wrote or dropped, to consolidation_log
--   * a bad call is logged, not raised: action 'error' (a line that is empty, has a
--     line break or is over digest_line_chars; an unknown session; a block that is
--     not aligned, exists already or is missing a half) or 'capped', and the CALL
--     succeeds. An argument that does not fit its parameter (a negative id, a line
--     over 255 characters, a run_id over 40), or a rail in consolidation_config that
--     is not a whole number, fails the CALL and writes nothing.
-- Re-runnable: views are dropped and recreated, the index is IF NOT EXISTS, and
-- config rows are inserted with INSERT OR IGNORE so a tuned value survives a re-run.
--
-- Procedures: sp_digest_put_leaf, sp_digest_skip, sp_digest_put_block,
--             sp_digest_forget (all capped); sp_digest_cover and sp_digest_tile
--             (read-only, for boot; sp_digest_tile fills a temp table
--             tmp_digest_cover(seq_lo, level) that its caller must have created).
--
-- TIME: sessions and notes are local time; transcripts are UTC. The views move
-- transcript times to local with to_local(), and reviewed_until back to UTC with
-- to_utc(), each with the offset in force at that moment (DST included). Only a
-- time inside the repeated hour of a DST fall-back is ambiguous.
--
-- REVERTING A RUN: every mutation is in consolidation_log under its run_id.
--   digest_leaf / digest_block -> DELETE FROM digest_lines WHERE id = target_id
--                                 (leaves: only the newest of a project, or the
--                                 positions after it shift; revert newest first)
--   digest_leaf / digest_skip  -> also restore or DELETE the session's
--                                 digest_session_reviews row from before_json
--   digest_forget              -> re-INSERT the row in before_json, or let the
--                                 next pass rebuild it

-- ---------- config rows ----------

INSERT OR IGNORE INTO consolidation_config (cfg_key, cfg_value, note) VALUES
  ('digest_enabled',             '0',   'Switch for the recent-work digest alone; 0 until the supervised preview is reviewed'),
  ('digest_boot_lines',          '16',  'Lines session boot prints for the digest; a no-project boot splits them between project heads and the no-project stream'),
  ('digest_line_chars',          '200', 'Longest digest line, in characters'),
  ('digest_quiet_hours',         '2',   'A session is digested once it has had no notes or transcript messages for this many hours'),
  ('digest_raw_max_level',       '4',   'Blocks up to this level (2^4 = 16 sessions) are summarised from leaf lines; bigger ones from their two halves'),
  ('max_digest_actions_per_run', '40',  'Per-run cap on digest mutations (leaf, skip, block, forget); separate from max_actions_per_run');

-- ---------- index ----------

-- v_digest_sessions needs each session's newest main-transcript time. last_message_at
-- sits after raw_jsonl in the transcripts row, so reading it from the table walks the
-- overflow pages of every compressed transcript; from this index the per-session MAX
-- is read without touching the table.
CREATE INDEX IF NOT EXISTS ix_transcript_digest ON transcripts (kind, session_uuid, last_message_at);

-- ---------- views ----------

DROP VIEW IF EXISTS v_digest_config;
CREATE VIEW v_digest_config AS
SELECT
  MAX(CASE WHEN cfg_key = 'digest_boot_lines'    THEN CAST(cfg_value AS INTEGER) END) AS boot_lines,
  MAX(CASE WHEN cfg_key = 'digest_line_chars'    THEN CAST(cfg_value AS INTEGER) END) AS line_chars,
  MAX(CASE WHEN cfg_key = 'digest_quiet_hours'   THEN CAST(cfg_value AS INTEGER) END) AS quiet_hours,
  MAX(CASE WHEN cfg_key = 'digest_raw_max_level' THEN CAST(cfg_value AS INTEGER) END) AS raw_max_level
FROM consolidation_config;

-- Every session with notes, and when it was last active: its newest note or its
-- newest archived transcript message, whichever is later. Sessions without
-- notes are left out; in practice they are boot artifacts and probes.
-- note_titles holds the newest four titles, newest first: enough for a 200-char line.
DROP VIEW IF EXISTS v_digest_sessions;
CREATE VIEW v_digest_sessions AS
SELECT s.id AS session_id, s.project_id, IFNULL(s.project_id, 0) AS scope_project_id, s.started_at,
       n.note_count, n.note_titles,
       max(s.started_at, n.last_note_at, IFNULL(tx.last_message_at, s.started_at)) AS last_activity_at,
       r.reviewed_until
FROM sessions s
JOIN (SELECT session_id, COUNT(*) AS note_count, MAX(created_at) AS last_note_at,
             group_concat(iif(newest <= 4, title, NULL), ' | ' ORDER BY id DESC) AS note_titles
      FROM (SELECT session_id, id, title, created_at,
                   ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY id DESC) AS newest
            FROM session_notes) sn
      GROUP BY session_id) n ON n.session_id = s.id
LEFT JOIN (SELECT session_uuid, to_local(MAX(last_message_at)) AS last_message_at
           FROM transcripts WHERE kind = 'main' GROUP BY session_uuid) tx ON tx.session_uuid = s.session_uuid
LEFT JOIN digest_session_reviews r ON r.session_id = s.id;

-- Sessions with work the digest has not covered yet: never read, or active
-- again since. is_quiet marks the ones the pass may digest now; boot shows all
-- of them. reviewed_until_utc is for filtering transcript messages (UTC) on a
-- resumed session.
DROP VIEW IF EXISTS v_digest_session_worklist;
CREATE VIEW v_digest_session_worklist AS
SELECT d.session_id, d.project_id, d.scope_project_id, p.slug AS project, d.started_at,
       d.last_activity_at, d.note_count, d.note_titles, d.reviewed_until,
       to_utc(d.reviewed_until) AS reviewed_until_utc,
       d.last_activity_at <= datetime(now(), '-' || c.quiet_hours || ' hours') AS is_quiet
FROM v_digest_sessions d
LEFT JOIN projects p ON p.id = d.project_id
CROSS JOIN v_digest_config c
WHERE d.reviewed_until IS NULL OR d.last_activity_at > d.reviewed_until;

-- Blocks ready to write (both halves exist, the block does not), one row per
-- input line: the block's leaves up to raw_max_level, its two halves above it.
DROP VIEW IF EXISTS v_digest_pending;
CREATE VIEW v_digest_pending AS
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
-- Dates read 'Nov 3' this year and 'Nov 3 2025' before it, as sp_digest_cover prints them.
DROP VIEW IF EXISTS v_digest_project_heads;
CREATE VIEW v_digest_project_heads AS
SELECT h.project || '  S' || h.session_id || ' ' ||
       iif(strftime('%Y', h.at) = strftime('%Y', curdate()), date_format(h.at, '%b %e'), date_format(h.at, '%b %e %Y')) ||
       '  ' || h.line AS display,
       h.project, h.at
FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.project ORDER BY x.at DESC, x.session_id DESC) AS rn
      FROM (SELECT w.project, w.session_id, w.last_activity_at AS at,
                   '(not digested yet) ' || substr(w.note_titles, 1, 200) AS line
            FROM v_digest_session_worklist w WHERE w.project_id IS NOT NULL
            UNION ALL
            SELECT p.slug, l.session_id, l.last_at, l.line
            FROM digest_lines l JOIN projects p ON p.id = l.project_id
            WHERE l.level = 0) x) h
WHERE h.rn = 1
ORDER BY h.at DESC;

-- ---------- reference query ----------

-- Blocks are aligned powers of two, so the block [lo-hi] at level k has hi - lo + 1 = 2^k
-- and its halves are the level k-1 lines at lo and at lo + 2^(k-1).
INSERT INTO reference_queries (name, description, sql_template) VALUES
  ('digest-zoom',
   'Open a recent-work digest block [lo-hi] from session boot into its two halves (project slug, or NULL project for the no-project stream)',
   'SELECT l.level, l.seq_lo, l.first_session_id, l.last_session_id, l.first_at, l.last_at, l.line
FROM digest_lines l
WHERE l.scope_project_id = IFNULL((SELECT id FROM projects WHERE slug = ''<slug>''), 0)
  AND (1 << (l.level + 1)) = <hi> - <lo> + 1
  AND l.seq_lo IN (<lo>, <lo> + (<hi> - <lo> + 1) / 2)
ORDER BY l.seq_lo;')
ON CONFLICT (name) DO UPDATE SET description = excluded.description, sql_template = excluded.sql_template;
