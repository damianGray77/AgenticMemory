# run-consolidation.ps1 -- unattended judgment-tier consolidation pass.
# Invokes the consolidate-memory-db skill headless via the Claude CLI, with
# tool permissions scoped by runner-settings.json (merged over global settings).
# All real safety (dry_run, enabled kill switch, thresholds, blast-radius cap,
# soft deletes, audit log) lives in the database stored procedures, not here.
# Output is appended to .\logs\run_<stamp>.log for inspection.

$ErrorActionPreference = 'Continue'
$root   = '{{CONSOLIDATOR_ROOT_WIN}}'
$claude = '{{CLAUDE_CLI_WIN}}'

if (-not (Test-Path "$root\logs")) { New-Item -ItemType Directory -Force "$root\logs" | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log   = Join-Path "$root\logs" "run_$stamp.log"

"[$(Get-Date -Format o)] consolidation run START" | Out-File -FilePath $log -Encoding utf8
# Maintenance pass, not a work session (S703): without this, every 3-hourly run booted a {{DB_NAME}}
# session row it never closed — the source of the NULL-project orphan flood (8/day at :07 past the hour).
# session_boot.sh honors this alongside MAH_HEADLESS; the skill still has full DB access for its own work.
$env:CLAUDE_MEMORY_SKIP_BOOT = '1'
& $claude -p "/consolidate-memory-db" --settings "$root\runner-settings.json" *>> $log
"[$(Get-Date -Format o)] consolidation run END (claude exit $LASTEXITCODE)" | Out-File -FilePath $log -Append -Encoding utf8
