#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks raw gh WRITE surfaces in agent
# sessions that have a sanctioned companion-script funnel — the scripts carry
# gates a raw call bypasses in one move (pre-pr-gate test evidence + no-slop
# body lint for PR creation; lint + addressed-marker arithmetic for comment
# posting). Built 2026-08-24 alongside block-raw-asana-api.sh: same
# substitution failure class (agent that never read the skill improvises the
# raw command and skips every gate wired into the script).
#
# Three trigger classes:
#   1. `gh pr create` WITHOUT --draft  -> pr-create.sh (draft dep PRs are
#      sanctioned raw, per one-shot dep-pr-draft-vs-bump / pre-pr-gate header)
#   2. `gh pr comment` / `gh pr review` -> pr-address.sh / github-pr-review.sh
#   3. `gh api` WRITES to comment/review endpoints (POST/PATCH/DELETE shapes)
#      -> same scripts. Reads (bare GET listings) stay allowed. DELETE is
#      matched too: the sanctioned retraction is pr-address.sh delete-comment,
#      which is author-scoped to currentUser, so an agent can clean up its own
#      accidental post without gaining the ability to erase a human's review.
#
# Known residual: graphql addComment/submitPullRequestReview mutations.
# block-raw-thread-resolve.sh owns resolveReviewThread; extend here if a
# graphql-comment substitution ever shows up.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Companion scripts are exempt by
# path. Exit 0 allow, exit 2 block.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string
# must not fire this hook. Fail-open to the raw command if the helper is
# unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# Sanctioned scripts first — they invoke gh internally (invisible here), so
# this exempts mixed commands that both run a script and match a trigger.
case "$CMD" in
  *pr-create.sh*|*pr-address.sh*|*github-pr-review.sh*|*github-pr-comments.sh*|\
  *pr-finalize-fixups.sh*|*pr-land*|*bugbot*/scripts/*) exit 0 ;;
esac

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Class 1+2: gh pr subcommands at execution position in the stripped view.
if printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
  printf '%s' "$CMD_M" | grep -q -- '--draft' || block "raw \`gh pr create\` is forbidden in agent sessions (only \`--draft\` dep PRs are sanctioned raw). PR creation goes through /pr-create's pr-create.sh: it enforces the test-evidence gate, lints the body per /no-slop, injects the Asana link, and attaches the PR to the task. Read ~/.cursor/skills/pr-create/SKILL.md and use its script."
fi
if printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])gh[[:space:]]+pr[[:space:]]+(comment|review)([[:space:]]|$)'; then
  block "raw \`gh pr comment\`/\`gh pr review\` is forbidden in agent sessions — outbound PR prose goes through the linted funnels: /pr-address's pr-address.sh (reply, comment, mark-addressed) or /pr-review's github-pr-review.sh (review submit). Both lint per /no-slop and keep the addressed-marker arithmetic the Complete gate reads. Read the owning SKILL.md and use its script."
fi

# Class 3: gh api writes to comment/review endpoints. Trigger = endpoint shape
# anywhere in the raw command (endpoints sit inside quotes) AND an actual
# `gh api` invocation AND a write marker in the stripped view. gh api defaults
# to POST when -f/-F fields are present.
if echo "$CMD" | grep -qE '(issues|pulls)/[0-9]+/(comments|reviews)|issues/comments/[0-9]+|pulls/comments/[0-9]+'; then
  if printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])gh[[:space:]]+api([[:space:]]|$)' && \
     printf '%s' "$CMD_M" | grep -qE '(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]]|$|=)|--method[[:space:]=]+(POST|PATCH|DELETE)|-X[[:space:]]+(POST|PATCH|DELETE)'; then
    block "raw \`gh api\` writes to comment/review endpoints are forbidden in agent sessions — posting goes through pr-address.sh (reply, comment, mark-addressed) or github-pr-review.sh (review submit), which lint the body per /no-slop and keep the addressed-marker arithmetic the Complete gate reads. RETRACTING a comment you posted by mistake also has a sanctioned path: \`pr-address.sh delete-comment --owner <o> --repo <r> --comment-id <id>\`, which refuses any author but you. Reads (bare GET listings) are fine. Read the owning SKILL.md and use its script."
  fi
fi

exit 0
