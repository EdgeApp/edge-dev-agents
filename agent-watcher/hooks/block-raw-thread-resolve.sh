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

echo "$CMD" | grep -q "resolveReviewThread" || exit 0

case "$CMD" in
  *pr-address.sh*|*bugbot*/scripts/*|*github-pr-comments.sh*) exit 0 ;;
esac

echo "BLOCKED: raw resolveReviewThread mutations are forbidden in agent sessions. Review threads are resolved through the sanctioned flow, which replies IN-THREAD first: /pr-address for human and mixed feedback, /bugbot for cursor[bot] findings (their companion scripts reply then resolve). A resolved thread without an in-thread reply hides the reasoning from reviewers and the audit trail. Read the relevant SKILL.md and use its scripts." >&2
exit 2
