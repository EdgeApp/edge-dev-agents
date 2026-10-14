#!/usr/bin/env bash
# operator-hold-gate.sh -- PreToolUse hook (matcher: Bash). While an operator
# hold is active (operator-hold.sh status), block the commands that ADVANCE an
# orchestrated run, so a human steering the session cannot be overtaken by
# momentum: agent_status transitions (other than a --blocked yes, which the
# operator may have asked for), git push, PR creation, and landing/publishing.
# Everything else passes: reads, local edits, commits, builds, drives.
#
# Trigger precision: the commands the line runs, read by the shared parser
# (cmd-executes.sh and cmd-parse.sh), so a read of a script or a quoted
# mention never fires, and a push or PR action behind git -C, git -c, gh -R,
# a cd or bash -c text still does. When the line cannot be read, the push and
# PR triggers fall back to a text match on the mention-stripped command
# (strip-cmd-mentions.sh).
#
# Scope: no-op unless AGENT_TASK_GID is set. Exit 0 = allow, exit 2 = block
# (stderr fed to the model). Fail-open on any helper error.
set -uo pipefail
[ -n "${AGENT_TASK_GID:-}" ] || exit 0
GID="$AGENT_TASK_GID"
H="$HOME/.config/agent-watcher"
STATE=$("$H/operator-hold.sh" status "$GID" 2>/dev/null) || exit 0   # clear (or oracle missing) → allow

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
CMD_M=$(printf '%s' "$CMD" | "$H/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
executes() { printf '%s' "$CMD" | "$H/hooks/cmd-executes.sh" "$1" 2>/dev/null; }

WHAT=""
# A blocked completion is allowed under a hold (operator-directed); every other
# status write is held. Classified by the shared lib so this gate and the
# completion judge agree on what a block is.
source "$H/hooks/lib/completion-event.sh"
case "$(completion_event "$CMD")" in complete|status) WHAT="an agent_status transition (update-status.sh)" ;; esac
for s in pr-create.sh pr-land-automerge.sh pr-land-merge.sh pr-land-publish.sh npm-publish-web.sh upgrade-dep.sh staging-cherry-pick.sh pr-finalize-fixups.sh cheese-build.sh; do
  [ -n "$WHAT" ] && break
  executes "$s" && WHAT="a PR/landing action ($s)"
done
if [ -z "$WHAT" ] && RECS=$(printf '%s' "$CMD" | "$H/hooks/cmd-parse.sh" 2>/dev/null); then
  WHAT=$(printf '%s' "$RECS" | jq -rs '
    if any(.[]; .git.sub == "push") then "a git push"
    elif any(.[]; .name == "git-branch-ops.sh" and .argv[1] == "push") then "a git push (git-branch-ops.sh push)"
    elif any(.[]; .gh.sub == "pr create" or .gh.sub == "pr merge" or .gh.sub == "pr ready") then "a PR action (gh pr)"
    else "" end' 2>/dev/null || true)
elif [ -z "$WHAT" ]; then
  if printf '%s' "$CMD_M" | grep -qE '(^|[;&|(]|\$\()[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)'; then
    WHAT="a git push"
  elif printf '%s' "$CMD_M" | grep -qE 'git-branch-ops\.sh[[:space:]]+push([[:space:]]|$)'; then
    WHAT="a git push (git-branch-ops.sh push)"
  elif printf '%s' "$CMD_M" | grep -qE '(^|[;&|(]|\$\()[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|merge|ready)([[:space:]]|$)'; then
    WHAT="a PR action (gh pr)"
  fi
fi
[ -n "$WHAT" ] || exit 0

cat >&2 <<EOF
BLOCKED by operator hold ($STATE): this command is $WHAT, and a human is steering this session right now. Answer the operator in prose and END YOUR TURN; do not advance the run. The operator releases the hold with a message that starts with go, resume, continue or proceed. A hold the operator leaves alone lapses on its own: the watchdog releases it after operator_hold_ttl_min (15 by default) of an idle pane and sends <operator-hold-expired>. If the operator asked you to stop or block the task, use update-status.sh <gid> Complete --blocked yes --reason "operator-directed: <their words>", which this gate allows. Do not remove /tmp/agent-operator-hold-$GID yourself.
EOF
exit 2
