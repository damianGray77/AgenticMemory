#!/bin/bash
# claude_scanner.sh v3 - Fast project scanner for the claude_memory database
# Uses project-wide grep passes instead of per-file extraction.
# Designed for Windows (Git Bash) + the SQLite memory database, driven through memdb.exe.
#
# Usage (run without arguments for the full list):
#   ./claude_scanner.sh scan <project-slug>
#   ./claude_scanner.sh scan-all
#   ./claude_scanner.sh onboard <slug> <name> <path> [language] [framework] [desc]
#   ./claude_scanner.sh update <project-slug> [--file <relative-path>]
#   ./claude_scanner.sh deps <project-slug>
#   ./claude_scanner.sh status [project-slug]
#   ./claude_scanner.sh reset <project-slug>

set -uo pipefail

# memdb finds the database itself (--db, else $CLAUDE_MEMORY_DB, else ..\claude_memory.db
# next to its bin folder), so no path or credentials are passed here.
MEMDB="{{MEMDB_POSIX}}"
SQL_FILE=""

# One query; tab-separated rows without a header. memdb escapes tab, newline and backslash
# inside values as \t \n \\ (so a stored C:\path comes back as C:\\path; win_to_unix copes).
memdb_exec() {
  "$MEMDB" -N -B -e "$1" 2>/dev/null | tr -d '\r'
}

# A generated SQL script, fed on stdin. memdb stops at the first failing statement and exits 1;
# the scripts below run inside BEGIN ... COMMIT, so a failure leaves the database unchanged.
memdb_batch() {
  "$MEMDB" < "$1" 2>&1
}

win_to_unix() {
  echo "$1" | tr '\\' '/' | awk '{sub(/^[A-Za-z]:/, "/" tolower(substr($0,1,1))); print}'
}

# Body of an SQLite string literal: double each single quote. A backslash is an ordinary
# character in SQLite, so Windows paths and regexes are stored exactly as written.
escape_sql() {
  printf '%s' "$1" | sed "s/'/''/g"
}

emit() {
  printf '%s\n' "$1" >> "$SQL_FILE"
}

# Note: Marker generation is handled by AI enrichment (enrich command), not algorithmically.

# ============================================================
# Exclude pattern for grep
# ============================================================
get_grep_excludes() {
  local lang="$1" framework="$2"
  # VCS and IDE
  local args="--exclude-dir=.svn --exclude-dir=.git --exclude-dir=.vs --exclude-dir=.nuget --exclude-dir=.claude"
  # Package managers
  args="$args --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=bower_components --exclude-dir=packages"
  # Build output
  args="$args --exclude-dir=bin --exclude-dir=obj --exclude-dir=debug --exclude-dir=release"
  # Vendor libraries
  args="$args --exclude-dir=Vendor --exclude-dir=Libraries --exclude-dir=kendo --exclude-dir=Kendo"
  args="$args --exclude-dir=ckeditor --exclude-dir=tinymce --exclude-dir=Backup --exclude-dir=backup"
  # Minified files and vendor JS
  args="$args --exclude=*.min.js --exclude=*.min.css"
  args="$args --exclude=jquery*.js --exclude=modernizr*.js --exclude=bootstrap*.js"
  args="$args --exclude=respond*.js --exclude=angular*.js --exclude=signalr*.js"
  case "$framework" in
    *wordpress*) args="$args --exclude-dir=wp-includes --exclude-dir=wp-admin --exclude-dir=plugins --exclude-dir=uploads" ;;
  esac
  echo "$args"
}

get_find_excludes() {
  local lang="$1" framework="$2"
  # VCS and IDE
  local p="/\\.svn/|/\\.git/|/\\.vs/|/\\.nuget/|/\\.claude/"
  # Package managers
  p="$p|/node_modules/|/vendor/|/bower_components/|/packages/"
  # Build output
  p="$p|/bin/|/obj/|/debug/|/release/"
  # Vendor libraries and backups
  p="$p|/Vendor/|/Libraries/|/[Kk]endo/|/ckeditor/|/tinymce/|/[Bb]ackup/"
  # Minified and vendor JS files
  p="$p|\\.min\\.js$|\\.min\\.css$"
  p="$p|/jquery[^/]*\\.js$|/modernizr[^/]*\\.js$|/bootstrap[^/]*\\.js$"
  p="$p|/respond[^/]*\\.js$|/angular[^/]*\\.js$|/signalr[^/]*\\.js$"
  case "$framework" in
    *wordpress*) p="$p|/wp-includes/|/wp-admin/|/wp-content/plugins/|/wp-content/uploads/" ;;
  esac
  echo "$p"
}

