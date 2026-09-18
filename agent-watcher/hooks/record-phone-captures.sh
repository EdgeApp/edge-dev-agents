#!/usr/bin/env bash
# record-phone-captures.sh -- PostToolUse(Bash).
#
# Notes where a phone screenshot just landed, so downscale-phone-screenshots.sh
# can scope by PROVENANCE instead of by filename. Detection, the ledger format,
# and the rationale for both live in lib/phone-capture-ledger.sh.
#
# Never blocks and never writes to stdout: a capture it fails to parse or
# resolve is simply not recorded, and the Read hook falls back to its path
# allowlist. Exit 0 always.
set -uo pipefail

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
# Cheap reject before spawning the parser: every capture form names one of these.
case "$CMD" in
  *screenshot*|*screencap*) ;;
  *) exit 0 ;;
esac

HOOKS="$HOME/.config/agent-watcher/hooks"
CMD_M=$(printf '%s' "$CMD" | "$HOOKS/strip-cmd-mentions.sh" 2>/dev/null) || CMD_M="$CMD"
[ "${#CMD_M}" -eq "${#CMD}" ] || CMD_M="$CMD"

. "$HOOKS/lib/phone-capture-ledger.sh" 2>/dev/null || exit 0
. "$HOOKS/lib/shell-word-resolve.sh" 2>/dev/null || exit 0

while IFS=$'\t' read -r POS WORD; do
  [ -n "${WORD:-}" ] || continue
  # $U / "$AGENT_SIM_UDID"-style paths resolve against assignments earlier in the
  # same command and then this hook's environment. No eval; an unresolvable word
  # is skipped rather than recorded as literal text.
  DEST=$(resolve_shell_word "$WORD" "$CMD" "$CMD_M" "$POS" 2>/dev/null) || continue
  [ -n "$DEST" ] || continue
  ledger_record "$DEST" 2>/dev/null || true
done < <(phone_capture_dests "$CMD" "$CMD_M" 2>/dev/null)

exit 0
