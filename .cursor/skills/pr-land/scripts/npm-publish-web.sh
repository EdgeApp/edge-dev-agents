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
# Relay contract (owned by pr-land `npm-publish-auth`): every AUTH_URL goes into
# the assistant's next MESSAGE as a bare clickable url AND into a push
# notification, the moment it prints. Poll this script's log file directly for
# new lines; do not rely on a batched event stream. A fresh url supersedes the
# previous one.
#
# Link lifetime: an unclaimed auth session dies server-side in about 5 minutes
# (its doneUrl poll flips 202 -> 404); login links have died sooner. Each
# attempt prints a FRESH link and the timeout remints BEFORE the measured
# expiry, so whenever the operator looks, a live link exists. Re-measure with:
# curl -s -o /dev/null -w '%{http_code}' "<doneUrl>" in a loop until it stops
# returning 202.
#
# Attempt semantics: only a phase that TIMES OUT (exit 124: link expired or
# never used) earns a fresh attempt. A phase whose npm process exits on its own
# without success is a real error (auth completed, then npm rejected the
# request): the loop STOPS and prints npm's own output, because re-minting
# links against a registry rejection reads to the operator as their approvals
# being ignored. Every attempt's PTY capture is kept as <phase>.<n>.out, and the
# work dir is preserved on any non-zero exit so the error survives the run.
#
# Registry replication lags a successful publish by seconds to a minute:
# published() polls `npm view` for up to REPLICATION_SETTLE seconds before
# concluding a version is absent, so a completed approval is not mistaken for
# an expired link.
#
# All npm invocations go through the `sfw` wrapper (Socket Firewall shim
# machines reject bare npm).
#
# Usage: npm-publish-web.sh <repo-dir> [--timeout <secs>] [--attempts <n>] [--settle <secs>]
# Exit: 0 = published, 1 = error, 2 = auth never completed (all attempts
#       timed out or were declined)

REPO_DIR=""
# Measured unclaimed-session lifetime is ~292s; remint before expiry.
PHASE_TIMEOUT=240
# Each attempt prints a FRESH link; a long remint window costs one idle PTY,
# an expired link costs a full relay round-trip. Only timeouts consume attempts.
MAX_ATTEMPTS=20
# Seconds to poll the registry for a just-published version before deciding
# it is absent (npm read replicas lag the write).
REPLICATION_SETTLE=90

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) PHASE_TIMEOUT="$2"; shift 2 ;;
    --attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --settle) REPLICATION_SETTLE="$2"; shift 2 ;;
    *) REPO_DIR="$1"; shift ;;
  esac
done
[ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ] || { echo "usage: npm-publish-web.sh <repo-dir>" >&2; exit 1; }

NPM="sfw npm"
command -v sfw >/dev/null 2>&1 || NPM="npm"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/npm-web.XXXXXX")
CHILD_PID=""
ATTEMPT=0
# Kill a process and every descendant. The phase runs as subshell -> script(1)
# -> sfw -> npm; killing only the subshell orphans the npm poller, which keeps
# its auth session alive and its PTY open long after this script is gone.
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill "$pid" 2>/dev/null
}

cleanup() {
  local rc=$?
  [ -n "$CHILD_PID" ] && kill_tree "$CHILD_PID"
  if [ "$rc" -eq 0 ]; then
    rm -rf "$WORK_DIR"
  else
    echo "npm output kept at $WORK_DIR (one <phase>.<attempt>.out per attempt)" >&2
  fi
}
trap cleanup EXIT

# Print the last meaningful lines of a PTY capture: ANSI stripped, spinner
# frames and per-file `npm notice` lines dropped.
show_tail() {
  perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r/\n/g' "$1" 2>/dev/null \
    | grep -a -v -E '^\s*[-\\|/]*\s*$|^\|?npm notice [0-9.]+ ?[kMB]' \
    | tail -"${2:-12}" >&2
}

