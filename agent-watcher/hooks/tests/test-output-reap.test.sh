#!/usr/bin/env bash
# test-output-reap.test.sh: test-output-reap.sh deletes old flow runs and Maestro
# output, keeps recent ones, skips anything a process holds open, and touches nothing
# else in the temp dir. Runs against a throwaway root.
set -uo pipefail

S="$HOME/.config/agent-watcher/test-output-reap.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-output-reap-test.XXXXXX")
HOLD_PID=""
trap '[[ -n "$HOLD_PID" ]] && kill "$HOLD_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
gone() { [[ ! -e "$2" ]] && ok "$1" || fail "$1: $2 still exists"; }
here() { [[ -e "$2" ]] && ok "$1" || fail "$1: $2 is gone"; }
aged() { # aged <dir> <days>: a folder holding one file, with that age
  mkdir -p "$1"; printf 'x\n' > "$1/f"
  touch -t "$(date -v-"$2"d +%Y%m%d%H%M)" "$1"
}
build() {
  R="$TMP/r$1"; F="$R/edge-flow-runs"
  aged "$F/OLD/run-old" 10
  aged "$F/MIX/run-old" 10
  aged "$F/MIX/run-new" 1
  aged "$R/maestro_xctestrunner_xcodebuild_output1" 3
  aged "$R/maestro_xctestrunner_xcodebuild_output2" 0
  aged "$R/com.other.tool" 40
  aged "$R/maestro_other" 40
}

# --- a dry run names candidates and deletes nothing ---
build 1
out=$("$S" --root "$R" --dry-run)
[[ "$out" == *"REAP"*"run-old"* && "$out" == *"reaped 3 folder"* ]] && ok "dry run counts 3" || fail "dry run counts 3: $out"
here "dry run keeps an old run" "$F/OLD/run-old"
here "dry run keeps old Maestro output" "$R/maestro_xctestrunner_xcodebuild_output1"
here "dry run keeps the sim folder" "$F/OLD"

# --- a real pass ---
"$S" --root "$R" >/dev/null
gone "an old run goes" "$F/MIX/run-old"
here "a recent run in the same sim stays" "$F/MIX/run-new"
gone "a sim folder left empty goes" "$F/OLD"
gone "old Maestro output goes" "$R/maestro_xctestrunner_xcodebuild_output1"
here "recent Maestro output stays" "$R/maestro_xctestrunner_xcodebuild_output2"
here "another tool's folder stays" "$R/com.other.tool"
here "a similar name stays" "$R/maestro_other"

# --- limits are flags ---
build 2
"$S" --root "$R" --flow-days 30 --maestro-days 30 >/dev/null
here "--flow-days widens the limit" "$F/OLD/run-old"
here "--maestro-days widens the limit" "$R/maestro_xctestrunner_xcodebuild_output1"

# --- an open file keeps its folder at any age ---
build 3
tail -f "$F/OLD/run-old/f" >/dev/null 2>&1 &
HOLD_PID=$!
sleep 1
touch -t "$(date -v-10d +%Y%m%d%H%M)" "$F/OLD/run-old"
out=$("$S" --root "$R")
[[ "$out" == *"SKIP"*"run-old (in use)"* ]] && ok "an open folder reports SKIP" || fail "an open folder reports SKIP: $out"
here "an open folder stays" "$F/OLD/run-old/f"
gone "a closed old run in the same pass goes" "$F/MIX/run-old"
kill "$HOLD_PID" 2>/dev/null; HOLD_PID=""

# --- nothing to do, and a root with no flow runs ---
E="$TMP/empty"; mkdir -p "$E"
out=$("$S" --root "$E")
[[ "$out" == *"reaped 0 folder"* ]] && ok "an empty root reaps nothing" || fail "an empty root: $out"

# --- usage ---
"$S" --flow-days soon >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "a bad value exits 2" || fail "a bad value exits 2"
"$S" --nope >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "an unknown flag exits 2" || fail "an unknown flag exits 2"

[[ "$FAILS" -eq 0 ]] && echo "all passed" || echo "$FAILS FAILED"
exit "$((FAILS > 0))"
