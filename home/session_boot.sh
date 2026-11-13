#!/bin/bash
# session_boot.sh — One-command session startup for claude_memory (SQLite, via memdb)
# Usage: bash ~/.claude/session_boot.sh [--full] [working_directory]
# Returns: session_id, project context, recent work digest, behaviours, observations, limitations
# If working_directory not provided, uses current directory

# Headless pipeline guard: an automated worker (claude -p / codex exec run by a multi-agent pipeline)
# sets MAH_HEADLESS=1 and inherits it into this hook. Such workers must NOT boot a memory session:
# no human is there, and it only burns their limited turn. claude -p DOES fire SessionStart, so bail.
[ -n "$MAH_HEADLESS" ] && exit 0
# Maintenance-automation guard: headless passes over the memory database itself (the scheduled
# consolidation runner sets this) work ON the database but are not work sessions. Booting one
# created a session row that nothing ever closed.
[ -n "$CLAUDE_MEMORY_SKIP_BOOT" ] && exit 0

MEMDB="{{MEMDB_POSIX}}"

# Boot depth. Slim (default) creates the session row + minimal context so the
# automatic SessionStart hook stays cheap; --full also loads the complete
# memories/observations/limitations dump. In slim mode, query the DB (Rule 3)
# for the detail you need instead of loading everything up front.
FULL=0
if [ "$1" = "--full" ]; then FULL=1; shift; fi
WORK_DIR="${1:-$(pwd)}"

# Normalize path: backslashes to forward slashes, then convert Git Bash /c/... drive paths to c:/...
NORM_DIR=$(echo "$WORK_DIR" | sed 's|\\|/|g' | sed -E 's|^/([a-zA-Z])(/.*)?$|\1:\2|')
# Single quotes doubled for use inside SQL string literals (SQLite: backslashes are literal).
SQL_DIR=$(printf '%s' "$NORM_DIR" | sed "s/'/''/g")

run_sql() {
  "$MEMDB" -N -e "$1" 2>/dev/null
}

run_sql_with_headers() {
  "$MEMDB" -e "$1" 2>/dev/null
}

if ! "$MEMDB" -N -e "SELECT 1" >/dev/null 2>&1; then
  echo "=== claude_memory UNAVAILABLE: $("$MEMDB" -N -e "SELECT 1" 2>&1 | head -1) ==="
  echo "memdb: $MEMDB -- database: $("$MEMDB" --path 2>/dev/null)"
  exit 0
fi

# --- Step 1: Resolve project from working directory ---
# Try SVN-based matching first (works regardless of local path)
SVN_UUID=""
SVN_REL_URL=""
SVN_BRANCH=""
SVN_PROJECT_PATH=""

SVN_INFO=$(svn info "$WORK_DIR" 2>/dev/null)
if [ $? -eq 0 ]; then
  SVN_UUID=$(echo "$SVN_INFO" | grep "^Repository UUID:" | sed 's/Repository UUID: //')
  SVN_REL_URL=$(echo "$SVN_INFO" | grep "^Relative URL:" | sed 's/Relative URL: \^//')

  # Parse relative URL into project path and branch
  # Patterns: /ProjectName/trunk/..., /ProjectName/branches/name/..., /trunk/..., /branches/name/...
  if echo "$SVN_REL_URL" | grep -qE "^/[^/]+/trunk"; then
    SVN_PROJECT_PATH=$(echo "$SVN_REL_URL" | sed 's|^/\([^/]*\)/trunk.*|\1|')
    SVN_BRANCH="trunk"
  elif echo "$SVN_REL_URL" | grep -qE "^/[^/]+/branches/"; then
    SVN_PROJECT_PATH=$(echo "$SVN_REL_URL" | sed 's|^/\([^/]*\)/branches/.*|\1|')
    SVN_BRANCH=$(echo "$SVN_REL_URL" | sed 's|^/[^/]*/branches/\([^/]*\).*|\1|')
  elif echo "$SVN_REL_URL" | grep -qE "^/trunk"; then
    SVN_PROJECT_PATH=""
    SVN_BRANCH="trunk"
  elif echo "$SVN_REL_URL" | grep -qE "^/branches/"; then
    SVN_PROJECT_PATH=""
    SVN_BRANCH=$(echo "$SVN_REL_URL" | sed 's|^/branches/\([^/]*\).*|\1|')
  else
    # Could be /tags/ or something else — treat the first segment as project path
    SVN_PROJECT_PATH=$(echo "$SVN_REL_URL" | sed 's|^/\([^/]*\).*|\1|')
    SVN_BRANCH="unknown"
  fi
