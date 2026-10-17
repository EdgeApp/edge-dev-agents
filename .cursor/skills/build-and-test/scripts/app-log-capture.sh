#!/usr/bin/env bash
# app-log-capture.sh: per-slot capture of the gui's console, core and plugin
# logs included, with no source edit.
#
# The gui sends every console line to CONFIG.LOG_SERVER when config.json sets
# it (src/app.ts). `start` points the worktree's config.json at a listener on
# port Metro + 1000 (8183 -> 9183) and starts app-log-server.js there, so each
# slot writes its own file: /tmp/applog-<log port>.log. ios-rn-build.sh runs
# `start` before every launch in an agent worktree, so a drive needs no setup:
# grep the file (`path` prints it). Core logs at warn and above, so a
# `<pluginId> gave swap error` line lands here.
#
# The listener runs with cwd = the worktree, so slot teardown (the watchdog's
# freeWorktreeListeners, cleanup-task-workspace.sh) stops it and frees the port.
# While LOG_SERVER is set, the console goes to the file instead of React Native
# DevTools. Sync is chatty: grep the file, do not read it whole.
#
# Usage: app-log-capture.sh start|stop|status|path [--port <metro port>] [<gui-worktree>]
#   --port          Metro port; default $AGENT_METRO_PORT
#   <gui-worktree>  default $PWD; must be an agent worktree (never the primary
#                   checkout, whose config.json keeps LOG_SERVER unset)
#   start   set LOG_SERVER, start the listener if it is not up; prints
#           LOG=<file> CONFIG=changed|unchanged LISTENER=started|running.
#           CONFIG=changed takes effect on the next bundle (relaunch the app).
#   stop    stop the listener and remove LOG_SERVER from config.json
#   status  LISTENER=<pid>|down LOG=<file> LINES=<n>
#   path    print the log file
# A fresh listener empties a file left by another worktree; a restart in the
# same worktree appends.
# Exit: 0 ok; 1 the port is held by another process, or the listener did not
#       come up (see /tmp/applog-<log port>.server.log); 2 usage error, not an
#       agent worktree, or a branch without the LOG_SERVER config key
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HOME/.config/agent-watcher/lib/worktree-root.sh"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
CMD="${1:-}"
[ $# -gt 0 ] && shift
METRO_PORT="${AGENT_METRO_PORT:-}"
WT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) METRO_PORT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "app-log-capture: unknown flag $1" >&2; exit 2 ;;
    *) WT="$1" ;;
  esac
  shift
done
case "$CMD" in
  start|stop|status|path) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "app-log-capture: usage: app-log-capture.sh start|stop|status|path [--port <metro port>] [<gui-worktree>]" >&2; exit 2 ;;
esac
[[ "$METRO_PORT" =~ ^[0-9]+$ ]] || { echo "app-log-capture: no Metro port (pass --port or set AGENT_METRO_PORT)" >&2; exit 2; }

LOG_PORT=$((METRO_PORT + 1000))
LOG="/tmp/applog-$LOG_PORT.log"
if [ "$CMD" = path ]; then echo "$LOG"; exit 0; fi

WT="$(cd "${WT:-$PWD}" && pwd -P)"
ROOT="$(cd "$(worktree_root)" 2>/dev/null && pwd -P || true)"
if [ -z "$ROOT" ] || [[ "$WT/" != "$ROOT/"* ]]; then
  echo "app-log-capture: $WT is not an agent worktree (under $(worktree_root)); LOG_SERVER stays unset there" >&2
  exit 2
fi
CONFIG="$WT/config.json"

listener_pid() { lsof -nP -iTCP:"$LOG_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true; }
pid_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }

# `set` writes LOG_SERVER, `unset` removes it. Prints changed|unchanged.
write_config() {
  node -e '
    const fs = require("fs")
    const [p, mode, port] = process.argv.slice(1)
    const config = JSON.parse(fs.readFileSync(p, "utf8"))
    const want = mode === "set" ? { host: "http://127.0.0.1", port } : undefined
    if (JSON.stringify(config.LOG_SERVER) === JSON.stringify(want)) {
      console.log("unchanged")
    } else {
      if (want == null) delete config.LOG_SERVER
      else config.LOG_SERVER = want
      fs.writeFileSync(p, JSON.stringify(config, null, 2) + "\n")
      console.log("changed")
    }
  ' "$CONFIG" "$1" "$LOG_PORT"
}

# Exits 1 when the log port is held by a process outside this worktree.
assert_port_ours() {
  local pid="$1" cwd
  cwd="$(pid_cwd "$pid")"
  if [ "$cwd" != "$WT" ]; then
    echo "app-log-capture: port $LOG_PORT is held by PID $pid (cwd: ${cwd:-unknown}), not this worktree" >&2
    exit 1
  fi
}

case "$CMD" in
  status)
    pid="$(listener_pid)"
    lines=0; [ -f "$LOG" ] && lines=$(wc -l <"$LOG" | tr -d ' ')
    echo "LISTENER=${pid:-down} LOG=$LOG LINES=$lines"
    ;;
  stop)
    pid="$(listener_pid)"
    if [ -n "$pid" ]; then
      assert_port_ours "$pid"
      kill "$pid"
    fi
    changed=unchanged
    [ -f "$CONFIG" ] && changed="$(write_config unset)"
    echo "LISTENER=stopped CONFIG=$changed"
    ;;
  start)
    [ -f "$CONFIG" ] || { echo "app-log-capture: no config.json in $WT" >&2; exit 2; }
    grep -q 'LOG_SERVER' "$WT/src/configKeysSchema.ts" 2>/dev/null \
      || { echo "app-log-capture: $WT has no LOG_SERVER config key (src/configKeysSchema.ts)" >&2; exit 2; }
    pid="$(listener_pid)"
    if [ -n "$pid" ]; then
      assert_port_ours "$pid"
      state=running
    else
      header="# app-log-capture worktree=$WT"
      if [ ! -f "$LOG" ] || [ "$(head -1 "$LOG")" != "$header" ]; then
        echo "$header" >"$LOG"
      fi
      # exec: no shell stays behind holding a caller's $(...) pipe open.
      (cd "$WT" && exec nohup node "$SCRIPT_DIR/app-log-server.js" --port "$LOG_PORT" --out "$LOG") \
        </dev/null >"/tmp/applog-$LOG_PORT.server.log" 2>&1 &
      for _ in $(seq 1 25); do
        [ -n "$(listener_pid)" ] && break
        sleep 0.2
      done
      if [ -z "$(listener_pid)" ]; then
        echo "app-log-capture: listener did not come up on port $LOG_PORT (see /tmp/applog-$LOG_PORT.server.log)" >&2
        exit 1
      fi
      state=started
    fi
    echo "LOG=$LOG CONFIG=$(write_config set) LISTENER=$state"
    ;;
esac
