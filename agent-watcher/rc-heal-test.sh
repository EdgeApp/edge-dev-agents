#!/usr/bin/env bash
# rc-heal-test.sh — contract tests for rc-heal.sh's pure detectors (the two decisions
# that gate every remedy: is the RC bridge up, and is the pane parked on a human
# choice). Run after any edit to rc-heal.sh, and after porting it to another host.
#   ./rc-heal-test.sh            synthetic cases only
#   ./rc-heal-test.sh <anchor>   also asserts the live anchor's pane reads as bridge-UP
set -uo pipefail
ANCHOR="${1:-}"
set --   # a sourced script sees the CALLER's positional args; rc-heal.sh rejects unknown ones
RC_HEAL_LIB=1 source "$(dirname "$0")/rc-heal.sh"

pass=0; fail=0
t() { local d="$1" e="$2" f="$3" c="$4" r
  if "$f" "$c"; then r=0; else r=1; fi
  if [[ "$r" == "$e" ]]; then pass=$((pass + 1)); echo "ok   $d"
  else fail=$((fail + 1)); echo "FAIL $d (got $r want $e)"; fi
}

t "rc_up: current-build footer with /rc token" 0 rc_up '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents             /rc'
t "rc_up: same footer, no /rc token" 1 rc_up '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
t "rc_up: old-build banner in the tail" 0 rc_up "$(printf 'x\nRemote Control active\n')"
t "rc_up: /rc only in scrolled conversation" 1 rc_up "$(printf 'we discussed /rc earlier\n%s\n  (shift+tab to cycle)\n' "$(printf 'x\n%.0s' {1..12})")"
t "rc_up: empty pane" 1 rc_up ""
t "awaiting_choice: numbered menu" 0 awaiting_choice "$(printf '❯ 1. Yes\n  2. No\n')"
t "awaiting_choice: permission dialog" 0 awaiting_choice '  No, and tell Claude what to do differently'
t "awaiting_choice: trust prompt" 0 awaiting_choice 'Do you want to trust the files in this folder?'
t "awaiting_choice: idle composer is NOT a choice prompt" 1 awaiting_choice '❯ '

if [[ -n "$ANCHOR" ]]; then
  live=$(tmux capture-pane -t "claude-asana-$ANCHOR" -p 2>/dev/null) \
    && t "rc_up: live anchor $ANCHOR reads as bridge UP" 0 rc_up "$live" \
    || { fail=$((fail + 1)); echo "FAIL could not capture claude-asana-$ANCHOR"; }
fi

echo "--- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
