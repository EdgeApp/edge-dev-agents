#!/usr/bin/env bash
# metro-fresh.sh: does the Metro on a port see edits to its checkout?
#
# Metro learns of file changes from watchman. When watchman's watcher for the
# checkout stops observing changes, Metro keeps serving the module it
# transformed earlier, and a relaunched app runs the old code with no error.
# Two checks:
#   1. Watcher: watchman must observe a cookie file in the checkout's watch
#      root within 5s (`clock` with `sync_timeout`). A timeout means every edit
#      since the stall is invisible to Metro.
#   2. Files: Metro must serve each file's module. A .json module is compared
#      with the file on disk, value for value.
# Metro fills a source map's sourcesContent from disk at request time, so a
# map that matches disk proves nothing about the module Metro serves.
# Which Metro the app reads from is a separate question, answered by
# ~/.config/agent-watcher/bundle-ownership.sh.
#
# Usage: metro-fresh.sh --port <metro port> [--worktree <repo worktree>]
#          [--file <repo-relative path> ...]
#   --worktree defaults to the working directory of the process listening on
#     the port, which is the checkout that Metro serves.
#   Without --file: the .ts/.tsx/.js/.jsx files under src/ that differ from
#     HEAD~1 (uncommitted edits plus the last commit), first 20.
# Output: one UNKNOWN or STALE line per file that is not fresh, then one line:
#   VERDICT=FRESH checked=<n> unknown=<n>      watcher live, modules served
#   VERDICT=STALE watcher=stalled root=<dir>   watchman no longer sees edits
#   VERDICT=STALE stale=<n> checked=<n>        a served .json differs from disk
#   VERDICT=NO_METRO port=<p>                  nothing listens on the port
#   VERDICT=NOTHING_TO_CHECK                   watcher live, no file to check
#   UNKNOWN: Metro cannot serve the file, or the checkout has no watchman root
#     (the watcher cannot be checked) and the file is not .json.
# Exit: 0 FRESH or NOTHING_TO_CHECK; 1 STALE or NO_METRO; 2 usage error.
# Remedy for watcher=stalled: stop that Metro, `watchman watch-del <root>`,
# start Metro on the same port, re-run this check.

set -euo pipefail

PORT=""
WORKTREE=""
FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --file) FILES+=("${2:-}"); shift 2 ;;
    *) echo "metro-fresh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "usage: metro-fresh.sh --port <metro port> [--worktree <path>] [--file <repo-relative path> ...]" >&2; exit 2; }

PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
if [[ -z "$PID" ]]; then
  echo "VERDICT=NO_METRO port=$PORT"
  exit 1
fi
if [[ -z "$WORKTREE" ]]; then
  WORKTREE="$(lsof -a -p "$PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
fi
[[ -d "$WORKTREE" ]] || { echo "metro-fresh: no worktree for the Metro on $PORT (pass --worktree)" >&2; exit 2; }
WORKTREE="$(cd "$WORKTREE" && pwd -P)"

WATCHER="unwatched"
if command -v watchman >/dev/null 2>&1; then
  ROOT="$(watchman watch-list 2>/dev/null \
    | jq -r --arg w "$WORKTREE" '.roots[] | select($w == . or ($w | startswith(. + "/")))' 2>/dev/null \
    | head -1 || true)"
  if [[ -n "$ROOT" ]]; then
    if jq -cn --arg r "$ROOT" '["clock", $r, {sync_timeout: 5000}]' \
      | watchman -j 2>/dev/null | jq -e '.clock | type == "string"' >/dev/null 2>&1; then
      WATCHER="live"
    else
      echo "VERDICT=STALE watcher=stalled root=$ROOT"
      exit 1
    fi
  fi
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  BASE="HEAD~1"
  git -C "$WORKTREE" rev-parse --verify --quiet "$BASE" >/dev/null || BASE="HEAD"
  while IFS= read -r path; do
    [[ -n "$path" ]] && FILES+=("$path")
  done < <(git -C "$WORKTREE" diff --name-only "$BASE" -- src 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$' | head -20 || true)
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "VERDICT=NOTHING_TO_CHECK"
  exit 0
fi

# Exit 0 when the served module's exports equal the JSON file on disk.
json_module_matches() {
  node -e '
const fs = require("fs")
const vm = require("vm")
let served
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), {
  __d: factory => {
    const m = { exports: {} }
    factory({}, null, null, null, m, m.exports, [])
    served = m.exports
  }
})
const disk = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
process.exit(JSON.stringify(served) === JSON.stringify(disk) ? 0 : 1)
' "$1" "$2" 2>/dev/null
}

MODULE="$(mktemp "${TMPDIR:-/tmp}/metro-fresh.XXXXXX")"
trap 'rm -f "$MODULE"' EXIT
CHECKED=0
STALE=0
UNKNOWN=0
for path in "${FILES[@]}"; do
  [[ -f "$WORKTREE/$path" ]] || continue
  CHECKED=$((CHECKED + 1))
  entry="${path%.*}"
  [[ "$path" == *.json ]] && entry="$path"
  # The first request to a just-started Metro waits for its file crawl.
  code="$(curl -s -m 120 -o "$MODULE" -w '%{http_code}' \
    "http://localhost:$PORT/$entry.bundle?platform=ios&dev=true&modulesOnly=true&runModule=false&shallow=true" || true)"
  if [[ "$code" != 200 ]]; then
    UNKNOWN=$((UNKNOWN + 1))
    echo "UNKNOWN file=$path http=${code:-none}"
  elif [[ "$path" == *.json ]]; then
    if ! json_module_matches "$MODULE" "$WORKTREE/$path"; then
      STALE=$((STALE + 1))
      echo "STALE file=$path"
    fi
  elif [[ "$WATCHER" != live ]]; then
    UNKNOWN=$((UNKNOWN + 1))
    echo "UNKNOWN file=$path watcher=$WATCHER"
  fi
done

if [[ "$CHECKED" -eq 0 ]]; then
  echo "VERDICT=NOTHING_TO_CHECK"
  exit 0
fi
if [[ "$STALE" -gt 0 ]]; then
  echo "VERDICT=STALE stale=$STALE checked=$CHECKED"
  exit 1
fi
echo "VERDICT=FRESH checked=$CHECKED unknown=$UNKNOWN"
