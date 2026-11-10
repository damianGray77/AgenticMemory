#!/bin/bash
# scanner_awk.sh v3 - Fast AWK-based entity extraction for the claude_memory database
# Called by claude_scanner.sh. Generates SQLite SQL (run through memdb) from grep output.
# Usage: grep ... | bash scanner_awk.sh <mode> <project_id> <unix_path>
#
# Entity modes: cs_types, cs_methods, php_classes, php_functions, wp_hooks,
#               js_functions, js_classes, py_entities,
#               cpp_types, cpp_methods, cpp_functions
#   -> one INSERT INTO code_entities per match; file_id is looked up from source_files by
#      (project_id, relative_path), so the file must have been registered earlier in the script.
# Dependency modes: cs_usings, php_includes, js_imports, py_imports, cpp_includes
#   -> INSERT INTO _fdeps (a TEMP table claude_scanner.sh creates and resolves)
#
# Marker generation is NOT done here — it's handled by AI enrichment post-scan.

MODE="$1"
PID="$2"
UPATH="$3"

awk -v mode="$MODE" -v pid="$PID" -v upath="$UPATH" '
BEGIN {
  FS = ":"
}

# Body of an SQLite string literal: double each single quote (\047). Backslashes are ordinary
# characters in SQLite and pass through unchanged.
function escape(s) {
  gsub(/\047/, "\047\047", s)
  return s
}

# file_id of the current file (esc_path is set per input line below)
function file_id_sql() {
  return sprintf("(SELECT id FROM source_files WHERE project_id=%d AND relative_path=\047%s\047)", pid, esc_path)
}

