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

# Only gate maestro test/record/studio runs (global flags may sit between
# `maestro` and the subcommand); `maestro --help`, mcp, etc. pass through.
echo "$CMD" | grep -qE '\bmaestro\b[^|;&]*[[:space:]](test|record|studio)([[:space:]]|$)' || exit 0

MISSING=""
echo "$CMD" | grep -q -- '--device' || MISSING="--device"
# Per-slot driver port (maestro >= 2.6.0 hidden --driver-host-port): without it,
# parallel slots' iOS drivers contend. Required only when the session has a slot
# Metro port to derive it from.
if [ -n "${AGENT_METRO_PORT:-}" ]; then
  echo "$CMD" | grep -q -- '--driver-host-port' || MISSING="$MISSING --driver-host-port"
fi
[ -z "$MISSING" ] && exit 0

echo "BLOCKED: maestro run is missing:$MISSING. Multiple sims are booted and parallel slots run their own maestro drivers - an unpinned run attaches to an arbitrary sim (it may drive ANOTHER slot's app) and an unpinned driver port contends with neighbor slots. Use: maestro --device $AGENT_SIM_UDID --driver-host-port \$((AGENT_METRO_PORT + 1000)) test <flow>. Note the maestro MCP daemon ignores per-call device_id on this host; for MCP exploration verify the daemon's bound device matches \$AGENT_SIM_UDID first, and use the CLI for proof runs." >&2
exit 2
