#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks the Planning→Developing status
# transition in agent sessions until the planning artifacts exist and no
# operator ruling is pending:
#
#   1. INGESTION marker /tmp/asana-task-<gid>/.context-fetched — proof
#      asana-get-context.sh ran (task-review step 1; it downloads every task
#      attachment). Added 2026-08-24: task 1217796671374968 hand-rolled a raw
#      curl with notes-only opt_fields, never learned the prescribed script
#      existed, and planned past two repro screenshots. A read-gate on script
#      invocation cannot catch a script that is never invoked; only this
#      boundary-evidence check can.
#   2. PLAN document — deterministic counterpart to asana-plan's
#      `create-plan-required` (the prose-guarded plan contract was met 1/3 in
#      the last cohort; the hook-guarded contracts went 3/3). Accepted as:
#        - /tmp/plan-<gid>-*.md, a worktree-root plan, or a plan in the
#          harness scratchpad (/private/tmp/claude-*/<project>/<session>/
#          scratchpad/plan-<gid>-*.md), or
#        - a write of a plan-<gid>-*.md file (redirect/tee via
#          lib/md-write-target.sh, or cp/mv/install) earlier in the SAME
#          command as the update-status call ('cat > plan <<EOF ... EOF' then
#          update-status on the next line).
#
# FOLLOWUP SEGMENTS skip planning (one-shot followup-reopens-status: the
# operator's comments since the last run report ARE the scope). A segment is a
# followup when the check-followup-scope.sh marker records a run-report
# watermark (a report is already attached) AND was written during THIS segment
# (checked_at not before the segment start in versions/<gid>.jsonl). That run
# is the ingestion evidence (it live-fetches the comments and attachments), and
# it stands in for both the ingestion marker and the plan file, which
# inject-run-context.sh reaps at every segment start.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

case "$CMD_M" in
  *update-status.sh*) ;;
  *) exit 0 ;;
esac
echo "$CMD_M" | grep -q "Developing" || exit 0

GID="$AGENT_TASK_GID"
LIB="$HOME/.config/agent-watcher/hooks/lib"

# Followup segment (see header): fresh followup-scope marker with a watermark.
followup_segment() {
  local marker="/tmp/agent-followup-scope-$GID.json" vf seg checked wm
  [ -s "$marker" ] || return 1
  wm=$(jq -r '.watermark // empty' "$marker" 2>/dev/null || true)
  [ -n "$wm" ] || return 1
  vf="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions/$GID.jsonl"
  [ -f "$vf" ] || return 1
  seg=$(jq -rs '[.[] | .ts // empty] | last // empty' "$vf" 2>/dev/null || true)
  checked=$(jq -r '.checked_at // empty' "$marker" 2>/dev/null || true)
  [ -n "$seg" ] && [ -n "$checked" ] || return 1
  [[ ! "$checked" < "$seg" ]]
}

# A plan-<gid>-*.md written earlier in this same command, before update-status.
plan_written_in_command() {
  [ -f "$LIB/md-write-target.sh" ] || return 1
  . "$LIB/md-write-target.sh"
  [ -f "$LIB/shell-word-resolve.sh" ] && . "$LIB/shell-word-resolve.sh"
  local cwd lines line t
  cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  # First line of each raw top-level segment before the first update-status.sh
  # in the stripped view. The first line carries the redirect; a heredoc body
  # starts on the next line and is never scanned (prose there is not a write).
  lines=$(node -e '
const [raw, stripped] = process.argv.slice(1);
const m = stripped.length === raw.length ? stripped : raw;
const end = m.indexOf("update-status.sh");
if (end < 0) process.exit(0);
const pre = m.slice(0, end);
let s = 0;
const out = [];
for (const x of pre.matchAll(/&&|\|\||;|\n/g)) { out.push([s, x.index]); s = x.index + x[0].length; }
for (const [a, b] of out) {
  const line = raw.slice(a, b).split("\n")[0].trim();
  if (line) console.log(line);
}
' "$CMD" "$CMD_M" 2>/dev/null) || return 1
  [ -n "$lines" ] || return 1
  while IFS= read -r line; do
    t=$(bash_write_target "$line" "$cwd" md "$line")
    if [ -z "$t" ] && [[ "$line" =~ ^(sudo[[:space:]]+)?(cp|mv|install|ditto)[[:space:]] ]]; then
      t="${line##*[[:space:]]}"
      case "$t" in *'$'*) t=$(resolve_shell_word "$t" "$CMD" "$CMD_M" 2>/dev/null || printf '%s' "$t") ;; esac
      t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
    fi
    case "$(basename "${t:-x}")" in "plan-$GID-"*.md) return 0 ;; esac
  done <<< "$lines"
  return 1
}

