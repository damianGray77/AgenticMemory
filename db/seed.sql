-- Seed rows for a new claude_memory database: the minimum the system needs to run, and nothing
-- else. No sessions, notes, memories, observations or transcripts -- those are personal and are
-- created as you work. Regenerate from a live install with tools/export-from-live.ps1.
--
-- reference_queries are refreshed on every install; config rows and the evidence scale are only
-- inserted when missing, so re-installing never resets values tuned on the target machine.
-- (The digest-zoom reference query is installed by home/consolidator/digest.sql.)

-- reference_queries: SQL templates with <placeholders>; see CLAUDE.md "Reference Queries".
INSERT INTO reference_queries (name, description, sql_template, category) VALUES
('blast-radius', 'What depends on entity X (recursive)', 'WITH RECURSIVE blast AS (
  SELECT id, name, entity_kind, 0 AS depth FROM code_entities WHERE name = ''<entity-name>''
  UNION ALL
  SELECT ce.id, ce.name, ce.entity_kind, b.depth + 1
  FROM blast b JOIN entity_dependencies ed ON ed.callee_id = b.id
  JOIN code_entities ce ON ce.id = ed.caller_id WHERE b.depth < 10 AND ce.is_deleted = 0
)
SELECT DISTINCT name, entity_kind, depth FROM blast WHERE depth > 0 ORDER BY depth;', 'query'),
('class-methods', 'List methods in a class', 'SELECT ce.name, ce.signature, ce.visibility, ce.is_static, ce.line_start
FROM code_entities ce
JOIN code_entities parent ON parent.id = ce.parent_entity_id
WHERE parent.name = ''<ClassName>'' AND ce.entity_kind = ''method''
ORDER BY ce.line_start;', 'query'),
('file-deps', 'What does this file import/depend on', 'SELECT sf2.relative_path AS depends_on, fd.dependency_type
FROM file_dependencies fd
JOIN source_files sf1 ON sf1.id = fd.source_file_id
JOIN source_files sf2 ON sf2.id = fd.target_file_id
WHERE sf1.relative_path = ''<file-path>'';', 'query'),
('find-by-marker', 'Find code entities by contextual marker', 'SELECT ce.name, ce.qualified_name, ce.entity_kind, ce.signature, sf.relative_path, ce.line_start
FROM code_entities ce
JOIN source_files sf ON sf.id = ce.file_id
JOIN entity_markers em ON em.entity_id = ce.id
JOIN contextual_markers cm ON cm.id = em.marker_id
WHERE sf.project_id = (SELECT id FROM projects WHERE slug = ''<slug>'')
  AND cm.marker IN (''<marker1>'', ''<marker2>'') AND ce.is_deleted = 0;', 'query'),
('find-entity', 'Find a specific function/method by name', 'SELECT ce.name, ce.qualified_name, ce.signature, ce.purpose, sf.relative_path, ce.line_start
FROM code_entities ce
JOIN source_files sf ON sf.id = ce.file_id
WHERE sf.project_id = (SELECT id FROM projects WHERE slug = ''<slug>'')
  AND ce.name = ''<name>'';', 'query'),
('global-memories', 'Get global memories (apply to all projects)', 'SELECT id, memory_type, category, title, content FROM memories
WHERE project_id IS NULL AND is_active = 1;', 'query'),
('project-memories', 'Get all active memories for a project', 'SELECT id, memory_type, category, title, content, priority FROM memories
WHERE project_id = (SELECT id FROM projects WHERE slug = ''<slug>'') AND is_active = 1
  AND (expires_at IS NULL OR expires_at > now())
ORDER BY priority ASC;', 'query'),
('read-transcript-context', 'Read the messages around a search hit (or any message) to recall the discussion. Replace <transcript_id> and <seq>.', 'SELECT seq, role, ts, msg_text FROM transcript_messages WHERE transcript_id = <transcript_id> AND seq BETWEEN <seq> - 3 AND <seq> + 3 ORDER BY seq;', 'query'),
('resolve-memory-sources', 'Resolve a memory to its verbatim transcript span(s). One memory may have many memory_sources rows (discontiguous spans, even across transcripts) - all are returned, ordered.', 'SELECT ms.id AS source_id, ms.transcript_id, ms.start_message_uuid, ms.end_message_uuid,
  CAST(substr(uncompress(t.raw_jsonl), sm.byte_offset + 1,
       COALESCE(em.byte_offset + em.byte_length, sm.byte_offset + sm.byte_length) - sm.byte_offset) AS TEXT) AS verbatim
FROM memory_sources ms JOIN transcripts t ON t.id = ms.transcript_id
JOIN transcript_messages sm ON sm.transcript_id = ms.transcript_id AND sm.message_uuid = ms.start_message_uuid
LEFT JOIN transcript_messages em ON em.transcript_id = ms.transcript_id AND em.message_uuid = ms.end_message_uuid
WHERE ms.memory_id = <memory_id> ORDER BY ms.transcript_id, sm.byte_offset;', 'query'),
('resolve-note-sources', 'Same as resolve-memory-sources but for a session_note (memory_sources.note_id).', 'SELECT ms.id AS source_id, ms.transcript_id, ms.start_message_uuid, ms.end_message_uuid,
  CAST(substr(uncompress(t.raw_jsonl), sm.byte_offset + 1,
       COALESCE(em.byte_offset + em.byte_length, sm.byte_offset + sm.byte_length) - sm.byte_offset) AS TEXT) AS verbatim
FROM memory_sources ms JOIN transcripts t ON t.id = ms.transcript_id
JOIN transcript_messages sm ON sm.transcript_id = ms.transcript_id AND sm.message_uuid = ms.start_message_uuid
LEFT JOIN transcript_messages em ON em.transcript_id = ms.transcript_id AND em.message_uuid = ms.end_message_uuid
WHERE ms.note_id = <note_id> ORDER BY ms.transcript_id, sm.byte_offset;', 'query'),
('search-memories', 'Full-text search memories by keyword (any of the words, best match first)', 'SELECT m.id, m.title, m.content FROM memories_fts f JOIN memories m ON m.id = f.rowid
WHERE memories_fts MATCH fts_any(''<keyword>'') AND m.is_active = 1
ORDER BY f.rank;', 'query'),
('search-notes', 'Search session notes across all sessions', 'SELECT sn.note_type, sn.title, sn.content, s.started_at
FROM session_notes_fts f JOIN session_notes sn ON sn.id = f.rowid JOIN sessions s ON s.id = sn.session_id
WHERE session_notes_fts MATCH fts_any(''<keyword>'')
ORDER BY s.started_at DESC;', 'query'),
('search-transcripts', 'Find prior discussion across all archived transcripts (full-text). Replace <keywords>. Returns transcript_id + message_uuid (form a back-pointer [[transcript:id#uuid]]) + preview. Then use read-transcript-context to read around a hit.', 'SELECT t.id AS transcript_id, tm.message_uuid, tm.seq, tm.role, tm.ts, LEFT(tm.msg_text, 160) AS preview
FROM transcript_messages_fts f JOIN transcript_messages tm ON tm.id = f.rowid JOIN transcripts t ON t.id = tm.transcript_id
WHERE transcript_messages_fts MATCH fts_any(''<keywords>'')
ORDER BY tm.ts DESC LIMIT 20;', 'query'),
('semantic-search', 'Search entities by marker for a domain concept', 'SELECT ce.name, ce.purpose, sf.relative_path, ce.line_start
FROM code_entities ce JOIN source_files sf ON sf.id = ce.file_id
JOIN entity_markers em ON em.entity_id = ce.id
JOIN contextual_markers cm ON cm.id = em.marker_id
WHERE cm.marker IN (''<marker1>'', ''<marker2>'') AND ce.is_deleted = 0;', 'query')
ON CONFLICT (name) DO UPDATE SET description = excluded.description, sql_template = excluded.sql_template, category = excluded.category;

-- consolidation_config: the rails. The values are the original machine's, where every stage is live.
-- To watch a few runs before anything changes:
--   UPDATE consolidation_config SET cfg_value = '1' WHERE cfg_key IN ('dry_run', 'confirm_dry_run');
INSERT OR IGNORE INTO consolidation_config (cfg_key, cfg_value, note) VALUES
('behaviour_boot_min_strength', '0.50', 'Session boot lists active behaviours at or above this strength; conflicts are always listed'),
('behaviour_habit_half_life_days', '120', 'Half-life in days of evidence below the rule threshold'),
('behaviour_rule_threshold', '0.75', 'Evidence at or above this base weight makes a rule: it never decays, and only it can supersede older evidence'),
('behaviour_weight_tolerance', '0.05', 'How far a link may move off the anchor weight of its kind, for emphasis'),
('behaviours_enabled', '1', 'Switch for the behaviours layer alone'),
('confirm_dry_run', '0', 'Log-only for the confirm step'),
('confirm_enabled', '1', 'Kill switch for the confirm-memories step (confirm.sql)'),
('digest_boot_lines', '16', 'Lines session boot prints for the digest; a no-project boot splits them between project heads and the no-project stream'),
('digest_enabled', '1', 'Switch for the recent-work digest alone'),
('digest_line_chars', '200', 'Longest digest line, in characters'),
('digest_quiet_hours', '2', 'A session is digested once it has had no notes or transcript messages for this many hours'),
('digest_raw_max_level', '4', 'Blocks up to this level (2^4 = 16 sessions) are summarised from leaf lines; bigger ones from their two halves'),
('dry_run', '0', 'When 1 the pass only logs proposed actions without mutating'),
('enabled', '1', 'Master kill switch; 0 disables the autonomous pass'),
('max_actions_per_run', '50', 'Hard cap on mutating actions per run'),
('max_behaviour_actions_per_run', '50', 'Per-run cap on behaviour mutations (upsert, link, supersede, retire); separate from max_actions_per_run'),
('max_confirm_actions_per_run', '30', 'Blast-radius cap for sp_confirm_memory per run'),
('max_digest_actions_per_run', '40', 'Per-run cap on digest mutations (leaf, skip, block, forget); separate from max_actions_per_run'),
('min_merge_confidence', '0.85', 'Minimum judge confidence to merge two memories'),
('observation_decay_days', '30', 'Observations unseen this many days get decayed'),
('observation_decay_step', '0.05', 'Confidence subtracted per decay run'),
('review_interval_days', '30', 'Deferred notes are excluded from the consolidation batch for this many days before re-review');

-- behaviour_evidence_kinds: the weight scale for evidence behind a behaviour.
INSERT OR IGNORE INTO behaviour_evidence_kinds (kind, anchor_weight, description) VALUES
('approved_proposal', 0.75, '{{USER_NAME}} approved a rule I proposed'),
('correction', 0.85, '{{USER_NAME}} stopped or redirected me partway through a task'),
('cross_session_pattern', 0.55, '{{USER_NAME}}''s own behaviour shows the pattern across several sessions'),
('output_fix', 0.65, '{{USER_NAME}} fixed or rejected my work afterward without stating a rule'),
('own_default', 0.15, 'My own default, never confirmed'),
('project_convention', 0.25, 'Inferred from the project''s conventions, not from {{USER_NAME}}'),
('requirement', 1.00, '{{USER_NAME}} stated it as a hard requirement, or it is enforced by a hook or deny rule'),
('silent_acceptance', 0.45, '{{USER_NAME}} accepted my approach without comment'),
('single_session_pattern', 0.35, 'A pattern seen in only one session'),
('stated_preference', 0.90, '{{USER_NAME}} stated it as a preference and it was saved with approval');
