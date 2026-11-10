<#
.SYNOPSIS
    Install the claude_memory system into a Claude Code installation on Windows.

.DESCRIPTION
    Fills the {{TOKENS}} in this repo's templates with this machine's values and installs:

      1. Files      home\*                -> the Claude config folder (~\.claude)
                    consolidator-runner\* -> the consolidation runner folder (C:\Tools\consolidator)
      2. Database   the claude_memory database: tables, seed rows, stored procedures, views, and
                    the hourly mechanical-consolidation event
      3. Settings   SessionStart/SessionEnd hooks in ~\.claude\settings.json, and Claude Code's
                    built-in auto memory turned off (the database replaces it)
      4. Optional   the 3-hourly judgment-tier consolidation task (-RegisterConsolidationTask)

    Safe to re-run, which is also how you upgrade: a file that would change is backed up first to
    ~\.claude\backups\claude-memory-install-<stamp>\, tables are only created when missing,
    procedures, views and the event are replaced, and existing config rows are kept.

.PARAMETER UserName
    Your name as the skills should use it ("ask <name>", "<name>'s decisions").

.PARAMETER MysqlPassword
    Password for -MysqlUser. If omitted: $env:CLAUDE_MEMORY_PASSWORD, else a prompt. It is written
    into the installed scripts, as on the original machine, so use a local-only MySQL account.

.PARAMETER WireSessionClose
    Also add session_close.sh as a SessionEnd hook, so a session's row is marked completed when it
    ends instead of being swept to 'abandoned' by the next boot. Off by default, matching the
    original machine (where it is wired only for Codex).

.PARAMETER RegisterConsolidationTask
    Register the Windows scheduled task that runs the consolidate-memory-db skill headless every
    3 hours. Needs the claude CLI at a path a scheduled task can reach (-ClaudeCli).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName Damian

.EXAMPLE
    .\install.ps1 -UserName Damian -RegisterConsolidationTask -ClaudeCli C:\Tools\npm\claude.cmd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $UserName,
    [string] $MysqlUser = 'root',
    [string] $MysqlPassword,
    [string] $DbName = 'claude_memory',
    [string] $ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [string] $ConsolidatorRoot = 'C:\Tools\consolidator',
    [string] $ClaudeCli,
    [string] $MysqlExe,
    [switch] $WireSessionClose,
    [switch] $RegisterConsolidationTask,
    [string] $TaskName = 'ClaudeMemoryConsolidation',
    [switch] $SkipFiles,
    [switch] $SkipDatabase,
    [switch] $SkipServerSettings,
    [switch] $SkipSettings
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repo 'tools\common.ps1')
$manifest = Import-PowerShellDataFile (Join-Path $repo 'manifest.psd1')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $ClaudeHome "backups\claude-memory-install-$stamp"

function Write-Step([string] $Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }
function Write-Item([string] $State, [string] $What) { Write-Host ("   {0,-10} {1}" -f $State, $What) }

# =============================================================================================
# Inputs
# =============================================================================================
Write-Step 'Checking inputs'

# Each value is written verbatim into SQL literals, bash and PowerShell, so restrict the alphabet
# rather than try to escape for all three.
if ($UserName -notmatch '^[A-Za-z][A-Za-z .-]*$') { throw '-UserName: letters, spaces, dots and hyphens only.' }
if ($DbName -notmatch '^[A-Za-z0-9_]+$')        { throw '-DbName: letters, digits and underscores only.' }
if ($MysqlUser -notmatch '^[A-Za-z0-9_.-]+$')   { throw '-MysqlUser: letters, digits, _ . - only.' }

if (-not $MysqlPassword) { $MysqlPassword = $env:CLAUDE_MEMORY_PASSWORD }
if (-not $MysqlPassword) {
    $secure = Read-Host "MySQL password for '$MysqlUser'" -AsSecureString
    $MysqlPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if ($MysqlPassword -notmatch '^[A-Za-z0-9_.@#%^+=~,:-]+$') {
    throw 'The MySQL password ends up unquoted in bash and PowerShell commands. Use only letters, digits and _ . @ # % ^ + = ~ , : -'
}

if (-not $MysqlExe) {
    $found = Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { $MysqlExe = $found.FullName }
    else {
        $cmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
        if ($cmd) { $MysqlExe = $cmd.Source }
    }
}
if (-not $MysqlExe -or -not (Test-Path -LiteralPath $MysqlExe)) { throw 'mysql.exe not found. Install MySQL Server 8.0, or pass -MysqlExe.' }
Write-Item 'mysql' $MysqlExe

if (-not $ClaudeCli) {
    foreach ($name in @('claude.exe', 'claude.cmd')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $ClaudeCli = $cmd.Source; break }
    }
    if (-not $ClaudeCli) {
        $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
        if (Test-Path -LiteralPath $native) { $ClaudeCli = $native }
    }
}
if ($ClaudeCli) { Write-Item 'claude' $ClaudeCli }
else {
    $ClaudeCli = 'claude'
    Write-Warning 'claude CLI not found; the consolidation runner will call plain "claude". Pass -ClaudeCli before using -RegisterConsolidationTask.'
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash -and -not (Test-Path 'C:\Program Files\Git\bin\bash.exe')) {
    Write-Warning 'bash not found. The session boot hook and the scanner need Git for Windows (Git Bash).'
}

