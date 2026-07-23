#!/usr/bin/env bash
# bundle-ownership.sh — answer deterministically: WHICH Metro will this app load
# its JS bundle from, and does that Metro serve THIS task's worktree?
#
# "My edit isn't applying" is an OWNERSHIP question before it is a cache
# question. The 2026-07-22 swapter run lost ~2h to cache nukes, reload
# broadcasts, an RCT_jsLocation redirect and a sim reboot when the actual fault
# was a stale main-checkout Metro squatting RN's default port 8081 — the app
# silently loaded the wrong worktree's bundle with no error. This script turns
# that hour of bisection into one deterministic verdict, and writes the marker
# that require-bundle-triage.sh gates cache-escalation commands on.
#
# Usage: bundle-ownership.sh --udid <u> --worktree <repo-worktree-path>
#          [--task-gid <gid>] [--bundle <id>]
#   --task-gid defaults to $AGENT_TASK_GID; needed only for the marker name.
# Verdicts:
#   OK        the app's effective packager port is served by YOUR worktree
#   MISMATCH  another directory's Metro owns the port the app will read
#   NO_METRO  nothing listens on the app's effective port
# Exit: 0 = triage completed (any verdict), 1 = error, 2 = usage.

set -uo pipefail

BUNDLE="co.edgesecure.app"
UDID="" WORKTREE="" GID="${AGENT_TASK_GID:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --task-gid) GID="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    *) echo "bundle-ownership: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$UDID" && -n "$WORKTREE" ]] || { echo "usage: bundle-ownership.sh --udid <u> --worktree <path> [--task-gid <gid>] [--bundle <id>]" >&2; exit 2; }
WORKTREE="${WORKTREE%/}"

# Effective packager source: the app's RCT_jsLocation pref (ios-rn-build.sh's
# cached-launch path pins this to the slot port), else RN's default 8081.
PIN=$(xcrun simctl spawn "$UDID" defaults read "$BUNDLE" RCT_jsLocation 2>/dev/null || true)
PORT="8081"; SRC="default (no RCT_jsLocation pin)"
if [[ "$PIN" =~ :([0-9]+) ]]; then PORT="${BASH_REMATCH[1]}"; SRC="RCT_jsLocation pin ($PIN)"; fi

# Who serves that port, from where?
PID=$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null | head -1)
CWD=""
[[ -n "$PID" ]] && CWD=$(lsof -a -p "$PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)

VERDICT="" REMEDY=""
if [[ -z "$PID" ]]; then
  VERDICT="NO_METRO"
  REMEDY="nothing listens on $PORT — start YOUR worktree's Metro on port $PORT (the port the app actually reads); do not redirect the app"
elif [[ "$CWD" == "$WORKTREE" || "$CWD" == "$WORKTREE"/* ]]; then
  VERDICT="OK"
  REMEDY="the app will load YOUR bundle from pid $PID — if the edit still doesn't show, it's a reload/cache question now (cold-launch first, then --reset-cache)"
else
  VERDICT="MISMATCH"
  REMEDY="pid $PID serves $CWD, NOT your worktree — the app silently loads THAT bundle. Verify the squatter is stale (its cwd tells you whose it is), kill it, and start your Metro on port $PORT. NEVER hand-write RCT_jsLocation to dodge a squatter (blocked by hook); packager pinning belongs to ios-rn-build.sh"
fi

# Embedded-bundle FYI: a Release-style app with main.jsbundle never fetches
# Metro at all — Metro-side edits cannot apply without a rebuild/reinstall.
APPDIR=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" app 2>/dev/null || true)
EMBEDDED="no"
[[ -n "$APPDIR" && -f "$APPDIR/main.jsbundle" ]] && EMBEDDED="yes"

echo ">> bundle-ownership: $BUNDLE on $UDID"
echo ">>   effective source: port $PORT via $SRC"
echo ">>   listener: ${PID:-none}${CWD:+ ($CWD)}"
echo ">>   embedded main.jsbundle present: $EMBEDDED"
echo ">>   VERDICT: $VERDICT"
echo ">>   $REMEDY"
[[ "$EMBEDDED" == "yes" ]] && echo ">>   NOTE: embedded bundle present — if the app runs it (0 Metro requests in the Metro log), Metro edits need ios-rn-build.sh (rebuild/cached-launch), not Metro restarts"

MARKER="/tmp/agent-bundle-triage-${GID:-nogid}.json"
jq -nc --arg gid "${GID:-}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg udid "$UDID" --arg port "$PORT" --arg pid "${PID:-}" --arg cwd "${CWD:-}" \
  --arg verdict "$VERDICT" --arg embedded "$EMBEDDED" \
  '{gid:$gid, ts:$ts, udid:$udid, effective_port:$port, listener_pid:$pid, listener_cwd:$cwd, verdict:$verdict, embedded_bundle:($embedded=="yes")}' \
  > "$MARKER" 2>/dev/null || true
echo ">>   marker written: $MARKER"
