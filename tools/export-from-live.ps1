<#
.SYNOPSIS
    Refresh this repo from a live claude_memory installation - the reverse of install.ps1.

.DESCRIPTION
    Copies every file listed in manifest.psd1 from the live machine into the repo, replacing the
    machine-specific values with {{TOKENS}} so the result installs anywhere:

        paths            C:\Users\you\.claude, C:\Tools\consolidator, mysql.exe, the claude CLI
        credentials      the MySQL user and password, in the patterns the scripts use them
        database name    claude_memory (whole word only, so claude_memory_schema.sql survives)
        your name        as the skills and SQL comments use it ("ask Damian" -> "ask {{USER_NAME}}")

    It also regenerates db\seed.sql from the live seed tables listed in the manifest.

    Afterwards it scans the exported files for anything that still looks machine-specific (your
    Windows user name, the password, any of the paths) and exits 1 if it finds one, so a missed
    pattern cannot slip into a commit unnoticed.

.EXAMPLE
    $env:CLAUDE_MEMORY_PASSWORD = '...'
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\export-from-live.ps1 -UserName Damian
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $UserName,
    [string] $MysqlUser = 'root',
    [string] $MysqlPassword = $env:CLAUDE_MEMORY_PASSWORD,
    [string] $DbName = 'claude_memory',
    [string] $ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [string] $ConsolidatorRoot = 'C:\Tools\consolidator',
    [string] $ClaudeCli = 'C:\Tools\npm\claude.cmd',
    [string] $MysqlExe = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside param() defaults, so resolve it here.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $here }
. (Join-Path $here 'common.ps1')

if (-not $MysqlPassword) { throw 'Pass -MysqlPassword or set CLAUDE_MEMORY_PASSWORD.' }
$manifest = Import-PowerShellDataFile (Join-Path $RepoRoot 'manifest.psd1')
$map = Get-TokenMap -UserName $UserName -DbName $DbName -MysqlUser $MysqlUser -MysqlPassword $MysqlPassword `
    -MysqlExe $MysqlExe -ClaudeHome $ClaudeHome -ConsolidatorRoot $ConsolidatorRoot -ClaudeCli $ClaudeCli

# ---------------------------------------------------------------------------------------------
# Reverse substitution rules, applied in order.
# ---------------------------------------------------------------------------------------------
$rules = New-Object System.Collections.Generic.List[object]

# 1. Paths: literal, case-insensitive, longest first so no path is half-replaced by a shorter one.
$pathTokens = $map.Keys | Where-Object { $_ -match '_(WIN|FWD|POSIX)$' }
$pathTokens | Sort-Object { $map[$_].Length } -Descending | ForEach-Object {
    $rules.Add(@{ Pattern = [regex]::Escape($map[$_]); Replacement = "{{$_}}"; Options = 'IgnoreCase' })
}

# 2. Credentials, only in the shapes the scripts actually use them. A bare search for the password
#    would also hit it in prose ("password" is a word), so match the surrounding syntax.
$u  = [regex]::Escape($MysqlUser)
$pw = [regex]::Escape($MysqlPassword)
# (Hashtables, not nested @() arrays: PowerShell flattens @(@(a,b) @(c,d)) into one list.)
$credRules = @(
    @{ P = "(-u\s*)$u(\s+-p)$pw(?![A-Za-z0-9_])"; R = '${1}{{MYSQL_USER}}${2}{{MYSQL_PASSWORD}}' }  # -u <user> -p<password>
    @{ P = "(MYSQL_PWD\s*=\s*['""])$pw(['""])";    R = '${1}{{MYSQL_PASSWORD}}${2}' }               # $env:MYSQL_PWD = '...'
    @{ P = "(\`$pw\s*=\s*['""])$pw(['""])";        R = '${1}{{MYSQL_PASSWORD}}${2}' }               # mem.ps1 fallback
    @{ P = "(MYSQL_PASS=['""])$pw(['""])";         R = '${1}{{MYSQL_PASSWORD}}${2}' }               # claude_scanner.sh
    @{ P = "(MYSQL_USER=['""])$u(['""])";          R = '${1}{{MYSQL_USER}}${2}' }                   # claude_scanner.sh
    @{ P = "('-u',\s*')$u(')";                     R = '${1}{{MYSQL_USER}}${2}' }                   # @('-u','root',...)
)
foreach ($r in $credRules) { $rules.Add(@{ Pattern = $r.P; Replacement = $r.R; Options = 'None' }) }

# 3. Database name as a whole word, so file names such as claude_memory_schema.sql are left alone.
$rules.Add(@{ Pattern = "(?<![A-Za-z0-9_])$([regex]::Escape($DbName))(?![A-Za-z0-9_])"; Replacement = '{{DB_NAME}}'; Options = 'None' })

# 4. The user's name.
$rules.Add(@{ Pattern = "\b$([regex]::Escape($UserName))\b"; Replacement = '{{USER_NAME}}'; Options = 'None' })

function ConvertTo-Template([string] $Text) {
    foreach ($r in $rules) {
        $opts = [System.Text.RegularExpressions.RegexOptions]::$($r.Options)
        $Text = [regex]::Replace($Text, $r.Pattern, $r.Replacement, $opts)
    }
    # LF in the repo; .gitattributes decides what each platform checks out.
    return $Text.Replace("`r`n", "`n")
}

