# run-reflection.ps1 -- unattended sleep-time reflection pass.
# Invokes the 'reflect' skill headless via the Claude CLI, with tool permissions
# scoped by runner-settings.json. The skill reads recent work from claude_memory,
# advances the open reflection_threads, and writes one reflection row; session boot
# prints the latest one, so daytime sessions wake up having "slept on it".
# Guards live in the skill + DB: reflection_enabled kill switch, one-pass-per-day
# check, thread cap, nothing-new retirement. Output -> .\logs\run_<stamp>.log.

$ErrorActionPreference = 'Continue'
$root   = '{{REFLECTOR_ROOT_WIN}}'
$claude = '{{CLAUDE_CLI_WIN}}'

foreach ($d in @("$root\logs", "$root\runs")) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
}
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log   = Join-Path "$root\logs" "run_$stamp.log"

"[$(Get-Date -Format o)] reflection run START" | Out-File -FilePath $log -Encoding utf8
# A maintenance pass, not a work session: session_boot.sh honours this and skips
# creating a session row the run would never close.
$env:CLAUDE_MEMORY_SKIP_BOOT = '1'
& $claude -p "/reflect" --settings "$root\runner-settings.json" *>> $log
"[$(Get-Date -Format o)] reflection run END (claude exit $LASTEXITCODE)" | Out-File -FilePath $log -Append -Encoding utf8
