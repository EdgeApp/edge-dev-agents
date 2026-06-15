#!/usr/bin/env bash
# Spawns the per-session maestro MCP server pinned to the session's slot sim.
# Stdio MCP servers inherit the claude session's env, so in a watcher slot
# ($AGENT_SIM_UDID set) the GLOBAL --device flag binds the server to that sim
# at startup — the per-call device_id tool param is ignored by maestro 2.6.0's
# session management, which under parallel slots let one session's MCP bind a
# neighbor's sim. Outside a slot (no $AGENT_SIM_UDID), behavior is unchanged.
set -euo pipefail

MAESTRO=/Users/eddy/.maestro/bin/maestro

if [ -n "${AGENT_SIM_UDID:-}" ]; then
  exec "$MAESTRO" --device "$AGENT_SIM_UDID" mcp --no-viewer "$@"
fi
exec "$MAESTRO" mcp --no-viewer "$@"
