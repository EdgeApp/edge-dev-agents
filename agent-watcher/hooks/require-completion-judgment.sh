#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash, timeout 600). Gates every COMPLETION EVENT of an
# orchestrated run behind the completion judge (~/.cursor/skills/completion-judge):
#   complete   `update-status.sh <gid> Complete`
#   block      `update-status.sh <gid> ... --blocked yes --reason "<why>"`
#   pr-create  `pr-create.sh ...`
# The judge runs OUTSIDE the run (completion-judge.sh spawns a headless Opus with
# the evidence bundle; the agent never writes the verdict). Its verdict is bound to
# the evidence hash, so an unchanged retry is instant and any new evidence is
# re-judged. Supersedes require-concession-validation.sh (a shim at that path
# forwards here): the concession taxonomy is one section of the judge's rubric,
# and the block/downgrade kinds are the `block` event and the J5 dimension.
#
# Pass-throughs (no judgment):
#   - a block while an OPERATOR HOLD is active: the human who would judge it is the
#     one asking for it (operator-directed)
#   - /tmp/agent-judge-waiver-<gid> written by an OPERATOR (never the run), by
#     hand or by hooks/operator-hold-prompt.sh on an ordered override ("complete
#     the task", "stop the task", "bypass the judge"), or by completion-judge.sh when
#     such an order sits in an OPERATOR COMMENT in the segment's scope: stands for
#     the segment (spawn/resume clears it); the text is echoed for the eval
# Judge unavailable (no binary, timeout under the launcher's own deadline, garbage
# output) DENIES with a retry recipe: a timed-out hook would fail OPEN, so the
# launcher deadline (480s) stays under this hook's timeout (600s).
#
# Scope: no-op unless AGENT_TASK_GID is set. Exit 0 allow; exit 2 block (stderr to
# the model). Trigger precision via cmd-executes.sh on the mention-stripped command.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
GID="$AGENT_TASK_GID"
H="$HOME/.config/agent-watcher"
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
CMD_M=$(printf '%s' "$CMD" | "$H/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

EXEC="$H/hooks/cmd-executes.sh"
RUNS_UPDATE_STATUS=false; RUNS_PR_CREATE=false
printf '%s' "$CMD_M" | "$EXEC" update-status.sh 2>/dev/null && RUNS_UPDATE_STATUS=true
printf '%s' "$CMD_M" | "$EXEC" pr-create.sh 2>/dev/null && RUNS_PR_CREATE=true

EVENT=""
if $RUNS_UPDATE_STATUS; then
  # Only this session's task.
  case "$CMD_M" in *"$GID"*) ;; *) exit 0 ;; esac
  case "$CMD_M" in
    *--blocked*yes*) EVENT="block" ;;
    *Complete*) EVENT="complete" ;;
  esac
fi
[ -z "$EVENT" ] && $RUNS_PR_CREATE && EVENT="pr-create"
[ -n "$EVENT" ] || exit 0

REASON=""
if [ "$EVENT" = "block" ]; then
  REASON=$(printf '%s' "$CMD" | node -e 'const s=require("fs").readFileSync(0,"utf8");const m=s.match(/--reason\s+("([^"]*)"|\x27([^\x27]*)\x27|(\S+))/);process.stdout.write(m?(m[2]!==undefined?m[2]:m[3]!==undefined?m[3]:m[4]||""):"")' 2>/dev/null || true)
  # PreToolUse sees the command UNEXPANDED: expand $(cat F) / $(< F) / `cat F` here.
  SUBST=$(printf '%s' "$REASON" | sed -nE 's/^\$\((cat|<)[[:space:]]+([^)]+)\)$/\2/p; s/^`cat[[:space:]]+([^`]+)`$/\1/p' | head -1)
  if [ -n "$SUBST" ]; then
    SUBST="${SUBST/#\~/$HOME}"
    [ -r "$SUBST" ] && REASON=$(cat "$SUBST") || { echo "BLOCKED: --reason uses \$(cat $SUBST) but that file is not readable by the gate. Write the file first or pass a plain quoted string." >&2; exit 2; }
  fi
  [ -n "$REASON" ] || { echo "BLOCKED: a --blocked yes write must carry --reason \"<the claimed blocker>\" so the completion judge can rule on it. Add --reason and retry." >&2; exit 2; }
  if "$H/operator-hold.sh" status "$GID" >/dev/null 2>&1; then
    echo "operator hold active: block accepted as operator-directed (no judgment required)."
    exit 0
  fi
fi

WAIVER="/tmp/agent-judge-waiver-$GID"
if [ -s "$WAIVER" ]; then
  echo "completion judge WAIVED by operator for task $GID: $(head -c 200 "$WAIVER" | tr '\n' ' ')"
  exit 0
fi

ARGS=(--gid "$GID" --event "$EVENT")
[ -n "$REASON" ] && ARGS+=(--reason "$REASON")
OUT=$("$H/completion-judge.sh" "${ARGS[@]}" 2>/tmp/agent-judge-$GID.stderr)
RC=$?
case "$RC" in
  0) echo "completion judge: allow ($EVENT)"; exit 0 ;;
  1)
    echo "BLOCKED: the completion judge DENIED the $EVENT event for task $GID. It judged the evidence bundle (/tmp/agent-completion-evidence-$GID.md: task asks, operator comments since the report watermark, run report, state file, attempt-log, proof frames, PR diff) in a clean context; it reads evidence, not arguments. Do each what_to_do below, which changes the evidence and triggers a fresh judgment on retry:
$OUT
Full verdict: /tmp/agent-completion-verdict-$GID.json" >&2
    exit 2 ;;
  *)
    echo "BLOCKED: the completion judge could not rule on the $EVENT event ($(head -c 300 /tmp/agent-judge-$GID.stderr | tr '\n' ' ')). This is infrastructure, not a verdict: wait a minute and retry the same command. If it keeps failing, report it in the run report's Orchestration Issues; only an operator can waive the judge (they write /tmp/agent-judge-waiver-$GID)." >&2
    exit 2 ;;
esac
