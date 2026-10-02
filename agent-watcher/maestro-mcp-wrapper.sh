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
# The server runs behind maestro-mcp-lazy.js: the JVM starts on the session's
# first maestro tool call and stops after 10 idle minutes, so a session that
# never drives with maestro holds no JVM. MAESTRO_MCP_EAGER=1 runs the JVM
# directly, as does a machine without node.
set -euo pipefail

MAESTRO=/Users/eddy/.maestro/bin/maestro
LAZY="$(cd "$(dirname "$0")" && pwd)/maestro-mcp-lazy.js"
if [ -z "${MAESTRO_MCP_EAGER:-}" ] && [ -f "$LAZY" ] && command -v node >/dev/null 2>&1; then
  export MAESTRO_BIN="$MAESTRO"
  MAESTRO="$LAZY"
fi

if [ -n "${AGENT_SIM_UDID:-}" ]; then
  PORT_ARGS=()
  [ -n "${AGENT_METRO_PORT:-}" ] && PORT_ARGS=(--driver-host-port "$((AGENT_METRO_PORT + 2000))")
  exec "$MAESTRO" --device "$AGENT_SIM_UDID" ${PORT_ARGS[@]+"${PORT_ARGS[@]}"} mcp --no-viewer "$@"
fi
exec "$MAESTRO" mcp --no-viewer "$@"
