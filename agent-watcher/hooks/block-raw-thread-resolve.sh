#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks raw `resolveReviewThread` GraphQL
# mutations in agent sessions — review threads are resolved ONLY through the
# sanctioned companion scripts, which reply in-thread first (pr-address
# `reply-before-resolve`, bugbot's per-thread flow). A resolved thread with no
# in-thread reply is audit-silent.
#
# Scope: EVERY session, orchestrated or chat. Companion scripts are exempt by
# DIRECTORY, so a script added under those roots is covered without editing a
# name list here.
# Was: no-ops unless AGENT_TASK_GID is set. Companion scripts are exempt by
# path. Exit 0 allow, exit 2 block.
set -euo pipefail


# Read the payload ONCE: stdin is consumable, and both the command and the
# cwd (used to resolve which repo this targets) come out of it.
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
# Scope: EdgeApp repos only. The sanctioned funnels this gate redirects to
# (pr-address.sh, github-pr-review.sh, pr-create.sh) are Edge-specific, so
# applying it to another orchestrator's repos blocks work with no compliant
# path. Resolution order: a repo named in the command, else the cwd's origin
# remote. Unresolvable means fail open, never block work this gate cannot own.
gh_target_is_edge() {
  local cmd="$1" cwd="$2" named
  named=$(printf '%s' "$cmd" | grep -oE '(repos/|--repo[ =]+)([A-Za-z0-9_.-]+)/[A-Za-z0-9_.-]+' | head -1 \
          | sed -E 's#(repos/|--repo[ =]+)##')
  if [ -n "$named" ]; then
    case "$named" in EdgeApp/*) return 0 ;; *) return 1 ;; esac
  fi
  [ -n "$cwd" ] || return 1
  local remote
  remote=$(cd "$cwd" 2>/dev/null && git remote get-url origin 2>/dev/null) || return 1
  case "$remote" in *EdgeApp/*|*EdgeApp.git*) return 0 ;; *) return 1 ;; esac
}

CWD_IN=$(printf '%s' "${INPUT:-}" | jq -r '.cwd // empty' 2>/dev/null || true)
gh_target_is_edge "$CMD" "$CWD_IN" || exit 0

CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
# The mutation string itself legitimately sits INSIDE quotes (a graphql -f
# query argument), so the trigger is: the string anywhere in the raw command
# AND an actual graphql invocation in the stripped view. A heredoc or echo
# that merely quotes the mutation has no graphql invocation.
echo "$CMD" | grep -q "resolveReviewThread" || exit 0
printf '%s' "$CMD_M" | grep -qE '(^|[;&|[:space:]])gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)' || exit 0

# Companion scripts are exempt by DIRECTORY, but only when one is actually
# INVOKED: cmd-executes.sh owns the command-position test and the reason a
# substring match is not good enough.
printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/cmd-executes.sh" \
  --under /.cursor/skills/ --under /.config/agent-watcher/ && exit 0

echo "BLOCKED: raw resolveReviewThread mutations are forbidden in agent sessions. Review threads are resolved through the sanctioned flow, which replies IN-THREAD first: /pr-address for human and mixed feedback, /bugbot for cursor[bot] findings (their companion scripts reply then resolve). A resolved thread without an in-thread reply hides the reasoning from reviewers and the audit trail. Read the relevant SKILL.md and use its scripts." >&2
exit 2
