#!/usr/bin/env bash
# edge-log-fetch.sh — fetch Edge client log dumps from logs1.edge.app.
#
# The viewer URL a bug report carries (https://logs1.edge.app/#/<id>) is a web
# app; the API behind it authenticates with loginUser/loginPassword QUERY
# PARAMS (cookies thereafter), NOT HTTP basic auth — a bare curl -u gets
# 401 "Bad Login Info." forever. This wrapper owns that quirk, keeps the
# password out of ps/history (curl reads the query string from a config file
# on fd), and pretty-prints where sensible.
#
# Usage:
#   edge-log-fetch.sh get <log-id> [--out <path>] [--meta-only]
#   edge-log-fetch.sh find --start <iso8601|epoch> --end <iso8601|epoch> \
#       [--os <regex>] [--device <regex>] [--message <regex>] [--user <name>]
#
#   <log-id> accepts the raw _id (2026-08-02T15:34:09.701Z_743530_info) or the
#   full viewer URL (https://logs1.edge.app/#/2026-08-02T15:34:09.701Z_743530_info).
#
# get:  full log incl. the client log data -> --out (default
#       /tmp/edge-log-<id>.json). --meta-only skips the data payload.
# find: metadata list of logs in [start, end) matching the filters.
#
# Credentials: $EDGE_LOGS_USER / $EDGE_LOGS_PASSWORD (loaded by ~/.zshrc from
# ~/.config/agent-watcher/credentials.json keys edge_logs_user/edge_logs_password).
#
# Exit: 0 ok; 1 usage/auth/env; 2 HTTP error (status printed).
set -euo pipefail

BASE="https://logs1.edge.app"
CRED_FILE="$HOME/.config/agent-watcher/credentials.json"

USER_VAL="${EDGE_LOGS_USER:-}"
PASS_VAL="${EDGE_LOGS_PASSWORD:-}"
if [[ -z $USER_VAL || -z $PASS_VAL ]]; then
  # Direct fallback for sessions whose shell predates the zshrc loader.
  USER_VAL=$(jq -r '.edge_logs_user // empty' "$CRED_FILE" 2>/dev/null || true)
  PASS_VAL=$(jq -r '.edge_logs_password // empty' "$CRED_FILE" 2>/dev/null || true)
fi
if [[ -z $USER_VAL || -z $PASS_VAL ]]; then
  echo "edge-log-fetch: no credentials (EDGE_LOGS_USER/EDGE_LOGS_PASSWORD unset and $CRED_FILE has no edge_logs_* keys)" >&2
  exit 1
fi

# curl --config keeps the password off the command line (invisible to ps).
auth_curl() { # <url-without-auth-params> <extra query, may be empty> <out>
  local url="$1" extra="$2" out="$3" sep code
  [[ $url == *\?* ]] && sep='&' || sep='?'
  local full="${url}${sep}loginUser=${USER_VAL}&loginPassword=${PASS_VAL}"
  [[ -n $extra ]] && full="${full}&${extra}"
  code=$(curl -s -m 60 -o "$out" -w '%{http_code}' --config /dev/fd/3 3<<<"url = \"$full\"")
  if [[ $code != 200 ]]; then
    echo "edge-log-fetch: HTTP $code from $url" >&2
    head -c 300 "$out" >&2 || true; echo >&2
    return 2
  fi
}

# ISO 8601 -> epoch seconds passthrough (the API takes float seconds).
to_epoch() {
  local v="$1"
  if [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]]; then echo "$v"; return; fi
  python3 - "$v" <<'PY'
import sys, datetime
v = sys.argv[1].replace('Z', '+00:00')
print(datetime.datetime.fromisoformat(v).timestamp())
PY
}

cmd="${1:-}"; shift || true
case "$cmd" in
  get)
    ID="${1:-}"; shift || true
    [[ -z $ID ]] && { echo "usage: edge-log-fetch.sh get <log-id|viewer-url> [--out <path>] [--meta-only]" >&2; exit 1; }
    ID="${ID##*#/}"   # accept the viewer URL verbatim
    OUT="/tmp/edge-log-${ID}.json"; META=false
    while [[ $# -gt 0 ]]; do case "$1" in
      --out) OUT="$2"; shift 2 ;;
      --meta-only) META=true; shift ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac; done
    EXTRA="withData=true"; $META && EXTRA=""
    auth_curl "$BASE/v1/getLog/?_id=$ID" "$EXTRA" "$OUT"
    echo "$OUT"
    ;;
  find)
    START=""; END=""; EXTRA=""
    while [[ $# -gt 0 ]]; do case "$1" in
      --start) START=$(to_epoch "$2"); shift 2 ;;
      --end) END=$(to_epoch "$2"); shift 2 ;;
      --os) EXTRA="$EXTRA&deviceOS=$2"; shift 2 ;;
      --device) EXTRA="$EXTRA&deviceInfo=$2"; shift 2 ;;
      --message) EXTRA="$EXTRA&userMessage=$2"; shift 2 ;;
      --user) EXTRA="$EXTRA&userName=$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac; done
    [[ -z $START || -z $END ]] && { echo "usage: edge-log-fetch.sh find --start <iso|epoch> --end <iso|epoch> [--os --device --message --user]" >&2; exit 1; }
    OUT=$(mktemp /tmp/edge-log-find.XXXXXX.json)
    auth_curl "$BASE/v1/findLogs/?start=$START&end=$END" "${EXTRA#&}" "$OUT"
    jq -r '.[] | "\(._id)\t\(.OS // "?")\t\(.deviceInfo // "?")\t\(.appVersion // "?")\t\(.userMessage // "" | gsub("\n"; " ") | .[0:60])"' "$OUT" 2>/dev/null || cat "$OUT"
    rm -f "$OUT"
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
