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
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

if echo "$CMD_M" | grep -qE '\bsimctl\b' && echo "$CMD" | grep -qE '(^|[[:space:]"'"'"'])booted([[:space:]"'"'"']|$)'; then
  echo "BLOCKED: 'simctl ... booted' is ambiguous in this session — multiple sims can be booted concurrently and 'booted' may resolve to ANOTHER slot's sim (installing/launching/logging against another run's device). Your sim is AGENT_SIM_UDID=$AGENT_SIM_UDID — use that UDID explicitly in every simctl call (per slot-sim-is-the-clone). Same rule for the maestro MCP: select the device matching \$AGENT_SIM_UDID before driving." >&2
  exit 2
fi

exit 0