FOLLOWUP=0
followup_segment && FOLLOWUP=1

# Check 1: ingestion evidence. Checked before the plan check — a plan written
# without ingestion is exactly the failure this catches, so prescribing "write
# the plan" first would order the fix backwards.
if [ "$FOLLOWUP" = 0 ] && [ ! -f "/tmp/asana-task-$GID/.context-fetched" ]; then
  echo "BLOCKED: no task-ingestion evidence for $GID. Read ~/.cursor/skills/task-review/SKILL.md and run its steps 1-3 BEFORE planning: step 1's asana-get-context.sh fetches the task, comments, subtasks, AND downloads every attachment to /tmp/asana-task-$GID/ (screenshots, specs, and logs attached to the task are requirements; a hand-rolled curl with notes-only opt_fields silently misses them all), and the skill's later steps tell you how to READ each downloaded artifact and fold it into the plan. Running the script bare skips those steps, so read the skill first. Revise the plan file if it already exists, then retry this status update. FOLLOWUP segment (a run report is already attached to the task): run ~/.config/agent-watcher/check-followup-scope.sh --task-gid $GID instead; this segment's run of it counts as ingestion and a followup skips planning." >&2
  exit 2
fi

# Check 2: operator ruling. asana-get-context.sh writes this marker when a
# non-operator human's comment or description edit postdates the operator's
# last word (task-review operator-final-say). Implementation waits for the
# operator; the marker clears itself on the next ingestion after the operator
# comments.
RULING="/tmp/asana-task-$GID/.awaiting-operator-ruling"
if [ -s "$RULING" ]; then
  echo "BLOCKED: task $GID has other-human text the operator has not ruled on (task-review operator-final-say): $(tr '\n' ';' < "$RULING"). The operator has final say before implementation. Do NOT enter Developing. Attach the plan, then post ONE agent comment that lists each open proposal by author with the plan's chosen default for it, so the operator can answer in one line; then take the blocked completion per one-shot yolo-true-blockers (e): ~/.config/agent-watcher/update-status.sh $GID Complete --blocked yes --reason \"awaiting operator ruling: <items>\". An operator comment after that ruling re-arms the task with a clear marker." >&2
  exit 2
fi

[ "$FOLLOWUP" = 1 ] && exit 0

if ls /tmp/plan-"$GID"-*.md >/dev/null 2>&1 || \
   ls "$HOME"/git/.agent-worktrees/"$GID"/*/plan-"$GID"-*.md >/dev/null 2>&1 || \
   ls /private/tmp/claude-*/*/*/scratchpad/plan-"$GID"-*.md >/dev/null 2>&1; then
  exit 0
fi
plan_written_in_command && exit 0

echo "BLOCKED: no plan document exists for task $GID. Before entering Developing, write the plan per asana-plan's create-plan-required: /tmp/plan-$GID-<short-slug>.md with all six sections (Summary; Goal/Definition of Done; Likely relevant files; Findings so far; Numbered implementation steps; Constraints), stamped with \$AGENT_SESSION_UUID. Then attach it to the task: ~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task $GID --attach-file <plan-path> --attach-name plan-<short-slug>.md. Then retry this status update." >&2
exit 2
