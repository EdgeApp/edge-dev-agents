#!/usr/bin/env bash
# mark-operator-present.sh — UserPromptSubmit hook. NON-BLOCKING.
# Stamps /tmp/agent-operator-present-$AGENT_TASK_GID on every prompt a HUMAN
# typed into an agent session. Machine-sent prompts confer no presence and are
# skipped: the orch spawn/re-fire prompt (`/one-shot ...`) and the watchdog
# revive ping. Everything else arriving on this channel is a person typing into
# the session.
#
# Consumer: no-push-after-complete.sh. A fresh stamp (<= 30 min) is its
# operator-present carve-out — a post-Complete push directed by a human in the
# live session is watched work, unlike the headless resume the block exists
# for. The stamp carries presence ONLY; it does not relax the app-testing
# boundary (the slot sim is retired at Complete; device verification still
# requires a re-arm to Pending).
#
# Fail-open: never blocks a prompt, never prints.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

PROMPT=$(jq -r '.prompt // empty' 2>/dev/null || true)
[ -n "$PROMPT" ] || exit 0

case "$PROMPT" in
  '<watchdog-revive-ping>'*) exit 0 ;;
  '/one-shot'*) exit 0 ;;
esac

touch "/tmp/agent-operator-present-$AGENT_TASK_GID" 2>/dev/null || true
exit 0