# ---------------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------------
$exported = New-Object System.Collections.Generic.List[string]
$sets = @(
    @{ Source = $ClaudeHome;       Dest = 'home';                Files = $manifest.Home }
    @{ Source = $ConsolidatorRoot; Dest = 'consolidator-runner'; Files = $manifest.Runner }
)
foreach ($set in $sets) {
    foreach ($rel in $set.Files) {
        $src = Join-Path $set.Source $rel
        if (-not (Test-Path -LiteralPath $src)) { throw "Listed in manifest.psd1 but missing on this machine: $src" }
        $dst = Join-Path (Join-Path $RepoRoot $set.Dest) $rel
        Write-Utf8 $dst (ConvertTo-Template (Read-Utf8 $src))
        $exported.Add($dst)
        Write-Host ("  {0,-22} {1}" -f $set.Dest, $rel)
    }
}

# ---------------------------------------------------------------------------------------------
# db\seed.sql from the live seed tables
# ---------------------------------------------------------------------------------------------
$seed = New-Object System.Text.StringBuilder
[void]$seed.AppendLine('-- Seed rows for a new claude_memory database. GENERATED by tools/export-from-live.ps1 from the')
[void]$seed.AppendLine('-- live database: edit there and re-export rather than editing this file by hand.')
[void]$seed.AppendLine('-- reference_queries are refreshed on every install; config rows and the evidence scale are only')
[void]$seed.AppendLine('-- inserted when missing, so re-installing never resets values tuned on the target machine.')
foreach ($t in $manifest.Seed) {
    $cols    = ($t.Columns | ForEach-Object { "``$_``" }) -join ', '
    $quoted  = ($t.Columns | ForEach-Object { "QUOTE(``$_``)" }) -join ", ', ', "
    $verb    = 'INSERT INTO'
    $tail    = "';'"
    if ($t.Mode -eq 'Ignore') { $verb = 'INSERT IGNORE INTO' }
    else {
        $upd  = ($t.Columns | Where-Object { $_ -ne $t.Key } | ForEach-Object { "``$_`` = VALUES(``$_``)" }) -join ', '
        $tail = "'\n  ON DUPLICATE KEY UPDATE $upd;'"
    }
    $sql = "SELECT CONCAT('$verb ``$($t.Table)`` ($cols) VALUES (', $quoted, ')', $tail) FROM ``$($t.Table)`` ORDER BY ``$($t.Key)``;"
    $rows = Invoke-MysqlCapture -MysqlExe $MysqlExe -MysqlUser $MysqlUser -MysqlPassword $MysqlPassword -Database $DbName -Sql $sql
    [void]$seed.AppendLine('')
    [void]$seed.AppendLine("-- $($t.Table)")
    [void]$seed.Append($rows)
    Write-Host ("  {0,-22} {1}" -f 'db\seed.sql', $t.Table)
}
$seedPath = Join-Path $RepoRoot 'db\seed.sql'
Write-Utf8 $seedPath (ConvertTo-Template $seed.ToString())
$exported.Add($seedPath)

# ---------------------------------------------------------------------------------------------
# Leak scan: anything machine-specific that survived the rules above.
# ---------------------------------------------------------------------------------------------
$leakPatterns = New-Object System.Collections.Generic.List[string]
if ($env:USERNAME) { $leakPatterns.Add([regex]::Escape($env:USERNAME)) }
$leakPatterns.Add("\b$([regex]::Escape($UserName))\b")
$leakPatterns.Add("-p$pw(?![A-Za-z0-9_])")
$leakPatterns.Add("['""=]$pw['""]")
foreach ($k in $pathTokens) { $leakPatterns.Add([regex]::Escape($map[$k])) }

$leaks = 0
foreach ($f in $exported) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f, $script:Utf8NoBom)) {
        $n++
        foreach ($p in $leakPatterns) {
            if ([regex]::IsMatch($line, $p, 'IgnoreCase')) {
                $leaks++
                Write-Warning ("possible leak  {0}:{1}  [{2}]  {3}" -f $f.Substring($RepoRoot.Length + 1), $n, $p, $line.Trim())
            }
        }
    }
}
if ($leaks -gt 0) {
    Write-Warning "$leaks possible leak(s): extend the rules in this script, or confirm each line is safe, before committing."
    exit 1
}
Write-Host "Exported $($exported.Count) files; leak scan clean."
