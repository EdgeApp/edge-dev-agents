#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks branch/PR-mutating commands in an
# orchestrated session whose task is already at agent_status = Complete, per
# one-shot's `finalize-gate` (Complete is the terminal action) and
# `yolo-execution` (the only acceptable turn end is Complete).
#
# Why: `finalize-gate` is a SNAPSHOT. It is evaluated against the PR head that
# exists when Complete is set, and nothing re-opens it afterwards. On task
# 1217498055202092 (2026-08-18) the gate was genuinely green on `03d00865`
# (Cursor Bugbot completed `success` at 22:49:06, Complete at 22:51:51), and the
# run then resumed 50 minutes later and force-pushed five more times, ending at
# `6bd3f85` with 109 changed lines in the plugin. Cursor Bugbot re-ran on two of
# those heads and concluded `neutral` BOTH times (neutral = findings posted), and
# no one was watching: the session had already declared itself done. The operator
# found the second one 17 hours later.
#
# A prose rule cannot catch this, because the agent is not disobeying a rule it
# remembers at the moment it pushes — it has simply thought of one more fix and
# the terminal state is 50 minutes behind it in the transcript. Only a mechanical
# check at the push itself converts "kept working after Complete" into "reopened
# the phase", which is the correct move: set agent_status back to Reviewing, push,
# re-run watch-pr.sh (bots re-run on the new head), re-gate, refresh the report,
# then Complete again.
#
# NOT gated (deliberate):
#   - local commits (lint-commit.sh, git commit). Committing changes nothing a
#     reviewer or CI can see; the push is the event that invalidates the gate.
#   - `gh pr edit` of the title, body, labels or reviewers. None of it moves the
#     PR head, so no check or reviewer bot re-runs and the gate stays valid on
#     the head it ruled on. `gh pr edit --base` IS gated: retargeting the merge
#     base re-runs CI against different code.
#   - EVERY comment operation, for the same reason: `gh pr comment`, `gh pr
#     review`, POST/PATCH/DELETE against issues/comments or pulls/comments, the
#     pr-address reply and resolve-thread scripts, pr-attach-screenshots.sh.
#     Talking on a finished PR is how a run answers a late reviewer, and none of
#     it changes what the gate ruled on. This exemption is intentional, not
#     incidental: it holds because those verbs are absent from TARGETS below, so
#     any future broadening must keep tests/no-push-after-complete.test.py green.
#     Do NOT implement it as an early exit — a blanket comment-op exemption would
#     pass `gh pr comment ... && git push` straight through.
#   - a blocked completion's aftermath. `Complete --blocked yes` is still
#     Complete, and a blocked run has nothing to push; if it does, it is the same
#     defect and gets the same block.
#   - everything outside an orchestrated session (no AGENT_TASK_GID).
#
# Fail-open on API/network errors: Asana being down must not wedge a push.
# Exit 2 = block (stderr -> model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Branch/PR-mutating commands only. Anything here changes what a reviewer bot or
# a human sees on the PR, which is exactly what the finalize gate ruled on.
#
# Match INVOCATIONS, not mentions: the shared strip-cmd-mentions.sh blanks
# heredoc bodies and quoted spans (see its header for the rationale and the
# known bash -c gap), then the token must sit at a command position (start of
# string or after a shell separator, allowing the usual wrappers).
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
MATCHED=$(printf '%s' "$CMD_M" | python3 -c '
import re, sys
cmd = sys.stdin.read()
WRAPPERS = r"(?:(?:sudo|nohup|command|timeout\s+\S+|env(?:\s+\w+=\S+)*|\w+=\S+)\s+)*"
PATH_PREFIX = r"(?:[\w./~-]*/)?"
TARGETS = (r"(?:" + PATH_PREFIX + r"git\s+push|" + PATH_PREFIX +
           r"git-branch-ops\.sh\s+push|" + PATH_PREFIX +
           r"gh\s+pr\s+(?:create|ready|reopen)|" + PATH_PREFIX +
           r"gh\s+pr\s+edit\s[^;&|]*--base)")
pat = re.compile(r"(?:^|[;&|(]|\|\||&&|\bthen\b|\bdo\b)\s*" + WRAPPERS + TARGETS)
print("yes" if pat.search(cmd) else "no")
' 2>/dev/null || echo no)

[ "$MATCHED" = "yes" ] || exit 0

GID="$AGENT_TASK_GID"

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || exit 0

STATUS="$(curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" \
  "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.name,custom_fields.display_value" 2>/dev/null \
  | jq -r '[.data.custom_fields[]? | select(.name == "agent_status") | .display_value] | first // empty' 2>/dev/null || true)"

[ "$STATUS" = "Complete" ] || exit 0

cat >&2 <<EOF
BLOCKED: task $GID is at agent_status = Complete, so the finalize gate has
already been evaluated and closed. Pushing now changes the PR head the gate ruled
on, and nothing re-opens it: reviewer bots re-run on the new head and their
findings land with no one watching (task 1217498055202092, 2026-08-18 — two
Cursor Bugbot rounds concluded \`neutral\` on post-Complete heads and went unread
for 17 hours).

If this push is real work, REOPEN the phase rather than working past Complete:
  1. \$HOME/.config/agent-watcher/update-status.sh $GID Reviewing
  2. push
  3. ~/.cursor/skills/one-shot/scripts/watch-pr.sh --pr <num> --task-gid $GID
     (let the reviewer bots conclude on the NEW head; address findings)
  4. refresh the run report if its Finalize Gate section names the old head,
     re-attach it, then set Complete again.

If this push is NOT task work (a test-* cheese branch, an unrelated repo), say so
in the run report and re-run it after step 1.
EOF
exit 2
