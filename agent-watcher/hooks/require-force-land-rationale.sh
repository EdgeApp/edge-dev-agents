#!/usr/bin/env bash
# require-force-land-rationale.sh -- PreToolUse(Bash).
# Blocks `gh pr merge ... --admin` until the PR carries this run's force-land
# rationale comment.
#
# WHY: an admin merge is the one land that no human ever approved, and the PR
# is where the next reader looks for why. pr-land `force-land-review-bypass`
# prescribes the comment; under mid-land momentum the merge command is the
# thing that gets typed and the comment is the thing that gets skipped, so the
# merge waits on the marker instead.
#
# The marker is written by ~/.cursor/skills/pr-land/scripts/force-land-rationale.sh
# AFTER the comment posts, so it can only exist if the comment does. It is
# per-PR (/tmp/agent-force-land-rationale-<owner>-<repo>-<pr>.json) and must be
# fresher than MAX_AGE: a marker from a land hours ago says nothing about the
# commits sitting on HEAD now.
#
# Scope: no-ops unless AGENT_TASK_GID is set. No escape hatch — the remedy is
# one script call, and the script itself refuses without Force Land authority
# and green checks. Exit 0 allow, exit 2 block.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

MAX_AGE=21600 # 6h

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view: a command that merely QUOTES the merge (a report body,
# an echoed instruction) must not fire this hook. Fail open to the raw command.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' || exit 0
printf '%s' "$CMD_M" | grep -qE '(^|[[:space:]])--admin([[:space:]]|=|$)' || exit 0

# PR number: `gh pr merge <n>` or a PR URL argument. Absent when gh infers the
# PR from the current branch, in which case any fresh marker satisfies the gate.
PR=$(printf '%s' "$CMD_M" | sed -nE 's|.*/pull/([0-9]+).*|\1|p' | head -1)
[ -n "$PR" ] || PR=$(printf '%s' "$CMD_M" | sed -nE 's/.*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+).*/\1/p' | head -1)

if [ -n "$PR" ]; then
  PATTERN="/tmp/agent-force-land-rationale-"*"-$PR.json"
else
  PATTERN="/tmp/agent-force-land-rationale-"*".json"
fi

NOW=$(date +%s)
for marker in $PATTERN; do
  [ -f "$marker" ] || continue
  mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || echo 0)
  [ $((NOW - mtime)) -le "$MAX_AGE" ] && exit 0
done

echo "BLOCKED: no force-land rationale comment on this PR (pr-land \`force-land-review-bypass\`). An admin merge lands with no approving review, so the PR has to say why review was skipped. Run it first:" >&2
echo "  ~/.cursor/skills/pr-land/scripts/force-land-rationale.sh --owner <o> --repo <r> --pr <n> --task-gid \$AGENT_TASK_GID --rationale \"<the change class that made review unnecessary>\"" >&2
echo "It posts the comment, then writes the marker this gate reads. It refuses without Force Land authority or with checks not green, which is the same answer as not merging." >&2
exit 2
