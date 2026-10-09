#!/usr/bin/env bash
# UserPromptSubmit hook. NON-BLOCKING. Tells the operator, once per settings
# change, that THIS session started before ~/.claude/settings.canonical.json
# last changed, what it is missing, and how to restart it.
#
# A canonical edit reaches new sessions only; settings-guard.sh restarts
# nothing. A session that started earlier keeps the hooks, env and folder list
# it loaded, so the operator decides per session whether the change matters
# there. The line is printed on the first operator prompt after each change
# (marker /tmp/settings-stale-notified-<session-id>-<canonical-hash>), never
# again for that change.
#
# Silent in orchestrated runs (AGENT_TASK_GID): a run keeps what it loaded at
# spawn and is never asked to restart. Silent when the session is current, when
# the guard is absent, and on any error. Never blocks.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
[ -z "${AGENT_TASK_GID:-}" ] || exit 0
GUARD="$HOME/.config/agent-watcher/settings-guard.sh"
[ -x "$GUARD" ] || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$SID" ] || exit 0

ROW=$("$GUARD" --behind "$SID" 2>/dev/null || true)
[ -n "$ROW" ] || exit 0
IFS=$'\t' read -r PID TNAME HASH SUMMARY <<< "$ROW"
[ -n "${HASH:-}" ] || exit 0
MARK="/tmp/settings-stale-notified-$SID-$HASH"
[ -e "$MARK" ] && exit 0
: > "$MARK" 2>/dev/null || true

if [ "$TNAME" = "-" ]; then
  HOW="This session is not in a tmux pane, so it cannot restart itself: the operator restarts it from the app if they want the change."
else
  HOW="If the operator says to restart, finish or note anything in flight, then run this as the LAST action of your turn: tmux run-shell -b \"\$HOME/.config/agent-watcher/restart-session-in-place.sh --pid $PID --note '<what to continue>'\""
fi
echo "[settings-behind] This session started before the shared Claude settings last changed, so it is still running what it loaded at startup. Missing here: $SUMMARY. Answer the operator's message first, then tell them this in one short line at the end of your reply and ask whether to restart this session to load it. Do not restart unless they say so. $HOW"
exit 0
