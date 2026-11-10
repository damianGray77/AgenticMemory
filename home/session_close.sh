#!/bin/bash
# session_close.sh — SessionEnd hook: close this session's claude_memory row.
#
# The boot (session_boot.sh) creates a sessions row keyed by CLAUDE_CODE_SESSION_ID. Without a
# close, a session stays 'active' until a later boot sweeps it to 'abandoned'. Best-effort and
# silent, like the boot. Wired in by install.ps1 -WireSessionClose.
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

"{{MEMDB_POSIX}}" -e "
  UPDATE sessions SET status = 'completed', ended_at = now(),
    summary = COALESCE(summary, '(auto-closed at session end - no in-session close ran)')
  WHERE session_uuid = '$CLAUDE_CODE_SESSION_ID' AND status = 'active';" >/dev/null 2>&1

exit 0
