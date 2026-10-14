#!/usr/bin/env bash
# run.sh: Run the hook tests against the installed trees or against a checkout.
#
# Every test addresses the code under test through ~/.cursor and
# ~/.config/agent-watcher. With ORCH_TEST_TREE unset, the tests run as they are
# and exercise the installed trees. With ORCH_TEST_TREE=<checkout of this repo>,
# each test runs with HOME set to a scratch dir whose .cursor and
# .config/agent-watcher link into the checkout, so the same tests exercise the
# checkout and read nothing installed. The test files run are the checkout's own.
#
# The scratch config dir gets a placeholder credentials.json copied from the
# example file, because a checkout carries no credentials and several hooks
# stop early without one. No test may reach the network with it.
#
# Under ORCH_TEST_TREE the run also drops AGENT_TASK_GID and the XDG dirs from
# the environment and sets a git identity, since the scratch HOME has no
# gitconfig and no state.
#
# Usage: [ORCH_TEST_TREE=<checkout>] run.sh [name-substring ...]
#   name-substring  run only the test files whose name contains one of these
# Output: one line per test file, PASS|FAIL <file> rc=<n> <secs>s, with the
#         first failing lines under a FAIL; then a totals line.
# Exit: 0 every file passed; 1 a file failed; 2 usage error.
set -uo pipefail

TREE="${ORCH_TEST_TREE:-}"
if [[ -n "$TREE" ]]; then
  TREE=$(cd "$TREE" 2>/dev/null && pwd) || { echo "ORCH_TEST_TREE is not a directory: $ORCH_TEST_TREE" >&2; exit 2; }
  [[ -d "$TREE/.cursor" && -d "$TREE/agent-watcher/hooks/tests" ]] || {
    echo "ORCH_TEST_TREE has no .cursor and agent-watcher/hooks/tests: $TREE" >&2; exit 2; }
  TESTS="$TREE/agent-watcher/hooks/tests"
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/hook-tests-home.XXXXXX")
  trap 'rm -rf "$SCRATCH"' EXIT
  mkdir -p "$SCRATCH/.config/agent-watcher"
  ln -s "$TREE/.cursor" "$SCRATCH/.cursor"
  # Entry-by-entry links, so a file a test writes at the top of the config dir
  # lands in the scratch dir, and the credentials file a checkout never carries
  # can be a placeholder.
  for E in "$TREE"/agent-watcher/* "$TREE"/agent-watcher/.[!.]*; do
    [[ -e "$E" ]] && ln -s "$E" "$SCRATCH/.config/agent-watcher/$(basename "$E")"
  done
  [[ -e "$SCRATCH/.config/agent-watcher/credentials.json" ]] ||
    cp "$TREE/agent-watcher/credentials.example.json" "$SCRATCH/.config/agent-watcher/credentials.json"
  unset AGENT_TASK_GID XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
  export HOME="$SCRATCH"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
  cd "$TREE"
else
  TESTS="$HOME/.config/agent-watcher/hooks/tests"
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/hook-tests-out.XXXXXX")
PASSED=0; FAILED=0; RAN=0
for F in "$TESTS"/*.test.*; do
  [[ -f "$F" ]] || continue
  NAME=$(basename "$F")
  if [[ $# -gt 0 ]]; then
    WANT=0
    for SUB in "$@"; do [[ "$NAME" == *"$SUB"* ]] && WANT=1; done
    [[ $WANT -eq 1 ]] || continue
  fi
  case "$NAME" in
    *.py) RUNNER=python3 ;;
    *.js) RUNNER=node ;;
    *.sh) RUNNER=bash ;;
    *) continue ;;
  esac
  RAN=$((RAN + 1))
  START=$SECONDS
  "$RUNNER" "$F" > "$OUT" 2>&1 < /dev/null
  RC=$?
  # Some tests print FAIL lines and still exit 0, so both signals count.
  BAD=$(grep -cE '^(FAIL|not ok)' "$OUT" || true)
  if [[ $RC -eq 0 && $BAD -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    echo "PASS $NAME rc=0 $((SECONDS - START))s"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL $NAME rc=$RC $((SECONDS - START))s"
    if [[ $BAD -gt 0 ]]; then grep -E '^(FAIL|not ok)' "$OUT" | head -5 | sed 's/^/      /'
    else tail -5 "$OUT" | sed 's/^/      /'; fi
  fi
done
rm -f "$OUT"

[[ $RAN -gt 0 ]] || { echo "no test file matched in $TESTS" >&2; exit 2; }
echo "$PASSED passed, $FAILED failed, $RAN run (${TREE:-installed trees})"
[[ $FAILED -eq 0 ]]