$map = Get-TokenMap -UserName $UserName -DbName $DbName -MysqlUser $MysqlUser -MysqlPassword $MysqlPassword `
    -MysqlExe $MysqlExe -ClaudeHome $ClaudeHome -ConsolidatorRoot $ConsolidatorRoot -ClaudeCli $ClaudeCli
Write-Item 'home' $map.CLAUDE_HOME_WIN
Write-Item 'runner' $map.CONSOLIDATOR_ROOT_WIN
Write-Item 'database' $DbName

# =============================================================================================
# Rendering
# =============================================================================================
function Expand-Template([string] $Source) {
    $text = Read-Utf8 $Source
    foreach ($k in $map.Keys) { $text = $text.Replace("{{$k}}", [string]$map[$k]) }
    $left = @([regex]::Matches($text, '\{\{[A-Z_]+\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($left.Count -gt 0) { throw "Unfilled token(s) $($left -join ', ') in $Source" }
    # Bash scripts must be LF whatever git checked out.
    if ($Source.EndsWith('.sh')) { $text = $text.Replace("`r`n", "`n") }
    return $text
}

function Save-Backup([string] $Target, [string] $Root) {
    $rel = $Target.Substring($Root.TrimEnd('\').Length).TrimStart('\')
    $dest = Join-Path $backupRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $Target -Destination $dest -Force
}

# Write $Text to $Target, backing up a different existing file first. Returns what happened.
function Set-InstalledFile([string] $Target, [string] $Text, [string] $Root) {
    if (Test-Path -LiteralPath $Target) {
        if ((Read-Utf8 $Target) -ceq $Text) { return 'unchanged' }
        Save-Backup $Target $Root
        Write-Utf8 $Target $Text
        return 'updated'
    }
    Write-Utf8 $Target $Text
    return 'created'
}

# CLAUDE.md may already hold someone's own instructions. Keep them: the rules go in a marked block
# that a re-install replaces in place. A CLAUDE.md that IS the rules (the original layout, or a
# previous install into an empty folder) is simply replaced.
$blockBegin = '<!-- BEGIN claude-memory rules (managed by install.ps1) -->'
$blockEnd   = '<!-- END claude-memory rules -->'
function Merge-ClaudeMd([string] $Target, [string] $Rules) {
    if (-not (Test-Path -LiteralPath $Target)) { return $Rules }
    $existing = Read-Utf8 $Target
    $b = $existing.IndexOf($blockBegin)
    $e = $existing.IndexOf($blockEnd)
    if ($b -ge 0 -and $e -gt $b) {
        return $existing.Substring(0, $b) + $blockBegin + "`n" + $Rules.TrimEnd() + "`n" + $existing.Substring($e)
    }
    if ($existing.Contains('The Database Is Your Memory')) { return $Rules }
    return $existing.TrimEnd() + "`n`n" + $blockBegin + "`n" + $Rules.TrimEnd() + "`n" + $blockEnd + "`n"
}

# =============================================================================================
# 1. Files
# =============================================================================================
if (-not $SkipFiles) {
    Write-Step "Installing files into $($map.CLAUDE_HOME_WIN)"
    foreach ($rel in $manifest.Home) {
        $text = Expand-Template (Join-Path $repo "home\$rel")
        $target = Join-Path $ClaudeHome $rel
        if ($rel -eq 'CLAUDE.md') { $text = Merge-ClaudeMd $target $text }
        Write-Item (Set-InstalledFile $target $text $ClaudeHome) $rel
    }

    Write-Step "Installing the consolidation runner into $($map.CONSOLIDATOR_ROOT_WIN)"
    foreach ($rel in $manifest.Runner) {
        $text = Expand-Template (Join-Path $repo "consolidator-runner\$rel")
        Write-Item (Set-InstalledFile (Join-Path $ConsolidatorRoot $rel) $text $ConsolidatorRoot) $rel
    }
    foreach ($d in @('logs', 'runs')) { New-Item -ItemType Directory -Force -Path (Join-Path $ConsolidatorRoot $d) | Out-Null }
}

# =============================================================================================
# 2. Database
# =============================================================================================
function Invoke-SqlFile([string] $Path, [bool] $NoDb) {
    $a = @('-u', $MysqlUser, '--default-character-set=utf8mb4')
    if (-not $NoDb) { $a += $DbName }
    $a += @('-e', "SOURCE $($Path.Replace('\', '/'))")
    $env:MYSQL_PWD = $MysqlPassword
    try { & $MysqlExe @a }
    finally { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { throw "mysql failed (exit $LASTEXITCODE) on $Path" }
}

if (-not $SkipDatabase) {
    Write-Step "Building database $DbName"
    $tmp = Join-Path $env:TEMP "claude-memory-install-$stamp"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $i = 0
        foreach ($step in $manifest.Database) {
            if ($SkipServerSettings -and $step.File -eq 'db:server-settings.sql') { Write-Item 'skipped' $step.File; continue }
            $kind, $rel = $step.File -split ':', 2
            $src = Join-Path $repo ("{0}\{1}" -f ($(if ($kind -eq 'db') { 'db' } else { 'home' })), $rel)
            $i++
            $rendered = Join-Path $tmp ('{0:D2}_{1}' -f $i, [System.IO.Path]::GetFileName($rel))
            Write-Utf8 $rendered (Expand-Template $src)
            Invoke-SqlFile $rendered ([bool]$step.NoDb)
            Write-Item 'applied' $step.File
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $sql = "SELECT " +
        "(SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DbName' AND table_type = 'BASE TABLE'), " +
        "(SELECT COUNT(*) FROM information_schema.views WHERE table_schema = '$DbName'), " +
        "(SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = '$DbName' AND routine_type = 'PROCEDURE'), " +
        "(SELECT COUNT(*) FROM information_schema.events WHERE event_schema = '$DbName'), " +
        "@@global.event_scheduler;"
    $row = (Invoke-MysqlCapture -MysqlExe $MysqlExe -MysqlUser $MysqlUser -MysqlPassword $MysqlPassword -Sql $sql).Trim() -split "`t"
    $exp = $manifest.Expect
    Write-Item 'tables' ("{0} (expected {1})" -f $row[0], $exp.Tables)
    Write-Item 'views' ("{0} (expected {1})" -f $row[1], $exp.Views)
    Write-Item 'procs' ("{0} (expected {1})" -f $row[2], $exp.Procedures)
    Write-Item 'events' ("{0} (expected {1}); event_scheduler={2}" -f $row[3], $exp.Events, $row[4])
    if ([int]$row[0] -lt $exp.Tables -or [int]$row[1] -lt $exp.Views -or [int]$row[2] -lt $exp.Procedures -or [int]$row[3] -lt $exp.Events) {
        throw 'The database is missing objects; see the mysql output above.'
    }
    if ($row[4] -ne 'ON') { Write-Warning 'event_scheduler is OFF: the hourly mechanical consolidation will not run until it is turned on.' }
}

# =============================================================================================
# 3. settings.json hooks
# =============================================================================================
function Set-Prop($Object, [string] $Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function New-Obj([object[]] $Pairs) {
    # Ordered properties without relying on [pscustomobject] casts of hashtable variables, which
    # Windows PowerShell 5.1 does not convert.
    $o = New-Object psobject
    for ($j = 0; $j -lt $Pairs.Count; $j += 2) { $o | Add-Member -NotePropertyName $Pairs[$j] -NotePropertyValue $Pairs[$j + 1] }
    return $o
}

# Re-indent ConvertTo-Json output: Windows PowerShell 5.1 pads with ragged runs of spaces.
function Format-Json([string] $Json) {
    $sb = New-Object System.Text.StringBuilder
    $depth = 0; $inStr = $false; $esc = $false
    foreach ($c in $Json.ToCharArray()) {
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false } elseif ($c -eq [char]'\') { $esc = $true } elseif ($c -eq [char]'"') { $inStr = $false }
            continue
        }
        if ($c -eq [char]'"') { $inStr = $true; [void]$sb.Append($c) }
        elseif ($c -eq [char]'{' -or $c -eq [char]'[') { $depth++; [void]$sb.Append($c).Append("`n").Append('  ' * $depth) }
        elseif ($c -eq [char]'}' -or $c -eq [char]']') { $depth--; [void]$sb.Append("`n").Append('  ' * $depth).Append($c) }
        elseif ($c -eq [char]',') { [void]$sb.Append(",`n").Append('  ' * $depth) }
        elseif ($c -eq [char]':') { [void]$sb.Append(': ') }
        elseif (-not [char]::IsWhiteSpace($c)) { [void]$sb.Append($c) }
    }
    $out = [regex]::Replace($sb.ToString(), '([\[{])\s+([\]}])', '$1$2')
    # 5.1 also escapes these for HTML safety; plain characters are valid JSON and easier to read.
    foreach ($pair in @(@('\u0027', "'"), @('\u0026', '&'), @('\u003c', '<'), @('\u003e', '>'))) { $out = $out.Replace($pair[0], $pair[1]) }
    return $out + "`n"
}

if (-not $SkipSettings) {
    Write-Step "Wiring hooks into $($map.CLAUDE_HOME_WIN)\settings.json"
    $settingsPath = Join-Path $ClaudeHome 'settings.json'
    $settings = $null
    if (Test-Path -LiteralPath $settingsPath) {
        $raw = Read-Utf8 $settingsPath
        if ($raw.Trim()) { $settings = $raw | ConvertFrom-Json }
    }
    if ($null -eq $settings) { $settings = New-Object psobject }
    if (-not $settings.PSObject.Properties['hooks']) { Set-Prop $settings 'hooks' (New-Object psobject) }

    function Add-Hook([string] $HookEvent, [string] $Matcher, [string] $Command, [int] $Timeout, [string] $Status, [string] $Marker) {
        $groups = @()
        if ($settings.hooks.PSObject.Properties[$HookEvent]) { $groups = @($settings.hooks.$HookEvent) }
        foreach ($g in $groups) {
            foreach ($h in @($g.hooks)) {
                if ($h -and $h.command -and ([string]$h.command).Contains($Marker)) { Write-Item 'present' "$HookEvent $Marker"; return }
            }
        }
        $hook = New-Obj @('type', 'command', 'command', $Command, 'timeout', $Timeout, 'statusMessage', $Status)
        if ($Matcher) { $group = New-Obj @('matcher', $Matcher, 'hooks', @($hook)) }
        else          { $group = New-Obj @('hooks', @($hook)) }
        Set-Prop $settings.hooks $HookEvent (@($groups) + @($group))
        Write-Item 'added' "$HookEvent $Marker"
    }

    $archiveCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($map.CLAUDE_HOME_WIN)\archive_transcripts.ps1`""
    $bootCmd    = "bash `"$($map.CLAUDE_HOME_FWD)/session_boot.sh`""
    $closeCmd   = "bash `"$($map.CLAUDE_HOME_FWD)/session_close.sh`""
    Add-Hook 'SessionStart' ''        $archiveCmd 120 'Archiving session transcripts...'          'archive_transcripts.ps1'
    Add-Hook 'SessionStart' 'startup' $bootCmd    60  "Booting session from $DbName..."          'session_boot.sh'
    Add-Hook 'SessionEnd'   ''        $archiveCmd 120 'Archiving session transcripts...'          'archive_transcripts.ps1'
    if ($WireSessionClose) {
        Add-Hook 'SessionEnd' ''      $closeCmd   30  "Closing $DbName session..."               'session_close.sh'
    }
    # Rule 1: the database is the only memory. Claude Code's own file-based auto memory would compete.
    Set-Prop $settings 'autoMemoryEnabled' $false
    Write-Item 'set' 'autoMemoryEnabled = false'

    $json = Format-Json (ConvertTo-Json -InputObject $settings -Depth 32)
    $null = $json | ConvertFrom-Json   # never write a file Claude Code cannot parse
    Write-Item (Set-InstalledFile $settingsPath $json $ClaudeHome) 'settings.json'
}

# =============================================================================================
# 4. Scheduled consolidation (optional)
# =============================================================================================
if ($RegisterConsolidationTask) {
    Write-Step "Registering scheduled task $TaskName"
    $runner = Join-Path $ConsolidatorRoot 'run-consolidation.ps1'
    # conhost --headless keeps the 3-hourly run from flashing a console window.
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$runner`""
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(7)) -RepetitionInterval (New-TimeSpan -Hours 3)
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    # Interactive: runs only while you are logged on, with your profile and your Claude login.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $taskSettings -Principal $principal `
        -Description "Claude memory consolidation (judgment tier) via the consolidate-memory-db skill, every 3 hours. Gated by consolidation_config in $DbName." `
        -Force | Out-Null
    Write-Item 'registered' "$TaskName -> $runner"
}

# =============================================================================================
Write-Step 'Done'
if (Test-Path -LiteralPath $backupRoot) { Write-Host "   Replaced files were backed up to $backupRoot" }
Write-Host @"

   Next:
   1. Start a NEW Claude Code session. Its context should open with '=== SESSION: <n> ==='.
   2. Register each project so boot can match it and the code index can be built:
        bash "$($map.CLAUDE_HOME_FWD)/claude_scanner.sh" onboard <slug> '<Name>' '<C:/path/to/project>'
   3. Optional: rerun with -RegisterConsolidationTask for the 3-hourly consolidation pass.
"@
