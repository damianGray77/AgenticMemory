# run-consolidation.ps1 -- unattended judgment-tier consolidation pass.
# Invokes the consolidate-memory-db skill headless via the Claude CLI, with
# tool permissions scoped by runner-settings.json (merged over global settings).
# All real safety (dry_run, enabled kill switch, thresholds, blast-radius cap,
# soft deletes, audit log) lives in the consolidation procedures inside memdb, not here.
# Output is appended to .\logs\run_<stamp>.log for inspection.

$ErrorActionPreference = 'Continue'
$root   = '{{CONSOLIDATOR_ROOT_WIN}}'
$claude = '{{CLAUDE_CLI_WIN}}'

if (-not (Test-Path "$root\logs")) { New-Item -ItemType Directory -Force "$root\logs" | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log   = Join-Path "$root\logs" "run_$stamp.log"

"[$(Get-Date -Format o)] consolidation run START" | Out-File -FilePath $log -Encoding utf8
# A maintenance pass, not a work session: without this, every run would boot a claude_memory
# session row it never closes. session_boot.sh honours it; the skill keeps full database access.
$env:CLAUDE_MEMORY_SKIP_BOOT = '1'
& $claude -p "/consolidate-memory-db" --settings "$root\runner-settings.json" *>> $log
"[$(Get-Date -Format o)] consolidation run END (claude exit $LASTEXITCODE)" | Out-File -FilePath $log -Append -Encoding utf8
