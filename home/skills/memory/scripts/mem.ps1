<#
.SYNOPSIS
    Write to the {{DB_NAME}} database - notes, memories, observations, session close, back-pointers.

.DESCRIPTION
    This exists for three reasons, in order of how much they actually hurt.

    1. QUOTING. Memory content is prose: apostrophes, em dashes, newlines, embedded SQL, Windows
       paths full of backslashes. Threading that through `mysql -e "..."` inside a shell is fragile
       enough that sessions routinely gave up and wrote throwaway .sql files to a scratch directory
       first. Content arrives here through -ContentFile (or stdin) and never touches a command line
       or a shell parser, so there is nothing to escape by hand.

    2. PERMISSION CHURN. Claude Code appends the LITERAL command string to permissions.allow when
       you approve one. Because every INSERT carried unique prose, every write minted a new
       single-use rule that could never match again - 379 of them, 539 KB, including whole memory
       bodies frozen into a settings file. One stable script means one prefix rule, forever.

    3. DRIFT. Required columns, the memory_type enum, the observations upsert that bumps
       observed_count and nudges confidence, the memory_sources shape - every session re-derived
       these from CLAUDE.md and some got them subtly wrong. They live here once.

    The password stays out of argv: a --defaults-file is used when present, so the credential is
    not visible in the command line, the process list, the approved-command list, or the transcript.

.PARAMETER Action
    note | memory | observe | close | source. See the EXAMPLES.

.PARAMETER ContentFile
    Path to a UTF-8 file holding the body. Preferred over -Content: nothing to escape, no size
    limit, and the command stays short enough to read. Use '-' to read stdin.

.EXAMPLE
    .\mem.ps1 -Action note -SessionId 1382 -Type decision -Title "Chose X over Y" -ContentFile note.txt
    .\mem.ps1 -Action memory -Type project -Category completed_work -ProjectId 8 -Title "..." -ContentFile m.txt
    .\mem.ps1 -Action observe -Category workstyle -Title "Prefers terse diffs" -ContentFile o.txt
    .\mem.ps1 -Action close -SessionId 1382 -Summary "..." -Topics '["archive","fable"]'
    .\mem.ps1 -Action source -MemoryId 1465 -TranscriptId 3150 -StartUuid abc -EndUuid def
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('note', 'memory', 'observe', 'close', 'source')]
    [string] $Action,

    # --- content (all write actions) ---------------------------------------------------------
    [string] $Title,
    [string] $Content,
    [string] $ContentFile,

    # --- note ---------------------------------------------------------------------------------
    [int] $SessionId,

    # note_type (free-form by schema; these are the CLAUDE.md set) or memory_type (a real ENUM).
    [string] $Type,

    # --- memory / observe ---------------------------------------------------------------------
    [string] $Category,
    [int] $ProjectId = 0,          # 0 => NULL (a global memory, not project-scoped)
    [int] $Priority = 0,           # 0 => leave the column default
    [string] $ExpiresAt,

    # --- observe -------------------------------------------------------------------------------
    [double] $ConfidenceStep = 0.10,

    # --- close -----------------------------------------------------------------------------------
    [string] $Summary,
    [string] $Files,               # JSON array literal
    [string] $Topics,              # JSON array literal
    [ValidateSet('completed', 'abandoned', 'active')]
    [string] $Status = 'completed',

    # --- source (Rule 11 back-pointers) ----------------------------------------------------------
    [int] $MemoryId,
    [int] $NoteId,
    [int] $TranscriptId,
    [string] $StartUuid,
    [string] $EndUuid,
    [string] $Rationale,

    # --- plumbing ---------------------------------------------------------------------------------
    [string] $MysqlExe = '{{MYSQL_EXE_WIN}}',
    [string] $DefaultsFile = "$env:USERPROFILE\.claude\.my.cnf",
    [string] $Database = '{{DB_NAME}}',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# SQL string literal escaping. Order matters: the backslash must be doubled FIRST, or the
