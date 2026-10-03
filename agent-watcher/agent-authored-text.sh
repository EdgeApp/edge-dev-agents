#!/usr/bin/env bash
# agent-authored-text.sh — wrap agent-authored Asana prose in the orch's
# authorship markers, deterministically and idempotently.
#
# Every piece of Asana text the ORCH writes (task descriptions, comments,
# subtask notes) is marked so a human scanning a task can tell agent output from
# operator output at a glance:
#
#   🥋 <the text starts inline, after one space>
#   <...>
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

# ORCH-authored text only, same boundary the MCP-path hook enforces: the
# in-flight-run test (AGENT_TASK_GID AND live tmux name, see
# orch-run-context.sh) decides. Operator-context sessions, including RETIRED
# post-completion sessions that still carry AGENT_TASK_GID, pass text through
# unmarked: it is operator instruction. `--check` is exempt: it is a predicate
# about the text, not a write, and callers use it to detect already-wrapped
# input either way.
if [[ "$MODE" == "wrap" ]] && ! "$(dirname "$0")/orch-run-context.sh"; then
  printf '%s' "$TEXT"
  exit 0
fi

# Already wrapped? The ONE test lives in lib/agent-authored.jq (every reader of
# the markers uses it): first non-blank line opens with the open marker, last
# non-blank line is the close marker alone.
SELF="$0"; [[ -L "$SELF" ]] && SELF="$(readlink "$SELF")"   # tests link this script into a fake HOME
if printf '%s' "$TEXT" | jq -Rse -L "$(dirname "$SELF")/lib" 'include "agent-authored"; agent_authored' >/dev/null 2>&1; then
  [[ "$MODE" == "check" ]] && exit 0
  printf '%s' "$TEXT"
  exit 0
fi

[[ "$MODE" == "check" ]] && exit 1
printf '%s %s\n%s' "$OPEN" "$TEXT" "$CLOSE"
