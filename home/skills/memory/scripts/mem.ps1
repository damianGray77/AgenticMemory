<#
.SYNOPSIS
    Write to the claude_memory database - notes, memories, observations, session close, back-pointers.

.DESCRIPTION
    This exists for three reasons, in order of how much they actually hurt.

    1. QUOTING. Memory content is prose: apostrophes, em dashes, newlines, embedded SQL, Windows
       paths full of backslashes. Threading that through a database CLI's -e "..." inside a shell is
       fragile enough that sessions routinely gave up and wrote throwaway .sql files to a scratch
       directory first. Content arrives here through -ContentFile (or stdin) and never touches a
       command line or a shell parser, so there is nothing to escape by hand.

    2. PERMISSION CHURN. Claude Code appends the LITERAL command string to permissions.allow when
       you approve one. Because every INSERT carried unique prose, every write minted a new
       single-use rule that could never match again - hundreds of them, including whole memory
       bodies frozen into a settings file. One stable script means one prefix rule, forever.

    3. DRIFT. Required columns, the memory_type enum, the observations upsert that bumps
       observed_count and nudges confidence, the memory_sources shape - every session re-derived
       these from CLAUDE.md and some got them subtly wrong. They live here once.

    The database is SQLite, driven by memdb.exe; memdb finds the database file itself.

.PARAMETER Action
    note | memory | observe | close | source. See the EXAMPLES.

.PARAMETER ContentFile
    Path to a UTF-8 file holding the body. Preferred over -Content: nothing to escape, no size
    limit, and the command stays short enough to read. Use '-' to read stdin.

.EXAMPLE
    .\mem.ps1 -Action note -SessionId 1382 -Type decision -Title "Chose X over Y" -ContentFile note.txt
    .\mem.ps1 -Action memory -Type project -Category completed_work -ProjectId 8 -Title "..." -ContentFile m.txt
    .\mem.ps1 -Action observe -Category workstyle -Title "Prefers terse diffs" -ContentFile o.txt
    .\mem.ps1 -Action close -SessionId 1382 -Summary "..." -Topics '["archive","search"]'
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

    # note_type (free-form by schema; these are the CLAUDE.md set) or memory_type (a real enum).
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
    [string] $Memdb = '{{MEMDB_WIN}}',
    [string] $DbPath,              # default: wherever memdb resolves it
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# SQL string literal. SQLite has exactly one escape: a single quote is doubled. Backslashes are
# ordinary characters, so Windows paths ("C:\Projects\...") go in untouched.
# ---------------------------------------------------------------------------------------------
function ConvertTo-SqlLiteral {
    param([AllowNull()] [string] $Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + $Value.Replace("'", "''") + "'"
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

# Titles are capped at 255 characters (a CHECK constraint). Fail loudly with a readable message
# rather than a constraint error - a clipped title is how a memory becomes unfindable later.
function Assert-Title {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "-Title is required for action '$Action'." }
    if ($Value.Length -gt 255) { throw "-Title is $($Value.Length) chars; the limit is 255. Shorten it." }
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
VALUES ($SessionId, $(ConvertTo-SqlLiteral $Type), $(ConvertTo-SqlLiteral $Title), $(ConvertTo-SqlLiteral $body))
RETURNING id;
"@
    }

    'memory' {
        # memory_type is a CHECK-constrained enum - reject a bad value here with a readable message.
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
VALUES ($($vals -join ', '))
RETURNING id;
"@
    }

    'observe' {
        # user_observations has a UNIQUE (case-insensitive) title, which is what makes this an upsert
        # rather than a duplicate: re-observing the same pattern bumps the count and nudges confidence
        # toward 1.0 instead of littering near-identical rows. Rounded to 2 places, as the column was
        # DECIMAL(3,2) under MySQL and the boot filters on confidence >= 0.50.
        if ([string]::IsNullOrWhiteSpace($Category)) { throw "-Category is required for an observation." }
        Assert-Title $Title
        Assert-Body $body
        $step = $ConfidenceStep.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        $sql = @"
INSERT INTO user_observations (category, title, content)
VALUES ($(ConvertTo-SqlLiteral $Category), $(ConvertTo-SqlLiteral $Title), $(ConvertTo-SqlLiteral $body))
ON CONFLICT (title) DO UPDATE SET
  observed_count = observed_count + 1,
  last_seen      = now(),
  confidence     = min(round(confidence + $step, 2), 1.00)
RETURNING id;
"@
    }

    'close' {
        if ($SessionId -le 0) { throw "-SessionId is required to close a session." }
        $sets = @("status = $(ConvertTo-SqlLiteral $Status)", 'ended_at = now()')
        if ($PSBoundParameters.ContainsKey('Summary')) { $sets += "summary = $(ConvertTo-SqlLiteral $Summary)" }
        elseif ($body)                                 { $sets += "summary = $(ConvertTo-SqlLiteral $body)" }
        if ($Files)  { $sets += "files_touched = $(ConvertTo-SqlLiteral $Files)" }
        if ($Topics) { $sets += "topics = $(ConvertTo-SqlLiteral $Topics)" }
        $sql = @"
UPDATE sessions SET $($sets -join ', ') WHERE id = $SessionId;
SELECT changes();
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
        $TranscriptId, $(ConvertTo-SqlLiteral $StartUuid), $endLit, $(ConvertTo-SqlLiteral $Rationale))
RETURNING id;
"@
    }
}

if ($DryRun) {
    Write-Output $sql
    return
}

if (-not (Test-Path -LiteralPath $Memdb)) { throw "memdb.exe not found at: $Memdb" }

$memdbArgs = @('-N')
if ($DbPath) { $memdbArgs = @('--db', $DbPath) + $memdbArgs }

# Piped over stdin rather than passed with -e: no command-line length ceiling, and the prose never
# meets a shell parser. memdb reads stdin as UTF-8.
#
# THE UNICODE PATH - each stage silently degrades prose if left alone:
#   1. $OutputEncoding governs how a string piped into a NATIVE process is encoded, and in Windows
#      PowerShell 5.1 it defaults to ASCIIEncoding: every non-ASCII character would reach memdb as
#      '?' (an em dash stored as three question marks, unrecoverably).
#   2. Do NOT stage this through a temp file read back with Get-Content: without a BOM, 5.1 decodes
#      the file as the ANSI codepage, so UTF-8 bytes come back as mojibake and then get re-encoded.
#      $sql is already in memory - pipe it directly and there is no decode step to get wrong.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# No 2>&1 here: in Windows PowerShell 5.1, redirecting a NATIVE command's stderr wraps each line in
# a NativeCommandError and flips $? to false even on a clean exit 0. stderr passes through to the
# caller on its own; the exit code is the honest success signal.
$out = $sql | & $Memdb @memdbArgs
$code = $LASTEXITCODE
$text = ($out | Out-String).Trim()
if ($code -ne 0) {
    throw "memdb exited $code : $text"
}
Write-Output $text