# backslashes introduced when escaping quotes get doubled a second time and corrupt the value.
# Windows paths ("C:\Projects\...") make this a routine case, not a corner one.
# ---------------------------------------------------------------------------------------------
function ConvertTo-SqlLiteral {
    param([AllowNull()] [string] $Value)
    if ($null -eq $Value) { return 'NULL' }
    $e = $Value.Replace('\', '\\').Replace("'", "''")
    return "'" + $e + "'"
}

function ConvertTo-SqlNumber {
    param([int] $Value, [int] $NullWhen = 0)
    if ($Value -eq $NullWhen) { return 'NULL' }
    return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# Body resolution. -ContentFile wins; '-' means stdin. Reading as raw UTF-8 keeps em dashes and
# newlines intact - the schema columns are TEXT, so there is no reason to flatten anything.
function Resolve-Body {
    if ($ContentFile) {
        # [Console]::In, not $input: $input only carries pipeline input bound to THIS function, and
        # nothing is piped into Resolve-Body - it would silently read as empty.
        if ($ContentFile -eq '-') {
            return [Console]::In.ReadToEnd()
        }
        if (-not (Test-Path -LiteralPath $ContentFile)) {
            throw "ContentFile not found: $ContentFile"
        }
        $full = (Resolve-Path -LiteralPath $ContentFile).ProviderPath
        return [System.IO.File]::ReadAllText($full, [System.Text.UTF8Encoding]::new($false))
    }
    if ($PSBoundParameters.ContainsKey('Content')) { return $Content }
    return $null
}

# title is VARCHAR(255) on memories/session_notes/user_observations. Fail loudly rather than let
# the server truncate a title silently - a clipped title is how a memory becomes unfindable later.
function Assert-Title {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "-Title is required for action '$Action'." }
    if ($Value.Length -gt 255) { throw "-Title is $($Value.Length) chars; the column is VARCHAR(255). Shorten it." }
}

function Assert-Body {
    param([AllowNull()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "A body is required for action '$Action' - pass -ContentFile (preferred) or -Content."
    }
}

$body = Resolve-Body

switch ($Action) {

    'note' {
        if ($SessionId -le 0) { throw "-SessionId is required for a note." }
        if ([string]::IsNullOrWhiteSpace($Type)) { $Type = 'context' }
        Assert-Title $Title
        Assert-Body $body
        $sql = @"
INSERT INTO session_notes (session_id, note_type, title, content)
VALUES ($SessionId, $(ConvertTo-SqlLiteral $Type), $(ConvertTo-SqlLiteral $Title), $(ConvertTo-SqlLiteral $body));
SELECT LAST_INSERT_ID();
"@
    }

    'memory' {
        # memory_type is a real ENUM - reject a bad value here with a readable message rather than
        # letting MySQL emit "Data truncated for column 'memory_type'", which says nothing useful.
        $valid = @('user', 'feedback', 'project', 'reference')
        if ($valid -notcontains $Type) {
            throw "-Type must be one of: $($valid -join ', ')  (got '$Type')"
        }
        Assert-Title $Title
        Assert-Body $body
        $cols = @('project_id', 'memory_type', 'category', 'title', 'content')
        $vals = @(
            (ConvertTo-SqlNumber $ProjectId),
            (ConvertTo-SqlLiteral $Type),
            (ConvertTo-SqlLiteral $Category),
            (ConvertTo-SqlLiteral $Title),
            (ConvertTo-SqlLiteral $body)
        )
        # The consolidation pass confirms a memory by checking it against its session's transcript,
        # so every memory needs its session. Without -SessionId, use this Claude Code session's row:
        # session_boot.sh stores CLAUDE_CODE_SESSION_ID as sessions.session_uuid. NULL if none matches.
        if ($SessionId -gt 0) {
            $cols += 'source_session'; $vals += (ConvertTo-SqlNumber $SessionId)
        } elseif ($env:CLAUDE_CODE_SESSION_ID) {
            $cols += 'source_session'
            $vals += "(SELECT MAX(id) FROM sessions WHERE session_uuid = $(ConvertTo-SqlLiteral $env:CLAUDE_CODE_SESSION_ID))"
        }
        if ($Priority -gt 0) { $cols += 'priority';       $vals += (ConvertTo-SqlNumber $Priority) }
        if ($ExpiresAt)      { $cols += 'expires_at';     $vals += (ConvertTo-SqlLiteral $ExpiresAt) }
        $sql = @"
INSERT INTO memories ($($cols -join ', '))
VALUES ($($vals -join ', '));
SELECT LAST_INSERT_ID();
"@
    }

    'observe' {
        # user_observations has UNIQUE(title), which is what makes this an upsert rather than a
        # duplicate: re-observing the same pattern bumps the count and nudges confidence toward 1.0
        # instead of littering near-identical rows. The clamp lives here so every caller shares it.
        if ([string]::IsNullOrWhiteSpace($Category)) { throw "-Category is required for an observation." }
        Assert-Title $Title
        Assert-Body $body
        $step = $ConfidenceStep.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        $sql = @"
INSERT INTO user_observations (category, title, content)
VALUES ($(ConvertTo-SqlLiteral $Category), $(ConvertTo-SqlLiteral $Title), $(ConvertTo-SqlLiteral $body))
ON DUPLICATE KEY UPDATE
  observed_count = observed_count + 1,
  last_seen      = NOW(),
  confidence     = LEAST(confidence + $step, 1.00);
SELECT LAST_INSERT_ID();
"@
    }

    'close' {
        if ($SessionId -le 0) { throw "-SessionId is required to close a session." }
        $sets = @("status = $(ConvertTo-SqlLiteral $Status)", 'ended_at = NOW()')
        if ($PSBoundParameters.ContainsKey('Summary')) { $sets += "summary = $(ConvertTo-SqlLiteral $Summary)" }
        elseif ($body)                                 { $sets += "summary = $(ConvertTo-SqlLiteral $body)" }
        if ($Files)  { $sets += "files_touched = $(ConvertTo-SqlLiteral $Files)" }
        if ($Topics) { $sets += "topics = $(ConvertTo-SqlLiteral $Topics)" }
        $sql = @"
UPDATE sessions SET $($sets -join ', ') WHERE id = $SessionId;
SELECT ROW_COUNT();
"@
    }

    'source' {
        # Rule 11: a memory may have MANY spans, so this appends one row per call rather than
        # replacing. end_message_uuid NULL means the span is a single message.
        if ($MemoryId -le 0 -and $NoteId -le 0) { throw "Pass -MemoryId or -NoteId." }
        if ($MemoryId -gt 0 -and $NoteId -gt 0)  { throw "Pass only ONE of -MemoryId / -NoteId." }
        if ($TranscriptId -le 0)                 { throw "-TranscriptId is required." }
        if ([string]::IsNullOrWhiteSpace($StartUuid)) { throw "-StartUuid is required." }
        $srcType = 'memory'
        if ($NoteId -gt 0) { $srcType = 'session_note' }
        $endLit = 'NULL'
        if ($EndUuid) { $endLit = ConvertTo-SqlLiteral $EndUuid }
        $sql = @"
INSERT INTO memory_sources (source_type, memory_id, note_id, transcript_id, start_message_uuid, end_message_uuid, rationale)
VALUES ($(ConvertTo-SqlLiteral $srcType), $(ConvertTo-SqlNumber $MemoryId), $(ConvertTo-SqlNumber $NoteId),
        $TranscriptId, $(ConvertTo-SqlLiteral $StartUuid), $endLit, $(ConvertTo-SqlLiteral $Rationale));
SELECT LAST_INSERT_ID();
"@
    }
}

$script = "USE ``$Database``;`n$sql"

if ($DryRun) {
    Write-Output $script
    return
}

if (-not (Test-Path -LiteralPath $MysqlExe)) { throw "mysql.exe not found at: $MysqlExe" }

# Credentials: a --defaults-file keeps them out of argv entirely. Without one we fall back to the
# documented local-dev login, so the script works on a machine that has not been hardened yet.
$connArgs = @()
if (Test-Path -LiteralPath $DefaultsFile) {
    $connArgs += "--defaults-file=$DefaultsFile"
} else {
    $pw = $env:CLAUDE_MEMORY_PASSWORD
    if (-not $pw) { $pw = '{{MYSQL_PASSWORD}}' }
    $connArgs += @('-u', '{{MYSQL_USER}}', "-p$pw")
}
# -N -B: no column headers, tab-separated - the caller wants the inserted id, not a rendered table.
$connArgs += @('-N', '-B')

# NOT optional. The script is written as UTF-8, but the client otherwise decodes stdin using its own
# default (the console codepage here), and every character it cannot map silently becomes a literal
# '?'. Verified: without this an em dash round-tripped to HEX 3F3F3F - three question marks, stored
# and unrecoverable. Prose memories are full of em dashes, curly quotes and accented names, so a
# silent lossy write is the worst possible failure for an archive nobody re-reads immediately.
$connArgs += '--default-character-set=utf8mb4'

# Piped over stdin rather than passed with -e: no command-line length ceiling, and the prose never
# meets a shell parser.
#
# THE UNICODE PATH, which took three attempts to get right - each stage silently degrades prose:
#   1. $OutputEncoding governs how a string piped into a NATIVE process is encoded, and in Windows
#      PowerShell 5.1 it defaults to ASCIIEncoding. Left alone, every non-ASCII character reaches
#      mysql as '?'. Measured: an em dash stored as HEX 3F3F3F.
#   2. --default-character-set=utf8mb4 alone fixes nothing, because that loss happens upstream of
#      the client. Both are required.
#   3. Do NOT stage this through a temp file read back with Get-Content: without a BOM, 5.1 decodes
#      the file as the ANSI codepage, so UTF-8 bytes come back as mojibake and then get re-encoded
#      as UTF-8 (an em dash became C3A2E282AC...). $script is already in memory - pipe it directly
#      and there is no decode step to get wrong.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# No 2>&1 here: in Windows PowerShell 5.1, redirecting a NATIVE command's stderr wraps each line in
# a NativeCommandError and flips $? to false even on a clean exit 0. stderr passes through to the
# caller on its own; the exit code is the honest success signal.
$out = $script | & $MysqlExe @connArgs
$code = $LASTEXITCODE
$text = ($out | Out-String).Trim()
if ($code -ne 0) {
    throw "mysql exited $code : $text"
}
Write-Output $text
