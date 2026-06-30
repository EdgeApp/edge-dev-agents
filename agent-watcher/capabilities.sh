#!/usr/bin/env bash
set -euo pipefail

# capabilities.sh — classify the infrastructure a repo's tasks require, so the
# provisioner (setup-task-workspace.sh) and the tester (build-and-test) route
# identically and can never disagree. This is the single source of truth for
# that routing decision.
#
#   capabilities.sh detect <repo> [repo-path]   -> prints exactly one of:
#                                                  ios-sim | couch | none
#   capabilities.sh test                        -> self-check against known repos
#
# Lanes:
#   ios-sim : edge-react-gui and the gui-dependency repos. Changes there are not
#             verified until they run in the app on a simulator.
#   couch   : server repos whose real integration test needs a CouchDB
#             (initDbs + a queryEngine cycle), not just tsc + unit tests.
#   none    : pure libraries / CLIs. Unit tests + tsc are the full test surface.
#
# Detection is a curated table first (explicit for known repos) then a feature
# sniff for repos not yet listed. The sim list MUST stay in sync with
# build-and-test's `gui-dependency-integration` rule (same repos).
#
# Consumers must FAIL LOUD: if detect returns a lane whose host capability is
# absent (no couch, no simulator), the run reports the lane as skipped and does
# NOT silently fall back to tsc/placeholder and report "tested".

GIT_ROOT="${GIT_ROOT:-$HOME/git}"

# Repos whose changes require simulator verification (gui + gui dependencies).
SIM_REPOS=(
  edge-react-gui
  edge-core-js
  edge-currency-accountbased
  edge-currency-plugins
  edge-exchange-plugins
  edge-login-ui-rn
  edge-currency-monero
  react-native-piratechain
  react-native-zcash
  react-native-zano
)

# Server repos whose real integration tests need a CouchDB.
COUCH_REPOS=(
  edge-reports-server
  edge-info-server
  edge-change-server
)

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# Feature sniff for couch repos not in the curated list: a couch client
# dependency, an initDbs setup script, or a couch URL in the repo config.
detect_couch_by_features() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  if [[ -f "$path/package.json" ]] &&
    grep -qE '"nano"|edge-server-tools|initDbs' "$path/package.json"; then
    return 0
  fi
  if grep -rqsE 'couchDbFullpath|couchUris' \
    "$path/config.json" "$path/src/config.ts" 2>/dev/null; then
    return 0
  fi
  return 1
}

detect() {
  local repo="$1"
  local path="${2:-$GIT_ROOT/$repo}"

  # 1. Simulator lane (curated: gui + gui-deps). Takes precedence: a gui dep is
  #    verified on the sim even if it also has server-ish signals.
  if in_list "$repo" "${SIM_REPOS[@]}"; then
    echo "ios-sim"; return 0
  fi
  # 2. Couch lane (curated, then feature sniff for new server repos).
  if in_list "$repo" "${COUCH_REPOS[@]}" || detect_couch_by_features "$path"; then
    echo "couch"; return 0
  fi
  # 3. Default: no special infrastructure.
  echo "none"
}

selftest() {
  local fail=0
  check() {
    local got
    got="$(detect "$1" "${3:-}")"
    if [[ "$got" == "$2" ]]; then
      printf 'ok    %-32s -> %s\n' "$1" "$got"
    else
      printf 'FAIL  %-32s -> %s (want %s)\n' "$1" "$got" "$2"
      fail=1
    fi
  }
  check edge-react-gui ios-sim
  check edge-core-js ios-sim
  check edge-currency-accountbased ios-sim
  check edge-exchange-plugins ios-sim
  check edge-reports-server couch
  check biggystring none
  check disklet none
  return "$fail"
}

cmd="${1:-}"
case "$cmd" in
  detect) shift; detect "$@" ;;
  test) selftest ;;
  *)
    echo "usage: capabilities.sh detect <repo> [repo-path] | test" >&2
    exit 2
    ;;
esac
