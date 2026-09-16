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

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
IS_DRIVE=0
case "$TOOL" in
  # Read-only calls drive nothing: enumerating devices (the natural first
  # probe), a screenshot, a hierarchy read. They still hit
  # require-maestro-device.sh's booted guard (a downed bound sim re-latches the
  # daemon, so a screenshot could show the wrong device).
  mcp__maestro__list_devices|mcp__maestro__take_screenshot|mcp__maestro__inspect_screen) ;;
  mcp__maestro__*) IS_DRIVE=1 ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    [ -n "$CMD" ] || exit 0
    case "$CMD" in *maestro*|*capture-buy-quote*) ;; *) exit 0 ;; esac
    # Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
    # backticked spans blanked): a command that merely QUOTES a trigger string
    # (a report heredoc, an echo) must not fire this hook.
    CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    # A drive is what lib/maestro-cmd.sh says it is (shared with
    # require-maestro-device.sh): maestro EXECUTED with a test/record/studio/
    # hierarchy subcommand, or capture-buy-quote.sh / maestro-mcp-wrapper.sh
    # executed. `maestro --version`, `ls .../maestro`, and grep/cat of maestro
    # paths are not drives.
    LIB="$HOME/.config/agent-watcher/hooks/lib"
    [ -f "$LIB/maestro-cmd.sh" ] || exit 0
    . "$LIB/maestro-cmd.sh"
    if [ -n "$(maestro_cmd_segments "$CMD" "$CMD_M" 2>/dev/null || true)" ]; then
      IS_DRIVE=1
    fi
    ;;
esac
[ "$IS_DRIVE" = 1 ] || exit 0

# Playbook already read: pass, but once per run inject the working-set check at
# the FIRST post-read drive. Salience delivery, not availability — the playbook
# is force-read (below) yet its working-set bullet was read-and-missed on an
# asset task (HOOD, 2026-08-12). Fires only when corePlugins.ts is untouched;
# a trimmed worktree or a non-gui repo sees nothing. Never blocks.
if [ -f "$MARKER" ]; then
  NUDGE_FLAG="/tmp/agent-coreplugins-nudge-$AGENT_TASK_GID"
  [ -f "$NUDGE_FLAG" ] && exit 0
  : > "$NUDGE_FLAG"
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  TOP=$(git -C "${CWD:-/nonexistent}" rev-parse --show-toplevel 2>/dev/null || true)
  CP="$TOP/src/util/corePlugins.ts"
  if [ -n "$TOP" ] && [ -f "$CP" ] && git -C "$TOP" diff --quiet HEAD -- src/util/corePlugins.ts 2>/dev/null; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: "corePlugins.ts is untouched. If this task is asset/chain/provider-scoped, trim the plugin set to the task WORKING SET before driving: the target plugin(s) plus funding sources (BTC/ETH/USDC) plus every provider under test — playbook \"working set\" entry. Funding carve-out: if a funding route later needs a filtered-out asset/provider, widen or remove the trim, fund, re-trim if useful; a funding blocker caused by your own trim is self-inflicted (concession-validator denies it). If the full plugin set is intentional for this task, drive on."}}'
  fi
  exit 0
fi

PLAYBOOK="$HOME/.cursor/skills/build-and-test/references/sim-testing-playbook.md"
cat >&2 <<MSG
BLOCKED: no maestro drive before the sim-testing playbook is read this run.
Read it now (short file, one Read call unblocks every later drive):
  $PLAYBOOK
It holds the working knowledge that otherwise gets re-learned on the sim clock:
$(grep -E '^## ' "$PLAYBOOK" 2>/dev/null | sed 's/^## /  - /')
Start with "Investigate cheap before driving the UI": pick the swap pair via
direct provider API + account holdings BEFORE any in-sim quote probing, and on
an asset/provider-scoped task apply the corePlugins force FIRST (navigation
churn otherwise). Swipes: percentage coordinates + short strokes; the confirm
slider is SOLVED in common/confirm-slider.yaml - never re-derive either.
Then COMPOSE drives from ~/.cursor/skills/build-and-test/maestro/common/
via runFlow instead of re-deriving taps:
  login-if-needed.yaml            logged-in account incl. PIN entry
  dismiss-startup-modals.yaml     clear survey/notification/update modals
  select-swap-pair.yaml           Exchange -> wallets -> amount -> quote
                                  (SRC_WALLET, DST_WALLET, FIAT_AMOUNT, PROVIDER)
  confirm-slider.yaml             the confirm slider gesture (SOLVED)
MSG
exit 2
