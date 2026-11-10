# Shared helpers for install.ps1 and tools\export-from-live.ps1.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a script without a BOM as the
# ANSI code page, so a stray em dash in a string literal would be silently mangled.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# One path in the three spellings the templates use:
#   Win   C:\Users\me\.claude    (PowerShell, settings.json, CLAUDE.md prose)
#   Fwd   C:/Users/me/.claude    (hook commands)
#   Posix /c/Users/me/.claude    (Git Bash scripts)
function Get-PathForms {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $p     = $Path.TrimEnd('\', '/')
    $win   = $p.Replace('/', '\')
    $fwd   = $win.Replace('\', '/')
    $posix = $fwd
    if ($fwd -match '^([A-Za-z]):(/.*)?$') { $posix = '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    [pscustomobject]@{ Win = $win; Fwd = $fwd; Posix = $posix }
}

# Token -> value, for every {{TOKEN}} the templates may contain.
function Get-TokenMap {
    param(
        [string] $UserName, [string] $ClaudeHome, [string] $DbPath,
        [string] $ConsolidatorRoot, [string] $ClaudeCli
    )
    $home_ = Get-PathForms $ClaudeHome
    $memdb = Get-PathForms (Join-Path $ClaudeHome 'bin\memdb.exe')
    $db    = Get-PathForms $DbPath
    $run   = Get-PathForms $ConsolidatorRoot
    $map = [ordered]@{
        USER_NAME               = $UserName
        MEMDB_WIN               = $memdb.Win
        MEMDB_POSIX             = $memdb.Posix
        DB_PATH_WIN             = $db.Win
        CLAUDE_HOME_WIN         = $home_.Win
        CLAUDE_HOME_FWD         = $home_.Fwd
        CLAUDE_HOME_POSIX       = $home_.Posix
        CONSOLIDATOR_ROOT_WIN   = $run.Win
        CONSOLIDATOR_ROOT_FWD   = $run.Fwd
        CONSOLIDATOR_ROOT_POSIX = $run.Posix
        CLAUDE_CLI_WIN          = $ClaudeCli.Replace('/', '\')
    }
    return $map
}

function Read-Utf8 {
    param([Parameter(Mandatory = $true)] [string] $Path)
    # ReadAllText strips a UTF-8 BOM if one is present.
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-Utf8 {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

# Run memdb and return its stdout decoded as UTF-8, exactly. Piping a native command's output
# through PowerShell decodes it with the console code page instead, which mangles non-ASCII text.
function Invoke-MemdbCapture {
    param(
        [Parameter(Mandatory = $true)] [string] $Memdb,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Memdb
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw ("memdb exited {0}: {1}" -f $p.ExitCode, $err.Result.Trim()) }
    return $out.Result
}
