#!/usr/bin/env bash
# refresh-report-judge-section.sh -- PostToolUse(Bash). After a run's FINISHING
# status write lands (`update-status.sh <gid> Complete`, or `--blocked yes`),
# splices the Completion Judge section into this segment's run report and
# re-attaches it, so the attached report ends with the verdict the run finished
# on.
#
# Why after the status write and not after the verdict: the report is attached
# before the first completion event, and a verdict is not the outcome. An allow
# can still be followed by a sibling PreToolUse gate denying the same call, and a
# deny is followed by a fix and a retry. Only a status write that succeeded marks
# the segment's last judge call; any earlier snapshot can freeze a deny that was
# later overturned.
#
# Trigger: the success line update-status.sh prints after Asana accepted the
# write ("Updated task <gid>: agent_status=Complete" or "..., blocked=yes"), for
# THIS session's gid. A failed write prints no such line, and a command that only
# quotes the script never produces it, so no command parsing is needed.
#
# Report: the first line of /tmp/agent-report-doc-<gid> (session|slug|path), the
# report this segment attached. The attach name is <iteration>-agent-run-report.md
# from the report's frontmatter; asana-task-update.sh replaces the same-name
# attachment in place. The re-attach is a subprocess, so no PreToolUse gate
# fires on it and it cannot loop.
#
# Exit 0, or 2 when the re-attach failed: a PostToolUse exit 2 blocks nothing (the
# status write already landed) and shows stderr, with the manual re-attach
# command, to the model.
# Scope: no-op unless AGENT_TASK_GID is set.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
GID="$AGENT_TASK_GID"
H="$HOME/.config/agent-watcher"

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0
OUT=$(printf '%s' "$INPUT" | jq -r '
  .tool_response | if type == "object" then (.stdout // "") elif type == "string" then . else "" end' 2>/dev/null) || exit 0
printf '%s\n' "$OUT" | grep -qE "^Updated task $GID: agent_status=(Complete|[^,]*, blocked=yes)" || exit 0

DOC="/tmp/agent-report-doc-$GID"
[ -s "$DOC" ] || exit 0
LINE=$(head -1 "$DOC")
case "$LINE" in *"|"*) REPORT="${LINE##*|}" ;; *) exit 0 ;; esac
[ -s "$REPORT" ] || exit 0

. "$H/hooks/lib/splice-judge-section.sh"
splice_judge_section "$GID" "$REPORT"

ITER=$(grep -m1 -E '^iteration: "?[0-9]+' "$REPORT" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
NAME="agent-run-report.md"
[ -n "$ITER" ] && NAME="$ITER-agent-run-report.md"
if "$HOME/.cursor/skills/asana-task-update/scripts/asana-task-update.sh" \
     --task "$GID" --attach-file "$REPORT" --attach-name "$NAME" >/dev/null 2>&1; then
  echo "completion judge: final verdict spliced into $REPORT and re-attached as $NAME"
else
  echo "completion judge: final verdict spliced into $REPORT but the re-attach failed; run asana-task-update.sh --task $GID --attach-file $REPORT --attach-name $NAME" >&2
  exit 2
fi
exit 0
