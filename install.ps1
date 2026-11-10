<#
.SYNOPSIS
    Install the claude_memory system into a Claude Code installation on Windows.

.DESCRIPTION
    Nothing to download and no database server: the database is a single SQLite file, driven by
    memdb.exe, which this script compiles from memdb\src with the C# compiler that ships with
    Windows, on top of the SQLite engine that also ships with Windows (winsqlite3.dll).

      1. memdb      compile memdb.exe into <ClaudeHome>\bin
      2. Files      home\*                -> the Claude config folder (~\.claude)
                    consolidator-runner\* -> the consolidation runner folder (C:\Tools\consolidator)
      3. Database   create or update the database file: tables, full-text indexes, seed rows, views
      4. Settings   SessionStart/SessionEnd hooks in ~\.claude\settings.json, and Claude Code's
                    built-in auto memory turned off (the database replaces it)
      5. Optional   the 3-hourly judgment-tier consolidation task (-RegisterConsolidationTask)

    Safe to re-run, which is also how you upgrade: a file that would change is backed up first to
    ~\.claude\backups\claude-memory-install-<stamp>\, tables are only created when missing, views
    are replaced, reference queries refreshed, and existing config rows kept.

.PARAMETER UserName
    Your name as the skills should use it ("ask <name>", "<name>'s decisions").

.PARAMETER DbPath
    Where the database file lives. Default: <ClaudeHome>\claude_memory.db.

.PARAMETER WireSessionClose
    Also add session_close.sh as a SessionEnd hook, so a session's row is marked completed when it
    ends instead of being swept to 'abandoned' by the next boot.

.PARAMETER RegisterConsolidationTask
    Register the Windows scheduled task that runs the consolidate-memory-db skill headless every
    3 hours. Needs the claude CLI at a path a scheduled task can reach (-ClaudeCli).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UserName Alex

.EXAMPLE
    .\install.ps1 -UserName Alex -RegisterConsolidationTask -ClaudeCli C:\Tools\npm\claude.cmd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $UserName,
    [string] $ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [string] $DbPath,
    [string] $ConsolidatorRoot = 'C:\Tools\consolidator',
    [string] $ClaudeCli,
    [switch] $WireSessionClose,
    [switch] $RegisterConsolidationTask,
    [string] $TaskName = 'ClaudeMemoryConsolidation',
    [switch] $SkipFiles,
    [switch] $SkipDatabase,
    [switch] $SkipSettings
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repo 'tools\common.ps1')
$manifest = Import-PowerShellDataFile (Join-Path $repo 'manifest.psd1')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $ClaudeHome "backups\claude-memory-install-$stamp"
$ClaudeHome = $ClaudeHome.TrimEnd('\', '/')
if (-not $DbPath) { $DbPath = Join-Path $ClaudeHome 'claude_memory.db' }
$memdb = Join-Path $ClaudeHome 'bin\memdb.exe'

function Write-Step([string] $Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }
function Write-Item([string] $State, [string] $What) { Write-Host ("   {0,-10} {1}" -f $State, $What) }

# =============================================================================================
# Inputs
# =============================================================================================
Write-Step 'Checking inputs'

# The name is written into SQL string literals and prose; keep its alphabet simple.
if ($UserName -notmatch '^[A-Za-z][A-Za-z .-]*$') { throw '-UserName: letters, spaces, dots and hyphens only.' }
if ($DbPath -match "'") { throw '-DbPath must not contain a single quote.' }

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

$map = Get-TokenMap -UserName $UserName -ClaudeHome $ClaudeHome -DbPath $DbPath `
    -ConsolidatorRoot $ConsolidatorRoot -ClaudeCli $ClaudeCli
Write-Item 'home' $map.CLAUDE_HOME_WIN
Write-Item 'database' $map.DB_PATH_WIN
Write-Item 'runner' $map.CONSOLIDATOR_ROOT_WIN

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
# that a re-install replaces in place. A CLAUDE.md that IS the rules (an earlier install into an
# empty folder) is simply replaced.
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
# 1. memdb
# =============================================================================================
if (-not $SkipFiles -or -not (Test-Path -LiteralPath $memdb)) {
    Write-Step "Compiling memdb.exe into $(Split-Path -Parent $memdb)"
    # csc stamps every build differently, so compare the SOURCE: an unchanged memdb.exe is left alone
    # (replacing it would also fail while another session is running it).
    $srcText = (@(Get-ChildItem -LiteralPath (Join-Path $repo 'memdb\src') -Filter *.cs | Sort-Object Name) +
                @(Get-Item -LiteralPath (Join-Path $repo 'memdb\build.ps1')) |
                ForEach-Object { $_.Name + "`n" + (Read-Utf8 $_.FullName) }) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $srcHash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($srcText)) | ForEach-Object { $_.ToString('x2') })
    $hashFile = Join-Path (Split-Path -Parent $memdb) 'memdb.srchash'
    $oldHash = if (Test-Path -LiteralPath $hashFile) { (Read-Utf8 $hashFile).Trim() } else { '' }
    if ((Test-Path -LiteralPath $memdb) -and $oldHash -eq $srcHash) {
        Write-Item 'unchanged' 'bin\memdb.exe'
    } else {
        $built = Join-Path $env:TEMP "claude-memory-memdb-$stamp.exe"
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'memdb\build.ps1') -OutFile $built | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $built)) { throw 'memdb build failed; run memdb\build.ps1 to see the compiler output.' }
        try {
            if (Test-Path -LiteralPath $memdb) {
                Save-Backup $memdb $ClaudeHome
                try { Copy-Item -LiteralPath $built -Destination $memdb -Force }
                catch { throw "Could not replace $memdb (is a memdb command still running?). Close it and re-run. $_" }
                Write-Item 'updated' 'bin\memdb.exe'
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $memdb) | Out-Null
                Copy-Item -LiteralPath $built -Destination $memdb -Force
                Write-Item 'created' 'bin\memdb.exe'
            }
            Write-Utf8 $hashFile ($srcHash + "`n")
        } finally { Remove-Item -LiteralPath $built -ErrorAction SilentlyContinue }
    }

    # memdb finds the database next to its bin folder unless told otherwise.
    $defaultDb = [System.IO.Path]::GetFullPath((Join-Path $ClaudeHome 'claude_memory.db'))
    $pathFile = Join-Path (Split-Path -Parent $memdb) 'memdb.dbpath'
    if ([System.IO.Path]::GetFullPath($DbPath) -ne $defaultDb) {
        Write-Item (Set-InstalledFile $pathFile ("# database used by memdb.exe (written by install.ps1)`n" + $DbPath + "`n") $ClaudeHome) 'bin\memdb.dbpath'
    } elseif (Test-Path -LiteralPath $pathFile) {
        Save-Backup $pathFile $ClaudeHome; Remove-Item -LiteralPath $pathFile; Write-Item 'removed' 'bin\memdb.dbpath'
    }
}