# run_phase <phase-name> <command...>
# Runs the command under a PTY, tails its output for an auth URL (relayed as
# an AUTH_URL line), and waits for completion up to PHASE_TIMEOUT.
# Returns the command's exit code, or 124 on timeout.
run_phase() {
  local phase="$1"; shift
  local out="$WORK_DIR/$phase.$ATTEMPT.out"
  : > "$out"
  ln -sf "$out" "$WORK_DIR/$phase.out"
  (cd "$REPO_DIR" && script -q "$out" "$@" < /dev/null > /dev/null 2>&1) &
  CHILD_PID=$!

  local url_seen=""
  local waited=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if [ -z "$url_seen" ]; then
      local url
      # -a: the `script` PTY capture carries control bytes, so without it grep
      # declares the file binary and emits "Binary file ... matches" as the URL.
      url=$(grep -aoE 'https://www\.npmjs\.com/(login\?next=[^ "[:cntrl:]]+|auth/cli/[a-f0-9-]+)' "$out" 2>/dev/null | head -1 || true)
      if [ -n "$url" ]; then
        echo "AUTH_URL $phase $url"
        echo "link minted $(date -u +%H:%M:%SZ) (attempt $ATTEMPT)" >&2
        url_seen=1
      fi
    fi
    # Expiry is also detectable directly: npm's own poll of the session's
    # doneUrl 404s the moment it dies. Reacting to that beats waiting out the
    # timer when npm surfaces the failure early.
    if grep -qiE "WebLoginInvalidResponse|Invalid response from web login|not found" "$out" 2>/dev/null; then
      kill_tree "$CHILD_PID"
      wait "$CHILD_PID" 2>/dev/null
      CHILD_PID=""
      return 124
    fi
    if [ "$waited" -ge "$PHASE_TIMEOUT" ]; then
      kill_tree "$CHILD_PID"
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
    ATTEMPT=$attempt
    echo "login attempt $attempt/$MAX_ATTEMPTS..." >&2
    run_phase login $NPM login --auth-type=web
    rc=$?
    if (cd "$REPO_DIR" && $NPM whoami > "$WORK_DIR/whoami" 2>/dev/null); then ok=1; break; fi
    if [ "$rc" -ne 124 ]; then
      show_tail "$WORK_DIR/login.out"
      echo "FAILED login npm exited $rc without a session (see stderr tail)"
      exit 1
    fi
  done
  [ -n "$ok" ] || { echo "FAILED login auth never completed"; exit 2; }
fi
echo "logged in as $(cat "$WORK_DIR/whoami" 2>/dev/null | tail -1)" >&2

# --- Phase 2: publish ---
pkg_name=$(cd "$REPO_DIR" && node -e "process.stdout.write(require(process.cwd()+\"/package.json\").name)")
pkg_version=$(cd "$REPO_DIR" && node -e "process.stdout.write(require(process.cwd()+\"/package.json\").version)")

# --- Phase 2a: prepack + tarball sanity -------------------------------------
# This machine hardens npm with ignore-scripts=true (postinstall-RCE guard), so
# a publish SKIPS prepack — which, for repos that vendor their native SDK at
# pack time (react-native-zcash / react-native-piratechain: update-sources
# clones the Swift sources and builds the xcframework), silently published
# tarballs missing the whole iOS payload (0.13.3 / 0.6.2, 2026-08-27: 36MB to
# 108KB, every downstream iOS build failed on missing SDK types). Running the
# repo's OWN prepack by name is a deliberate first-party invocation — the run
# subcommand is unaffected by ignore-scripts — so the hardening stays intact.
has_prepack=$(cd "$REPO_DIR" && node -e "process.stdout.write(require(process.cwd()+\"/package.json\").scripts?.prepack ? \"1\" : \"\")")
if [ -n "$has_prepack" ]; then
  echo "running prepack explicitly (ignore-scripts=true skips it at pack time)..." >&2
  (cd "$REPO_DIR" && $NPM run prepack) > "$WORK_DIR/prepack.out" 2>&1 || {
    tail -15 "$WORK_DIR/prepack.out" >&2
    echo "FAILED prepack (see stderr tail)"
    exit 1
  }
fi

# Tarball sanity: whatever the cause, a pack that SHRANK dramatically vs the
# registry's previous release is a gutted package, and publishing it breaks
# every consumer. Failures are stops.
prev_size=$(cd "$REPO_DIR" && $NPM view "$pkg_name" dist.unpackedSize 2>/dev/null | tail -1 | tr -dc 0-9)
new_size=$(cd "$REPO_DIR" && $NPM pack --dry-run --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j[0].unpackedSize||0))}catch(e){process.stdout.write("0")}})')
if [ -n "$prev_size" ] && [ "${new_size:-0}" -gt 0 ] && [ "$new_size" -lt $((prev_size / 2)) ]; then
  echo "FAILED publish tarball-shrunk: new pack ${new_size}B is under half the previous release ${prev_size}B — refusing to publish a gutted package"
  exit 4
fi
echo "tarball sanity: new ${new_size:-?}B vs previous ${prev_size:-?}B" >&2

published_now() {
  local v
  v=$(cd "$REPO_DIR" && $NPM view "$pkg_name@$pkg_version" version 2>/dev/null | tail -1)
  [ "$v" = "$pkg_version" ]
}

# Poll the registry for up to REPLICATION_SETTLE seconds before deciding the
# version is absent.
published() {
  local waited=0
  while :; do
    published_now && return 0
    [ "$waited" -ge "$REPLICATION_SETTLE" ] && return 1
    sleep 10; waited=$((waited + 10))
  done
}

if published_now; then
  echo "PUBLISHED $pkg_name@$pkg_version (already on npm)"
  exit 0
fi

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  ATTEMPT=$attempt
  echo "publish attempt $attempt/$MAX_ATTEMPTS..." >&2
  run_phase publish $NPM publish
  rc=$?
  if published; then
    echo "PUBLISHED $pkg_name@$pkg_version"
    exit 0
  fi
  out="$WORK_DIR/publish.out"
  # Terminal registry rejections are not auth expiry: re-minting links against
  # them reads to the operator as their approvals being ignored. -a: the PTY
  # capture is binary to grep.
  if grep -qa "cannot publish over the previously published versions" "$out" 2>/dev/null; then
    echo "FAILED publish version-conflict: registry claims $pkg_version exists but view cannot see it after ${REPLICATION_SETTLE}s; re-run once replication settles"
    exit 3
  fi
  if grep -qaE "You do not have permission to publish|403 Forbidden|E403" "$out" 2>/dev/null; then
    echo "FAILED publish permission-denied: $(grep -aoE '403 Forbidden[^"]*' "$out" | head -1)"
    exit 3
  fi
  if grep -qaE "E402|payment required" "$out" 2>/dev/null; then
    echo "FAILED publish payment-required"
    exit 3
  fi
  if [ "$rc" -ne 124 ]; then
    # npm exited on its own without publishing: a real error, not an expired
    # link. Show its output and stop instead of minting another link.
    show_tail "$out"
    echo "FAILED publish npm exited $rc after auth (see stderr tail; capture: $out)"
    exit 1
  fi
done

# Distinguish auth-timeout from a real registry error using the last output.
if grep -qiE "auth|otp|2fa|browser" "$WORK_DIR/publish.out" 2>/dev/null; then
  echo "FAILED publish auth never completed"
  exit 2
fi
show_tail "$WORK_DIR/publish.out"
echo "FAILED publish registry error (see stderr tail)"
exit 1
