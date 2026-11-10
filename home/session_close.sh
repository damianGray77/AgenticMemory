#!/bin/bash
# session_close.sh — SessionEnd hook: close this session's {{DB_NAME}} row (S703).
#
# The boot (session_boot.sh) creates a sessions row keyed by CLAUDE_CODE_SESSION_ID — set by Claude Code
# AND by the codex hook engine (claude-compatible env; verified: 322/323 orphan rows carried a uuid).
# Without a close, codex sessions stayed 'active' until a later boot swept them to 'abandoned' — the
# NULL-project orphan flood. Best-effort and silent, like the boot.
#
# A Rule-7 MANUAL close (status + summary written in-session) is never overwritten: this touches only a
# row that is still 'active' for THIS session's uuid, and only fills the summary when none was written.

# Same guards as the boot — a session that never booted has nothing to close.
[ -n "$MAH_HEADLESS" ] && exit 0
[ -n "$CLAUDE_MEMORY_SKIP_BOOT" ] && exit 0
[ -z "$CLAUDE_CODE_SESSION_ID" ] && exit 0

# The uuid comes from the hook engine, but never trust it into SQL unvalidated.
case "$CLAUDE_CODE_SESSION_ID" in
  *[!0-9a-fA-F-]*) exit 0 ;;
esac

MYSQL="{{MYSQL_EXE_POSIX}}"
"$MYSQL" -u {{MYSQL_USER}} -p{{MYSQL_PASSWORD}} -e "USE {{DB_NAME}}; \
  UPDATE sessions SET status='completed', ended_at=NOW(), \
    summary=COALESCE(summary, '(auto-closed at session end - no in-session close ran)') \
  WHERE session_uuid='$CLAUDE_CODE_SESSION_ID' AND status='active';" 2>/dev/null

exit 0
