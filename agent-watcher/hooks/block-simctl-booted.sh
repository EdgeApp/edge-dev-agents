#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks `simctl ... booted` in slot sessions.
# With concurrent runs, multiple sims are booted and `booted` resolves to an
# ARBITRARY one — a session can install/launch/log against another slot's sim
# (deterministic counterpart to build-and-test's `slot-sim-is-the-clone`).
#
# Scope: no-ops unless AGENT_SIM_UDID is set (exported by spawn-test-session.sh
# in slot mode), so interactive sessions and legacy runs are unaffected.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail

[ -n "${AGENT_SIM_UDID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

if echo "$CMD" | grep -qE '\bsimctl\b' && echo "$CMD" | grep -qE '(^|[[:space:]"'"'"'])booted([[:space:]"'"'"']|$)'; then
  echo "BLOCKED: 'simctl ... booted' is ambiguous in this session — multiple sims can be booted concurrently and 'booted' may resolve to ANOTHER slot's sim (installing/launching/logging against another run's device). Your sim is AGENT_SIM_UDID=$AGENT_SIM_UDID — use that UDID explicitly in every simctl call (per slot-sim-is-the-clone). Same rule for the maestro MCP: select the device matching \$AGENT_SIM_UDID before driving." >&2
  exit 2
fi

exit 0
