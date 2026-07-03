#!/usr/bin/env bash
# Spawns the per-session maestro MCP server pinned to the session's slot sim.
# Stdio MCP servers inherit the claude session's env, so in a watcher slot
# ($AGENT_SIM_UDID set) the GLOBAL --device flag binds the server to that sim
# at startup — the per-call device_id tool param is ignored by maestro 2.6.0's
# session management, which under parallel slots let one session's MCP bind a
# neighbor's sim. Outside a slot (no $AGENT_SIM_UDID), behavior is unchanged.
# Driver port isolation (maestro >= 2.6.0, hidden --driver-host-port): the
# daemon's iOS driver gets METRO+2000 — distinct from CLI proof runs at
# METRO+1000 (both can be live in the same slot simultaneously) and unique
# per slot (parallel slots' drivers stay off each other's ports).
set -euo pipefail

MAESTRO=/Users/eddy/.maestro/bin/maestro

if [ -n "${AGENT_SIM_UDID:-}" ]; then
  PORT_ARGS=()
  [ -n "${AGENT_METRO_PORT:-}" ] && PORT_ARGS=(--driver-host-port "$((AGENT_METRO_PORT + 2000))")
  exec "$MAESTRO" --device "$AGENT_SIM_UDID" ${PORT_ARGS[@]+"${PORT_ARGS[@]}"} mcp --no-viewer "$@"
fi
exec "$MAESTRO" mcp --no-viewer "$@"
