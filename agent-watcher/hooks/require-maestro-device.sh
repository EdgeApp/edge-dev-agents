#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Requires an explicit --device on maestro CLI
# invocations in slot sessions. With concurrent runs, multiple sims are booted
# and an unpinned maestro driver attaches to an arbitrary one — a session can
# drive ANOTHER slot's app (the cross-slot contention that needed an operator
# intervention). The maestro MCP daemon also ignores device_id on this host, so
# the CLI with --device is the reliable path for proof runs.
#
# Scope: no-ops unless AGENT_SIM_UDID is set. Exit 0 allow, exit 2 block.
set -euo pipefail

[ -n "${AGENT_SIM_UDID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Only gate maestro test/record runs; `maestro --help`, mcp, etc. pass through.
echo "$CMD" | grep -qE '\bmaestro\b[[:space:]]+(test|record|studio)' || exit 0
echo "$CMD" | grep -q -- '--device' && exit 0

echo "BLOCKED: maestro without --device is ambiguous in this session - multiple sims can be booted and the driver attaches to an arbitrary one (it may drive ANOTHER slot's app). Use: maestro --device $AGENT_SIM_UDID test <flow>. Note the maestro MCP daemon ignores device_id on this host; for MCP exploration verify the daemon's bound device matches \$AGENT_SIM_UDID first, and use the CLI for proof runs." >&2
exit 2
