-- claude_memory schema, SQLite edition. Run through memdb (it needs memdb's now() function).
--
-- Conventions, chosen so behaviour matches the MySQL original:
--   * Timestamps are LOCAL time as TEXT 'YYYY-MM-DD HH:MM:SS', defaulting to memdb's now().
--     (The Windows build of SQLite omits 'localtime'; memdb supplies now(), to_utc(), to_local().)
--     transcript_messages.ts is the exception: UTC, straight from Claude Code's JSONL.
--   * Short text columns are COLLATE NOCASE: MySQL's utf8mb4_unicode_ci compared them
--     case-insensitively, and upserts such as the observation-title one rely on it.
--   * ids are AUTOINCREMENT, so like MySQL they are never reused (back-pointers depend on that).
--   * ENUMs are CHECK constraints; MySQL FULLTEXT indexes are FTS5 tables named <table>_fts,
--     kept in sync by triggers. Search them with:  ... WHERE <table>_fts MATCH fts_any('words')
--   * ON UPDATE CURRENT_TIMESTAMP is a trigger: it stamps updated_at when another column
--     changed and the statement did not set updated_at itself.
--   * Foreign keys are enforced: memdb turns PRAGMA foreign_keys on for every connection.
--
-- Safe to re-run: everything is IF NOT EXISTS. The views live in consolidator/*.sql and the
-- consolidation procedures inside memdb.exe.

PRAGMA journal_mode = WAL;   -- readers never block the writer; hooks and sessions overlap

-- ---------------------------------------------------------------------------
-- Projects, sessions, notes, memories, observations
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS projects (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  slug             TEXT    NOT NULL COLLATE NOCASE UNIQUE,
  name             TEXT    NOT NULL COLLATE NOCASE,
  root_path        TEXT    NOT NULL COLLATE NOCASE,
  svn_uuid         TEXT    COLLATE NOCASE,          -- SVN repository UUID, for path-independent matching
  svn_project_path TEXT    COLLATE NOCASE,          -- project folder within the SVN repository
  primary_language TEXT    COLLATE NOCASE,
  framework        TEXT    COLLATE NOCASE,
  description      TEXT,
  last_scan_at     TEXT,
  last_scan_commit TEXT    COLLATE NOCASE,
  is_active        INTEGER NOT NULL DEFAULT 1,
  created_at       TEXT    NOT NULL DEFAULT (now()),
  updated_at       TEXT    NOT NULL DEFAULT (now())
);

CREATE TABLE IF NOT EXISTS sessions (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id    INTEGER REFERENCES projects (id) ON DELETE SET NULL,
  session_uuid  TEXT    COLLATE NOCASE,             -- Claude Code session UUID (transcript filename stem)
  branch        TEXT    COLLATE NOCASE,             -- SVN branch name (trunk, or branch folder name)
  status        TEXT    NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active','completed','abandoned')),
  started_at    TEXT    NOT NULL DEFAULT (now()),
  ended_at      TEXT,
  summary       TEXT,
  files_touched TEXT,                               -- JSON array
  topics        TEXT                                -- JSON array
);
CREATE INDEX IF NOT EXISTS ix_sessions_project ON sessions (project_id, started_at);
CREATE INDEX IF NOT EXISTS ix_sessions_status  ON sessions (status, started_at);
CREATE INDEX IF NOT EXISTS ix_sessions_uuid    ON sessions (session_uuid);

CREATE TABLE IF NOT EXISTS session_notes (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      INTEGER NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  note_type       TEXT    NOT NULL COLLATE NOCASE,  -- decision, attempt, discovery, blocker, context, milestone
  title           TEXT    NOT NULL COLLATE NOCASE CHECK (length(title) <= 255),
  content         TEXT    NOT NULL,
  created_at      TEXT    NOT NULL DEFAULT (now()),
  is_consolidated INTEGER NOT NULL DEFAULT 0,
  last_reviewed   TEXT                              -- reviewed and kept (deferred); skipped for review_interval_days
);
CREATE INDEX IF NOT EXISTS ix_notes_session       ON session_notes (session_id, note_type);
CREATE INDEX IF NOT EXISTS ix_notes_consolidation ON session_notes (is_consolidated, created_at);

CREATE TABLE IF NOT EXISTS memories (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id         INTEGER REFERENCES projects (id) ON DELETE SET NULL,
  memory_type        TEXT    NOT NULL COLLATE NOCASE CHECK (memory_type IN ('user','feedback','project','reference')),
  category           TEXT    COLLATE NOCASE,
  title              TEXT    NOT NULL COLLATE NOCASE CHECK (length(title) <= 255),
  content            TEXT    NOT NULL,
  source_session     INTEGER REFERENCES sessions (id) ON DELETE SET NULL,
  is_active          INTEGER NOT NULL DEFAULT 1,
  -- Confirmation (consolidator/confirm.sql): a new memory is a draft that the consolidation pass
  -- checks against its source transcript, correcting it only to make it faithful; once confirmed
  -- it is the append-only record.
  confirmed          INTEGER NOT NULL DEFAULT 0,    -- 0 = draft; 1 = append-only record
  confirm_outcome    TEXT    COLLATE NOCASE CHECK (confirm_outcome IN ('backfill','faithful','corrected','no_source')),
  confirm_checked_at TEXT,
  priority           INTEGER DEFAULT 3,
  expires_at         TEXT,
  last_accessed_at   TEXT,
  created_at         TEXT    NOT NULL DEFAULT (now()),
  updated_at         TEXT    NOT NULL DEFAULT (now())
);
CREATE INDEX IF NOT EXISTS ix_memories_project_type     ON memories (project_id, memory_type, is_active);
CREATE INDEX IF NOT EXISTS ix_memories_type_category    ON memories (memory_type, category, is_active);
CREATE INDEX IF NOT EXISTS ix_memories_project_category ON memories (project_id, category, is_active);
CREATE INDEX IF NOT EXISTS ix_memories_confirm          ON memories (confirmed, is_active);

CREATE TABLE IF NOT EXISTS user_observations (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  category       TEXT    NOT NULL COLLATE NOCASE,   -- free-form: rapport, workstyle, communication, ...
  title          TEXT    NOT NULL COLLATE NOCASE UNIQUE CHECK (length(title) <= 255),
  content        TEXT    NOT NULL,
  observed_count INTEGER NOT NULL DEFAULT 1,
  confidence     REAL    NOT NULL DEFAULT 0.50,
  first_seen     TEXT    NOT NULL DEFAULT (now()),
  last_seen      TEXT    NOT NULL DEFAULT (now()),
  is_active      INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS ix_obs_active_conf ON user_observations (is_active, confidence);

CREATE TABLE IF NOT EXISTS reference_queries (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  name         TEXT NOT NULL COLLATE NOCASE UNIQUE, -- short lookup key, e.g. blast-radius
  description  TEXT NOT NULL,
  sql_template TEXT NOT NULL,                       -- SQL with <placeholders>
  category     TEXT NOT NULL DEFAULT 'query' COLLATE NOCASE   -- query, scanner, enrichment, maintenance
);

-- ---------------------------------------------------------------------------
-- Code index (claude_scanner.sh)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS source_files (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id      INTEGER NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
  relative_path   TEXT    NOT NULL COLLATE NOCASE,
  file_type       TEXT    NOT NULL COLLATE NOCASE,
  line_count      INTEGER,
  purpose         TEXT,
  file_hash       TEXT    COLLATE NOCASE,
  last_scanned_at TEXT,
  is_deleted      INTEGER NOT NULL DEFAULT 0,
  created_at      TEXT    NOT NULL DEFAULT (now()),
  updated_at      TEXT    NOT NULL DEFAULT (now()),
  UNIQUE (project_id, relative_path)
);
CREATE INDEX IF NOT EXISTS ix_source_files_type   ON source_files (project_id, file_type);
CREATE INDEX IF NOT EXISTS ix_source_files_active ON source_files (project_id, is_deleted, relative_path);

CREATE TABLE IF NOT EXISTS code_entities (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  file_id          INTEGER NOT NULL REFERENCES source_files (id) ON DELETE CASCADE,
  parent_entity_id INTEGER REFERENCES code_entities (id) ON DELETE SET NULL,
  entity_kind      TEXT    NOT NULL COLLATE NOCASE,
  name             TEXT    NOT NULL COLLATE NOCASE,
  qualified_name   TEXT    COLLATE NOCASE,
  signature        TEXT,
  line_start       INTEGER,
  line_end         INTEGER,
  visibility       TEXT    COLLATE NOCASE CHECK (visibility IN ('public','private','protected','internal','export','default')),
  is_static        INTEGER,
  purpose          TEXT,
  last_scanned_at  TEXT,
  is_deleted       INTEGER NOT NULL DEFAULT 0,
  created_at       TEXT    NOT NULL DEFAULT (now()),
  updated_at       TEXT    NOT NULL DEFAULT (now())
);
CREATE INDEX IF NOT EXISTS ix_entities_file           ON code_entities (file_id);
CREATE INDEX IF NOT EXISTS ix_entities_file_active    ON code_entities (file_id, is_deleted);
CREATE INDEX IF NOT EXISTS ix_entities_file_kind_line ON code_entities (file_id, entity_kind, line_start);
CREATE INDEX IF NOT EXISTS ix_entities_kind           ON code_entities (entity_kind, name);
CREATE INDEX IF NOT EXISTS ix_entities_parent         ON code_entities (parent_entity_id);

CREATE TABLE IF NOT EXISTS contextual_markers (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  marker TEXT NOT NULL COLLATE NOCASE UNIQUE
);

CREATE TABLE IF NOT EXISTS entity_markers (
  entity_id  INTEGER NOT NULL REFERENCES code_entities (id) ON DELETE CASCADE,
  marker_id  INTEGER NOT NULL REFERENCES contextual_markers (id) ON DELETE CASCADE,
  confidence REAL    NOT NULL DEFAULT 1.00,
  PRIMARY KEY (entity_id, marker_id)
);
CREATE INDEX IF NOT EXISTS ix_entity_markers_marker ON entity_markers (marker_id);

CREATE TABLE IF NOT EXISTS file_markers (
  file_id    INTEGER NOT NULL REFERENCES source_files (id) ON DELETE CASCADE,
  marker_id  INTEGER NOT NULL REFERENCES contextual_markers (id) ON DELETE CASCADE,
  confidence REAL    NOT NULL DEFAULT 1.00,
  PRIMARY KEY (file_id, marker_id)
);
CREATE INDEX IF NOT EXISTS ix_file_markers_marker ON file_markers (marker_id);

CREATE TABLE IF NOT EXISTS entity_dependencies (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  caller_id       INTEGER NOT NULL REFERENCES code_entities (id) ON DELETE CASCADE,
  callee_id       INTEGER NOT NULL REFERENCES code_entities (id) ON DELETE CASCADE,
  dependency_type TEXT    NOT NULL DEFAULT 'calls' COLLATE NOCASE
                  CHECK (dependency_type IN ('calls','imports','extends','implements','uses','hooks','overrides')),
  line_reference  INTEGER,
  UNIQUE (caller_id, callee_id, dependency_type)
);
CREATE INDEX IF NOT EXISTS ix_deps_callee ON entity_dependencies (callee_id);
CREATE INDEX IF NOT EXISTS ix_deps_type   ON entity_dependencies (dependency_type);

CREATE TABLE IF NOT EXISTS file_dependencies (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  source_file_id  INTEGER NOT NULL REFERENCES source_files (id) ON DELETE CASCADE,
  target_file_id  INTEGER NOT NULL REFERENCES source_files (id) ON DELETE CASCADE,
  dependency_type TEXT    NOT NULL DEFAULT 'imports' COLLATE NOCASE,
  UNIQUE (source_file_id, target_file_id, dependency_type)
);
CREATE INDEX IF NOT EXISTS ix_file_deps_target ON file_dependencies (target_file_id);

-- ---------------------------------------------------------------------------
-- Transcript retention (lossless raw record) + back-pointers.
-- INVARIANT: transcripts.id is stable across re-ingest of a grown jsonl --
-- archive_transcripts.ps1 upserts the row in place (keyed on source_path,
-- 1:1 with session_uuid since the file basename IS the uuid). Ingest must never
-- DELETE+reinsert a transcripts row: memory_sources' ON DELETE CASCADE would
-- silently destroy back-pointers.
-- raw_jsonl uses MySQL's COMPRESS() format (memdb's compress()/uncompress()), so
-- archives move between the two engines byte for byte.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS transcripts (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id          INTEGER REFERENCES projects (id) ON DELETE SET NULL,
  session_id          INTEGER REFERENCES sessions (id) ON DELETE SET NULL,   -- via CLAUDE_CODE_SESSION_ID
  session_uuid        TEXT    NOT NULL COLLATE NOCASE,
  kind                TEXT    NOT NULL DEFAULT 'main' COLLATE NOCASE CHECK (kind IN ('main','subagent')),
  parent_session_uuid TEXT    COLLATE NOCASE,                                -- subagents: the parent session
  source_path         TEXT    NOT NULL COLLATE NOCASE UNIQUE,                -- original on-disk path of the .jsonl
  raw_jsonl           BLOB    NOT NULL,                                      -- verbatim bytes; compress() when is_compressed = 1
  is_compressed       INTEGER NOT NULL DEFAULT 1,
  content_sha256      TEXT    NOT NULL COLLATE NOCASE,                       -- of the uncompressed bytes
  byte_size           INTEGER NOT NULL,                                      -- uncompressed size
  line_count          INTEGER NOT NULL,
  message_count       INTEGER NOT NULL,                                      -- indexed user/assistant messages
  first_message_at    TEXT,
  last_message_at     TEXT,
  captured_at         TEXT    NOT NULL DEFAULT (now()),
  updated_at          TEXT    NOT NULL DEFAULT (now())
);
CREATE INDEX IF NOT EXISTS ix_transcript_session_uuid ON transcripts (session_uuid);
CREATE INDEX IF NOT EXISTS ix_transcript_sha          ON transcripts (content_sha256);

CREATE TABLE IF NOT EXISTS transcript_messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  transcript_id INTEGER NOT NULL REFERENCES transcripts (id) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,                   -- position of the message within the transcript
  message_uuid  TEXT    NOT NULL COLLATE NOCASE,    -- stable per-message anchor (the back-pointer target)
  parent_uuid   TEXT    COLLATE NOCASE,
  role          TEXT    COLLATE NOCASE,             -- user, assistant
  byte_offset   INTEGER NOT NULL,                   -- offset of this line in the UNCOMPRESSED raw_jsonl
  byte_length   INTEGER NOT NULL,
  line_number   INTEGER NOT NULL,
  ts            TEXT,                               -- UTC
  msg_text      TEXT,                               -- extracted human-readable text, full-text indexed
  UNIQUE (transcript_id, message_uuid)
);
CREATE INDEX IF NOT EXISTS ix_msg_uuid ON transcript_messages (message_uuid);

CREATE TABLE IF NOT EXISTS memory_sources (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type        TEXT    NOT NULL COLLATE NOCASE CHECK (source_type IN ('memory','session_note')),
  memory_id          INTEGER REFERENCES memories (id) ON DELETE CASCADE,
  note_id            INTEGER REFERENCES session_notes (id) ON DELETE CASCADE,
  transcript_id      INTEGER NOT NULL REFERENCES transcripts (id) ON DELETE CASCADE,
  start_message_uuid TEXT    NOT NULL COLLATE NOCASE,   -- first message of the span
  end_message_uuid   TEXT    COLLATE NOCASE,            -- last message; NULL = a single message
  rationale          TEXT,
  created_at         TEXT    NOT NULL DEFAULT (now())
);
CREATE INDEX IF NOT EXISTS ix_src_memory     ON memory_sources (memory_id);
CREATE INDEX IF NOT EXISTS ix_src_note       ON memory_sources (note_id);
CREATE INDEX IF NOT EXISTS ix_src_transcript ON memory_sources (transcript_id);

-- Mailbox for an MCP bridge between Claude Desktop (peer 'chat') and Claude Code (peer 'code').
-- Not part of the memory model; kept so a bridge server can share the database.
CREATE TABLE IF NOT EXISTS bridge_messages (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  sender     TEXT NOT NULL COLLATE NOCASE,                  -- code | chat
  recipient  TEXT NOT NULL DEFAULT 'any' COLLATE NOCASE,    -- code | chat | any
  topic      TEXT COLLATE NOCASE,
  content    TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (now()),
  read_at    TEXT                                           -- NULL = unread
);
CREATE INDEX IF NOT EXISTS idx_bridge_inbox   ON bridge_messages (recipient, read_at);
CREATE INDEX IF NOT EXISTS idx_bridge_created ON bridge_messages (created_at);

-- ---------------------------------------------------------------------------
-- Autonomous consolidation: config / kill switch + reversible audit log.
-- Every consolidation procedure (in memdb) reads its rails here and logs here.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS consolidation_config (
  cfg_key    TEXT PRIMARY KEY COLLATE NOCASE,
  cfg_value  TEXT NOT NULL,
  note       TEXT,
  updated_at TEXT NOT NULL DEFAULT (now())
);

CREATE TABLE IF NOT EXISTS consolidation_log (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id       TEXT    NOT NULL COLLATE NOCASE,
  action       TEXT    NOT NULL COLLATE NOCASE,   -- decay_observation, expire_memory, promote_note, merge_memory, ...
  target_table TEXT    COLLATE NOCASE,
  target_id    INTEGER,
  before_json  TEXT,                              -- prior state, for reversibility
  after_json   TEXT,
  reason       TEXT,
  dry_run      INTEGER NOT NULL DEFAULT 0,
  reverted     INTEGER NOT NULL DEFAULT 0,
  reverted_at  TEXT,
  created_at   TEXT    NOT NULL DEFAULT (now())
);
CREATE INDEX IF NOT EXISTS idx_log_run    ON consolidation_log (run_id);
CREATE INDEX IF NOT EXISTS idx_log_action ON consolidation_log (action);
CREATE INDEX IF NOT EXISTS idx_log_target ON consolidation_log (target_table, target_id);

-- ---------------------------------------------------------------------------
-- Behaviours: the current guidance DERIVED from memories.
-- Memories are an append-only record of what happened and are never edited to change
-- behaviour; a behaviour is what to do now, worked out from all of the evidence linked to it.
-- Written only by the consolidation procedures (see consolidator/behaviours.sql for the model).
--   RULE  = at least one live piece of evidence at or above behaviour_rule_threshold
--           ({{USER_NAME}} said it, approved it, or corrected me). It never decays; only a
--           newer statement replaces it.
--   HABIT = everything weaker. Each piece fades with a half-life of
--           behaviour_habit_half_life_days; seeing it again adds fresh evidence.
--   strength = 1 - PRODUCT(1 - w) over live supporting events (noisy-OR).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS behaviour_evidence_kinds (
  kind          TEXT PRIMARY KEY COLLATE NOCASE,
  anchor_weight REAL NOT NULL,                     -- base weight; a link may move off it by behaviour_weight_tolerance
  description   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS behaviours (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  subject          TEXT    NOT NULL COLLATE NOCASE CHECK (length(subject) <= 100),  -- dotted lowercase key
  project_id       INTEGER REFERENCES projects (id),                                -- NULL = global
  scope_project_id INTEGER GENERATED ALWAYS AS (IFNULL(project_id, 0)) STORED,      -- NULLs never collide in a UNIQUE key
  statement        TEXT    NOT NULL,
  kind             TEXT    NOT NULL DEFAULT 'habit' COLLATE NOCASE CHECK (kind IN ('rule','habit')),
  strength         REAL    NOT NULL DEFAULT 0.000,
  status           TEXT    NOT NULL DEFAULT 'active' COLLATE NOCASE CHECK (status IN ('active','conflict','retired')),
  conflict_note    TEXT,
  resolved_at      TEXT,
  resolved_run_id  TEXT    COLLATE NOCASE,
  created_at       TEXT    NOT NULL DEFAULT (now()),
  updated_at       TEXT    NOT NULL DEFAULT (now()),
  UNIQUE (subject, scope_project_id)
);
CREATE INDEX IF NOT EXISTS ix_behaviour_boot ON behaviours (status, kind, strength);

CREATE TABLE IF NOT EXISTS behaviour_evidence (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  behaviour_id  INTEGER NOT NULL REFERENCES behaviours (id) ON DELETE CASCADE,
  source_type   TEXT    NOT NULL COLLATE NOCASE CHECK (source_type IN ('memory','observation','session_note')),
  source_id     INTEGER NOT NULL,                  -- memories.id / user_observations.id / session_notes.id
  evidence_kind TEXT    NOT NULL COLLATE NOCASE REFERENCES behaviour_evidence_kinds (kind) ON UPDATE CASCADE,
  weight        REAL    NOT NULL,                  -- anchor for its kind, +/- behaviour_weight_tolerance
  stance        TEXT    NOT NULL DEFAULT 'supports' COLLATE NOCASE CHECK (stance IN ('supports','opposes')),
  occurred_at   TEXT    NOT NULL,                  -- when it happened; drives decay and supersession
  event_key     TEXT    NOT NULL COLLATE NOCASE,   -- rows sharing one count once per behaviour
  superseded_by INTEGER REFERENCES behaviour_evidence (id) ON DELETE SET NULL,
  rationale     TEXT,
  run_id        TEXT    COLLATE NOCASE,
  created_at    TEXT    NOT NULL DEFAULT (now()),
  UNIQUE (behaviour_id, event_key, source_type, source_id)
);
CREATE INDEX IF NOT EXISTS ix_evidence_source     ON behaviour_evidence (source_type, source_id);
CREATE INDEX IF NOT EXISTS ix_evidence_superseded ON behaviour_evidence (superseded_by);

-- Sources the behaviour step has already considered (including those bearing on no behaviour),
-- so v_behaviour_worklist does not re-read them. A source changed after review is queued again.
CREATE TABLE IF NOT EXISTS behaviour_source_reviews (
  source_type TEXT    NOT NULL COLLATE NOCASE CHECK (source_type IN ('memory','observation','session_note')),
  source_id   INTEGER NOT NULL,
  reviewed_at TEXT    NOT NULL DEFAULT (now()),
  run_id      TEXT    COLLATE NOCASE,
  outcome     TEXT,
  PRIMARY KEY (source_type, source_id)
);

-- ---------------------------------------------------------------------------
-- Recent-work digest: an OptMem-style merge tree over sessions, one tree per project
-- plus one for sessions with no project. A LEAF (level 0) is one line for one finished
-- session; a BLOCK at level k rolls up the 2^k leaves from seq_lo into one line, written
-- once both halves exist. Session boot prints an age-decayed cover of the tree
-- (CALL sp_digest_cover). Leaves are append-only; blocks are a cache. See consolidator/digest.sql.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS digest_lines (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id       INTEGER REFERENCES projects (id),                                 -- NULL = the no-project stream
  scope_project_id INTEGER GENERATED ALWAYS AS (IFNULL(project_id, 0)) STORED,
  level            INTEGER NOT NULL,               -- 0 = one session; k = a block of 2^k leaves
  seq_lo           INTEGER NOT NULL,               -- first leaf position covered; a multiple of 2^level
  session_id       INTEGER REFERENCES sessions (id),                                 -- level 0 only
  first_session_id INTEGER NOT NULL,
  last_session_id  INTEGER NOT NULL,
  session_count    INTEGER NOT NULL DEFAULT 1,     -- distinct sessions; a resumed session can have two leaves
  first_at         TEXT    NOT NULL,               -- start of the earliest session covered (local)
  last_at          TEXT    NOT NULL,               -- last activity covered (local)
  line             TEXT    NOT NULL CHECK (length(line) <= 255),
  run_id           TEXT    COLLATE NOCASE,
  created_at       TEXT    NOT NULL DEFAULT (now()),
  UNIQUE (scope_project_id, level, seq_lo)
);
CREATE INDEX IF NOT EXISTS ix_digest_session ON digest_lines (session_id);

-- Which sessions the digest step has read, and up to when (local). New activity after
-- reviewed_until queues the session again, so a resumed session gets a second leaf.
CREATE TABLE IF NOT EXISTS digest_session_reviews (
  session_id     INTEGER PRIMARY KEY REFERENCES sessions (id) ON DELETE CASCADE,
  reviewed_until TEXT    NOT NULL,
  outcome        TEXT,                             -- leaf <seq>, or skipped: <why>
  run_id         TEXT    COLLATE NOCASE,
  reviewed_at    TEXT    NOT NULL DEFAULT (now())
);

-- ---------------------------------------------------------------------------
-- MySQL ON UPDATE CURRENT_TIMESTAMP: stamp updated_at when another column changed and the
-- statement left updated_at alone. (COLLATE BINARY so a case-only change still counts.)
-- ---------------------------------------------------------------------------

CREATE TRIGGER IF NOT EXISTS trg_projects_touch AFTER UPDATE ON projects
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.slug IS NOT OLD.slug COLLATE BINARY OR NEW.name IS NOT OLD.name COLLATE BINARY
  OR NEW.root_path IS NOT OLD.root_path COLLATE BINARY OR NEW.svn_uuid IS NOT OLD.svn_uuid COLLATE BINARY
  OR NEW.svn_project_path IS NOT OLD.svn_project_path COLLATE BINARY OR NEW.primary_language IS NOT OLD.primary_language COLLATE BINARY
  OR NEW.framework IS NOT OLD.framework COLLATE BINARY OR NEW.description IS NOT OLD.description
  OR NEW.last_scan_at IS NOT OLD.last_scan_at OR NEW.last_scan_commit IS NOT OLD.last_scan_commit COLLATE BINARY
  OR NEW.is_active IS NOT OLD.is_active)
BEGIN UPDATE projects SET updated_at = now() WHERE id = NEW.id; END;

CREATE TRIGGER IF NOT EXISTS trg_memories_touch AFTER UPDATE ON memories
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.project_id IS NOT OLD.project_id OR NEW.memory_type IS NOT OLD.memory_type COLLATE BINARY
  OR NEW.category IS NOT OLD.category COLLATE BINARY OR NEW.title IS NOT OLD.title COLLATE BINARY
  OR NEW.content IS NOT OLD.content OR NEW.source_session IS NOT OLD.source_session
  OR NEW.is_active IS NOT OLD.is_active OR NEW.confirmed IS NOT OLD.confirmed
  OR NEW.confirm_outcome IS NOT OLD.confirm_outcome COLLATE BINARY OR NEW.confirm_checked_at IS NOT OLD.confirm_checked_at
  OR NEW.priority IS NOT OLD.priority OR NEW.expires_at IS NOT OLD.expires_at
  OR NEW.last_accessed_at IS NOT OLD.last_accessed_at)
BEGIN UPDATE memories SET updated_at = now() WHERE id = NEW.id; END;

CREATE TRIGGER IF NOT EXISTS trg_source_files_touch AFTER UPDATE ON source_files
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.project_id IS NOT OLD.project_id OR NEW.relative_path IS NOT OLD.relative_path COLLATE BINARY
  OR NEW.file_type IS NOT OLD.file_type COLLATE BINARY OR NEW.line_count IS NOT OLD.line_count
  OR NEW.purpose IS NOT OLD.purpose OR NEW.file_hash IS NOT OLD.file_hash COLLATE BINARY
  OR NEW.last_scanned_at IS NOT OLD.last_scanned_at OR NEW.is_deleted IS NOT OLD.is_deleted)
BEGIN UPDATE source_files SET updated_at = now() WHERE id = NEW.id; END;

CREATE TRIGGER IF NOT EXISTS trg_code_entities_touch AFTER UPDATE ON code_entities
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.file_id IS NOT OLD.file_id OR NEW.parent_entity_id IS NOT OLD.parent_entity_id
  OR NEW.entity_kind IS NOT OLD.entity_kind COLLATE BINARY OR NEW.name IS NOT OLD.name COLLATE BINARY
  OR NEW.qualified_name IS NOT OLD.qualified_name COLLATE BINARY OR NEW.signature IS NOT OLD.signature
  OR NEW.line_start IS NOT OLD.line_start OR NEW.line_end IS NOT OLD.line_end
  OR NEW.visibility IS NOT OLD.visibility COLLATE BINARY OR NEW.is_static IS NOT OLD.is_static
  OR NEW.purpose IS NOT OLD.purpose OR NEW.last_scanned_at IS NOT OLD.last_scanned_at
  OR NEW.is_deleted IS NOT OLD.is_deleted)
BEGIN UPDATE code_entities SET updated_at = now() WHERE id = NEW.id; END;

CREATE TRIGGER IF NOT EXISTS trg_transcripts_touch AFTER UPDATE ON transcripts
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.project_id IS NOT OLD.project_id OR NEW.session_id IS NOT OLD.session_id
  OR NEW.session_uuid IS NOT OLD.session_uuid COLLATE BINARY OR NEW.kind IS NOT OLD.kind COLLATE BINARY
  OR NEW.parent_session_uuid IS NOT OLD.parent_session_uuid COLLATE BINARY
  OR NEW.source_path IS NOT OLD.source_path COLLATE BINARY OR NEW.content_sha256 IS NOT OLD.content_sha256 COLLATE BINARY
  OR NEW.is_compressed IS NOT OLD.is_compressed OR NEW.byte_size IS NOT OLD.byte_size
  OR NEW.line_count IS NOT OLD.line_count OR NEW.message_count IS NOT OLD.message_count
  OR NEW.first_message_at IS NOT OLD.first_message_at OR NEW.last_message_at IS NOT OLD.last_message_at)
BEGIN UPDATE transcripts SET updated_at = now() WHERE id = NEW.id; END;

CREATE TRIGGER IF NOT EXISTS trg_consolidation_config_touch AFTER UPDATE ON consolidation_config
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.cfg_key IS NOT OLD.cfg_key COLLATE BINARY OR NEW.cfg_value IS NOT OLD.cfg_value OR NEW.note IS NOT OLD.note)
BEGIN UPDATE consolidation_config SET updated_at = now() WHERE cfg_key = NEW.cfg_key; END;

CREATE TRIGGER IF NOT EXISTS trg_behaviours_touch AFTER UPDATE ON behaviours
WHEN NEW.updated_at IS OLD.updated_at AND (
     NEW.subject IS NOT OLD.subject COLLATE BINARY OR NEW.project_id IS NOT OLD.project_id
  OR NEW.statement IS NOT OLD.statement OR NEW.kind IS NOT OLD.kind COLLATE BINARY
  OR NEW.strength IS NOT OLD.strength OR NEW.status IS NOT OLD.status COLLATE BINARY
  OR NEW.conflict_note IS NOT OLD.conflict_note OR NEW.resolved_at IS NOT OLD.resolved_at
  OR NEW.resolved_run_id IS NOT OLD.resolved_run_id COLLATE BINARY)
BEGIN UPDATE behaviours SET updated_at = now() WHERE id = NEW.id; END;

CREATE TRIGGER IF NOT EXISTS trg_digest_session_reviews_touch AFTER UPDATE ON digest_session_reviews
WHEN NEW.reviewed_at IS OLD.reviewed_at AND (
     NEW.reviewed_until IS NOT OLD.reviewed_until OR NEW.outcome IS NOT OLD.outcome
  OR NEW.run_id IS NOT OLD.run_id COLLATE BINARY)
BEGIN UPDATE digest_session_reviews SET reviewed_at = now() WHERE session_id = NEW.session_id; END;

-- ---------------------------------------------------------------------------
-- Full-text search (MySQL FULLTEXT -> FTS5). External-content tables: the text lives
-- once, in the base table; triggers keep each index in step.
-- Query:  SELECT m.* FROM memories m JOIN memories_fts f ON f.rowid = m.id
--         WHERE memories_fts MATCH fts_any('keywords') ORDER BY f.rank
-- ---------------------------------------------------------------------------

CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(title, content, content='memories', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS memories_fts_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts (rowid, title, content) VALUES (NEW.id, NEW.title, NEW.content); END;
CREATE TRIGGER IF NOT EXISTS memories_fts_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts (memories_fts, rowid, title, content) VALUES ('delete', OLD.id, OLD.title, OLD.content); END;
CREATE TRIGGER IF NOT EXISTS memories_fts_au AFTER UPDATE OF title, content ON memories BEGIN
  INSERT INTO memories_fts (memories_fts, rowid, title, content) VALUES ('delete', OLD.id, OLD.title, OLD.content);
  INSERT INTO memories_fts (rowid, title, content) VALUES (NEW.id, NEW.title, NEW.content); END;

CREATE VIRTUAL TABLE IF NOT EXISTS session_notes_fts USING fts5(title, content, content='session_notes', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS session_notes_fts_ai AFTER INSERT ON session_notes BEGIN
  INSERT INTO session_notes_fts (rowid, title, content) VALUES (NEW.id, NEW.title, NEW.content); END;
CREATE TRIGGER IF NOT EXISTS session_notes_fts_ad AFTER DELETE ON session_notes BEGIN
  INSERT INTO session_notes_fts (session_notes_fts, rowid, title, content) VALUES ('delete', OLD.id, OLD.title, OLD.content); END;
CREATE TRIGGER IF NOT EXISTS session_notes_fts_au AFTER UPDATE OF title, content ON session_notes BEGIN
  INSERT INTO session_notes_fts (session_notes_fts, rowid, title, content) VALUES ('delete', OLD.id, OLD.title, OLD.content);
  INSERT INTO session_notes_fts (rowid, title, content) VALUES (NEW.id, NEW.title, NEW.content); END;

CREATE VIRTUAL TABLE IF NOT EXISTS user_observations_fts USING fts5(title, content, content='user_observations', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS user_observations_fts_ai AFTER INSERT ON user_observations BEGIN
  INSERT INTO user_observations_fts (rowid, title, content) VALUES (NEW.id, NEW.title, NEW.content); END;
CREATE TRIGGER IF NOT EXISTS user_observations_fts_ad AFTER DELETE ON user_observations BEGIN
  INSERT INTO user_observations_fts (user_observations_fts, rowid, title, content) VALUES ('delete', OLD.id, OLD.title, OLD.content); END;
CREATE TRIGGER IF NOT EXISTS user_observations_fts_au AFTER UPDATE OF title, content ON user_observations BEGIN
  INSERT INTO user_observations_fts (user_observations_fts, rowid, title, content) VALUES ('delete', OLD.id, OLD.title, OLD.content);
  INSERT INTO user_observations_fts (rowid, title, content) VALUES (NEW.id, NEW.title, NEW.content); END;

CREATE VIRTUAL TABLE IF NOT EXISTS reference_queries_fts USING fts5(name, description, sql_template, content='reference_queries', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS reference_queries_fts_ai AFTER INSERT ON reference_queries BEGIN
  INSERT INTO reference_queries_fts (rowid, name, description, sql_template) VALUES (NEW.id, NEW.name, NEW.description, NEW.sql_template); END;
CREATE TRIGGER IF NOT EXISTS reference_queries_fts_ad AFTER DELETE ON reference_queries BEGIN
  INSERT INTO reference_queries_fts (reference_queries_fts, rowid, name, description, sql_template) VALUES ('delete', OLD.id, OLD.name, OLD.description, OLD.sql_template); END;
CREATE TRIGGER IF NOT EXISTS reference_queries_fts_au AFTER UPDATE OF name, description, sql_template ON reference_queries BEGIN
  INSERT INTO reference_queries_fts (reference_queries_fts, rowid, name, description, sql_template) VALUES ('delete', OLD.id, OLD.name, OLD.description, OLD.sql_template);
  INSERT INTO reference_queries_fts (rowid, name, description, sql_template) VALUES (NEW.id, NEW.name, NEW.description, NEW.sql_template); END;

CREATE VIRTUAL TABLE IF NOT EXISTS code_entities_fts USING fts5(name, qualified_name, purpose, content='code_entities', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS code_entities_fts_ai AFTER INSERT ON code_entities BEGIN
  INSERT INTO code_entities_fts (rowid, name, qualified_name, purpose) VALUES (NEW.id, NEW.name, NEW.qualified_name, NEW.purpose); END;
CREATE TRIGGER IF NOT EXISTS code_entities_fts_ad AFTER DELETE ON code_entities BEGIN
  INSERT INTO code_entities_fts (code_entities_fts, rowid, name, qualified_name, purpose) VALUES ('delete', OLD.id, OLD.name, OLD.qualified_name, OLD.purpose); END;
CREATE TRIGGER IF NOT EXISTS code_entities_fts_au AFTER UPDATE OF name, qualified_name, purpose ON code_entities BEGIN
  INSERT INTO code_entities_fts (code_entities_fts, rowid, name, qualified_name, purpose) VALUES ('delete', OLD.id, OLD.name, OLD.qualified_name, OLD.purpose);
  INSERT INTO code_entities_fts (rowid, name, qualified_name, purpose) VALUES (NEW.id, NEW.name, NEW.qualified_name, NEW.purpose); END;

CREATE VIRTUAL TABLE IF NOT EXISTS transcript_messages_fts USING fts5(msg_text, content='transcript_messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS transcript_messages_fts_ai AFTER INSERT ON transcript_messages BEGIN
  INSERT INTO transcript_messages_fts (rowid, msg_text) VALUES (NEW.id, NEW.msg_text); END;
CREATE TRIGGER IF NOT EXISTS transcript_messages_fts_ad AFTER DELETE ON transcript_messages BEGIN
  INSERT INTO transcript_messages_fts (transcript_messages_fts, rowid, msg_text) VALUES ('delete', OLD.id, OLD.msg_text); END;
CREATE TRIGGER IF NOT EXISTS transcript_messages_fts_au AFTER UPDATE OF msg_text ON transcript_messages BEGIN
  INSERT INTO transcript_messages_fts (transcript_messages_fts, rowid, msg_text) VALUES ('delete', OLD.id, OLD.msg_text);
  INSERT INTO transcript_messages_fts (rowid, msg_text) VALUES (NEW.id, NEW.msg_text); END;

CREATE VIRTUAL TABLE IF NOT EXISTS behaviours_fts USING fts5(subject, statement, content='behaviours', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS behaviours_fts_ai AFTER INSERT ON behaviours BEGIN
  INSERT INTO behaviours_fts (rowid, subject, statement) VALUES (NEW.id, NEW.subject, NEW.statement); END;
CREATE TRIGGER IF NOT EXISTS behaviours_fts_ad AFTER DELETE ON behaviours BEGIN
  INSERT INTO behaviours_fts (behaviours_fts, rowid, subject, statement) VALUES ('delete', OLD.id, OLD.subject, OLD.statement); END;
CREATE TRIGGER IF NOT EXISTS behaviours_fts_au AFTER UPDATE OF subject, statement ON behaviours BEGIN
  INSERT INTO behaviours_fts (behaviours_fts, rowid, subject, statement) VALUES ('delete', OLD.id, OLD.subject, OLD.statement);
  INSERT INTO behaviours_fts (rowid, subject, statement) VALUES (NEW.id, NEW.subject, NEW.statement); END;
