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
#   - /tmp/agent-judge-waiver-<gid> written by an OPERATOR (never the run), by hand
#     or by hooks/operator-hold-prompt.sh on an ordered override ("complete the
#     task", "stop the task", "bypass the judge"): covers ONE completion event and
#     is consumed (removed) by it, so the next event is judged again; the text is
#     echoed and written to the provenance log as `"verdict":"override"`. The same
#     order sitting in an OPERATOR COMMENT in the segment's scope overrides per
#     event inside completion-judge.sh, each with its own log line.
# Judge unavailable (no binary, timeout under the launcher's own deadline, garbage
# output) DENIES with a retry recipe: a timed-out hook would fail OPEN, so the
# launcher deadline (480s) stays under this hook's timeout (600s).
#
# The verdict reaches the attached run report after the status write lands
# (hooks/refresh-report-judge-section.sh, PostToolUse), not from here: an allow
# here is not the outcome while a sibling gate can still deny the same call.
#
# Scope: no-op unless AGENT_TASK_GID is set. Exit 0 allow; exit 2 block (stderr to
# the model). Trigger precision via cmd-executes.sh, which strips mentions itself.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
GID="$AGENT_TASK_GID"
H="$HOME/.config/agent-watcher"
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
CMD_M=$(printf '%s' "$CMD" | "$H/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# The shared classifier (lib/completion-event.sh) decides the event, so every
# completion gate reads the same command the same way.
source "$H/hooks/lib/completion-event.sh"
EVENT=$(completion_event "$CMD" "$GID")
case "$EVENT" in block|complete|pr-create) ;; *) exit 0 ;; esac

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

# OPERATOR WAIVER: one event, then gone. The file is CONSUMED here (removed) and
# the skip is written to the judge provenance log as a `"verdict":"override"` line,
# the same log resolve-run surfaces as blocking.judge_log: an authorized bypass is
# readable as such, and a completion event with neither a verdict nor an override
# line is a gate evasion. The next completion event, in this segment or a later one,
# is judged again; the operator waives again by saying so again.
WAIVER="/tmp/agent-judge-waiver-$GID"
if [ -s "$WAIVER" ]; then
  TEXT=$(head -c 300 "$WAIVER" | tr '\n' ' ')
  KIND=$(printf '%s' "$TEXT" | sed -nE 's/^operator-directed ([a-z]+) .*/\1/p; s/^operator override \(([a-z]+)\).*/\1/p' | head -1)
  [ -n "$KIND" ] || KIND=waiver
  . "$H/lib/judge-log.sh"
  judge_log_override "$GID" "$EVENT" "$KIND" "operator waiver" "$TEXT"
  rm -f "$WAIVER" 2>/dev/null
  echo "completion judge WAIVED by operator for this $EVENT event on task $GID: $TEXT"
  echo "The waiver is consumed: it covered this one event and is now gone, so the next completion event is judged again (the operator waives again by saying so again). Logged to the judge provenance log as an operator override."
  exit 0
fi

ARGS=(--gid "$GID" --event "$EVENT")
[ -n "$REASON" ] && ARGS+=(--reason "$REASON")
# pr-create: the PR does not exist yet, so its --base (when given) tells the
# evidence bundle which branch the diff is measured from.
if [ "$EVENT" = pr-create ]; then
  PR_BASE=$(printf '%s' "$CMD" | sed -nE 's/.*--base[[:space:]=]+["'"'"']?([^"'"'"'[:space:]]+).*/\1/p' | head -1)
  [ -n "$PR_BASE" ] && ARGS+=(--base "$PR_BASE")
fi
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
