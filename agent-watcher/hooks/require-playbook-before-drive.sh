#!/usr/bin/env bash
# require-playbook-before-drive.sh — PreToolUse(Bash | mcp__maestro__run).
# Blocks the run's maestro drives (MCP inline yaml AND CLI `maestro ... test`)
# until the sim-testing playbook has been read THIS run, evidenced by the marker
# mark-playbook-read.sh (PostToolUse) writes when any Read/Bash touches the file.
#
# Successor to nudge-flow-library.sh (2026-07-23), which pointed at the playbook
# on the first inline MCP drive but allowed re-issuing unchanged. Measured
# 2026-07-28: the nudge lifted the sim-active playbook read rate 33% -> 71%, and
# ALL residual non-readers were either nudged-and-ignored (4/6: took the
# re-issue escape hatch, never read, never adopted runFlow) or CLI-only drivers
# the MCP-only trigger missed (2/6). Both gaps close here: every drive path
# triggers, and the out is reading the file, not re-issuing.
#
# Not one-bounce: blocks until the marker exists. The remedy is a single Read of
# a short file whose PostToolUse marker then passes every subsequent drive, so
# a loop only occurs if the agent refuses the read. The deny message carries the
# flow-library index (the old nudge's payload) so composition guidance still
# arrives at the drive moment.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
MARKER="/tmp/agent-playbook-read-$AGENT_TASK_GID"
[ -f "$MARKER" ] && exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
IS_DRIVE=0
case "$TOOL" in
  mcp__maestro__*) IS_DRIVE=1 ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # CLI drives: `maestro ... test/studio ...`. Reads/inspections of maestro
    # dirs, capture-buy-quote.sh (which wraps the CLI), and the mcp wrapper all
    # count as drives too — every path to the sim goes through the playbook.
    if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])(maestro|capture-buy-quote\.sh|maestro-mcp-wrapper\.sh)[[:space:]]'; then
      IS_DRIVE=1
    fi
    ;;
esac
[ "$IS_DRIVE" = 1 ] || exit 0

PLAYBOOK="$HOME/.cursor/skills/build-and-test/references/sim-testing-playbook.md"
cat >&2 <<MSG
BLOCKED: no maestro drive before the sim-testing playbook is read this run.
Read it now (short file, one Read call unblocks every later drive):
  $PLAYBOOK
It holds the working knowledge that otherwise gets re-learned on the sim clock:
$(grep -E '^## ' "$PLAYBOOK" 2>/dev/null | sed 's/^## /  - /')
Start with "Investigate cheap before driving the UI": pick the swap pair via
direct provider API + account holdings BEFORE any in-sim quote probing.
Then COMPOSE drives from ~/.cursor/skills/build-and-test/maestro/common/
via runFlow instead of re-deriving taps:
  login-if-needed.yaml            logged-in account incl. PIN entry
  dismiss-startup-modals.yaml     clear survey/notification/update modals
  select-swap-pair.yaml           Exchange -> wallets -> amount -> quote
                                  (SRC_WALLET, DST_WALLET, FIAT_AMOUNT, PROVIDER)
  confirm-slider.yaml             the confirm slider gesture (SOLVED)
MSG
exit 2
