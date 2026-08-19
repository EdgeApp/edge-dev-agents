#!/usr/bin/env bash
# mark-playbook-read.sh — PostToolUse(Read | Bash).
# Writes the per-run marker require-playbook-before-drive.sh checks, when the
# completed tool call actually touched the sim-testing playbook: a Read of the
# file, or a Bash command referencing it (cat/grep/sed count — any engagement
# with the content beats none). Never blocks; exit 0 always.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
MARKER="/tmp/agent-playbook-read-$AGENT_TASK_GID"
[ -f "$MARKER" ] && exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  Read)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    case "$FP" in *sim-testing-playbook.md) touch "$MARKER" ;; esac
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # Stripped view: quoting the path in a heredoc/echo is not reading it.
    CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    case "$CMD_M" in *sim-testing-playbook*) touch "$MARKER" ;; esac
    ;;
esac
exit 0