fi
SVN_BRANCH_SQL=$(printf '%s' "$SVN_BRANCH" | sed "s/'/''/g")

# Match by SVN UUID + project path
PROJECT_SLUG=""
if [ -n "$SVN_UUID" ]; then
  PROJECT_SLUG=$(run_sql "
    SELECT slug FROM projects WHERE is_active = 1
    AND svn_uuid = '$SVN_UUID'
    AND svn_project_path = '$(printf '%s' "$SVN_PROJECT_PATH" | sed "s/'/''/g")'
    LIMIT 1;")
fi

# Fallback: path-based matching (exact then longest prefix)
if [ -z "$PROJECT_SLUG" ]; then
  PROJECT_SLUG=$(run_sql "
    SELECT slug FROM projects WHERE is_active = 1
    AND REPLACE(LOWER(root_path), '\\', '/') = LOWER('$SQL_DIR')
    LIMIT 1;")
fi
if [ -z "$PROJECT_SLUG" ]; then
  PROJECT_SLUG=$(run_sql "
    SELECT slug FROM projects WHERE is_active = 1
    AND LOWER('$SQL_DIR') LIKE REPLACE(LOWER(root_path), '\\', '/') || '%'
    ORDER BY LENGTH(root_path) DESC LIMIT 1;")
fi

if [ -z "$PROJECT_SLUG" ]; then
  echo "=== PROJECT: none (working directory not matched) ==="
  echo "DIR: $WORK_DIR"
  PROJECT_ID="NULL"
else
  PROJECT_ID=$(run_sql "SELECT id FROM projects WHERE slug = '$PROJECT_SLUG';")
  echo "=== PROJECT: $PROJECT_SLUG (id=$PROJECT_ID) ==="
  if [ -n "$SVN_BRANCH" ]; then
    echo "BRANCH: $SVN_BRANCH"
  fi
fi

# --- Step 2: Close orphaned active sessions ---
ORPHANS=$(run_sql "SELECT COUNT(*) FROM sessions WHERE status = 'active';")
if [ "${ORPHANS:-0}" -gt 0 ]; then
  run_sql "UPDATE sessions SET status = 'abandoned', ended_at = now() WHERE status = 'active';"
  echo "Closed $ORPHANS orphaned session(s)"
fi

# --- Step 3: Create new session ---
# Claude Code sets CLAUDE_CODE_SESSION_ID to the session UUID (== transcript filename stem).
# Recording it links this DB session to its archived raw transcript (transcripts.session_uuid).
SESSION_UUID="${CLAUDE_CODE_SESSION_ID:-}"
case "$SESSION_UUID" in *[!0-9a-zA-Z-]*) SESSION_UUID="" ;; esac
if [ -n "$SESSION_UUID" ]; then SUID_SQL="'$SESSION_UUID'"; else SUID_SQL="NULL"; fi
if [ -n "$SVN_BRANCH" ]; then BRANCH_SQL="'$SVN_BRANCH_SQL'"; else BRANCH_SQL="NULL"; fi
SESSION_ID=$(run_sql "
  INSERT INTO sessions (project_id, session_uuid, branch, started_at)
  VALUES ($PROJECT_ID, $SUID_SQL, $BRANCH_SQL, now()) RETURNING id;")
echo "=== SESSION: $SESSION_ID ==="
echo ""

# --- Step 3b: Mechanical consolidation tier (~/.claude/consolidator/tier1_mechanical.sql) ---
# Replaces MySQL's hourly event: decay stale observations, expire past-TTL memories. The procedure
# does real work at most once a day, so every boot after the first one of the day is a no-op.
run_sql "CALL sp_consolidate_mechanical('boot-$(date +%Y%m%d)');" >/dev/null

# --- Step 4: Recent work (age-decayed digest, OptMem-style; ~/.claude/consolidator/digest.sql) ---
# One line per session, recent ones first; older work in rolled-up blocks [a-b] that the
# digest-zoom reference query opens. Sessions the consolidation pass has not digested yet
# show their note titles. -r keeps backslashes in lines (Windows paths) unescaped.
DIGEST_LINES=$(run_sql "SELECT cfg_value FROM consolidation_config WHERE cfg_key = 'digest_boot_lines';")
DIGEST_LINES="${DIGEST_LINES:-16}"
if [ "$PROJECT_ID" != "NULL" ]; then
  echo "=== RECENT WORK: $PROJECT_SLUG (newest first) ==="
  "$MEMDB" -N -r -e "CALL sp_digest_cover($PROJECT_ID, $DIGEST_LINES);" 2>/dev/null
else
  echo "=== RECENT WORK BY PROJECT (newest line of each) ==="
  "$MEMDB" -N -r -e "SELECT display FROM v_digest_project_heads ORDER BY at DESC LIMIT $((DIGEST_LINES / 2));" 2>/dev/null
  echo ""
  echo "=== RECENT WORK: no project (newest first) ==="
  "$MEMDB" -N -r -e "CALL sp_digest_cover(NULL, $((DIGEST_LINES / 2)));" 2>/dev/null
fi
echo ""

# --- Step 4b: Behaviours (every boot, slim or full) ---
# The current guidance the consolidation pass derives from memories: open conflicts first,
# then rules, then habits at or above behaviour_boot_min_strength. Small by design so it can
# load every session -- slim boot never surfaced preferences, so a standing rule could be broken
# repeatedly without the memory that stated it ever reaching context.
echo "=== BEHAVIOURS (current guidance; outranks older memories on the same subject) ==="
if [ -n "$PROJECT_SLUG" ]; then
  BEH_FILTER="WHERE project IS NULL OR project = '$PROJECT_SLUG'"
else
  BEH_FILTER="WHERE project IS NULL"
fi
BEHAVIOURS=$(run_sql_with_headers "
  SELECT kind, strength, status, subject, statement, IFNULL(conflict_note, '') AS conflict_note
  FROM v_behaviours_boot $BEH_FILTER
  ORDER BY (status = 'conflict') DESC, (kind = 'rule') DESC, strength DESC, subject;")
if [ -n "$BEHAVIOURS" ]; then
  echo "$BEHAVIOURS"
else
  echo "none yet"
fi
echo ""

# --- Steps 5-7: full memory context (loaded only with --full) ---
if [ "$FULL" = "1" ]; then

# --- Step 5: Global + project memories ---
echo "=== MEMORIES ==="
if [ "$PROJECT_ID" != "NULL" ]; then
  run_sql_with_headers "
    SELECT id, memory_type, category, title, LEFT(content, 100) AS content
    FROM memories
    WHERE is_active = 1 AND (expires_at IS NULL OR expires_at > now())
      AND (project_id IS NULL OR project_id = $PROJECT_ID)
    ORDER BY priority ASC, memory_type, category;"
else
  run_sql_with_headers "
    SELECT id, memory_type, category, title, LEFT(content, 100) AS content
    FROM memories
    WHERE is_active = 1 AND project_id IS NULL
      AND (expires_at IS NULL OR expires_at > now())
    ORDER BY priority ASC, memory_type, category;"
fi
echo ""

# --- Step 6: User observations ---
echo "=== OBSERVATIONS ==="
run_sql_with_headers "
  SELECT category, title, content, confidence, observed_count
  FROM user_observations
  WHERE is_active = 1 AND confidence >= 0.50
  ORDER BY confidence DESC;"
echo ""

# --- Step 7: Limitations ---
echo "=== LIMITATIONS ==="
run_sql_with_headers "
  SELECT id, title, LEFT(content, 150) AS content
  FROM memories
  WHERE category = 'limitation' AND is_active = 1;"
echo ""

else
  echo "=== MEMORIES / OBSERVATIONS / LIMITATIONS: not loaded (slim boot) ==="
  echo "Query the memories table for relevant items BEFORE decisions (Rule 3),"
  echo "or run: bash ~/.claude/session_boot.sh --full"
  echo ""
fi

# --- Step 8: Consolidation status ---
# The judgment pass (consolidate-memory-db; the optional ClaudeMemoryConsolidation task runs it
# every 3h) records every action in consolidation_log. The daily mechanical pass (mechanical_run,
# decay_observation) is not a judgment pass, so it does not count. Notes the pass deferred carry
# last_reviewed and are skipped for review_interval_days: they are counted apart from notes due.
# NEEDED = notes are due and the last pass is 6h+ old (two scheduled runs missed), or none ever ran.
IFS=$'\t' read -r LAST_CONSOL CONSOL_AGE NOTES_DUE NOTES_HELD <<< "$(run_sql "
  WITH last AS (
    SELECT MAX(created_at) AS at FROM consolidation_log
    WHERE dry_run = 0 AND reverted = 0
      AND action NOT IN ('mechanical_run', 'decay_observation', 'error')
  ), cfg AS (
    SELECT COALESCE((SELECT CAST(cfg_value AS INTEGER) FROM consolidation_config
                     WHERE cfg_key = 'review_interval_days'), 30) AS days
  )
  SELECT COALESCE(strftime('%Y-%m-%d %H:%M', last.at), 'never'),
         COALESCE(CAST((julianday(now()) - julianday(last.at)) * 24 AS INTEGER), -1),
         (SELECT COUNT(*) FROM session_notes WHERE is_consolidated = 0
            AND (last_reviewed IS NULL OR last_reviewed < datetime(now(), '-' || cfg.days || ' days'))),
         (SELECT COUNT(*) FROM session_notes WHERE is_consolidated = 0
            AND last_reviewed >= datetime(now(), '-' || cfg.days || ' days'))
  FROM last, cfg;")"
LAST_CONSOL=${LAST_CONSOL:-never}
if [ "$LAST_CONSOL" = "never" ]; then CONSOL_WHEN="never"; else CONSOL_WHEN="$LAST_CONSOL (${CONSOL_AGE}h ago)"; fi
if [ "$LAST_CONSOL" = "never" ] || { [ "${NOTES_DUE:-0}" -gt 0 ] && [ "${CONSOL_AGE:-0}" -ge 6 ]; }; then
  echo "=== CONSOLIDATION NEEDED: last judgment pass $CONSOL_WHEN; ${NOTES_DUE:-?} notes due, ${NOTES_HELD:-?} deferred ==="
else
  echo "=== CONSOLIDATION: last judgment pass $CONSOL_WHEN; ${NOTES_DUE:-?} notes due, ${NOTES_HELD:-?} deferred ==="
fi

# --- Step 8b: Memory confirmation (~/.claude/consolidator/confirm.sql) ---
# New memories are drafts until the consolidation pass has checked them against their transcript.
CONFIRM=$(run_sql "
  SELECT COUNT(*) || ' unconfirmed: ' || COALESCE(SUM(status = 'ready'), 0) || ' ready to check, ' ||
         COALESCE(SUM(status = 'waiting'), 0) || ' waiting for their transcript, ' ||
         COALESCE(SUM(status = 'no_source'), 0) || ' with no source to check against'
  FROM v_confirm_worklist;")
echo "=== MEMORY CONFIRMATION: $CONFIRM ==="

echo ""

# --- Step 9: Transcript archive (lossless raw record, full-text searchable) ---
TX_COUNT=$(run_sql "SELECT COUNT(*) FROM transcripts;")
echo "=== TRANSCRIPTS: $TX_COUNT archived (full-text searchable) ==="
echo "Recall prior work with the 'recall' skill (/recall <topic>) -- wraps search-transcripts / read-transcript-context / resolve-memory-sources over the archive."
echo ""

echo "=== RULES (follow every response) ==="
echo "- ALL storage goes to the database. NEVER write to .md files for memory/context/notes."
echo "- BEFORE decisions: query memories table for relevant preferences and past work."
echo "- DURING work: write session_notes in real time (memory skill). UPDATE code_entities after edits."
echo "- AFTER edits: UPDATE code_entities signatures, purposes, dependencies in the DB."
echo "- Store user preferences in memories table. Ask permission first, then write them."
echo "- When the user expresses something preferential, offer to save it as a memory."
echo "- NEVER rely on conversation context alone — query the database to verify."
echo "- BEHAVIOURS above are the current guidance. NEVER edit or deactivate a memory to change behaviour: record a newer memory and let the consolidation pass supersede the old one. A behaviour in conflict is {{USER_NAME}}'s to settle -- raise it, do not pick a side."
echo "- RECALL past work with the 'recall' skill (/recall <topic>): when the user references a prior discussion/decision, it full-text searches transcripts + notes and returns the verbatim exchange with back-pointers -- do this BEFORE reconstructing from memory."
echo "- Session ID for this session: $SESSION_ID"
