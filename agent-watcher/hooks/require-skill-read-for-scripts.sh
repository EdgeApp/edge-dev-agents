#!/usr/bin/env bash
# require-skill-read-for-scripts.sh — PreToolUse hook (matcher: Bash). Blocks
# executing a skill's companion script before the owning SKILL.md entered this
# run's context. A companion script is one STEP of its skill's contract; bare
# invocation ships the step without the contract around it (asana-get-context
# run bare fetches attachments nobody then opens — the 08-24/08-26 planning
# misses). Complements the substitution blocks (block-raw-asana-api,
# block-raw-gh-writes): those catch improvised REPLACEMENTS for a script,
# this catches the script itself used contract-blind.
#
# Ownership: any execution-position path skills/<name>/scripts/*.sh requires
# <name>'s marker. Shared top-level scripts with one governing skill are
# mapped explicitly below; unmapped shared scripts are exempt (no single
# owner). Markers come from mark-skill-read.sh and inject-run-context.sh.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view: a heredoc/echo that merely quotes a script path must
# not fire. Fail-open to raw if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

EXEC_POS='(^|[;&|(]|\$\(|\b(bash|sh|source)[[:space:]]+)[[:space:]]*[^[:space:]]*'

NEEDED=""
# Skill-directory scripts: owner is the directory name.
for sk in $(printf '%s' "$CMD_M" | grep -oE "${EXEC_POS}skills/[a-z0-9-]+/scripts/[^[:space:]]+\.sh" | grep -oE 'skills/[a-z0-9-]+/scripts' | sed -E 's|skills/([a-z0-9-]+)/scripts|\1|' | sort -u); do
  NEEDED="$NEEDED $sk"
done
# Shared top-level scripts with one governing skill.
if printf '%s' "$CMD_M" | grep -qE "${EXEC_POS}asana-get-context\.sh([[:space:]]|$)"; then
  NEEDED="$NEEDED task-review"
fi
if printf '%s' "$CMD_M" | grep -qE "${EXEC_POS}lint-commit\.sh([[:space:]]|$)"; then
  NEEDED="$NEEDED im"
fi

[ -n "${NEEDED// /}" ] || exit 0

# Deny-with-body: the mechanism and its rationale live in lib/skill-read-gate.sh,
# shared with the outward-prose gates (lint-md-on-write.sh, slack-prose-gate.sh).
. "$HOME/.config/agent-watcher/hooks/lib/skill-read-gate.sh"
MISSING=$(skill_read_missing $NEEDED)
[ -n "$MISSING" ] || exit 0

{
  echo "BLOCKED: this script is a step of a skill contract that has not entered this session's context yet. The full contract is below; it now counts as read. Act on it, then re-run this command."
  skill_read_deliver $MISSING
} >&2
exit 2
