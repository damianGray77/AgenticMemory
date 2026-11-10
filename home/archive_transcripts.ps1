<#
  archive_transcripts.ps1 — Lossless retention of Claude Code session transcripts.

  Sweeps ~/.claude/projects/**/*.jsonl and archives each transcript VERBATIM into
  the {{DB_NAME}} DB:
    - transcripts          : the whole .jsonl, zlib-compressed (COMPRESS), + metadata
    - transcript_messages  : one row per user/assistant line (uuid + byte offset/length
                             into the UNCOMPRESSED bytes + extracted text for FULLTEXT),
                             plus one role='user' row per message {{USER_NAME}} typed while Claude
                             was working (a queued_command attachment line, see Test-HumanQueued)

  Idempotent: an unchanged file is skipped via a free byte-size comparison (transcripts are
  append-only, so size is a reliable change signal; content_sha256 is still stored from the
  loaded bytes). JSONL being append-only also means existing message byte-offsets never shift
  as a file grows; a grown file is re-captured on the next sweep by UPDATING its transcripts
  row IN PLACE (upsert keyed on uq_transcript_path) and re-indexing its messages. The id must
  stay stable across re-ingest: a DELETE+reinsert would mint a new id and ON DELETE CASCADE
  would silently destroy memory_sources back-pointers referencing the old transcript_id.

  No Python (per environment): ConvertFrom-Json + LOAD DATA LOCAL INFILE + COMPRESS().
  The bytes read for parsing are what gets archived: they are staged to a short %TEMP% path for
  LOAD DATA, because mysql.exe cannot open a path of 260+ chars (deep scratch-workspace subagent
  transcripts) and re-reading a live file could capture bytes the index never saw.

  Size limit: every reader does UNCOMPRESS(raw_jsonl), which returns NULL when the uncompressed
  transcript is larger than the server's max_allowed_packet. The server runs with
  SET PERSIST max_allowed_packet = 1G (MySQL's ceiling); a transcript over the live limit is still
  archived (retention comes first) but warned about, since nothing can read it back until raised.

  -Reindex rebuilds transcript_messages for transcripts ALREADY archived, parsing the archived
  bytes (the .jsonl may be long gone) - use it after changing what Parse-Bytes indexes. It never
  touches raw_jsonl or transcripts.id, and skips a transcript a concurrent sweep re-ingested
  after it was read (content_sha256 checked under a row lock).

  Usage:
    powershell -NoProfile -File archive_transcripts.ps1
    powershell -NoProfile -File archive_transcripts.ps1 -Only ScratchML -MaxFiles 2
    powershell -NoProfile -Command "& 'archive_transcripts.ps1' -Reindex -Ids 12492,12551"
#>
[CmdletBinding()]
param(
  [string]$ProjectsRoot = (Join-Path $HOME '.claude\projects'),
  [string]$Only        = $null,   # only process source paths containing this substring (testing)
  [int]   $MaxFiles    = 0,       # 0 = no limit (testing)
  [int]   $MsgTextCap  = 16000,   # cap stored msg_text length (raw blob keeps the full content)
  [int]   $BatchRows   = 500,     # transcript_messages rows per INSERT statement
  [switch]$Reindex,               # re-index archived transcripts from their DB copy instead of sweeping disk
  [int[]] $Ids         = @()      # -Reindex: only these transcripts.id values (with -Only/-MaxFiles also honored)
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$MysqlExe = '{{MYSQL_EXE_WIN}}'
if (-not (Test-Path -LiteralPath $MysqlExe)) { throw "mysql.exe not found at $MysqlExe" }
$env:MYSQL_PWD = '{{MYSQL_PASSWORD}}'   # pass password via env so mysql does not emit the insecure-password stderr warning
$BaseArgs  = @('-u','{{MYSQL_USER}}','--default-character-set=utf8mb4','{{DB_NAME}}')
$LocalArgs = @('--local-infile=1') + $BaseArgs

function Invoke-Mysql([string[]]$mysqlArgs, [string]$stdin = $null) {
  # PS 5.1: relax EAP around the native call so a stray stderr line is not promoted to a terminating error.
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    if ($null -ne $stdin) { $out = $stdin | & $MysqlExe @mysqlArgs 2>&1 }
    else                  { $out =          & $MysqlExe @mysqlArgs 2>&1 }
  } finally { $ErrorActionPreference = $eap }
  if ($LASTEXITCODE -ne 0) { throw ("mysql failed (exit $LASTEXITCODE): " + (($out | ForEach-Object { $_.ToString() }) -join "`n")) }
  return $out
}
function Run-Sql([string[]]$extraArgs, [string]$sql) { return (Invoke-Mysql $extraArgs $sql) }
function Run-SqlFile([string[]]$extraArgs, [string]$file) {
  $fwd = $file.Replace('\','/')
  return (Invoke-Mysql ($extraArgs + @('-e',"SOURCE $fwd")))
}

function Esc([string]$s) {
  # Escape a value for a single-quoted MySQL string literal (default sql_mode: backslash is an escape).
  if ($null -eq $s) { return $null }
  return $s.Replace('\','\\').Replace("'","\'")
}
function SqlStr($s)  { if ($null -eq $s) { 'NULL' } else { "'" + (Esc $s) + "'" } }
function SqlDate($s) { if ([string]::IsNullOrWhiteSpace($s)) { 'NULL' } else { "'" + ($s.Substring(0,[Math]::Min(19,$s.Length)).Replace('T',' ')) + "'" } }

function Read-BytesShared([string]$path) {
  # Shared read so an actively-appending writer (a live session) cannot block the sweep.
  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  $ms = $null
  try { $ms = New-Object System.IO.MemoryStream; $fs.CopyTo($ms); return ,$ms.ToArray() }   # comma: see Read-ArchivedBytes
  finally { $fs.Dispose(); if ($ms) { $ms.Dispose() } }
}
function Get-MsgText($content) {
  if ($null -eq $content) { return $null }
  if ($content -is [string]) { return $content }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($b in $content) {
    if ($null -eq $b) { continue }
    switch ($b.type) {
      'text'     { if ($b.text) { [void]$parts.Add([string]$b.text) } }
      'tool_use' { [void]$parts.Add("[tool_use: $($b.name)]") }
      # tool_result bodies and thinking are intentionally NOT indexed (raw blob keeps them).
    }
  }
  if ($parts.Count -eq 0) { return $null }
  return ($parts -join "`n")
}
function Test-HumanQueued($o) {
  # A message {{USER_NAME}} types while Claude is working is not a user line: Claude Code stores it as an
  # attachment line of type queued_command with the text in attachment.prompt. Task notifications and
  # messages from other sessions share that type but carry origin.kind task-notification/peer/coordinator
  # (or, in older versions, commandMode task-notification and no origin); only kind 'human' is {{USER_NAME}}.
  return ($o.type -eq 'attachment' -and $o.attachment -and $o.attachment.type -eq 'queued_command' -and
          $o.attachment.origin -and $o.attachment.origin.kind -eq 'human')
}

# Parse raw .jsonl bytes: byte offsets per line + extracted user/assistant messages.
function Parse-Bytes([byte[]]$bytes) {
  $nl = [byte]0x0A; $cr = [byte]0x0D
  $rows = New-Object System.Collections.Generic.List[object]
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $pos = 0; $seq = 0; $total = 0
  while ($pos -lt $bytes.Length) {
    $idx = [Array]::IndexOf($bytes, $nl, $pos)
    if ($idx -lt 0) { $ce = $bytes.Length } else { $ce = $idx }
    if ($ce -gt $pos -and $bytes[$ce-1] -eq $cr) { $ce-- }   # strip a trailing CR if CRLF
    $len = $ce - $pos
    if ($len -gt 0) {
      $txt = [System.Text.Encoding]::UTF8.GetString($bytes, $pos, $len)
      $o = $null; try { $o = $txt | ConvertFrom-Json } catch {}
      $role = $null; $mt = $null
      if ($o -and $o.uuid) {
        if ($o.type -eq 'user' -or $o.type -eq 'assistant') {
          $role = if ($o.message -and $o.message.role) { [string]$o.message.role } else { [string]$o.type }
          $mt = if ($o.message) { Get-MsgText $o.message.content } else { $null }
        } elseif (Test-HumanQueued $o) {
          $role = 'user'; $mt = Get-MsgText $o.attachment.prompt
        }
      }
      if ($role -and $seen.Add([string]$o.uuid)) {
        if ($mt -and $mt.Length -gt $MsgTextCap) { $mt = $mt.Substring(0,$MsgTextCap) }
        $rows.Add([pscustomobject]@{
          seq = $seq; uuid = [string]$o.uuid
          parent = if ($o.parentUuid) { [string]$o.parentUuid } else { $null }
          role = $role; offset = $pos; length = $len; lineNo = $total + 1
          ts = if ($o.timestamp) { [string]$o.timestamp } else { $null }
          text = $mt
        })
        $seq++
      }
    }
    $total++
    if ($idx -lt 0) { break }
    $pos = $idx + 1
  }
  return [pscustomobject]@{ TotalLines = $total; Messages = $rows }
}

# Append batched INSERTs of parsed message rows into $table, with $tidExpr as transcript_id.
function Add-MessageInserts([System.Text.StringBuilder]$sb, [string]$table, [string]$tidExpr, $msgs) {
  for ($i=0; $i -lt $msgs.Count; $i++) {
    if ($i % $BatchRows -eq 0) {
      if ($i -gt 0) { [void]$sb.AppendLine(";") }
      [void]$sb.AppendLine("INSERT INTO $table (transcript_id, seq, message_uuid, parent_uuid, role, byte_offset, byte_length, line_number, ts, msg_text) VALUES")
    } else { [void]$sb.AppendLine(",") }
    $m = $msgs[$i]
    [void]$sb.Append("($tidExpr, $($m.seq), $(SqlStr $m.uuid), $(SqlStr $m.parent), $(SqlStr $m.role), $($m.offset), $($m.length), $($m.lineNo), $(SqlDate $m.ts), $(SqlStr $m.text))")
  }
  if ($msgs.Count -gt 0) { [void]$sb.AppendLine(";") }
}

function Read-ArchivedBytes([int]$id, [long]$size, [string]$sha) {
  # The archived, uncompressed bytes of one transcript. mysql.exe output reaches PowerShell as decoded
  # text, so the blob comes back as base64 in chunks that each fit one packet; the SHA-256 check also
  # catches a blob UNCOMPRESS cannot return (larger than max_allowed_packet comes back NULL).
  $chunk = 8MB
  $sql = New-Object System.Text.StringBuilder
  [void]$sql.AppendLine("SET @b := (SELECT IF(is_compressed, UNCOMPRESS(raw_jsonl), raw_jsonl) FROM transcripts WHERE id = $id);")
  for ($off = 0; $off -lt $size; $off += $chunk) {
    [void]$sql.AppendLine("SELECT REPLACE(TO_BASE64(SUBSTRING(@b, $($off + 1), $chunk)), '\n', '');")
  }
  $ms = New-Object System.IO.MemoryStream
  try {
    foreach ($line in (Run-Sql ($BaseArgs + @('--batch','--skip-column-names','--max-allowed-packet=64M')) $sql.ToString())) {
      if ($line -isnot [string]) { continue }   # a stderr record, not data
      $b = [Convert]::FromBase64String($line); $ms.Write($b, 0, $b.Length)
    }
    $bytes = $ms.ToArray()
  } finally { $ms.Dispose() }
  $got = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
  if ($got -ne $sha) { throw "archived bytes did not round-trip (got $($bytes.Length) of $size bytes; sha mismatch)" }
  return ,$bytes   # the comma stops PowerShell unrolling the array into boxed objects
}

try {
Write-Host "=== archive_transcripts: sweeping $ProjectsRoot ==="
if (-not (Test-Path -LiteralPath $ProjectsRoot)) { throw "Projects root not found: $ProjectsRoot" }

# Enable local_infile once for this run (LOAD DATA LOCAL needs server + client both on).
Run-Sql $LocalArgs "SET GLOBAL local_infile = 1;" | Out-Null
$maxPacket = [long]((Run-Sql ($BaseArgs + @('--batch','--skip-column-names')) "SELECT @@global.max_allowed_packet;") | Where-Object { $_ -is [string] } | Select-Object -First 1)

# Staged copies a killed run (hook timeout) left behind; an hour old so a concurrent sweep's are spared.
Get-ChildItem -LiteralPath $env:TEMP -File -Filter 'cm_*' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^cm_(raw|ingest|reindex)_[0-9a-f]{32}\.(jsonl|sql)$' -and $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

if ($Reindex) {
  # Rebuild the message index of already-archived transcripts from their archived bytes. raw_jsonl and
  # transcripts.id are untouched, so memory_sources (keyed on message uuids) keep resolving; seq values
  # may shift. Only message_count is refreshed: first/last_message_at feed the digest's "active again"
  # check (v_digest_sessions) and stay as the last ingest set them.
  $where = New-Object System.Collections.Generic.List[string]
  if ($Ids.Count) { [void]$where.Add("id IN (" + ($Ids -join ',') + ")") }
  if ($Only)      { [void]$where.Add("LOCATE($(SqlStr $Only), source_path) > 0") }
  $q = "SELECT id, byte_size, content_sha256 FROM transcripts" + $(if ($where.Count) { " WHERE " + ($where -join ' AND ') } else { '' }) + " ORDER BY id;"
  $done=0; $skipped=0; $errors=0; $msgTotal=0
  foreach ($line in (Run-Sql ($BaseArgs + @('--batch','--skip-column-names')) $q)) {
    if ($line -isnot [string] -or [string]::IsNullOrWhiteSpace($line)) { continue }
    $id,$size,$sha = $line.Trim() -split "`t",3
    try {
      $msgs = (Parse-Bytes (Read-ArchivedBytes ([int]$id) ([long]$size) $sha)).Messages
      # Stage the rows, then swap them in only if the transcript still holds the bytes just parsed: a
      # concurrent sweep that re-ingested a grown file in the meantime has already indexed it.
      $sb = New-Object System.Text.StringBuilder
      [void]$sb.AppendLine("CREATE TEMPORARY TABLE _cm_stage_msgs AS SELECT transcript_id, seq, message_uuid, parent_uuid, role, byte_offset, byte_length, line_number, ts, msg_text FROM transcript_messages LIMIT 0;")
      Add-MessageInserts $sb '_cm_stage_msgs' $id $msgs
      [void]$sb.AppendLine(@"
START TRANSACTION;
SET @tid := NULL;
SELECT id INTO @tid FROM transcripts WHERE id = $id AND content_sha256 = $(SqlStr $sha) FOR UPDATE;
DELETE FROM transcript_messages WHERE transcript_id = @tid;
INSERT INTO transcript_messages (transcript_id, seq, message_uuid, parent_uuid, role, byte_offset, byte_length, line_number, ts, msg_text)
  SELECT transcript_id, seq, message_uuid, parent_uuid, role, byte_offset, byte_length, line_number, ts, msg_text
  FROM _cm_stage_msgs WHERE @tid IS NOT NULL;
UPDATE transcripts SET message_count = $($msgs.Count), updated_at = updated_at WHERE id = @tid;
COMMIT;
SELECT @tid IS NOT NULL;
"@)
      $tmp = Join-Path $env:TEMP ("cm_reindex_{0}.sql" -f ([guid]::NewGuid().ToString('N')))
      [System.IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
      try { $out = Run-SqlFile ($BaseArgs + @('--batch','--skip-column-names')) $tmp } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
      if ((@($out | Where-Object { $_ -is [string] }) | Select-Object -Last 1) -eq '1') {
        $done++; $msgTotal += $msgs.Count
        Write-Host ("  ~ transcript {0}  msgs={1}" -f $id, $msgs.Count)
      } else {
        $skipped++
        Write-Host ("  = transcript {0}: re-ingested since it was read; left as the sweep indexed it" -f $id)
      }
    } catch {
      $errors++
      Write-Warning ("  ! transcript {0}: {1}" -f $id, $_.Exception.Message)
    }
    if ($MaxFiles -gt 0 -and $done -ge $MaxFiles) { break }
  }
  Write-Host ("=== reindex done: reindexed={0} skipped(changed)={1} errors={2} messages_indexed={3} ===" -f $done,$skipped,$errors,$msgTotal)
  return
}

# Existing (source_path -> sha) for skip detection.
$existing = @{}
foreach ($line in (Run-Sql ($BaseArgs + @('--batch','--skip-column-names')) "SELECT source_path, byte_size FROM transcripts;")) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $p,$sz = $line -split "`t",2
  $existing[$p] = [long]$sz
}

# Map Claude Code session UUID -> DB session id (session_boot.sh records session_uuid going forward).
$sessByUuid = @{}
foreach ($line in (Run-Sql ($BaseArgs + @('--batch','--skip-column-names')) "SELECT session_uuid, id FROM sessions WHERE session_uuid IS NOT NULL;")) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $u,$sid = $line -split "`t",2
  $sessByUuid[$u] = [int]$sid
}

$files = Get-ChildItem -LiteralPath $ProjectsRoot -Recurse -File -Filter *.jsonl
$seen=0; $skipped=0; $ingested=0; $msgTotal=0; $errors=0
foreach ($f in $files) {
  $fullFwd = $f.FullName.Replace('\','/')
  if ($Only -and ($fullFwd -notmatch [regex]::Escape($Only))) { continue }
  $seen++
  try {
    # Fast skip: transcripts are append-only, so an unchanged file keeps the same byte size.
    if ($existing.ContainsKey($fullFwd) -and $existing[$fullFwd] -eq $f.Length) { $skipped++; continue }
    $bytes = Read-BytesShared $f.FullName
    # Never replace archived content with nothing (a 0-byte file has nothing to retain).
    if ($bytes.Length -eq 0) { $skipped++; continue }

    # Identity from the path.
    $rel  = $f.FullName.Substring($ProjectsRoot.Length).TrimStart('\','/')
    $segs = $rel -split '[\\/]'
    if ($rel -match '[\\/]subagents[\\/]') { $kind='subagent'; $parent=$segs[1]; $sessionUuid=$f.BaseName }
    else                                   { $kind='main';     $parent=$null;   $sessionUuid=$f.BaseName }
    $sessId = if ($kind -eq 'main' -and $sessByUuid.ContainsKey($sessionUuid)) { $sessByUuid[$sessionUuid] } else { 'NULL' }

    $parsed = Parse-Bytes $bytes
    $msgs   = $parsed.Messages
    $first  = if ($msgs.Count) { ($msgs | Where-Object { $_.ts } | Select-Object -First 1).ts } else { $null }
    $last   = if ($msgs.Count) { ($msgs | Where-Object { $_.ts } | Select-Object -Last  1).ts } else { $null }
    $pathLit = SqlStr $fullFwd
    $guid    = [guid]::NewGuid().ToString('N')
    $rawTmp  = Join-Path $env:TEMP "cm_raw_$guid.jsonl"
    $tmp     = Join-Path $env:TEMP "cm_ingest_$guid.sql"

    # Raw blob + metadata + message index, as ONE transactional script over ONE
    # connection (UTF-8 no-BOM temp file + SOURCE). The raw bytes (the ones parsed
    # above, written to $rawTmp) are staged with LOAD DATA LOCAL into a temp table,
    # then UPSERTed into transcripts keyed on
    # uq_transcript_path: a re-ingested (grown) file UPDATES ITS ROW IN PLACE,
    # keeping transcripts.id stable. Never DELETE+reinsert here — the cascade on
    # fk_src_transcript would destroy memory_sources back-pointers (message uuids
    # and byte offsets are append-only-stable, so surviving pointers stay valid).
    # transcript_messages have no inbound FKs and are simply re-indexed.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(@"
CREATE TEMPORARY TABLE _cm_stage_raw (raw LONGBLOB NOT NULL);
LOAD DATA LOCAL INFILE $(SqlStr $rawTmp.Replace('\','/'))
  INTO TABLE _cm_stage_raw
  FIELDS TERMINATED BY '\0' ESCAPED BY ''
  LINES TERMINATED BY '\0'
  (@raw)
  SET raw = @raw;
START TRANSACTION;
INSERT INTO transcripts
  (raw_jsonl, is_compressed, byte_size, content_sha256, session_uuid, kind,
   parent_session_uuid, source_path, project_id, session_id, line_count,
   message_count, first_message_at, last_message_at)
SELECT COMPRESS(raw), 1, LENGTH(raw), SHA2(raw, 256), $(SqlStr $sessionUuid), '$kind',
       $(SqlStr $parent), $pathLit, NULL, $sessId, $($parsed.TotalLines),
       $($msgs.Count), $(SqlDate $first), $(SqlDate $last)
  FROM _cm_stage_raw
ON DUPLICATE KEY UPDATE
  raw_jsonl = VALUES(raw_jsonl), is_compressed = VALUES(is_compressed),
  byte_size = VALUES(byte_size), content_sha256 = VALUES(content_sha256),
  session_uuid = VALUES(session_uuid), kind = VALUES(kind),
  parent_session_uuid = VALUES(parent_session_uuid), session_id = VALUES(session_id),
  line_count = VALUES(line_count), message_count = VALUES(message_count),
  first_message_at = VALUES(first_message_at), last_message_at = VALUES(last_message_at);
SET @tid := (SELECT id FROM transcripts WHERE source_path = $pathLit);
DELETE FROM transcript_messages WHERE transcript_id = @tid;
"@)
    Add-MessageInserts $sb 'transcript_messages' '@tid' $msgs
    [void]$sb.AppendLine("COMMIT;")
    try {
      [System.IO.File]::WriteAllBytes($rawTmp, $bytes)
      [System.IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
      Run-SqlFile $LocalArgs $tmp | Out-Null
    } finally { Remove-Item -LiteralPath $rawTmp, $tmp -ErrorAction SilentlyContinue }

    $ingested++; $msgTotal += $msgs.Count
    Write-Host ("  + {0}  [{1}]  lines={2} msgs={3}" -f $f.Name, $kind, $parsed.TotalLines, $msgs.Count)
    if ($bytes.Length -gt $maxPacket) {
      Write-Warning ("  ! {0}: archived, but {1:N0} MB is over max_allowed_packet ({2:N0} MB) - UNCOMPRESS(raw_jsonl) returns NULL for it until that is raised" -f $f.Name, ($bytes.Length / 1MB), ($maxPacket / 1MB))
    }
    if ($MaxFiles -gt 0 -and $ingested -ge $MaxFiles) { break }
  } catch {
    $errors++
    Write-Warning ("  ! {0}: {1}" -f $f.Name, $_.Exception.Message)
  }
}

Write-Host ("=== done: seen={0} ingested={1} skipped(unchanged)={2} errors={3} messages_indexed={4} ===" -f $seen,$ingested,$skipped,$errors,$msgTotal)
} catch {
  # Never disrupt a session start/end: log and exit clean even if (e.g.) MySQL is momentarily down.
  Write-Warning ("archive_transcripts aborted: " + $_.Exception.Message)
  exit 0
}
