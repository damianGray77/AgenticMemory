<#
.SYNOPSIS
    Compile memdb.exe from memdb\src with the C# compiler that ships with Windows (.NET Framework 4.x).

.DESCRIPTION
    Nothing to download: csc.exe is part of .NET Framework 4.8, which Windows 10 (1903+) and
    Windows 11 include, and the SQLite engine memdb drives is winsqlite3.dll, also part of Windows.
    Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File memdb\build.ps1 -OutFile C:\Users\me\.claude\bin\memdb.exe
#>
[CmdletBinding()]
param(
    [string] $OutFile,
    # Build with only these procedure files (e.g. -Procs Digest), plus the core. Default: all.
    [string[]] $Procs
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutFile) { $OutFile = Join-Path $here 'bin\memdb.exe' }

$csc = $null
foreach ($fw in @('Framework64', 'Framework')) {
    $p = Join-Path $env:WINDIR "Microsoft.NET\$fw\v4.0.30319\csc.exe"
    if (Test-Path -LiteralPath $p) { $csc = $p; break }
}
if (-not $csc) { throw 'csc.exe not found: .NET Framework 4.x is required (it is built into Windows 10 1903+ and Windows 11).' }
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\winsqlite3.dll'))) {
    throw 'winsqlite3.dll not found in System32: Windows 10 or 11 is required.'
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# powershell -File passes "-Procs A,B" as one string; accept both forms.
if ($Procs) { $Procs = @($Procs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$src = @(Get-ChildItem -LiteralPath (Join-Path $here 'src') -Filter *.cs | Sort-Object Name | Where-Object {
    if (-not $Procs -or $_.Name -notmatch '^Procs\.(.+)\.cs$') { return $true }
    return $Procs -contains $Matches[1]
} | ForEach-Object { $_.FullName })
$out = & $csc /nologo /target:exe /optimize+ /platform:anycpu /warn:4 /nowarn:1591 `
    /r:System.dll /r:System.Core.dll /r:System.IO.Compression.dll "/out:$OutFile" $src 2>&1
$code = $LASTEXITCODE
$out | ForEach-Object { Write-Host $_ }
if ($code -ne 0) { throw "csc failed (exit $code)" }
Write-Host "built $OutFile"
