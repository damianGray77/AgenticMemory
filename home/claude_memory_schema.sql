CREATE DATABASE IF NOT EXISTS `{{DB_NAME}}`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE `{{DB_NAME}}`;

CREATE TABLE IF NOT EXISTS `projects` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `slug`            VARCHAR(100)    NOT NULL,
  `name`            VARCHAR(255)    NOT NULL,
  `root_path`       VARCHAR(500)    NOT NULL,
  `svn_uuid`        VARCHAR(50)     NULL COMMENT 'SVN repository UUID for path-independent matching',
  `svn_project_path` VARCHAR(255)   NULL COMMENT 'Project path within SVN repo (e.g. FlexWebsite, iCafe)',
  `primary_language` VARCHAR(50)    NULL,
  `framework`       VARCHAR(100)    NULL,
  `description`     TEXT            NULL,
  `last_scan_at`    DATETIME        NULL,
  `last_scan_commit` VARCHAR(50)    NULL,
  `is_active`       TINYINT(1)      NOT NULL DEFAULT 1,
  `created_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_projects_slug` (`slug`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `sessions` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `project_id`      INT UNSIGNED    NULL,
  `session_uuid`    VARCHAR(64)     NULL COMMENT 'Claude Code session UUID (transcript filename stem)',
  `branch`          VARCHAR(255)    NULL COMMENT 'SVN branch name (trunk, or branch folder name)',
  `status`          ENUM('active','completed','abandoned') NOT NULL DEFAULT 'active',
  `started_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `ended_at`        DATETIME        NULL,
  `summary`         TEXT            NULL,
  `files_touched`   JSON            NULL,
  `topics`          JSON            NULL,
  PRIMARY KEY (`id`),
  KEY `ix_sessions_project` (`project_id`, `started_at`),
  KEY `ix_sessions_status` (`status`, `started_at`),
  KEY `ix_sessions_uuid` (`session_uuid`),
  CONSTRAINT `fk_sessions_project` FOREIGN KEY (`project_id`)
    REFERENCES `projects` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `session_notes` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `session_id`      INT UNSIGNED    NOT NULL,
  `note_type`       VARCHAR(50)     NOT NULL COMMENT 'decision, attempt, discovery, blocker, context, milestone',
  `title`           VARCHAR(255)    NOT NULL,
  `content`         TEXT            NOT NULL,
  `created_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `is_consolidated` TINYINT(1)      NOT NULL DEFAULT 0,
  `last_reviewed`   DATETIME        NULL COMMENT 'Consolidator reviewed+kept (defer) at this time; excluded from re-read for review_interval_days',
  PRIMARY KEY (`id`),
  KEY `ix_notes_session` (`session_id`, `note_type`),
  KEY `ix_notes_unconsolidated` (`is_consolidated`, `note_type`),
  KEY `ix_notes_consolidation` (`is_consolidated`, `created_at`),
  FULLTEXT KEY `ft_notes` (`title`, `content`),
  CONSTRAINT `fk_notes_session` FOREIGN KEY (`session_id`)
    REFERENCES `sessions` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `memories` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `project_id`      INT UNSIGNED    NULL,
  `memory_type`     ENUM('user','feedback','project','reference') NOT NULL,
  `category`        VARCHAR(100)    NULL,
  `title`           VARCHAR(255)    NOT NULL,
  `content`         TEXT            NOT NULL,
  `source_session`  INT UNSIGNED    NULL,
  `is_active`       TINYINT(1)      NOT NULL DEFAULT 1,
  -- Confirmation (S1663, 2026-11-02; ~/.claude/consolidator/confirm.sql): a new memory is a draft the
  -- consolidation pass checks against its source transcript, correcting it only to make it faithful;
  -- once confirmed it is the append-only record. Memories older than 48h at setup were backfilled.
  `confirmed`       TINYINT(1)      NOT NULL DEFAULT 0
    COMMENT '0 = draft, checked against its transcript by the consolidation pass; 1 = append-only record',
  `confirm_outcome` ENUM('backfill','faithful','corrected','no_source') NULL,
  `confirm_checked_at` DATETIME     NULL,
  `priority`        TINYINT UNSIGNED DEFAULT 3,
  `expires_at`      DATETIME        NULL,
  `last_accessed_at` DATETIME       NULL,
  `created_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `ix_memories_project_type` (`project_id`, `memory_type`, `is_active`),
  KEY `ix_memories_type_category` (`memory_type`, `category`, `is_active`),
  KEY `ix_memories_project_category` (`project_id`, `category`, `is_active`),
  KEY `ix_memories_confirm` (`confirmed`, `is_active`),
  FULLTEXT KEY `ft_memories_content` (`title`, `content`),
  CONSTRAINT `fk_memories_project` FOREIGN KEY (`project_id`)
    REFERENCES `projects` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_memories_session` FOREIGN KEY (`source_session`)
    REFERENCES `sessions` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `source_files` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `project_id`      INT UNSIGNED    NOT NULL,
  `relative_path`   VARCHAR(500)    NOT NULL,
  `file_type`       VARCHAR(20)     NOT NULL,
  `line_count`      INT UNSIGNED    NULL,
  `purpose`         VARCHAR(500)    NULL,
  `file_hash`       VARCHAR(64)     NULL,
  `last_scanned_at` DATETIME        NULL,
  `is_deleted`      TINYINT(1)      NOT NULL DEFAULT 0,
  `created_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_source_files_path` (`project_id`, `relative_path`),
  KEY `ix_source_files_type` (`project_id`, `file_type`),
  KEY `ix_source_files_active` (`project_id`, `is_deleted`, `relative_path`),
  CONSTRAINT `fk_source_files_project` FOREIGN KEY (`project_id`)
    REFERENCES `projects` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `code_entities` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `file_id`         INT UNSIGNED    NOT NULL,
  `parent_entity_id` INT UNSIGNED   NULL,
  `entity_kind`     VARCHAR(50)     NOT NULL,
  `name`            VARCHAR(255)    NOT NULL,
  `qualified_name`  VARCHAR(500)    NULL,
  `signature`       VARCHAR(1000)   NULL,
  `line_start`      INT UNSIGNED    NULL,
  `line_end`        INT UNSIGNED    NULL,
  `visibility`      ENUM('public','private','protected','internal','export','default') NULL,
  `is_static`       TINYINT(1)      NULL,
  `purpose`         VARCHAR(500)    NULL,
  `last_scanned_at` DATETIME        NULL,
  `is_deleted`      TINYINT(1)      NOT NULL DEFAULT 0,
  `created_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `ix_entities_file` (`file_id`),
  KEY `ix_entities_file_active` (`file_id`, `is_deleted`),
  KEY `ix_entities_file_kind_line` (`file_id`, `entity_kind`, `line_start`),
  KEY `ix_entities_kind` (`entity_kind`, `name`),
  KEY `ix_entities_parent` (`parent_entity_id`),
  FULLTEXT KEY `ft_entities_name` (`name`, `qualified_name`, `purpose`),
  CONSTRAINT `fk_entities_file` FOREIGN KEY (`file_id`)
    REFERENCES `source_files` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_entities_parent` FOREIGN KEY (`parent_entity_id`)
    REFERENCES `code_entities` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `contextual_markers` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `marker`          VARCHAR(100)    NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_markers_marker` (`marker`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `entity_markers` (
  `entity_id`       INT UNSIGNED    NOT NULL,
  `marker_id`       INT UNSIGNED    NOT NULL,
  `confidence`      DECIMAL(3,2)    NOT NULL DEFAULT 1.00,
  PRIMARY KEY (`entity_id`, `marker_id`),
  KEY `ix_entity_markers_marker` (`marker_id`),
  CONSTRAINT `fk_em_entity` FOREIGN KEY (`entity_id`)
    REFERENCES `code_entities` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_em_marker` FOREIGN KEY (`marker_id`)
    REFERENCES `contextual_markers` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `file_markers` (
  `file_id`         INT UNSIGNED    NOT NULL,
  `marker_id`       INT UNSIGNED    NOT NULL,
  `confidence`      DECIMAL(3,2)    NOT NULL DEFAULT 1.00,
  PRIMARY KEY (`file_id`, `marker_id`),
  KEY `ix_file_markers_marker` (`marker_id`),
  CONSTRAINT `fk_fm_file` FOREIGN KEY (`file_id`)
    REFERENCES `source_files` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_fm_marker` FOREIGN KEY (`marker_id`)
    REFERENCES `contextual_markers` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `entity_dependencies` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `caller_id`       INT UNSIGNED    NOT NULL,
  `callee_id`       INT UNSIGNED    NOT NULL,
  `dependency_type` ENUM('calls','imports','extends','implements','uses','hooks','overrides')
                                    NOT NULL DEFAULT 'calls',
  `line_reference`  INT UNSIGNED    NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_deps_pair` (`caller_id`, `callee_id`, `dependency_type`),
  KEY `ix_deps_callee` (`callee_id`),
  KEY `ix_deps_type` (`dependency_type`),
  CONSTRAINT `fk_deps_caller` FOREIGN KEY (`caller_id`)
    REFERENCES `code_entities` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_deps_callee` FOREIGN KEY (`callee_id`)
    REFERENCES `code_entities` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `user_observations` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `category`        VARCHAR(50)     NOT NULL COMMENT 'free-form: rapport, workstyle, crossproject, communication, etc.',
  `title`           VARCHAR(255)    NOT NULL,
  `content`         TEXT            NOT NULL,
  `observed_count`  INT UNSIGNED    NOT NULL DEFAULT 1,
  `confidence`      DECIMAL(3,2)    NOT NULL DEFAULT 0.50,
  `first_seen`      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `last_seen`       DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `is_active`       TINYINT(1)      NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_obs_title` (`title`),
  KEY `ix_obs_active_conf` (`is_active`, `confidence`),
  FULLTEXT KEY `ft_obs` (`title`, `content`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `reference_queries` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `name`            VARCHAR(100)    NOT NULL COMMENT 'short lookup key e.g. blast-radius, find-entity',
  `description`     VARCHAR(255)    NOT NULL,
  `sql_template`    TEXT            NOT NULL COMMENT 'SQL with <placeholders> for substitution',
  `category`        VARCHAR(50)     NOT NULL DEFAULT 'query' COMMENT 'query, scanner, enrichment, maintenance',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_refq_name` (`name`),
  FULLTEXT KEY `ft_refq` (`name`, `description`, `sql_template`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `file_dependencies` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `source_file_id`  INT UNSIGNED    NOT NULL,
  `target_file_id`  INT UNSIGNED    NOT NULL,
  `dependency_type` VARCHAR(50)     NOT NULL DEFAULT 'imports',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_file_deps` (`source_file_id`, `target_file_id`, `dependency_type`),
  KEY `ix_file_deps_target` (`target_file_id`),
  CONSTRAINT `fk_fdeps_source` FOREIGN KEY (`source_file_id`)
    REFERENCES `source_files` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_fdeps_target` FOREIGN KEY (`target_file_id`)
    REFERENCES `source_files` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- Transcript retention (lossless raw record) + back-pointers.
-- Applied directly to the live DB; maintained here in place (no migration
-- files for this DB — a mysqldump copy is the cross-device mechanism).
-- INVARIANT: transcripts.id is stable across re-ingest of a grown jsonl —
-- archive_transcripts.ps1 upserts the row in place (keyed on uq_transcript_path,
-- 1:1 with session_uuid since the file basename IS the uuid). Ingest must never
-- DELETE+reinsert a transcripts row: fk_src_transcript ON DELETE CASCADE would
-- silently destroy memory_sources back-pointers (bug fixed 2026-06-10).
-- SERVER REQUIREMENT: max_allowed_packet = 1G (set 2026-11-02 with SET PERSIST,
-- which overrides my.ini's 64M). UNCOMPRESS(raw_jsonl) returns NULL when the
-- uncompressed transcript is larger than max_allowed_packet, and the largest
-- transcript is 233 MB. A server restored from a mysqldump copy needs the same
-- setting, and the dump/restore client needs --max-allowed-packet=1G.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `transcripts` (
  `id`                  INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `project_id`          INT UNSIGNED    NULL,
  `session_id`          INT UNSIGNED    NULL COMMENT 'DB session this transcript belongs to (via CLAUDE_CODE_SESSION_ID)',
  `session_uuid`        VARCHAR(64)     NOT NULL COMMENT 'Claude Code session UUID (transcript filename stem)',
  `kind`                ENUM('main','subagent') NOT NULL DEFAULT 'main',
  `parent_session_uuid` VARCHAR(64)     NULL COMMENT 'For subagent transcripts: the parent session UUID',
  `source_path`         VARCHAR(700)    NOT NULL COMMENT 'Original on-disk path of the .jsonl',
  `raw_jsonl`           LONGBLOB        NOT NULL COMMENT 'Verbatim transcript bytes; zlib via COMPRESS() when is_compressed=1',
  `is_compressed`       TINYINT(1)      NOT NULL DEFAULT 1,
  `content_sha256`      CHAR(64)        NOT NULL COMMENT 'SHA-256 of raw (uncompressed) bytes — change detection / idempotent re-sweep',
  `byte_size`           BIGINT          NOT NULL COMMENT 'Uncompressed byte size',
  `line_count`          INT             NOT NULL,
  `message_count`       INT             NOT NULL COMMENT 'Count of indexed user/assistant messages',
  `first_message_at`    DATETIME        NULL,
  `last_message_at`     DATETIME        NULL,
  `captured_at`         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_transcript_path` (`source_path`),
  KEY `ix_transcript_session_uuid` (`session_uuid`),
  KEY `ix_transcript_sha` (`content_sha256`),
  CONSTRAINT `fk_transcript_project` FOREIGN KEY (`project_id`)
    REFERENCES `projects` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_transcript_session` FOREIGN KEY (`session_id`)
    REFERENCES `sessions` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `transcript_messages` (
  `id`              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  `transcript_id`   INT UNSIGNED    NOT NULL,
  `seq`             INT             NOT NULL COMMENT 'Ordinal position of the message within the transcript',
  `message_uuid`    VARCHAR(64)     NOT NULL COMMENT 'Stable per-message anchor (the back-pointer target)',
  `parent_uuid`     VARCHAR(64)     NULL,
  `role`            VARCHAR(20)     NULL COMMENT 'user, assistant, etc.',
  `byte_offset`     BIGINT          NOT NULL COMMENT 'Offset of this line in the UNCOMPRESSED raw_jsonl',
  `byte_length`     INT             NOT NULL,
  `line_number`     INT             NOT NULL,
  `ts`              DATETIME        NULL,
  `msg_text`        MEDIUMTEXT      NULL COMMENT 'Extracted human-readable text for FULLTEXT retrieval',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_msg` (`transcript_id`, `message_uuid`),
  KEY `ix_msg_uuid` (`message_uuid`),
  FULLTEXT KEY `ft_msg` (`msg_text`),
  CONSTRAINT `fk_msg_transcript` FOREIGN KEY (`transcript_id`)
    REFERENCES `transcripts` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `memory_sources` (
  `id`                 INT UNSIGNED   NOT NULL AUTO_INCREMENT,
  `source_type`        ENUM('memory','session_note') NOT NULL,
  `memory_id`          INT UNSIGNED   NULL,
  `note_id`            INT UNSIGNED   NULL,
  `transcript_id`      INT UNSIGNED   NOT NULL,
  `start_message_uuid` VARCHAR(64)    NOT NULL COMMENT 'First message of the source span',
  `end_message_uuid`   VARCHAR(64)    NULL COMMENT 'Last message of the span; NULL = single message',
  `rationale`          VARCHAR(500)   NULL,
  `created_at`         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `ix_src_memory` (`memory_id`),
  KEY `ix_src_note` (`note_id`),
  KEY `ix_src_transcript` (`transcript_id`),
  CONSTRAINT `fk_src_transcript` FOREIGN KEY (`transcript_id`)
    REFERENCES `transcripts` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_src_memory` FOREIGN KEY (`memory_id`)
    REFERENCES `memories` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_src_note` FOREIGN KEY (`note_id`)
    REFERENCES `session_notes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Mailbox for the claude-bridge MCP server: two-way message passing between
-- Claude Desktop (peer 'chat') and Claude Code (peer 'code'). Not part of the
-- memory model proper; it is the transport store for the bridge tool.
CREATE TABLE IF NOT EXISTS `bridge_messages` (
  `id`         BIGINT         NOT NULL AUTO_INCREMENT,
  `sender`     VARCHAR(16)    NOT NULL COMMENT 'Originating peer: code | chat',
  `recipient`  VARCHAR(16)    NOT NULL DEFAULT 'any' COMMENT 'Target peer: code | chat | any',
  `topic`      VARCHAR(255)   NULL COMMENT 'Optional subject to group related messages',
  `content`    MEDIUMTEXT     NOT NULL,
  `created_at` DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `read_at`    DATETIME       NULL COMMENT 'When the recipient consumed it; NULL = unread',
  PRIMARY KEY (`id`),
  KEY `idx_inbox` (`recipient`, `read_at`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='MCP bridge mailbox between Claude Desktop (chat) and Claude Code (code)';

-- ---------------------------------------------------------------------------
-- Autonomous consolidation (S176): config/kill-switch + reversible audit log.
-- The mechanical tier (sp_consolidate_mechanical + worklist views) and the
-- judgment skill live in ~/.claude/consolidator/; these two tables are the
-- rails everything writes through. Applied live; mirrored here in place.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `consolidation_config` (
  `cfg_key`    VARCHAR(64)   NOT NULL,
  `cfg_value`  VARCHAR(255)  NOT NULL,
  `note`       VARCHAR(255)  NULL,
  `updated_at` DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`cfg_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Kill switch (enabled), dry_run, and thresholds for the consolidation pass';

CREATE TABLE IF NOT EXISTS `consolidation_log` (
  `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `run_id`       VARCHAR(40)     NOT NULL,
  `action`       VARCHAR(40)     NOT NULL COMMENT 'decay_observation, expire_memory, promote_note, merge_memory, normalize_category, add_backpointer, skipped',
  `target_table` VARCHAR(40)     NULL,
  `target_id`    INT UNSIGNED    NULL,
  `before_json`  JSON            NULL COMMENT 'Prior state, for reversibility',
  `after_json`   JSON            NULL,
  `reason`       VARCHAR(500)    NULL,
  `dry_run`      TINYINT(1)      NOT NULL DEFAULT 0,
  `reverted`     TINYINT(1)      NOT NULL DEFAULT 0,
  `reverted_at`  DATETIME        NULL,
  `created_at`   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_run` (`run_id`),
  KEY `idx_action` (`action`),
  KEY `idx_target` (`target_table`, `target_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Reversible audit log of every consolidation action (proposed or applied)';

-- ---------------------------------------------------------------------------
-- Behaviours (S1576, 2026-10-13): the current guidance DERIVED from memories.
-- Memories are an append-only record of what happened and are never edited to
-- change behaviour; a behaviour is what to do now, worked out from all of the
-- evidence linked to it. Written only by the consolidation pass, through the
-- sp_* procedures in ~/.claude/consolidator/behaviours.sql, which also holds
-- the views that compute strength and the seed rows for these tables.
--   RULE  = at least one live piece of evidence at or above
--           behaviour_rule_threshold ({{USER_NAME}} said it, approved it, or corrected
--           me). That evidence never decays; only a newer statement replaces it.
--   HABIT = everything weaker. Each piece fades with a half-life of
--           behaviour_habit_half_life_days; seeing it again adds fresh evidence.
--   strength = 1 - PRODUCT(1 - w) over live supporting events (noisy-OR):
--           each independent event closes part of the remaining gap to 1.00.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `behaviour_evidence_kinds` (
  `kind`          VARCHAR(40)   NOT NULL,
  `anchor_weight` DECIMAL(3,2)  NOT NULL COMMENT 'Base weight; a link may move off it by behaviour_weight_tolerance for emphasis',
  `description`   VARCHAR(255)  NOT NULL,
  PRIMARY KEY (`kind`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='The weight scale: where a piece of evidence came from, and what it is worth';

CREATE TABLE IF NOT EXISTS `behaviours` (
  `id`               INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  `subject`          VARCHAR(100)  NOT NULL COMMENT 'Dotted lowercase key, e.g. tooling.scripting-languages',
  `project_id`       INT UNSIGNED  NULL COMMENT 'NULL = global',
  `scope_project_id` INT UNSIGNED  AS (IFNULL(`project_id`, 0)) STORED COMMENT 'Lets a global subject be unique; NULLs never collide in a UNIQUE key',
  `statement`        TEXT          NOT NULL COMMENT 'The current guidance, in a sentence or two',
  `kind`             ENUM('rule','habit') NOT NULL DEFAULT 'habit' COMMENT 'Computed by sp_resolve_behaviour',
  `strength`         DECIMAL(4,3)  NOT NULL DEFAULT 0.000 COMMENT 'Computed by sp_resolve_behaviour; snapshot as of resolved_at',
  `status`           ENUM('active','conflict','retired') NOT NULL DEFAULT 'active',
  `conflict_note`    VARCHAR(500)  NULL,
  `resolved_at`      DATETIME      NULL,
  `resolved_run_id`  VARCHAR(40)   NULL,
  `created_at`       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_behaviour_subject` (`subject`, `scope_project_id`),
  KEY `ix_behaviour_boot` (`status`, `kind`, `strength`),
  FULLTEXT KEY `ft_behaviour` (`subject`, `statement`),
  -- No ON DELETE action: MySQL forbids CASCADE / SET NULL on the base column of a
  -- stored generated column. Projects are soft-deleted (is_active), so RESTRICT is fine.
  CONSTRAINT `fk_behaviour_project` FOREIGN KEY (`project_id`)
    REFERENCES `projects` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Current guidance derived from memories; one row per subject';

CREATE TABLE IF NOT EXISTS `behaviour_evidence` (
  `id`            INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  `behaviour_id`  INT UNSIGNED  NOT NULL,
  `source_type`   ENUM('memory','observation','session_note') NOT NULL,
  `source_id`     INT UNSIGNED  NOT NULL COMMENT 'memories.id / user_observations.id / session_notes.id',
  `evidence_kind` VARCHAR(40)   NOT NULL,
  `weight`        DECIMAL(3,2)  NOT NULL COMMENT 'Base weight: the anchor for its kind, +/- behaviour_weight_tolerance',
  `stance`        ENUM('supports','opposes') NOT NULL DEFAULT 'supports',
  `occurred_at`   DATETIME      NOT NULL COMMENT 'When it happened, not when it was linked; drives decay and supersession',
  `event_key`     VARCHAR(100)  NOT NULL COMMENT 'The real-world event; rows sharing one count once per behaviour (a note, memory and observation of one correction)',
  `superseded_by` INT UNSIGNED  NULL COMMENT 'The newer evidence row that replaced this one; this row is kept',
  `rationale`     VARCHAR(500)  NULL,
  `run_id`        VARCHAR(40)   NULL,
  `created_at`    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_evidence` (`behaviour_id`, `event_key`, `source_type`, `source_id`),
  KEY `ix_evidence_source` (`source_type`, `source_id`),
  KEY `ix_evidence_superseded` (`superseded_by`),
  CONSTRAINT `fk_evidence_behaviour` FOREIGN KEY (`behaviour_id`)
    REFERENCES `behaviours` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_evidence_kind` FOREIGN KEY (`evidence_kind`)
    REFERENCES `behaviour_evidence_kinds` (`kind`) ON UPDATE CASCADE,
  CONSTRAINT `fk_evidence_superseded` FOREIGN KEY (`superseded_by`)
    REFERENCES `behaviour_evidence` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Links each behaviour to the memories, observations and notes it is derived from';

-- Which sources the consolidation pass has already considered, including those
-- that bear on no behaviour, so v_behaviour_worklist does not re-read them every
-- run. A memory edited (or an observation seen again) after its review is queued again.
CREATE TABLE IF NOT EXISTS `behaviour_source_reviews` (
  `source_type` ENUM('memory','observation','session_note') NOT NULL,
  `source_id`   INT UNSIGNED  NOT NULL,
  `reviewed_at` DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `run_id`      VARCHAR(40)   NULL,
  `outcome`     VARCHAR(255)  NULL COMMENT 'What the pass decided, e.g. linked to workflow.file-edits, or no behaviour',
  PRIMARY KEY (`source_type`, `source_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Sources the behaviour step has reviewed, so it only reads new or changed ones';

-- ---------------------------------------------------------------------------
-- Recent-work digest (S1613, 2026-10-20): an OptMem-style merge tree over
-- sessions, one tree per project plus one for sessions with no project.
-- A LEAF (level 0) is one line for one finished session, numbered per project in
-- the order the consolidation pass writes them. A BLOCK at level k rolls up the
-- 2^k leaves from seq_lo into one line, written once both halves exist. Session
-- boot prints an age-decayed cover of the tree (sp_digest_cover): recent sessions
-- one line each, older work in progressively larger blocks. Leaves are append-only;
-- blocks are a cache that sp_digest_forget drops and the next pass rebuilds.
-- Views and procedures: ~/.claude/consolidator/digest.sql.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `digest_lines` (
  `id`               INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  `project_id`       INT UNSIGNED      NULL COMMENT 'NULL = the no-project stream',
  `scope_project_id` INT UNSIGNED      AS (IFNULL(`project_id`, 0)) STORED COMMENT 'Lets the no-project stream be unique; NULLs never collide in a UNIQUE key',
  `level`            TINYINT UNSIGNED  NOT NULL COMMENT '0 = one session; k = a block of 2^k leaves',
  `seq_lo`           INT UNSIGNED      NOT NULL COMMENT 'First leaf position covered; a multiple of 2^level',
  `session_id`       INT UNSIGNED      NULL COMMENT 'Level 0 only: the session the line describes',
  `first_session_id` INT UNSIGNED      NOT NULL,
  `last_session_id`  INT UNSIGNED      NOT NULL,
  `session_count`    SMALLINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'Distinct sessions covered; a resumed session can have two leaves',
  `first_at`         DATETIME          NOT NULL COMMENT 'Start of the earliest session covered (local time)',
  `last_at`          DATETIME          NOT NULL COMMENT 'Last activity covered, notes or transcript (local time)',
  `line`             VARCHAR(255)      NOT NULL,
  `run_id`           VARCHAR(40)       NULL,
  `created_at`       DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_digest_block` (`scope_project_id`, `level`, `seq_lo`),
  KEY `ix_digest_session` (`session_id`),
  -- No ON DELETE action on project_id: it is the base column of a stored generated column.
  CONSTRAINT `fk_digest_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`),
  CONSTRAINT `fk_digest_session` FOREIGN KEY (`session_id`) REFERENCES `sessions` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Recent-work digest: one line per session, rolled up into aligned power-of-two blocks';

-- Which sessions the digest step has read, and up to when. A session that gets
-- new notes or transcript messages after reviewed_until is queued again, so a
-- resumed session gets a second leaf for the new work.
CREATE TABLE IF NOT EXISTS `digest_session_reviews` (
  `session_id`     INT UNSIGNED  NOT NULL,
  `reviewed_until` DATETIME      NOT NULL COMMENT 'Activity up to here is covered (local time)',
  `outcome`        VARCHAR(255)  NULL COMMENT 'leaf <seq>, or skipped: <why>',
  `run_id`         VARCHAR(40)   NULL,
  `reviewed_at`    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`session_id`),
  CONSTRAINT `fk_digest_review_session` FOREIGN KEY (`session_id`) REFERENCES `sessions` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Sessions the digest step has read, so it only reads new or changed ones';