# =============================================================================================
# 2. Files
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
# 3. Database
# =============================================================================================
if (-not $SkipDatabase) {
    Write-Step "Building database $($map.DB_PATH_WIN)"
    $isNew = -not (Test-Path -LiteralPath $DbPath)
    if (-not $isNew) {
        # A consistent copy first: VACUUM INTO works while other sessions have the database open.
        $copy = Join-Path $backupRoot ('claude_memory-before-install.db')
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        Invoke-MemdbCapture -Memdb $memdb -Arguments @('--db', $DbPath, '-e', ("VACUUM INTO '" + $copy.Replace('\', '/') + "';")) | Out-Null
        Write-Item 'backed up' $copy
    }
    $tmp = Join-Path $env:TEMP "claude-memory-install-$stamp"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $i = 0
        foreach ($step in $manifest.Database) {
            $kind, $rel = $step -split ':', 2
            $src = Join-Path $repo ("{0}\{1}" -f ($(if ($kind -eq 'db') { 'db' } else { 'home' })), $rel)
            $i++
            $rendered = Join-Path $tmp ('{0:D2}_{1}' -f $i, [System.IO.Path]::GetFileName($rel))
            Write-Utf8 $rendered (Expand-Template $src)
            $memdbArgs = @('--db', $DbPath, '-f', $rendered)
            if ($i -eq 1) { $memdbArgs = @('--create') + $memdbArgs }
            Invoke-MemdbCapture -Memdb $memdb -Arguments $memdbArgs | Out-Null
            Write-Item 'applied' $step
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $sql = "SELECT " +
        "(SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite%' AND name NOT LIKE '%fts%'), " +
        "(SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%fts5%'), " +
        "(SELECT COUNT(*) FROM sqlite_schema WHERE type = 'view'), " +
        "(SELECT COUNT(*) FROM reference_queries), (SELECT COUNT(*) FROM consolidation_config);"
    $row = (Invoke-MemdbCapture -Memdb $memdb -Arguments @('--db', $DbPath, '-N', '-e', $sql)).Trim() -split "`t"
    $procs = @((Invoke-MemdbCapture -Memdb $memdb -Arguments @('--procs')).Trim() -split "`r?`n" | Where-Object { $_ })
    $exp = $manifest.Expect
    Write-Item 'tables' ("{0} (expected {1})" -f $row[0], $exp.Tables)
    Write-Item 'fts' ("{0} full-text indexes (expected {1})" -f $row[1], $exp.FtsIndexes)
    Write-Item 'views' ("{0} (expected {1})" -f $row[2], $exp.Views)
    Write-Item 'procs' ("{0} in memdb (expected {1})" -f $procs.Count, $exp.Procedures)
    Write-Item 'seed' ("{0} reference queries, {1} config rows" -f $row[3], $row[4])
    if ([int]$row[0] -lt $exp.Tables -or [int]$row[1] -lt $exp.FtsIndexes -or [int]$row[2] -lt $exp.Views -or $procs.Count -lt $exp.Procedures) {
        throw 'The database or memdb is missing objects; see above.'
    }
}

# =============================================================================================
# 4. settings.json hooks
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
    Add-Hook 'SessionStart' ''        $archiveCmd 120 'Archiving session transcripts...'   'archive_transcripts.ps1'
    Add-Hook 'SessionStart' 'startup' $bootCmd    60  'Booting session from claude_memory...' 'session_boot.sh'
    Add-Hook 'SessionEnd'   ''        $archiveCmd 120 'Archiving session transcripts...'   'archive_transcripts.ps1'
    if ($WireSessionClose) {
        Add-Hook 'SessionEnd' ''      $closeCmd   30  'Closing claude_memory session...'   'session_close.sh'
    }
    # Rule 1: the database is the only memory. Claude Code's own file-based auto memory would compete.
    Set-Prop $settings 'autoMemoryEnabled' $false
    Write-Item 'set' 'autoMemoryEnabled = false'

    $json = Format-Json (ConvertTo-Json -InputObject $settings -Depth 32)
    $null = $json | ConvertFrom-Json   # never write a file Claude Code cannot parse
    Write-Item (Set-InstalledFile $settingsPath $json $ClaudeHome) 'settings.json'
}

# =============================================================================================
# 5. Scheduled consolidation (optional)
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
        -Description 'Claude memory consolidation (judgment tier) via the consolidate-memory-db skill, every 3 hours. Gated by consolidation_config in the claude_memory database.' `
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
