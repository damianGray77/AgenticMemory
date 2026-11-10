-- behaviours.sql -- the behaviours layer: current guidance derived from memories.
-- SQLite edition; run it through memdb (the views call memdb's now(), timestampdiff(),
-- pow(), exp() and ln()).
-- Tables live in claude_memory_schema.sql (behaviours, behaviour_evidence,
-- behaviour_evidence_kinds, behaviour_source_reviews). This file holds their
-- seed rows and the views that compute strength; the rail-enforcing procedures
-- the consolidation pass calls are built into memdb.exe (memdb\src\Procs.Behaviours.cs)
-- and run with CALL as before. Same rails as the judgment procedures:
--   * honor enabled (kill switch) and dry_run (log-only) from consolidation_config
--   * honor behaviours_enabled, a second switch for this layer alone: it stays 0
--     until the supervised backfill has been reviewed and applied, so the
--     unattended scheduled run cannot start the backfill on its own
--   * cap real mutations per run at max_behaviour_actions_per_run (its own budget,
--     so behaviour work never starves note promotion, and vice versa)
--   * soft operations only; memories are never touched, evidence is superseded
--     rather than deleted, behaviours are retired rather than deleted
--   * write before/after JSON to consolidation_log for full reversibility
--   * problems are logged, not raised: action 'error', 'capped', 'supersede_refused',
--     'review_deferred_capped' or 'link_skipped_duplicate', and the CALL succeeds
-- Re-runnable: views are dropped and recreated, and seed rows are inserted with
-- INSERT OR IGNORE so a tuned anchor weight survives a re-run.
--
-- THE MODEL
--   A behaviour is one subject (dotted lowercase, e.g. tooling.scripting-languages,
--   global or scoped to one project) with a statement of what to do now. Evidence
--   rows link it to the memories, observations and session notes it is derived from;
--   each has a kind from behaviour_evidence_kinds (the weight scale), a weight within
--   behaviour_weight_tolerance of that kind's anchor, a stance (supports | opposes),
--   the date it happened, and an event_key.
--   * RULE vs HABIT: a behaviour is a rule when at least one live supporting event
--     weighs at or above behaviour_rule_threshold ({{USER_NAME}} said it, approved it,
--     or corrected me). Rule-level evidence never decays.
--   * DECAY: evidence below the threshold is a habit and fades with a half-life of
--     behaviour_habit_half_life_days, counted from when it happened (an observation
--     from its latest sighting). Seeing it again adds fresh evidence.
--   * STRENGTH = 1 - PRODUCT(1 - w) over live supporting events (noisy-OR): two
--     independent 0.5 signals make 0.75, and nothing short of a 1.00 requirement
--     reaches 1. Rows sharing an event_key are one event and count once, at their
--     best weight.
--   * SUPERSESSION: a newer statement from {{USER_NAME}} (at or above the rule threshold,
--     dated no earlier) replaces older evidence; the old row is kept and points at
--     its replacement, and stops counting. Weaker evidence can never supersede.
--   * CONFLICT: any live opposing evidence turns the behaviour into a conflict,
--     listed at every session boot until a newer statement settles it. Nothing
--     resolves a conflict silently.
--   * STATUS is recomputed by sp_resolve_behaviour after every change, and for all
--     behaviours by sp_refresh_behaviours (which is what applies decay over time).
--
-- Procedures (memdb): sp_upsert_behaviour, sp_link_evidence, sp_supersede_evidence,
--             sp_retire_behaviour (all capped); sp_resolve_behaviour,
--             sp_refresh_behaviours, sp_mark_reviewed (bookkeeping, not capped).
--
-- DRY RUN CAVEAT: under dry_run=1 nothing is inserted, so a later call that
-- needs a row an earlier call would have created (link to a new subject,
-- supersede a new evidence row) can only log what it would do. For a full
-- preview with computed strengths, run the calls live inside one memdb script
-- between BEGIN; and ROLLBACK; and SELECT the results before the ROLLBACK.
--
-- REVERTING A RUN: every mutation is in consolidation_log under its run_id.
--   link_evidence      -> DELETE FROM behaviour_evidence WHERE id = target_id
--   supersede_evidence -> UPDATE behaviour_evidence SET superseded_by = NULL WHERE id = target_id
--   upsert_behaviour   -> restore before_json.statement / before_json.status, or
--                         DELETE the behaviour when after_json.created is true
--   retire_behaviour   -> restore before_json.status
--   mark_reviewed      -> DELETE the behaviour_source_reviews row, or restore before_json
-- then CALL sp_refresh_behaviours('<revert-run>'); to recompute.
-- (before_json ->> '$.status' reads a value; after_json ->> '$.created' is 1 for true.)

-- ---------- seed rows ----------

-- The weight scale. Anchors are reference points, not the only legal values:
-- a link may move off its anchor by behaviour_weight_tolerance for emphasis.
INSERT OR IGNORE INTO behaviour_evidence_kinds (kind, anchor_weight, description) VALUES
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

INSERT OR IGNORE INTO consolidation_config (cfg_key, cfg_value, note) VALUES
  ('behaviour_rule_threshold',       '0.75', 'Evidence at or above this base weight makes a rule: it never decays, and only it can supersede older evidence'),
  ('behaviour_habit_half_life_days', '120',  'Half-life in days of evidence below the rule threshold'),
  ('behaviour_weight_tolerance',     '0.05', 'How far a link may move off the anchor weight of its kind, for emphasis'),
  ('behaviour_boot_min_strength',    '0.50', 'Session boot lists active behaviours at or above this strength; conflicts are always listed'),
  ('max_behaviour_actions_per_run',  '50',   'Per-run cap on behaviour mutations (upsert, link, supersede, retire); separate from max_actions_per_run'),
  ('behaviours_enabled',             '0',    'Switch for the behaviours layer alone; 0 until the supervised backfill is reviewed and applied');

