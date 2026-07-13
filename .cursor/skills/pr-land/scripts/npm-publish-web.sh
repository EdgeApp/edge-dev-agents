#!/usr/bin/env bash
set -uo pipefail

# npm-publish-web.sh — login (if needed) and publish one package via npm
# web/link auth, keeping the CLI poller alive under a PTY.
#
# npm's web auth delivers the token/approval to the CLI process that printed
# the link; if that process dies (no TTY, timeout) the link is dead. This
# script owns the full process lifecycle so the agent only relays links:
#   1. `npm whoami` preflight. On failure runs `npm login` FIRST — a publish
#      without a token dies at ENEEDAUTH before it ever prints an auth link,
#      so login is a separate, mandatory first phase.
#   2. `npm publish`, which may print a second auth link (2FA). Publishes in
#      the same auth session may skip this — treat the link as optional.
#   3. Each phase runs under `script -q` (PTY) so npm's poller stays alive,
#      with a hard timeout and an EXIT trap that kills the child — no stale
#      pollers, no dead links left on screen.
#   4. If a phase exits without success (link expired / user missed it), it
#      retries up to MAX_ATTEMPTS times, printing a FRESH link each attempt.
#
# The agent tails stdout for these machine lines and relays them:
#   AUTH_URL login <url>     — user must open on ANY device (passkey lives
#   AUTH_URL publish <url>     with them, not this machine)
#   PUBLISHED <name>@<version>
#   FAILED <phase> <reason>
#
# Interactive sessions surface AUTH_URL in chat; orchestrated runs deliver it
# via push notification (never Slack — self-sent Slacks do not notify).
#
# All npm invocations go through the `sfw` wrapper (Socket Firewall shim
# machines reject bare npm).
#
# Usage: npm-publish-web.sh <repo-dir> [--timeout <secs>] [--attempts <n>]
# Exit: 0 = published, 1 = error, 2 = auth never completed (all attempts
#       timed out or were declined)

REPO_DIR=""
PHASE_TIMEOUT=420
MAX_ATTEMPTS=2

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) PHASE_TIMEOUT="$2"; shift 2 ;;
    --attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    *) REPO_DIR="$1"; shift ;;
  esac
done
[ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ] || { echo "usage: npm-publish-web.sh <repo-dir>" >&2; exit 1; }

NPM="sfw npm"
command -v sfw >/dev/null 2>&1 || NPM="npm"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/npm-web.XXXXXX")
CHILD_PID=""
cleanup() {
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# run_phase <phase-name> <command...>
# Runs the command under a PTY, tails its output for an auth URL (relayed as
# an AUTH_URL line), and waits for completion up to PHASE_TIMEOUT.
# Returns the command's exit code, or 124 on timeout.
run_phase() {
  local phase="$1"; shift
  local out="$WORK_DIR/$phase.out"
  : > "$out"
  (cd "$REPO_DIR" && script -q "$out" "$@" < /dev/null > /dev/null 2>&1) &
  CHILD_PID=$!

  local url_seen=""
  local waited=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if [ -z "$url_seen" ]; then
      local url
      url=$(grep -oE 'https://www\.npmjs\.com/(login\?next=[^ "[:cntrl:]]+|auth/cli/[a-f0-9-]+)' "$out" 2>/dev/null | head -1 || true)
      if [ -n "$url" ]; then
        echo "AUTH_URL $phase $url"
        url_seen=1
      fi
    fi
    if [ "$waited" -ge "$PHASE_TIMEOUT" ]; then
      kill "$CHILD_PID" 2>/dev/null
      wait "$CHILD_PID" 2>/dev/null
      CHILD_PID=""
      return 124
    fi
    sleep 3; waited=$((waited + 3))
  done
  wait "$CHILD_PID" 2>/dev/null
  local rc=$?
  CHILD_PID=""
  return $rc
}

# --- Phase 1: login (only if whoami fails) ---
if ! (cd "$REPO_DIR" && $NPM whoami > "$WORK_DIR/whoami" 2>/dev/null); then
  ok=""
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "login attempt $attempt/$MAX_ATTEMPTS..." >&2
    run_phase login $NPM login --auth-type=web
    if (cd "$REPO_DIR" && $NPM whoami > "$WORK_DIR/whoami" 2>/dev/null); then ok=1; break; fi
  done
  [ -n "$ok" ] || { echo "FAILED login auth never completed"; exit 2; }
fi
echo "logged in as $(cat "$WORK_DIR/whoami" 2>/dev/null | tail -1)" >&2

# --- Phase 2: publish ---
pkg_name=$(cd "$REPO_DIR" && node -e "process.stdout.write(require(process.cwd()+\"/package.json\").name)")
pkg_version=$(cd "$REPO_DIR" && node -e "process.stdout.write(require(process.cwd()+\"/package.json\").version)")

published() {
  local v
  v=$(cd "$REPO_DIR" && $NPM view "$pkg_name@$pkg_version" version 2>/dev/null | tail -1)
  [ "$v" = "$pkg_version" ]
}

if published; then
  echo "PUBLISHED $pkg_name@$pkg_version (already on npm)"
  exit 0
fi

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "publish attempt $attempt/$MAX_ATTEMPTS..." >&2
  run_phase publish $NPM publish
  if published; then
    echo "PUBLISHED $pkg_name@$pkg_version"
    exit 0
  fi
done

# An auth approval that lands right at the phase deadline can complete on
# npm's side after the local poller was killed — re-check the registry after
# a settle delay before declaring failure.
sleep 20
if published; then
  echo "PUBLISHED $pkg_name@$pkg_version"
  exit 0
fi

# Distinguish auth-timeout from a real registry error using the last output.
if grep -qiE "auth|otp|2fa|browser" "$WORK_DIR/publish.out" 2>/dev/null; then
  echo "FAILED publish auth never completed"
  exit 2
fi
tail -5 "$WORK_DIR/publish.out" 2>/dev/null | tr -d '\r' >&2
echo "FAILED publish registry error (see stderr tail)"
exit 1
