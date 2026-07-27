#!/usr/bin/env bash
# agent-authored-text.sh — wrap agent-authored Asana prose in the orch's
# authorship markers, deterministically and idempotently.
#
# Every piece of Asana text the ORCH writes (task descriptions, comments,
# subtask notes) is marked so a human scanning a task can tell agent output from
# operator output at a glance:
#
#   🥋            <- first line, alone
#   <the text>
#   👊            <- last line, alone
#
# Deterministic, not prose: scripts pipe their text through here, and the
# PreToolUse hook `mark-agent-authored-asana.sh` rewrites MCP Asana writes the
# same way, so BOTH write paths are covered without agent goodwill.
#
# IDEMPOTENT: text already carrying both markers passes through untouched, so
# double-wrapping is impossible (a re-run, or a script whose text was already
# wrapped upstream, stays clean).
#
# Usage:
#   agent-authored-text.sh            # text on stdin  -> wrapped on stdout
#   agent-authored-text.sh --check    # exit 0 if stdin is already wrapped, 1 if not
#   agent-authored-text.sh "text"     # text as an argument
# Exit: 0 always (except --check, which reports wrapped-ness).

set -uo pipefail

OPEN="🥋"
CLOSE="👊"

MODE="wrap"
[[ "${1:-}" == "--check" ]] && { MODE="check"; shift; }

if [[ $# -gt 0 ]]; then TEXT="$*"; else TEXT="$(cat)"; fi

# Already wrapped? First non-empty line is the open marker AND last non-empty
# line is the close marker.
first_ne="$(printf '%s\n' "$TEXT" | grep -m1 -v '^[[:space:]]*$' || true)"
last_ne="$(printf '%s\n' "$TEXT" | grep -v '^[[:space:]]*$' | tail -1 || true)"
if [[ "$(printf '%s' "$first_ne" | tr -d '[:space:]')" == "$OPEN" \
   && "$(printf '%s' "$last_ne" | tr -d '[:space:]')" == "$CLOSE" ]]; then
  [[ "$MODE" == "check" ]] && exit 0
  printf '%s' "$TEXT"
  exit 0
fi

[[ "$MODE" == "check" ]] && exit 1
printf '%s\n%s\n%s' "$OPEN" "$TEXT" "$CLOSE"