function make_sig(line,    sig) {
  sig = line
  gsub(/^[[:space:]]+/, "", sig)
  gsub(/[[:space:]]+$/, "", sig)
  gsub(/\{[[:space:]]*$/, "", sig)
  gsub(/[[:space:]]+$/, "", sig)
  if (length(sig) > 500) sig = substr(sig, 1, 500)
  return escape(sig)
}

{
  # Parse grep output: filepath:linenum:content
  fpath = $1
  if ($1 ~ /^[A-Za-z]$/ && $2 ~ /^\//) {
    fpath = $1 ":" $2
    linenum = $3
    content = ""
    for (i = 4; i <= NF; i++) { if (i > 4) content = content ":"; content = content $i }
  } else {
    linenum = $2
    content = ""
    for (i = 3; i <= NF; i++) { if (i > 3) content = content ":"; content = content $i }
  }
  gsub(/\r/, "", content)
  gsub(/\r/, "", fpath)

  rel_path = fpath
  sub(upath "/", "", rel_path)
  esc_path = escape(rel_path)
  sig = make_sig(content)

  # ============================================================
  # Type definitions: classes, interfaces, enums, structs, py defs
  # ============================================================
  if (mode == "cs_types" || mode == "php_classes" || mode == "js_classes" || mode == "py_entities") {
    kind = ""
    if (content ~ /\<class\>/ || content ~ /[[:space:]]class[[:space:]]/) kind = "class"
    else if (content ~ /\<interface\>/ || content ~ /[[:space:]]interface[[:space:]]/) kind = "interface"
    else if (content ~ /\<enum\>/ || content ~ /[[:space:]]enum[[:space:]]/) kind = "enum"
    else if (content ~ /\<struct\>/ || content ~ /[[:space:]]struct[[:space:]]/) kind = "struct"
    else if (content ~ /[[:space:]]def[[:space:]]/) kind = "function"

    name = ""
    if (kind != "" && match(content, kind "[[:space:]]+[A-Za-z_][A-Za-z0-9_]*")) {
      name = substr(content, RSTART, RLENGTH)
      sub(kind "[[:space:]]+", "", name)
    }
    if (kind == "function" && match(content, "def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*")) {
      name = substr(content, RSTART, RLENGTH)
      sub("def[[:space:]]+", "", name)
      if (name ~ /^__.*__$/) next
    }

    vis = "public"
    if (match(content, /^[[:space:]]*(public|private|protected|internal)/)) {
      vis = substr(content, RSTART, RLENGTH)
      gsub(/^[[:space:]]+/, "", vis)
    }

    is_static = (content ~ /[[:space:]]static[[:space:]]/) ? 1 : 0

    if (name != "" && kind != "") {
      esc_name = escape(name)
      printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047%s\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), kind, esc_name, sig, linenum, vis, is_static
    }
  }

  # ============================================================
  # C# methods
  # ============================================================
  else if (mode == "cs_methods") {
    name = ""
    if (match(content, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
      name = substr(content, RSTART, RLENGTH)
      sub(/[[:space:]]*\(/, "", name)
    }
    vis = "public"
    if (match(content, /^[[:space:]]*(public|private|protected|internal)/)) {
      vis = substr(content, RSTART, RLENGTH)
      gsub(/^[[:space:]]+/, "", vis)
    }
    is_static = (content ~ /[[:space:]]static[[:space:]]/) ? 1 : 0

    if (name == "" || name ~ /^(get|set|add|remove|value|nameof|typeof|sizeof|default|base|this)$/) next

    esc_name = escape(name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047method\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), esc_name, sig, linenum, vis, is_static
  }

  # ============================================================
  # PHP functions
  # ============================================================
  else if (mode == "php_functions") {
    name = ""
    if (match(content, /function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(content, RSTART, RLENGTH)
      sub(/function[[:space:]]+/, "", name)
    }
    if (name == "" || name == "__construct" || name == "__destruct") next
    vis = "public"
    if (match(content, /^[[:space:]]*(public|private|protected)/)) {
      vis = substr(content, RSTART, RLENGTH)
      gsub(/^[[:space:]]+/, "", vis)
    }
    is_static = (content ~ /[[:space:]]static[[:space:]]/) ? 1 : 0

    esc_name = escape(name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047function\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), esc_name, sig, linenum, vis, is_static
  }

  # ============================================================
  # WordPress hooks & shortcodes
  # ============================================================
  else if (mode == "wp_hooks") {
    hook_name = ""
    kind = ""
    if (content ~ /add_shortcode/) kind = "shortcode"
    else if (content ~ /add_action/) kind = "action"
    else kind = "filter"

    if (match(content, /\047[^\047]+\047/)) {
      hook_name = substr(content, RSTART+1, RLENGTH-2)
    } else if (match(content, /"[^"]+"/)) {
      hook_name = substr(content, RSTART+1, RLENGTH-2)
    }
    if (hook_name == "") next
    esc_name = escape(hook_name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,last_scanned_at) VALUES (%s,\047%s\047,\047%s\047,\047%s\047,%d,now());\n", file_id_sql(), kind, esc_name, sig, linenum
  }

  # ============================================================
  # JS/TS functions (declarations + arrow/const)
  # ============================================================
  else if (mode == "js_functions") {
    name = ""
    if (content ~ /function[[:space:]]+[A-Za-z_$]/) {
      if (match(content, /function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
        name = substr(content, RSTART, RLENGTH)
        sub(/function[[:space:]]+/, "", name)
      }
    } else if (match(content, /(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
      if (content !~ /=>/ && content !~ /=[[:space:]]*(async[[:space:]]+)?function/) next
      name = substr(content, RSTART, RLENGTH)
      sub(/(const|let|var)[[:space:]]+/, "", name)
    }
    if (name == "") next
    vis = (content ~ /export/) ? "export" : "default"
    is_static = 0

    esc_name = escape(name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047function\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), esc_name, sig, linenum, vis, is_static
  }

  # ============================================================
  # File dependency modes
  # ============================================================
  else if (mode == "cs_usings") {
    if (match(content, /using[[:space:]]+([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*;/)) {
      ns = substr(content, RSTART, RLENGTH)
      sub(/using[[:space:]]+/, "", ns)
      sub(/[[:space:]]*;/, "", ns)
      if (ns ~ /^static/ || content ~ /=/) next
      esc_ns = escape(ns)
      printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_ns
    }
  }

  else if (mode == "php_includes") {
    if (match(content, /(require|include)(_once)?[[:space:]]*[\(]?[[:space:]]*[\047"][^\047"]+[\047"]/)) {
      target = content
      if (match(target, /[\047"][^\047"]+[\047"]/)) {
        target = substr(target, RSTART+1, RLENGTH-2)
        esc_target = escape(target)
        printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_target
      }
    }
    if (match(content, /^[[:space:]]*use[[:space:]]+[A-Za-z_\\][A-Za-z0-9_\\]*/)) {
      ns = substr(content, RSTART, RLENGTH)
      sub(/^[[:space:]]*use[[:space:]]+/, "", ns)
      esc_ns = escape(ns)
      printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_ns
    }
  }

  else if (mode == "js_imports") {
    target = ""
    if (match(content, /from[[:space:]]+[\047"][^\047"]+[\047"]/)) {
      target = substr(content, RSTART, RLENGTH)
      sub(/from[[:space:]]+[\047"]/, "", target)
      sub(/[\047"]/, "", target)
    } else if (match(content, /require[[:space:]]*\([[:space:]]*[\047"][^\047"]+[\047"]/)) {
      target = substr(content, RSTART, RLENGTH)
      sub(/require[[:space:]]*\([[:space:]]*[\047"]/, "", target)
      sub(/[\047"]/, "", target)
    }
    if (target == "") next
    esc_target = escape(target)
    printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_target
  }

  else if (mode == "py_imports") {
    if (match(content, /^[[:space:]]*from[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[[:space:]]+import/)) {
      mod = substr(content, RSTART, RLENGTH)
      sub(/^[[:space:]]*from[[:space:]]+/, "", mod)
      sub(/[[:space:]]+import.*/, "", mod)
      esc_mod = escape(mod)
      printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_mod
    } else if (match(content, /^[[:space:]]*import[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*/)) {
      mod = substr(content, RSTART, RLENGTH)
      sub(/^[[:space:]]*import[[:space:]]+/, "", mod)
      esc_mod = escape(mod)
      printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_mod
    }
  }

  # ============================================================
  # C++ types (class, struct, enum, namespace)
  # ============================================================
  else if (mode == "cpp_types") {
    kind = ""
    if (content ~ /[[:space:]]class[[:space:]]/ || content ~ /^class[[:space:]]/) kind = "class"
    else if (content ~ /[[:space:]]struct[[:space:]]/ || content ~ /^struct[[:space:]]/) kind = "struct"
    else if (content ~ /[[:space:]]enum[[:space:]]/ || content ~ /^enum[[:space:]]/) kind = "enum"
    else if (content ~ /[[:space:]]namespace[[:space:]]/ || content ~ /^namespace[[:space:]]/) kind = "namespace"

    name = ""
    if (kind != "" && match(content, kind "[[:space:]]+[A-Za-z_][A-Za-z0-9_]*")) {
      name = substr(content, RSTART, RLENGTH)
      sub(kind "[[:space:]]+", "", name)
    }
    if (name == "") next

    vis = "public"
    is_static = 0
    esc_name = escape(name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047%s\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), kind, esc_name, sig, linenum, vis, is_static
  }

  # ============================================================
  # C++ methods (Class::method pattern)
  # ============================================================
  else if (mode == "cpp_methods") {
    name = ""
    classname = ""
    if (match(content, /[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
      qname = substr(content, RSTART, RLENGTH)
      sub(/[[:space:]]*\(/, "", qname)
      n = split(qname, parts, "::")
      if (n >= 2) {
        classname = parts[1]
        name = parts[n]
      }
    }
    if (name == "" || name ~ /^(operator|~)/) next

    vis = "public"
    is_static = (content ~ /[[:space:]]static[[:space:]]/) ? 1 : 0
    esc_name = escape(name)
    esc_qname = escape(classname "." name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,qualified_name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047method\047,\047%s\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), esc_name, esc_qname, sig, linenum, vis, is_static
  }

  # ============================================================
  # C++ free functions (no :: qualifier)
  # ============================================================
  else if (mode == "cpp_functions") {
    name = ""
    if (match(content, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
      name = substr(content, RSTART, RLENGTH)
      sub(/[[:space:]]*\(/, "", name)
    }
    if (name == "" || name ~ /^(main|if|for|while|switch|catch|return|sizeof|typedef)$/) next

    vis = "public"
    is_static = (content ~ /^static[[:space:]]/) ? 1 : 0
    esc_name = escape(name)
    printf "INSERT INTO code_entities (file_id,entity_kind,name,signature,line_start,visibility,is_static,last_scanned_at) VALUES (%s,\047function\047,\047%s\047,\047%s\047,%d,\047%s\047,%d,now());\n", file_id_sql(), esc_name, sig, linenum, vis, is_static
  }

  # ============================================================
  # C++ includes (uses string manipulation to avoid quote regex issues)
  # ============================================================
  else if (mode == "cpp_includes") {
    target = ""
    # Find the < or " character, extract between delimiters using gsub/substr
    tmp = content
    gsub(/^[[:space:]]*#[[:space:]]*include[[:space:]]*/, "", tmp)
    if (substr(tmp, 1, 1) == "<") {
      # System include: extract between < and >
      sub(/^</, "", tmp)
      sub(/>.*/, "", tmp)
      target = tmp
    } else if (substr(tmp, 1, 1) == "\042") {
      # Local include: extract between quotes (using \042 for double-quote)
      sub(/^\042/, "", tmp)
      sub(/\042.*/, "", tmp)
      target = tmp
    }
    if (target == "") next
    esc_target = escape(target)
    printf "INSERT INTO _fdeps VALUES (\047%s\047,\047%s\047,\047imports\047);\n", esc_path, esc_target
  }
}
' </dev/stdin