# ============================================================
# Core scan function
# ============================================================
scan_project() {
  local slug="$1"
  local project_info
  project_info=$(memdb_exec "SELECT id, root_path, IFNULL(primary_language,''), IFNULL(framework,'') FROM projects WHERE slug='$slug' AND is_active=1")

  if [[ -z "$project_info" ]]; then
    echo "ERROR: Project '$slug' not found."
    return 1
  fi

  local project_id root_path lang framework unix_path
  project_id=$(printf '%s' "$project_info" | cut -f1)
  root_path=$(printf '%s' "$project_info" | cut -f2)
  lang=$(printf '%s' "$project_info" | cut -f3)
  framework=$(printf '%s' "$project_info" | cut -f4)
  unix_path=$(win_to_unix "$root_path")

  if [[ ! -d "$unix_path" ]]; then
    echo "ERROR: Path '$unix_path' not found."
    return 1
  fi

  local start_time=$SECONDS
  echo "=== Scanning '$slug' (id=$project_id) ==="
  echo "    Path: $unix_path"

  SQL_FILE="/tmp/claude_scan_${slug}.sql"
  local exclude_pat
  exclude_pat=$(get_find_excludes "$lang" "$framework")

  # --- SQL Header ---
  # The purge runs with foreign-key enforcement off, so deleting code_entities removes only the
  # rows deleted explicitly here (no ON DELETE cascades). PRAGMA foreign_keys cannot change inside
  # a transaction, so it is set before BEGIN and stays off for this one memdb connection; nothing
  # after the purge deletes rows, and every id the script inserts comes from an existing row.
  cat > "$SQL_FILE" << SQLHEADER
PRAGMA foreign_keys = OFF;
BEGIN;
DELETE FROM entity_markers WHERE entity_id IN (SELECT ce.id FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=$project_id);
DELETE FROM file_markers WHERE file_id IN (SELECT id FROM source_files WHERE project_id=$project_id);
DELETE FROM entity_dependencies WHERE caller_id IN (SELECT ce.id FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=$project_id);
DELETE FROM code_entities WHERE file_id IN (SELECT id FROM source_files WHERE project_id=$project_id);
DELETE FROM file_dependencies WHERE source_file_id IN (SELECT id FROM source_files WHERE project_id=$project_id);
UPDATE source_files SET is_deleted=1 WHERE project_id=$project_id;
DROP TABLE IF EXISTS temp._fdeps;
CREATE TEMP TABLE _fdeps (source_path TEXT COLLATE NOCASE, target_ref TEXT COLLATE NOCASE, dep_type TEXT COLLATE NOCASE);
SQLHEADER

  # --- Phase 1: Register all source files ---
  echo "    Phase 1: Registering files..."
  local file_count=0
  find "$unix_path" -type f \( \
    -name "*.cs" -o -name "*.php" -o -name "*.js" -o -name "*.jsx" \
    -o -name "*.ts" -o -name "*.tsx" -o -name "*.py" -o -name "*.sql" \
    -o -name "*.cshtml" -o -name "*.aspx" -o -name "*.ascx" -o -name "*.master" \
    -o -name "*.css" -o -name "*.html" -o -name "*.htm" \
    -o -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" -o -name "*.h" -o -name "*.hpp" \
  \) 2>/dev/null | grep -vE "$exclude_pat" | while IFS= read -r file; do
    local rel_path="${file#$unix_path/}"
    local ext="${file##*.}"
    local line_count hash esc_path
    line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    hash=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    esc_path=$(escape_sql "$rel_path")
    emit "INSERT INTO source_files (project_id,relative_path,file_type,line_count,file_hash,last_scanned_at,is_deleted) VALUES ($project_id,'$esc_path','$ext',$line_count,'$hash',now(),0) ON CONFLICT (project_id,relative_path) DO UPDATE SET line_count=$line_count,file_hash='$hash',last_scanned_at=now(),is_deleted=0;"
  done

  file_count=$(grep -c "INSERT INTO source_files" "$SQL_FILE")
  echo "    Registered $file_count files."

  # --- Phase 2: Extract entities with project-wide grep -> awk pipeline ---
  echo "    Phase 2: Extracting entities..."

  local grep_ex AWK_SCRIPT ENTITY_FILE
  grep_ex=$(get_grep_excludes "$lang" "$framework")
  AWK_SCRIPT="$(dirname "$0")/scanner_awk.sh"
  ENTITY_FILE="/tmp/claude_entities_${slug}.sql"
  > "$ENTITY_FILE"

  # C# types
  echo "      C# types..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(public|private|protected|internal)[[:space:]]+(abstract[[:space:]]+|static[[:space:]]+|sealed[[:space:]]+|partial[[:space:]]+)*(class|interface|enum|struct)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    "$unix_path" --include="*.cs" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" cs_types "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # C# methods
  echo "      C# methods..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(public|private|protected|internal)[[:space:]]+(static[[:space:]]+|virtual[[:space:]]+|override[[:space:]]+|abstract[[:space:]]+|async[[:space:]]+|new[[:space:]]+|sealed[[:space:]]+)*[A-Za-z_].*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
    "$unix_path" --include="*.cs" $grep_ex 2>/dev/null | tr -d '\r' | \
    grep -vE '\b(class|interface|enum|struct|if|for|while|switch|catch|using|return|throw|lock|foreach|delegate|new)\b' | \
    bash "$AWK_SCRIPT" cs_methods "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # PHP classes
  echo "      PHP classes..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(abstract[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    "$unix_path" --include="*.php" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" php_classes "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # PHP functions
  echo "      PHP functions..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+)?(static[[:space:]]+)?function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
    "$unix_path" --include="*.php" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" php_functions "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # WordPress hooks & shortcodes
  echo "      WP hooks..."
  LANG=en_US.UTF-8 grep -rnE "add_(action|filter|shortcode)[[:space:]]*\([[:space:]]*['\"][^'\"]+['\"]" \
    "$unix_path" --include="*.php" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" wp_hooks "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # JS/TS functions (declarations + arrow/const)
  echo "      JS/TS..."
  { LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*\(' \
      "$unix_path" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?(function|\([^)]*\)[[:space:]]*=>|[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=>)' \
      "$unix_path" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null
  } | tr -d '\r' | bash "$AWK_SCRIPT" js_functions "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # JS/TS classes
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?class[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' \
    "$unix_path" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" js_classes "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # Python
  echo "      Python..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(def|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    "$unix_path" --include="*.py" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" py_entities "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # C++ types (class, struct, enum, namespace)
  echo "      C++ types..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(class|struct|enum[[:space:]]*(class)?|namespace)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    "$unix_path" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
    grep -vE '[[:space:]](class|struct)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*;' | \
    bash "$AWK_SCRIPT" cpp_types "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # C++ methods/functions (return_type name(...))
  echo "      C++ methods..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(virtual[[:space:]]+|static[[:space:]]+|inline[[:space:]]+|explicit[[:space:]]+|constexpr[[:space:]]+)*[A-Za-z_][A-Za-z0-9_:*&<> ]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
    "$unix_path" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" cpp_methods "$project_id" "$unix_path" >> "$ENTITY_FILE"

  # C++ free functions (not class-qualified)
  echo "      C++ functions..."
  LANG=en_US.UTF-8 grep -rnE '^[A-Za-z_][A-Za-z0-9_:*&<> ]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]*$' \
    "$unix_path" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
    grep -vE '\b(if|for|while|switch|catch|return|throw|delete|new|sizeof|typedef|using|template)\b' | \
    grep -vE '::' | \
    bash "$AWK_SCRIPT" cpp_functions "$project_id" "$unix_path" >> "$ENTITY_FILE"

  local entity_count
  entity_count=$(grep -c "INSERT INTO code_entities" "$ENTITY_FILE" || echo 0)
  echo "    Extracted $entity_count entities."

  # --- Phase 2b: File dependencies ---
  echo "    Phase 2b: Extracting file dependencies..."
  local FDEP_FILE="/tmp/claude_fdeps_${slug}.sql"
  > "$FDEP_FILE"

  # C# using statements
  echo "      C# usings..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*using[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*;' \
    "$unix_path" --include="*.cs" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" cs_usings "$project_id" "$unix_path" >> "$FDEP_FILE"

  # PHP includes and use
  echo "      PHP includes..."
  { LANG=en_US.UTF-8 grep -rnE "(require|include)(_once)?[[:space:]]*[\(]?[[:space:]]*['\"][^'\"]+['\"]" \
      "$unix_path" --include="*.php" $grep_ex 2>/dev/null
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*use[[:space:]]+[A-Za-z_\\]' \
      "$unix_path" --include="*.php" $grep_ex 2>/dev/null
  } | tr -d '\r' | bash "$AWK_SCRIPT" php_includes "$project_id" "$unix_path" >> "$FDEP_FILE"

  # JS/TS imports and requires
  echo "      JS/TS imports..."
  { LANG=en_US.UTF-8 grep -rnE "(import[[:space:]]|from[[:space:]]+['\"]|require[[:space:]]*\([[:space:]]*['\"])" \
      "$unix_path" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null
  } | tr -d '\r' | bash "$AWK_SCRIPT" js_imports "$project_id" "$unix_path" >> "$FDEP_FILE"

  # Python imports
  echo "      Python imports..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(import|from)[[:space:]]+[A-Za-z_]' \
    "$unix_path" --include="*.py" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" py_imports "$project_id" "$unix_path" >> "$FDEP_FILE"

  # C++ includes
  echo "      C++ includes..."
  LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"]' \
    "$unix_path" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
    bash "$AWK_SCRIPT" cpp_includes "$project_id" "$unix_path" >> "$FDEP_FILE"

  local fdep_count
  fdep_count=$(grep -c "INSERT INTO _fdeps" "$FDEP_FILE" || echo 0)
  echo "    Found $fdep_count import references."

  # Append entities and deps after file registrations
  cat "$ENTITY_FILE" >> "$SQL_FILE"
  cat "$FDEP_FILE" >> "$SQL_FILE"
  rm -f "$ENTITY_FILE" "$FDEP_FILE"

  # --- Phase 3: Post-processing ---
  echo "    Phase 3: Post-processing and loading..."
  # Unquoted heredoc: $project_id is substituted; the SQL below has no other $ or backquote.
  cat >> "$SQL_FILE" << SQLFOOTER
-- Resolve file dependencies: match target_ref to actual source_files.
-- LIKE is case-insensitive for ASCII. ESCAPE keeps the scanner's original LIKE rule that a
-- backslash in the pattern (a PHP namespace such as App\Models\User) escapes the next character.
INSERT OR IGNORE INTO file_dependencies (source_file_id, target_file_id, dependency_type)
  SELECT sf_src.id, sf_tgt.id, fd.dep_type
  FROM _fdeps fd
  JOIN source_files sf_src ON sf_src.project_id=$project_id AND sf_src.relative_path=fd.source_path AND sf_src.is_deleted=0
  JOIN source_files sf_tgt ON sf_tgt.project_id=$project_id AND sf_tgt.is_deleted=0
    AND (sf_tgt.relative_path LIKE '%' || replace(fd.target_ref, '.', '/') || '%' ESCAPE '\\'
      OR sf_tgt.relative_path LIKE '%' || fd.target_ref || '%' ESCAPE '\\')
  WHERE sf_src.id != sf_tgt.id;
DROP TABLE IF EXISTS temp._fdeps;
-- Link methods/functions to their parent class (nearest preceding class in same file)
UPDATE code_entities AS child
SET parent_entity_id = linkage.parent_id,
    qualified_name = linkage.parent_name || '.' || child.name
FROM (
  SELECT m.id AS method_id,
    (SELECT c.id FROM code_entities c
     WHERE c.file_id = m.file_id
       AND c.entity_kind IN ('class','interface','struct')
       AND c.line_start <= m.line_start
     ORDER BY c.line_start DESC LIMIT 1) AS parent_id,
    (SELECT c.name FROM code_entities c
     WHERE c.file_id = m.file_id
       AND c.entity_kind IN ('class','interface','struct')
       AND c.line_start <= m.line_start
     ORDER BY c.line_start DESC LIMIT 1) AS parent_name
  FROM code_entities m
  JOIN source_files sf ON sf.id = m.file_id
  WHERE sf.project_id = $project_id
    AND m.entity_kind IN ('method','function')
    AND m.parent_entity_id IS NULL
) AS linkage
WHERE linkage.method_id = child.id
  AND linkage.parent_id IS NOT NULL;
-- Auto-generate file purpose from path structure (algorithmic best-guess): the last two path
-- segments with ' > ' between them, minus .cs/.php, plus a role suffix. SQLite has no
-- SUBSTRING_INDEX; rtrim(p, replace(p, '/', '')) cuts p back to its last '/', so applying it
-- twice gives the prefix to drop.
UPDATE source_files AS sf
SET purpose =
  replace(
    replace(
      replace(
        substr(t.relative_path, length(rtrim(t.dir, replace(t.dir, '/', ''))) + 1),
      '/', ' > '),
    '.cs', ''),
  '.php', '') ||
  CASE
    WHEN t.relative_path LIKE '%Controller%' THEN ' (controller)'
    WHEN t.relative_path LIKE '%Model%' THEN ' (model)'
    WHEN t.relative_path LIKE '%View%' OR t.relative_path LIKE '%cshtml' THEN ' (view)'
    WHEN t.relative_path LIKE '%Service%' THEN ' (service)'
    WHEN t.relative_path LIKE '%Repository%' THEN ' (repository)'
    WHEN t.relative_path LIKE '%Helper%' OR t.relative_path LIKE '%Util%' THEN ' (utility)'
    WHEN t.relative_path LIKE '%Test%' OR t.relative_path LIKE '%Spec%' THEN ' (test)'
    WHEN t.relative_path LIKE '%.js' THEN ' (script)'
    WHEN t.relative_path LIKE '%.css' THEN ' (stylesheet)'
    WHEN t.relative_path LIKE '%.sql' THEN ' (database script)'
    ELSE ''
  END
FROM (
  -- dir = the path up to (not including) its last '/', or '' when there is none
  SELECT id, relative_path, substr(head, 1, length(head) - 1) AS dir
  FROM (SELECT id, relative_path, rtrim(relative_path, replace(relative_path, '/', '')) AS head
        FROM source_files
        WHERE project_id = $project_id AND is_deleted = 0 AND purpose IS NULL)
) AS t
WHERE t.id = sf.id;
SQLFOOTER

  emit "UPDATE projects SET last_scan_at=now() WHERE id=$project_id;"
  emit "COMMIT;"

  local sql_size
  sql_size=$(wc -c < "$SQL_FILE" | tr -d ' ')
  echo "    Loading SQL ($(( sql_size / 1024 )) KB)..."

  if memdb_batch "$SQL_FILE"; then
    local db_files db_entities elapsed
    db_files=$(memdb_exec "SELECT COUNT(*) FROM source_files WHERE project_id=$project_id AND is_deleted=0")
    db_entities=$(memdb_exec "SELECT COUNT(*) FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=$project_id")
    elapsed=$(( SECONDS - start_time ))
    echo "    DONE: $db_files files, $db_entities entities in ${elapsed}s"
  else
    echo "    ERROR: memdb import failed (nothing was changed). SQL at $SQL_FILE"
    return 1
  fi

  rm -f "$SQL_FILE"
  echo ""
}

# ============================================================
# Management commands
# ============================================================
detect_language() {
  local path="$1"
  local cs_count php_count js_count py_count cpp_count
  cs_count=$(find "$path" -name "*.cs" 2>/dev/null | head -50 | wc -l)
  php_count=$(find "$path" -name "*.php" 2>/dev/null | head -50 | wc -l)
  js_count=$(find "$path" \( -name "*.js" -o -name "*.ts" -o -name "*.tsx" \) 2>/dev/null | head -50 | wc -l)
  py_count=$(find "$path" -name "*.py" 2>/dev/null | head -50 | wc -l)
  cpp_count=$(find "$path" \( -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" -o -name "*.h" -o -name "*.hpp" \) 2>/dev/null | head -50 | wc -l)

  local max=$cs_count lang="csharp"
  if (( php_count > max )); then max=$php_count; lang="php"; fi
  if (( js_count > max )); then max=$js_count; lang="javascript"; fi
  if (( py_count > max )); then max=$py_count; lang="python"; fi
  if (( cpp_count > max )); then max=$cpp_count; lang="cpp"; fi
  if (( max == 0 )); then lang=""; fi
  echo "$lang"
}

detect_framework() {
  local path="$1" lang="$2"
  if [[ -f "$path/wp-config.php" ]] || [[ -d "$path/wp-content" ]]; then
    echo "wordpress"; return
  fi
  if find "$path" -maxdepth 3 -name "*.csproj" 2>/dev/null | head -1 | xargs grep -l "Microsoft.AspNetCore\|System.Web.Mvc" 2>/dev/null | head -1 > /dev/null 2>&1; then
    echo "asp.net-mvc"; return
  fi
  if [[ -f "$path/package.json" ]]; then
    if grep -q '"react"' "$path/package.json" 2>/dev/null; then echo "react"; return; fi
    if grep -q '"next"' "$path/package.json" 2>/dev/null; then echo "nextjs"; return; fi
    if grep -q '"express"' "$path/package.json" 2>/dev/null; then echo "express"; return; fi
    echo "node"; return
  fi
  if [[ -f "$path/requirements.txt" ]] || [[ -f "$path/setup.py" ]]; then
    if grep -q "django" "$path/requirements.txt" 2>/dev/null; then echo "django"; return; fi
    if grep -q "flask" "$path/requirements.txt" 2>/dev/null; then echo "flask"; return; fi
  fi
  echo ""
}

cmd_onboard() {
  local slug="$1" name="$2" path="$3" lang="${4:-}" fw="${5:-}" desc="${6:-}"

  # Validate path
  if [[ ! -d "$path" ]]; then
    echo "ERROR: Path '$path' does not exist."
    return 1
  fi

  # Auto-detect language and framework if not provided
  if [[ -z "$lang" ]]; then
    lang=$(detect_language "$path")
    [[ -n "$lang" ]] && echo "Auto-detected language: $lang"
  fi
  if [[ -z "$fw" ]]; then
    fw=$(detect_framework "$path" "$lang")
    [[ -n "$fw" ]] && echo "Auto-detected framework: $fw"
  fi

  # root_path is stored exactly as given (Windows or Git Bash form); session_boot.sh matches the
  # working directory against it.
  local esc_n esc_p esc_d
  esc_n=$(escape_sql "$name"); esc_p=$(escape_sql "$path"); esc_d=$(escape_sql "$desc")
  memdb_exec "INSERT INTO projects (slug,name,root_path,primary_language,framework,description) VALUES ('$slug','$esc_n','$esc_p',NULLIF('$lang',''),NULLIF('$fw',''),NULLIF('$esc_d','')) ON CONFLICT (slug) DO UPDATE SET name='$esc_n',root_path='$esc_p',primary_language=NULLIF('$lang',''),framework=NULLIF('$fw',''),description=NULLIF('$esc_d','');"
  echo "Registered '$slug'. Scanning..."
  scan_project "$slug"
  echo ""
  echo "=== Onboarding complete ==="
  cmd_status "$slug"
}

cmd_status() {
  local slug="${1:-}"
  if [[ -n "$slug" ]]; then
    memdb_exec "SELECT p.slug,p.name,p.primary_language,p.framework,p.last_scan_at,(SELECT COUNT(*) FROM source_files sf WHERE sf.project_id=p.id AND sf.is_deleted=0),(SELECT COUNT(*) FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=p.id AND ce.is_deleted=0),(SELECT COUNT(DISTINCT cm.marker) FROM entity_markers em JOIN contextual_markers cm ON cm.id=em.marker_id JOIN code_entities ce ON ce.id=em.entity_id JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=p.id) FROM projects p WHERE p.slug='$slug';" | column -t -s $'\t'
  else
    echo "=== Project Status ==="
    printf "%-20s %-10s %-8s %-8s\n" "PROJECT" "LAST_SCAN" "FILES" "ENTITIES"
    memdb_exec "SELECT p.slug,IFNULL(DATE_FORMAT(p.last_scan_at,'%m/%d %H:%i'),'never'),(SELECT COUNT(*) FROM source_files sf WHERE sf.project_id=p.id AND sf.is_deleted=0),(SELECT COUNT(*) FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=p.id AND ce.is_deleted=0) FROM projects p WHERE p.is_active=1 ORDER BY p.slug;" | while IFS=$'\t' read -r s d f e; do
      printf "%-20s %-10s %-8s %-8s\n" "$s" "$d" "$f" "$e"
    done
  fi
}

cmd_reset() {
  local slug="$1"
  local pid
  pid=$(memdb_exec "SELECT id FROM projects WHERE slug='$slug'")
  [[ -z "$pid" ]] && { echo "Not found: '$slug'"; return 1; }
  # Foreign-key enforcement off, as in the scan purge: only the rows named here are deleted.
  # Note: entity_dependencies is not cleared, so the project's dependency rows are left behind
  # pointing at the deleted entities (long-standing behaviour, kept as is).
  memdb_exec "PRAGMA foreign_keys = OFF; BEGIN; DELETE FROM entity_markers WHERE entity_id IN (SELECT ce.id FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=$pid); DELETE FROM file_markers WHERE file_id IN (SELECT id FROM source_files WHERE project_id=$pid); DELETE FROM code_entities WHERE file_id IN (SELECT id FROM source_files WHERE project_id=$pid); DELETE FROM file_dependencies WHERE source_file_id IN (SELECT id FROM source_files WHERE project_id=$pid); DELETE FROM source_files WHERE project_id=$pid; UPDATE projects SET last_scan_at=NULL WHERE id=$pid; COMMIT;"
  echo "Cleared '$slug'."
}

# ============================================================
# Enrichment: export entities for AI-based marker generation
# ============================================================
cmd_enrich_export() {
  local slug="$1"
  local outdir="/tmp/claude_enrich_${slug}"
  mkdir -p "$outdir"

  local pid
  pid=$(memdb_exec "SELECT id FROM projects WHERE slug='$slug' AND is_active=1")
  [[ -z "$pid" ]] && { echo "ERROR: Project '$slug' not found."; return 1; }

  # Get count of entities without markers
  local total unenriched
  total=$(memdb_exec "SELECT COUNT(*) FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=$pid AND ce.is_deleted=0")
  unenriched=$(memdb_exec "SELECT COUNT(*) FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id LEFT JOIN entity_markers em ON em.entity_id=ce.id WHERE sf.project_id=$pid AND ce.is_deleted=0 AND em.entity_id IS NULL")

  echo "=== Enrich Export: $slug ==="
  echo "    Total entities: $total"
  echo "    Without markers: $unenriched"

  # Export entities grouped by file (batches of ~50 entities per file)
  local batch_num=0
  local batch_file=""
  local entity_in_batch=0
  local BATCH_SIZE=50

  memdb_exec "
    SELECT sf.relative_path, ce.id, ce.entity_kind, ce.name,
           IFNULL(ce.qualified_name,''), IFNULL(ce.signature,''),
           ce.line_start, IFNULL(ce.visibility,''), IFNULL(ce.purpose,'')
    FROM code_entities ce
    JOIN source_files sf ON sf.id = ce.file_id
    LEFT JOIN entity_markers em ON em.entity_id = ce.id
    WHERE sf.project_id = $pid AND ce.is_deleted = 0 AND em.entity_id IS NULL
    ORDER BY sf.relative_path, ce.line_start
  " | while IFS=$'\t' read -r fpath eid ekind ename qname sig lstart vis purpose; do
    if (( entity_in_batch == 0 )) || (( entity_in_batch >= BATCH_SIZE )); then
      batch_num=$(( batch_num + 1 ))
      batch_file="$outdir/batch_$(printf '%04d' $batch_num).txt"
      entity_in_batch=0
      echo "--- BATCH $batch_num ---" > "$batch_file"
    fi
    echo "FILE: $fpath" >> "$batch_file"
    echo "  ID=$eid KIND=$ekind NAME=$ename QNAME=$qname LINE=$lstart VIS=$vis" >> "$batch_file"
    echo "  SIG: $sig" >> "$batch_file"
    [[ -n "$purpose" ]] && echo "  PURPOSE: $purpose" >> "$batch_file"
    echo "" >> "$batch_file"
    entity_in_batch=$(( entity_in_batch + 1 ))
  done

  local batch_count
  batch_count=$(ls "$outdir"/batch_*.txt 2>/dev/null | wc -l)
  echo "    Exported $batch_count batch files to $outdir/"
  echo ""
  echo "To enrich, read each batch file and generate SQL (SQLite, run with memdb -f <file>) like:"
  echo "  -- NOTE: contextual_markers has only (id, marker) — no description column"
  echo "  -- Strings: double a single quote (''); a backslash needs no escaping"
  echo "  INSERT OR IGNORE INTO contextual_markers (marker) VALUES ('marker1'),('marker2');"
  echo "  INSERT OR IGNORE INTO entity_markers (entity_id, marker_id, confidence)"
  echo "    SELECT <entity_id>, id, <confidence> FROM contextual_markers WHERE marker='<marker>';"
  echo "  -- Also update entity purposes:"
  echo "  UPDATE code_entities SET purpose = '<description>' WHERE id = <entity_id>;"
  echo ""
  echo "  -- For file-level markers:"
  echo "  INSERT OR IGNORE INTO file_markers (file_id, marker_id, confidence)"
  echo "    SELECT <file_id>, id, <confidence> FROM contextual_markers WHERE marker='<marker>';"
}

# ============================================================
# Deps: infer entity_dependencies from cross-references
# Strategy:
#   1. Get class/interface/struct/enum names (distinctive, >4 chars)
#   2. Grep project files for whole-word references to those names
#   3. Load matches into temp table, JOIN to create 'uses' dependencies
#   4. Skip self-references (same file)
# ============================================================
cmd_deps() {
  local slug="$1"
  load_project_info "$slug" || return 1

  local start_time=$SECONDS
  echo "=== Building entity dependencies for '$slug' ==="

  local grep_ex
  grep_ex=$(get_grep_excludes "$P_LANG" "$P_FW")

  # Step 1: Get distinctive type names
  local PATTERN_FILE="/tmp/claude_deps_names_${slug}.txt"
  memdb_exec "
    SELECT DISTINCT ce.name
    FROM code_entities ce
    JOIN source_files sf ON sf.id = ce.file_id
    WHERE sf.project_id = $P_ID
      AND ce.is_deleted = 0
      AND ce.entity_kind IN ('class','interface','struct','enum')
      AND CHAR_LENGTH(ce.name) > 4
      AND ce.name NOT IN ('Index','Error','Model','Debug','Route','Event','Queue','Setup','Cache','State','Array','Panel','Field','Label','Group','Timer','Match','Value','ABORTING')
    ORDER BY ce.name
  " > "$PATTERN_FILE"

  local type_count
  type_count=$(wc -l < "$PATTERN_FILE" | tr -d ' ')
  echo "    $type_count searchable type names"

  if (( type_count == 0 )); then
    echo "    Nothing to process."
    rm -f "$PATTERN_FILE"
    return 0
  fi

  # Step 2: Grep for type names as whole words, extract matched name per file
  local MATCHED_FILE="/tmp/claude_deps_matched_${slug}.tsv"
  > "$MATCHED_FILE"

  echo "    Scanning for cross-references..."
  local batch_size=200 batch_num=0
  while true; do
    local offset=$(( batch_num * batch_size ))
    local batch_names
    batch_names=$(tail -n +$(( offset + 1 )) "$PATTERN_FILE" | head -n "$batch_size")
    [[ -z "$batch_names" ]] && break

    local pattern
    pattern=$(echo "$batch_names" | paste -sd'|' -)

    # -ow: whole-word match, output only matched text; -r recursive
    # NOTE: path must come LAST for Git Bash grep compatibility
    LANG=en_US.UTF-8 grep -rnow \
      --include="*.cs" --include="*.php" --include="*.js" --include="*.ts" \
      --include="*.tsx" --include="*.jsx" --include="*.py" \
      --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" \
      $grep_ex -E "$pattern" "$P_UNIX" 2>/dev/null | tr -d '\r' | \
      awk -F: -v upath="$P_UNIX/" '{
        sub(upath, "", $1)
        file=$1; name=$3
        key = file "\t" name
        if (!(key in seen)) { seen[key]=1; print key }
      }' >> "$MATCHED_FILE"

    batch_num=$(( batch_num + 1 ))
  done

  local match_count
  match_count=$(wc -l < "$MATCHED_FILE" | tr -d ' ')
  echo "    $match_count unique file-references-type pairs"

  # Step 3: Process in chunks of 2000 pairs to avoid oversized SQL
  local chunk_size=2000
  local total_inserted=0
  local chunk_num=0
  local chunk_lines

  # Split matched file into chunks
  while true; do
    local chunk_start=$(( chunk_num * chunk_size + 1 ))
    chunk_lines=$(sed -n "${chunk_start},$(( chunk_start + chunk_size - 1 ))p" "$MATCHED_FILE")
    [[ -z "$chunk_lines" ]] && break

    chunk_num=$(( chunk_num + 1 ))
    SQL_FILE="/tmp/claude_deps_${slug}_chunk${chunk_num}.sql"

    cat > "$SQL_FILE" << SQLHEADER
BEGIN;
DROP TABLE IF EXISTS temp._type_refs;
CREATE TEMP TABLE _type_refs (
  ref_file TEXT NOT NULL COLLATE NOCASE,
  type_name TEXT NOT NULL COLLATE NOCASE
);
CREATE INDEX temp.ix_type_refs_name ON _type_refs (type_name);
SQLHEADER

    # Batch insert the matches (500 per INSERT)
    local insert_batch=0
    local values=""
    while IFS=$'\t' read -r ref_file type_name; do
      [[ -z "$ref_file" || -z "$type_name" ]] && continue
      local esc_file esc_name
      esc_file=$(escape_sql "$ref_file")
      esc_name=$(escape_sql "$type_name")
      if [[ -z "$values" ]]; then
        values="('$esc_file','$esc_name')"
      else
        values="$values,('$esc_file','$esc_name')"
      fi
      insert_batch=$(( insert_batch + 1 ))
      if (( insert_batch >= 500 )); then
        emit "INSERT INTO _type_refs VALUES $values;"
        values=""
        insert_batch=0
      fi
    done <<< "$chunk_lines"
    [[ -n "$values" ]] && emit "INSERT INTO _type_refs VALUES $values;"

    # Join: create 'uses' dependencies where ref_file has a type that references another type
    # (unquoted heredoc: only $P_ID is substituted)
    cat >> "$SQL_FILE" << SQLDEPS

-- Create 'uses' deps: type in ref_file -> referenced type (different file only)
INSERT OR IGNORE INTO entity_dependencies (caller_id, callee_id, dependency_type)
SELECT DISTINCT caller.id, callee.id, 'uses'
FROM _type_refs tr
JOIN code_entities callee ON callee.name = tr.type_name
  AND callee.entity_kind IN ('class','interface','struct','enum')
  AND callee.is_deleted = 0
JOIN source_files sf_callee ON sf_callee.id = callee.file_id
  AND sf_callee.project_id = $P_ID
JOIN source_files sf_caller ON sf_caller.project_id = $P_ID
  AND sf_caller.relative_path = tr.ref_file
  AND sf_caller.is_deleted = 0
JOIN code_entities caller ON caller.file_id = sf_caller.id
  AND caller.entity_kind IN ('class','interface','struct','enum')
  AND caller.is_deleted = 0
WHERE sf_caller.id != sf_callee.id;

SELECT concat('Inserted ', changes(), ' dependencies');
DROP TABLE IF EXISTS temp._type_refs;
COMMIT;
SQLDEPS

    echo "    Chunk $chunk_num: loading..."

    if memdb_batch "$SQL_FILE"; then
      echo "    Chunk $chunk_num: done"
    else
      echo "    ERROR: Chunk $chunk_num failed. SQL at $SQL_FILE"
      return 1
    fi
    rm -f "$SQL_FILE"
  done

  local dep_count elapsed
  dep_count=$(memdb_exec "SELECT COUNT(*) FROM entity_dependencies ed JOIN code_entities ce ON ce.id = ed.caller_id JOIN source_files sf ON sf.id = ce.file_id WHERE sf.project_id = $P_ID")
  elapsed=$(( SECONDS - start_time ))
  echo "    DONE: $dep_count project deps (total DB: $(memdb_exec 'SELECT COUNT(*) FROM entity_dependencies')) in ${elapsed}s"

  rm -f "$PATTERN_FILE" "$MATCHED_FILE"
}

# ============================================================
# Helper: load project info for check/update commands
# ============================================================
load_project_info() {
  local slug="$1"
  PROJECT_INFO=$(memdb_exec "SELECT id, root_path, IFNULL(primary_language,''), IFNULL(framework,'') FROM projects WHERE slug='$slug' AND is_active=1")
  if [[ -z "$PROJECT_INFO" ]]; then
    echo "ERROR: Project '$slug' not found."
    return 1
  fi
  P_ID=$(printf '%s' "$PROJECT_INFO" | cut -f1)
  P_ROOT=$(printf '%s' "$PROJECT_INFO" | cut -f2)
  P_LANG=$(printf '%s' "$PROJECT_INFO" | cut -f3)
  P_FW=$(printf '%s' "$PROJECT_INFO" | cut -f4)
  P_UNIX=$(win_to_unix "$P_ROOT")
  if [[ ! -d "$P_UNIX" ]]; then
    echo "ERROR: Path '$P_UNIX' not found."
    return 1
  fi
}

# Helper: build current file list with hashes (TSV: path\thash\tline_count\text)
build_current_filelist() {
  local unix_path="$1" exclude_pat="$2" outfile="$3"
  find "$unix_path" -type f \( \
    -name "*.cs" -o -name "*.php" -o -name "*.js" -o -name "*.jsx" \
    -o -name "*.ts" -o -name "*.tsx" -o -name "*.py" -o -name "*.sql" \
    -o -name "*.cshtml" -o -name "*.aspx" -o -name "*.ascx" -o -name "*.master" \
    -o -name "*.css" -o -name "*.html" -o -name "*.htm" \
    -o -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" -o -name "*.h" -o -name "*.hpp" \
  \) 2>/dev/null | grep -vE "$exclude_pat" | while IFS= read -r file; do
    local rel_path="${file#$unix_path/}"
    local hash lc ext
    hash=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    lc=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    ext="${file##*.}"
    printf '%s\t%s\t%s\t%s\n' "$rel_path" "$hash" "$lc" "$ext"
  done | sort > "$outfile"
}

# Helper: diff current vs DB files using awk (no grep -P needed)
# Outputs three files: new_list, mod_list, del_list
diff_file_lists() {
  local current="$1" db="$2" new_out="$3" mod_out="$4" del_out="$5"
  awk -F'\t' '
    NR==FNR { db[$1] = $2; next }
    { cur[$1] = $2 }
    END {
      for (f in cur) {
        if (!(f in db)) print f > new_file
        else if (db[f] == "" || db[f] != cur[f]) print f > mod_file
      }
      for (f in db) {
        if (!(f in cur)) print f > del_file
      }
    }
  ' new_file="$new_out" mod_file="$mod_out" del_file="$del_out" "$db" "$current"
  # Ensure files exist even if empty
  touch "$new_out" "$mod_out" "$del_out"
}

# ============================================================
# Check: compare stored hashes against current files (read-only)
# ============================================================
cmd_check() {
  local slug="$1"
  load_project_info "$slug" || return 1

  echo "=== Checking '$slug' for changes ==="

  local exclude_pat
  exclude_pat=$(get_find_excludes "$P_LANG" "$P_FW")

  local current="/tmp/claude_check_cur_${slug}.tsv"
  local db_files="/tmp/claude_check_db_${slug}.tsv"
  local new_list="/tmp/claude_check_new_${slug}.txt"
  local mod_list="/tmp/claude_check_mod_${slug}.txt"
  local del_list="/tmp/claude_check_del_${slug}.txt"

  build_current_filelist "$P_UNIX" "$exclude_pat" "$current"

  memdb_exec "SELECT relative_path, IFNULL(file_hash,'') FROM source_files WHERE project_id=$P_ID AND is_deleted=0 ORDER BY relative_path" > "$db_files"

  diff_file_lists "$current" "$db_files" "$new_list" "$mod_list" "$del_list"

  local added changed deleted
  added=$(wc -l < "$new_list" | tr -d ' ')
  changed=$(wc -l < "$mod_list" | tr -d ' ')
  deleted=$(wc -l < "$del_list" | tr -d ' ')

  if (( added > 0 )); then
    echo ""
    echo "  NEW ($added):"
    head -20 "$new_list" | sed 's/^/    + /'
    (( added > 20 )) && echo "    ... and $(( added - 20 )) more"
  fi

  if (( deleted > 0 )); then
    echo ""
    echo "  DELETED ($deleted):"
    head -20 "$del_list" | sed 's/^/    - /'
    (( deleted > 20 )) && echo "    ... and $(( deleted - 20 )) more"
  fi

  if (( changed > 0 )); then
    echo ""
    echo "  MODIFIED ($changed):"
    head -20 "$mod_list" | sed 's/^/    ~ /'
    (( changed > 20 )) && echo "    ... and $(( changed - 20 )) more"
  fi

  local total=$(( added + changed + deleted ))
  echo ""
  if (( total == 0 )); then
    echo "  No changes detected. DB is up to date."
  else
    echo "  TOTAL: $added new, $changed modified, $deleted deleted"
    echo "  Run: $0 update $slug"
  fi

  rm -f "$current" "$db_files" "$new_list" "$mod_list" "$del_list"
}

# ============================================================
# Update: incremental scan — only changed/new/deleted files
# Preserves purposes and markers on unchanged entities.
# Usage: update <slug> [--file <relative-path>]
#   --file forces rescan of a specific file regardless of hash
# ============================================================
cmd_update() {
  local slug="$1"; shift
  local force_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) force_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  load_project_info "$slug" || return 1

  local start_time=$SECONDS
  echo "=== Incremental update '$slug' (id=$P_ID) ==="

  local exclude_pat grep_ex
  exclude_pat=$(get_find_excludes "$P_LANG" "$P_FW")
  grep_ex=$(get_grep_excludes "$P_LANG" "$P_FW")

  local current="/tmp/claude_update_cur_${slug}.tsv"
  local db_files="/tmp/claude_update_db_${slug}.tsv"
  local new_list="/tmp/claude_update_new_${slug}.txt"
  local mod_list="/tmp/claude_update_mod_${slug}.txt"
  local del_list="/tmp/claude_update_del_${slug}.txt"

  build_current_filelist "$P_UNIX" "$exclude_pat" "$current"

  memdb_exec "SELECT relative_path, IFNULL(file_hash,'') FROM source_files WHERE project_id=$P_ID AND is_deleted=0 ORDER BY relative_path" > "$db_files"

  if [[ -n "$force_file" ]]; then
    # Force mode: only process the specified file
    echo "$force_file" > "$new_list"
    > "$mod_list"
    > "$del_list"
    # Check if it exists in DB — if so, treat as modified instead
    if grep -qF "$force_file" "$db_files"; then
      > "$new_list"
      echo "$force_file" > "$mod_list"
    fi
    echo "    Force refresh: $force_file"
  else
    diff_file_lists "$current" "$db_files" "$new_list" "$mod_list" "$del_list"
  fi

  local n_new n_mod n_del
  n_new=$(wc -l < "$new_list" | tr -d ' ')
  n_mod=$(wc -l < "$mod_list" | tr -d ' ')
  n_del=$(wc -l < "$del_list" | tr -d ' ')

  echo "    Changes: $n_new new, $n_mod modified, $n_del deleted"

  if (( n_new + n_mod + n_del == 0 )); then
    echo "    Nothing to update."
    rm -f "$current" "$db_files" "$new_list" "$mod_list" "$del_list"
    return 0
  fi

  # Build SQL for changes (foreign keys stay enforced here, so deletes cascade)
  SQL_FILE="/tmp/claude_update_${slug}.sql"
  cat > "$SQL_FILE" << SQLHEADER
BEGIN;
SQLHEADER

  # Handle deleted files — mark as deleted (preserves history)
  if (( n_del > 0 )); then
    echo "    Marking $n_del deleted files..."
    while IFS= read -r del_path; do
      local esc_del
      esc_del=$(escape_sql "$del_path")
      emit "UPDATE source_files SET is_deleted=1 WHERE project_id=$P_ID AND relative_path='$esc_del';"
      emit "UPDATE code_entities SET is_deleted=1 WHERE file_id=(SELECT id FROM source_files WHERE project_id=$P_ID AND relative_path='$esc_del');"
    done < "$del_list"
  fi

  # Handle new + modified files — use awk to look up metadata from current file list
  if (( n_new > 0 )); then
    echo "    Registering $n_new new files..."
    while IFS= read -r new_path; do
      local esc_path meta hash lc ext
      esc_path=$(escape_sql "$new_path")
      meta=$(awk -F'\t' -v f="$new_path" '$1==f{print; exit}' "$current")
      hash=$(printf '%s' "$meta" | cut -f2)
      lc=$(printf '%s' "$meta" | cut -f3)
      ext=$(printf '%s' "$meta" | cut -f4)
      emit "INSERT INTO source_files (project_id,relative_path,file_type,line_count,file_hash,last_scanned_at,is_deleted) VALUES ($P_ID,'$esc_path','$ext',$lc,'$hash',now(),0) ON CONFLICT (project_id,relative_path) DO UPDATE SET line_count=$lc,file_hash='$hash',last_scanned_at=now(),is_deleted=0;"
    done < "$new_list"
  fi

  if (( n_mod > 0 )); then
    echo "    Updating $n_mod modified files..."
    while IFS= read -r mod_path; do
      local esc_path meta hash lc
      esc_path=$(escape_sql "$mod_path")
      meta=$(awk -F'\t' -v f="$mod_path" '$1==f{print; exit}' "$current")
      hash=$(printf '%s' "$meta" | cut -f2)
      lc=$(printf '%s' "$meta" | cut -f3)
      emit "UPDATE source_files SET line_count=$lc, file_hash='$hash', last_scanned_at=now() WHERE project_id=$P_ID AND relative_path='$esc_path';"
      # Remove old entities for this file (markers and deps cascade)
      emit "DELETE FROM code_entities WHERE file_id IN (SELECT id FROM source_files WHERE project_id=$P_ID AND relative_path='$esc_path');"
    done < "$mod_list"
  fi

  # Re-extract entities for new + modified files
  local affected_list="/tmp/claude_update_affected_${slug}.txt"
  cat "$new_list" "$mod_list" | sort -u > "$affected_list"
  local n_affected
  n_affected=$(wc -l < "$affected_list" | tr -d ' ')

  if (( n_affected > 0 )); then
    echo "    Extracting entities from $n_affected files..."
    local AWK_SCRIPT ENTITY_FILE
    AWK_SCRIPT="$(dirname "$0")/scanner_awk.sh"
    ENTITY_FILE="/tmp/claude_update_entities_${slug}.sql"
    > "$ENTITY_FILE"

    # Build a grep filter pattern from affected files
    local affected_pattern
    affected_pattern=$(sed 's/[.[\*^$()+?{|\\]/\\&/g' "$affected_list" | paste -sd'|' -)

    # C# types from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(public|private|protected|internal)[[:space:]]+(abstract[[:space:]]+|static[[:space:]]+|sealed[[:space:]]+|partial[[:space:]]+)*(class|interface|enum|struct)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      "$P_UNIX" --include="*.cs" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" cs_types "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # C# methods from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(public|private|protected|internal)[[:space:]]+(static[[:space:]]+|virtual[[:space:]]+|override[[:space:]]+|abstract[[:space:]]+|async[[:space:]]+|new[[:space:]]+|sealed[[:space:]]+)*[A-Za-z_].*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
      "$P_UNIX" --include="*.cs" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -vE '\b(class|interface|enum|struct|if|for|while|switch|catch|using|return|throw|lock|foreach|delegate|new)\b' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" cs_methods "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # PHP classes from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(abstract[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      "$P_UNIX" --include="*.php" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" php_classes "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # PHP functions from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+)?(static[[:space:]]+)?function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
      "$P_UNIX" --include="*.php" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" php_functions "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # WP hooks from affected files
    LANG=en_US.UTF-8 grep -rnE "add_(action|filter|shortcode)[[:space:]]*\([[:space:]]*['\"][^'\"]+['\"]" \
      "$P_UNIX" --include="*.php" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" wp_hooks "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # JS/TS from affected files
    { LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*\(' \
        "$P_UNIX" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null
      LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?(function|\([^)]*\)[[:space:]]*=>|[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=>)' \
        "$P_UNIX" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null
    } | tr -d '\r' | grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" js_functions "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # JS/TS classes from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?class[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' \
      "$P_UNIX" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" js_classes "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # Python from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(def|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      "$P_UNIX" --include="*.py" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" py_entities "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # C++ types from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(class|struct|enum[[:space:]]*(class)?|namespace)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      "$P_UNIX" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -vE '[[:space:]](class|struct)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*;' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" cpp_types "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # C++ methods from affected files
    LANG=en_US.UTF-8 grep -rnE '^[[:space:]]*(virtual[[:space:]]+|static[[:space:]]+|inline[[:space:]]+|explicit[[:space:]]+|constexpr[[:space:]]+)*[A-Za-z_][A-Za-z0-9_:*&<> ]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
      "$P_UNIX" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" cpp_methods "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    # C++ free functions from affected files
    LANG=en_US.UTF-8 grep -rnE '^[A-Za-z_][A-Za-z0-9_:*&<> ]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]*$' \
      "$P_UNIX" --include="*.cpp" --include="*.cc" --include="*.cxx" --include="*.h" --include="*.hpp" $grep_ex 2>/dev/null | tr -d '\r' | \
      grep -vE '\b(if|for|while|switch|catch|return|throw|delete|new|sizeof|typedef|using|template)\b' | \
      grep -vE '::' | \
      grep -E "($affected_pattern)" | \
      bash "$AWK_SCRIPT" cpp_functions "$P_ID" "$P_UNIX" >> "$ENTITY_FILE"

    local entity_count
    entity_count=$(grep -c "INSERT INTO code_entities" "$ENTITY_FILE" || echo 0)
    echo "    Extracted $entity_count entities from affected files."

    cat "$ENTITY_FILE" >> "$SQL_FILE"
    rm -f "$ENTITY_FILE" "$affected_list"
  fi

  # Post-processing: re-link parent entities (unquoted heredoc: only $P_ID is substituted)
  cat >> "$SQL_FILE" << SQLFOOTER
UPDATE code_entities AS child
SET parent_entity_id = linkage.parent_id,
    qualified_name = linkage.parent_name || '.' || child.name
FROM (
  SELECT m.id AS method_id,
    (SELECT c.id FROM code_entities c
     WHERE c.file_id = m.file_id
       AND c.entity_kind IN ('class','interface','struct')
       AND c.line_start <= m.line_start
     ORDER BY c.line_start DESC LIMIT 1) AS parent_id,
    (SELECT c.name FROM code_entities c
     WHERE c.file_id = m.file_id
       AND c.entity_kind IN ('class','interface','struct')
       AND c.line_start <= m.line_start
     ORDER BY c.line_start DESC LIMIT 1) AS parent_name
  FROM code_entities m
  JOIN source_files sf ON sf.id = m.file_id
  WHERE sf.project_id = $P_ID
    AND m.entity_kind IN ('method','function')
    AND m.parent_entity_id IS NULL
) AS linkage
WHERE linkage.method_id = child.id
  AND linkage.parent_id IS NOT NULL;
SQLFOOTER

  emit "UPDATE projects SET last_scan_at=now() WHERE id=$P_ID;"
  emit "COMMIT;"

  local sql_size
  sql_size=$(wc -c < "$SQL_FILE" | tr -d ' ')
  echo "    Loading SQL ($(( sql_size / 1024 )) KB)..."

  if memdb_batch "$SQL_FILE"; then
    local db_file_count db_entity_count elapsed
    db_file_count=$(memdb_exec "SELECT COUNT(*) FROM source_files WHERE project_id=$P_ID AND is_deleted=0")
    db_entity_count=$(memdb_exec "SELECT COUNT(*) FROM code_entities ce JOIN source_files sf ON sf.id=ce.file_id WHERE sf.project_id=$P_ID AND ce.is_deleted=0")
    elapsed=$(( SECONDS - start_time ))
    echo "    DONE: $db_file_count files, $db_entity_count entities (${elapsed}s)"
  else
    echo "    ERROR: memdb import failed (nothing was changed). SQL at $SQL_FILE"
    rm -f "$current" "$db_files" "$new_list" "$mod_list" "$del_list"
    return 1
  fi

  rm -f "$SQL_FILE" "$current" "$db_files" "$new_list" "$mod_list" "$del_list"
}

# ============================================================
# Check-all / Update-all
# ============================================================
cmd_check_all() {
  for s in $(memdb_exec "SELECT slug FROM projects WHERE is_active=1 ORDER BY slug"); do
    cmd_check "$s"
    echo ""
  done
}

cmd_update_all() {
  echo "=== Incremental update all projects ==="
  local total_start=$SECONDS
  for s in $(memdb_exec "SELECT slug FROM projects WHERE is_active=1 ORDER BY slug"); do
    cmd_update "$s" || echo "WARN: '$s' failed, continuing..."
  done
  echo "=== Complete in $(( SECONDS - total_start ))s ==="
  cmd_status
}

# ============================================================
# Main
# ============================================================
case "${1:-help}" in
  scan)
    [[ -z "${2:-}" ]] && { echo "Usage: $0 scan <slug>"; exit 1; }
    scan_project "$2"
    ;;
  scan-all)
    echo "=== Scanning all projects ==="
    total_start=$SECONDS
    for s in $(memdb_exec "SELECT slug FROM projects WHERE is_active=1 ORDER BY slug"); do
      scan_project "$s" || echo "WARN: '$s' failed, continuing..."
    done
    echo "=== Complete in $(( SECONDS - total_start ))s ==="
    cmd_status
    ;;
  check)
    [[ -z "${2:-}" ]] && { echo "Usage: $0 check <slug>"; exit 1; }
    cmd_check "$2"
    ;;
  check-all) cmd_check_all ;;
  update)
    [[ -z "${2:-}" ]] && { echo "Usage: $0 update <slug> [--file <path>]"; exit 1; }
    cmd_update "$2" "${@:3}"
    ;;
  update-all) cmd_update_all ;;
  onboard)
    [[ -z "${4:-}" ]] && { echo "Usage: $0 onboard <slug> <name> <path> [lang] [fw] [desc]"; exit 1; }
    cmd_onboard "$2" "$3" "$4" "${5:-}" "${6:-}" "${7:-}"
    ;;
  deps)
    [[ -z "${2:-}" ]] && { echo "Usage: $0 deps <slug>"; exit 1; }
    cmd_deps "$2"
    ;;
  deps-all)
    for s in $(memdb_exec "SELECT slug FROM projects WHERE is_active=1 ORDER BY slug"); do
      cmd_deps "$s"
    done
    ;;
  enrich)
    [[ -z "${2:-}" ]] && { echo "Usage: $0 enrich <slug>"; exit 1; }
    cmd_enrich_export "$2"
    ;;
  enrich-all)
    for s in $(memdb_exec "SELECT slug FROM projects WHERE is_active=1 ORDER BY slug"); do
      cmd_enrich_export "$s"
    done
    ;;
  migrate-history)
    # Legacy one-off: drives migrate_history.py, a migration helper that is NOT shipped with
    # this bundle. Without it the command stops here.
    [[ -z "${2:-}" ]] && { echo "Usage: $0 migrate-history <slug> [--max-batches N]"; exit 1; }
    if [[ ! -f "$(dirname "$0")/migrate_history.py" ]]; then
      echo "ERROR: migrate-history needs migrate_history.py next to this script."
      echo "  It is a one-off legacy migration helper and is not included in this bundle."
      exit 1
    fi
    slug="$2"; shift 2
    pid=$(memdb_exec "SELECT id FROM projects WHERE slug='$slug' AND is_active=1")
    [[ -z "$pid" ]] && { echo "ERROR: Project '$slug' not found."; exit 1; }
    root=$(memdb_exec "SELECT root_path FROM projects WHERE slug='$slug'")
    # Derive the project key directory from the root path
    norm_root=$(echo "$root" | sed 's|[\\:/]|-|g; s|^-||; s|-$||')
    project_key_dir="$HOME/.claude/projects/$norm_root"
    if [[ ! -d "$project_key_dir" ]]; then
      # Try finding it by listing project dirs that match (case-insensitive)
      project_key_dir=$(ls -d "$HOME/.claude/projects/"* 2>/dev/null | grep -i "$slug" | head -1)
    fi
    if [[ -z "$project_key_dir" ]] || [[ ! -d "$project_key_dir" ]]; then
      echo "ERROR: Cannot find project key directory. Try:"
      echo "  python3 ~/.claude/migrate_history.py <project-key-dir> /tmp/claude_migrate_${slug}/"
      exit 1
    fi
    outdir="/tmp/claude_migrate_${slug}"
    echo "Project key dir: $project_key_dir"
    # Find Python — try python3 first, fall back to python
    PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
    if [[ -z "$PYTHON" ]] || ! "$PYTHON" --version &>/dev/null; then
      # Windows fallback
      PYTHON=$(ls /c/Users/*/AppData/Local/Programs/Python/*/python.exe 2>/dev/null | head -1)
    fi
    [[ -z "$PYTHON" ]] && { echo "ERROR: Python not found."; exit 1; }
    "$PYTHON" "$(dirname "$0")/migrate_history.py" "$project_key_dir" "$outdir" "$@"
    ;;
  status) cmd_status "${2:-}" ;;
  reset)
    [[ -z "${2:-}" ]] && { echo "Usage: $0 reset <slug>"; exit 1; }
    cmd_reset "$2"
    ;;
  help|*)
    echo "claude_scanner.sh - Scan projects for claude_memory"
    echo "  scan <slug>           Full re-scan a project"
    echo "  scan-all              Full re-scan all projects"
    echo "  check <slug>          Check for file changes (read-only)"
    echo "  check-all             Check all projects for changes"
    echo "  update <slug>         Incremental update (only changed files)"
    echo "  update <slug> --file <path>  Force refresh a specific file"
    echo "  update-all            Incremental update all projects"
    echo "  onboard <slug> <name> <path> [lang] [fw] [desc]"
    echo "                        Register and scan a new project"
    echo "                        lang/fw auto-detected if omitted"
    echo "  deps <slug>           Infer entity dependencies from cross-references"
    echo "  deps-all              Infer deps for all projects"
    echo "  enrich <slug>         Export unenriched entities for AI marker generation"
    echo "  enrich-all            Export for all projects"
    echo "  migrate-history <slug> [--max-batches N]"
    echo "                        Export JSONL transcripts as batch files for DB migration"
    echo "                        (needs migrate_history.py, which is not included)"
    echo "  status [slug]         Show scan stats"
    echo "  reset <slug>          Clear scan data"
    ;;
esac
