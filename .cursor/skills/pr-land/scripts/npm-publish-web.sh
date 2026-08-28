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
# DELIVERY IS A MESSAGE, NOT A TOOL RESULT (2026-07-24): an AUTH_URL that only
# appears in command output is INVISIBLE — the operator reads the assistant's
# MESSAGE text, not tool results, and a session that "relayed" a link by running
# a grep has delivered nothing (this cost a publish cycle). Every session type,
# interactive included, must (1) write the bare url into its next MESSAGE as a
# CLICKABLE link — bare url or [text](url), NEVER inside backticks, since code
# spans are not linkified (writing-style `Reference links must be clickable`) —
# AND (2) fire a push notification carrying the url. Orchestrated runs: push is
# mandatory, never Slack (self-sent Slacks do not notify).
#
# LINKS EXPIRE IN ~5 MIN (measured; see PHASE_TIMEOUT). Relay each fresh
# AUTH_URL as it prints — an older link in an earlier message is already dead,
# so never tell the operator to "use the link above".
#
# All npm invocations go through the `sfw` wrapper (Socket Firewall shim
# machines reject bare npm).
#
# Usage: npm-publish-web.sh <repo-dir> [--timeout <secs>] [--attempts <n>]
# Exit: 0 = published, 1 = error, 2 = auth never completed (all attempts
#       timed out or were declined)

REPO_DIR=""
# MEASURED 2026-07-24: an unclaimed npm auth session dies at ~4m52s (the doneUrl
# poll flips 202 -> 404 "not found"); npm publishes no TTL anywhere, so this is
# empirical. The old 420s timeout therefore left a ~2-min window every cycle
# where the relayed link was already dead but no fresh one had been minted —
# that, not slow operators, is what burned five link cycles on the
# edge-exchange-plugins 2.52.1 publish. Remint BEFORE expiry: 240s < ~292s TTL.
# Re-measure with: curl -s -o /dev/null -w '%{http_code}' "<doneUrl>" in a loop
# until it stops returning 202.
PHASE_TIMEOUT=240
# Auth links expire server-side in minutes, and every relay round-trip through
# chat/push burns most of that window — with 2 attempts the operator has ~14
# min total and a link is usually stale by the time they open it (the
# 2026-07-24 edge-exchange-plugins publish burned five link cycles this way).
# Default to a LONG remint window instead: each attempt prints a FRESH link, so
# whenever the operator looks, a live one exists. Cost of waiting is one idle
# PTY; cost of expiry is another full relay cycle.
MAX_ATTEMPTS=20

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
      # -a: the `script` PTY capture carries control bytes, so without it grep
      # declares the file binary and emits "Binary file ... matches" as the URL.
      url=$(grep -aoE 'https://www\.npmjs\.com/(login\?next=[^ "[:cntrl:]]+|auth/cli/[a-f0-9-]+)' "$out" 2>/dev/null | head -1 || true)
      if [ -n "$url" ]; then
        echo "AUTH_URL $phase $url"
        url_seen=1
      fi
    fi
    # Expiry is also detectable directly: npm's own poll of the session's
    # doneUrl 404s the moment it dies. Reacting to that beats waiting out the
    # timer when npm surfaces the failure early.
    if grep -qiE "WebLoginInvalidResponse|Invalid response from web login|not found" "$out" 2>/dev/null; then
      kill "$CHILD_PID" 2>/dev/null
      wait "$CHILD_PID" 2>/dev/null
      CHILD_PID=""
      return 124
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
  # TERMINAL registry rejections are not auth expiry: retrying re-mints links
  # that authenticate fine and then hit the same wall, which reads to the
  # operator as their taps being ignored (the 2026-08-27 piratechain 403 burned
  # 20 links twice). Detect and stop. -a: the PTY capture is binary to grep.
  if grep -qa "cannot publish over the previously published versions" "$WORK_DIR/publish.out" 2>/dev/null; then
    # This 403 means the version IS on npm (an earlier auth completed server-side
    # while read replicas still denied it). Confirm with a settle delay.
    sleep 20
    if published; then
      echo "PUBLISHED $pkg_name@$pkg_version (landed earlier; replicas were lagging)"
      exit 0
    fi
    echo "FAILED publish version-conflict: registry claims $pkg_version exists but view cannot see it yet; re-run after replication settles"
    exit 3
  fi
  if grep -qaE "You do not have permission to publish|403 Forbidden|E403" "$WORK_DIR/publish.out" 2>/dev/null; then
    echo "FAILED publish permission-denied: $(grep -aoE '403 Forbidden[^"]*' "$WORK_DIR/publish.out" | head -1)"
    exit 3
  fi
  if grep -qaE "E402|payment required" "$WORK_DIR/publish.out" 2>/dev/null; then
    echo "FAILED publish payment-required"
    exit 3
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
