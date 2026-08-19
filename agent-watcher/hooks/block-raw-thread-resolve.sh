#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks raw `resolveReviewThread` GraphQL
# mutations in agent sessions — review threads are resolved ONLY through the
# sanctioned companion scripts, which reply in-thread first (pr-address
# `reply-before-resolve`, bugbot's per-thread flow). A resolved thread with no
# in-thread reply is audit-silent.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Companion scripts are exempt by
# path. Exit 0 allow, exit 2 block.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
# The mutation string itself legitimately sits INSIDE quotes (a graphql -f
# query argument), so the trigger is: the string anywhere in the raw command
# AND an actual graphql invocation in the stripped view. A heredoc or echo
# that merely quotes the mutation has no graphql invocation.
echo "$CMD" | grep -q "resolveReviewThread" || exit 0
printf '%s' "$CMD_M" | grep -qE '(^|[;&|[:space:]])gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)' || exit 0

case "$CMD" in
  *pr-address.sh*|*bugbot*/scripts/*|*github-pr-comments.sh*) exit 0 ;;
esac

echo "BLOCKED: raw resolveReviewThread mutations are forbidden in agent sessions. Review threads are resolved through the sanctioned flow, which replies IN-THREAD first: /pr-address for human and mixed feedback, /bugbot for cursor[bot] findings (their companion scripts reply then resolve). A resolved thread without an in-thread reply hides the reasoning from reviewers and the audit trail. Read the relevant SKILL.md and use its scripts." >&2
exit 2