-- ---------- views ----------
-- Numbers: MySQL held weights as DECIMAL(3,2) and strength as DECIMAL(4,3); here they
-- are REAL, rounded to the same number of places wherever they are computed.

-- user_name is the name the procedures write into conflict notes and refusals
-- (memdb.exe is not a template, so it reads the name from here).
DROP VIEW IF EXISTS v_behaviour_config;
CREATE VIEW v_behaviour_config AS
SELECT
  max(CASE WHEN cfg_key = 'behaviour_rule_threshold'       THEN round(CAST(cfg_value AS REAL), 2) END) AS rule_threshold,
  max(CASE WHEN cfg_key = 'behaviour_habit_half_life_days' THEN CAST(cfg_value AS INTEGER)        END) AS half_life_days,
  max(CASE WHEN cfg_key = 'behaviour_boot_min_strength'    THEN round(CAST(cfg_value AS REAL), 3) END) AS boot_min_strength,
  '{{USER_NAME}}' AS user_name
FROM consolidation_config;

-- Evidence that still counts: not superseded, and its source still active
-- (an expired or merged-away memory stops counting; a session note always
-- counts). An observation seen again since it was linked is dated by its
-- latest sighting. Evidence below the rule threshold decays by half-life;
-- evidence at or above it keeps its full weight.
-- (The exponent is days / half-life rounded to 4 places, as MySQL's decimal
-- division gave it, so both engines decay identically.)
DROP VIEW IF EXISTS v_behaviour_evidence_live;
CREATE VIEW v_behaviour_evidence_live AS
SELECT x.*,
       CASE WHEN x.weight >= c.rule_threshold THEN x.weight
            ELSE round(x.weight * pow(0.5, round(max(0, timestampdiff('DAY', x.occurred_at, now())) * 1.0
                                                 / c.half_life_days, 4)), 4)
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
-- (event_key and stance are COLLATE NOCASE columns, so keys group case-insensitively
-- as they did under MySQL.)
DROP VIEW IF EXISTS v_behaviour_events;
CREATE VIEW v_behaviour_events AS
SELECT behaviour_id, event_key, stance,
       max(weight)      AS weight,
       max(weight_eff)  AS weight_eff,
       max(occurred_at) AS occurred_at,
       count(*)         AS source_rows
FROM v_behaviour_evidence_live
GROUP BY behaviour_id, event_key, stance;

-- strength = 1 - PRODUCT(1 - w) over supporting events, done as a sum of logs.
-- The 0.0001 floor keeps ln() finite for a 1.00 requirement (rounds to 1.000).
DROP VIEW IF EXISTS v_behaviour_strength;
CREATE VIEW v_behaviour_strength AS
SELECT b.id AS behaviour_id,
       round(1 - exp(coalesce(sum(CASE WHEN ev.stance = 'supports'
                                       THEN ln(max(1 - ev.weight_eff, 0.0001)) END), 0)), 3) AS strength,
       CASE WHEN max(CASE WHEN ev.stance = 'supports' AND ev.weight >= c.rule_threshold THEN 1 ELSE 0 END) = 1
            THEN 'rule' ELSE 'habit' END AS kind,
       coalesce(sum(ev.stance = 'supports'), 0) AS supporting_events,
       coalesce(sum(ev.stance = 'opposes'), 0)  AS opposing_events,
       max(CASE WHEN ev.stance = 'opposes' THEN ev.weight_eff END) AS max_opposing_weight
FROM behaviours b
LEFT JOIN v_behaviour_events ev ON ev.behaviour_id = b.id
CROSS JOIN v_behaviour_config c
GROUP BY b.id, c.rule_threshold;

-- What session boot prints: open conflicts first, then rules, then habits.
DROP VIEW IF EXISTS v_behaviours_boot;
CREATE VIEW v_behaviours_boot AS
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
DROP VIEW IF EXISTS v_behaviour_worklist;
CREATE VIEW v_behaviour_worklist AS
SELECT 'memory' AS source_type, m.id AS source_id, m.memory_type AS type, m.category,
       m.title, m.content, m.created_at AS dated, r.reviewed_at
FROM memories m
LEFT JOIN behaviour_source_reviews r ON r.source_type = 'memory' AND r.source_id = m.id
WHERE m.is_active = 1
  AND m.confirmed = 1          -- only memories checked against their transcript (confirm.sql)
  AND m.memory_type IN ('user','feedback')
  AND rtrim(ifnull(m.category, ''), ' ') <> 'limitation' COLLATE NOCASE
  AND (r.reviewed_at IS NULL OR m.updated_at > r.reviewed_at)
UNION ALL
SELECT 'observation', o.id, 'observation', o.category,
       o.title, o.content, o.last_seen, r.reviewed_at
FROM user_observations o
LEFT JOIN behaviour_source_reviews r ON r.source_type = 'observation' AND r.source_id = o.id
WHERE o.is_active = 1
  AND (r.reviewed_at IS NULL OR o.last_seen > r.reviewed_at)
ORDER BY dated;
