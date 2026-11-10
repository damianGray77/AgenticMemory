# Shared helpers for install.ps1 and tools\export-from-live.ps1.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a script without a BOM as the
# ANSI code page, so a stray em dash in a string literal would be silently mangled.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# One path in the three spellings the templates use:
#   Win   C:\Users\me\.claude    (PowerShell, settings.json, CLAUDE.md prose)
#   Fwd   C:/Users/me/.claude    (hook commands, mysql SOURCE)
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
        [string] $UserName, [string] $DbName, [string] $MysqlUser, [string] $MysqlPassword,
        [string] $MysqlExe, [string] $ClaudeHome, [string] $ConsolidatorRoot, [string] $ClaudeCli
    )
    $exe  = Get-PathForms $MysqlExe
    $home_ = Get-PathForms $ClaudeHome
    $run  = Get-PathForms $ConsolidatorRoot
    $map = [ordered]@{
        USER_NAME               = $UserName
        DB_NAME                 = $DbName
        MYSQL_USER              = $MysqlUser
        MYSQL_PASSWORD          = $MysqlPassword
        MYSQL_EXE_WIN           = $exe.Win
        MYSQL_EXE_FWD           = $exe.Fwd
        MYSQL_EXE_POSIX         = $exe.Posix
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

# Run mysql.exe and return its stdout decoded as UTF-8, exactly. Piping a native command's output
# through PowerShell decodes it with the console code page instead, which mangles non-ASCII prose.
# The password travels in MYSQL_PWD so it never appears on a command line.
function Invoke-MysqlCapture {
    param(
        [Parameter(Mandatory = $true)] [string] $MysqlExe,
        [Parameter(Mandatory = $true)] [string] $MysqlUser,
        [Parameter(Mandatory = $true)] [string] $MysqlPassword,
        [string] $Database,
        [Parameter(Mandatory = $true)] [string] $Sql   # must not contain double quotes
    )
    if ($Sql.Contains('"')) { throw 'Invoke-MysqlCapture: the SQL must not contain double quotes.' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MysqlExe
    $dbArg = ''
    if ($Database) { $dbArg = " $Database" }
    $psi.Arguments = "-u $MysqlUser --default-character-set=utf8mb4 -N -r -B$dbArg -e `"$Sql`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $psi.EnvironmentVariables['MYSQL_PWD'] = $MysqlPassword
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw ("mysql exited {0}: {1}" -f $p.ExitCode, $err.Result.Trim()) }
    return $out.Result
}
