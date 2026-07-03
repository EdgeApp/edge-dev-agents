#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks `update-status.sh <gid> Complete` in
# orchestrated agent sessions unless a FRESH followup-scope check exists, per
# one-shot's `followup-scope-is-the-deliverable`.
#
# Why: every watcher resume auto-compacts the session from a pre-followup summary
# (resume menu -> "Resume from summary" -> /compact), so a resumed agent's memory
# cannot know about newer operator comments. Runs asserted "no comment newer than
# my run-report" from that stale summary and re-Completed past real followup scope
# (the 1209296431612665 UTXO miss, 2026-07-02, twice). A prose rule cannot fix a
# stale world model; only a forced live fetch can.
#
# Requires: /tmp/agent-followup-scope-<gid>.json written by check-followup-scope.sh,
# AND its newest_comment_at matching the live newest comment (one cheap curl) so a
# marker from a previous cycle cannot cover comments that arrived after it.
# Fail-open on API/network errors WHEN a marker exists (Asana being down should not
# wedge the fleet; without network update-status.sh would fail anyway).
#
# Scope: no-op (exit 0) unless AGENT_TASK_GID is set. Exit 2 = block (stderr -> model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Only gate: update-status.sh ... Complete for THIS session's task.
case "$CMD" in
  *update-status.sh*"$AGENT_TASK_GID"*Complete*) ;;
  *) exit 0 ;;
esac

GID="$AGENT_TASK_GID"
MARKER="/tmp/agent-followup-scope-$GID.json"
CHECK="\$HOME/.config/agent-watcher/check-followup-scope.sh --task-gid $GID"

if [ ! -s "$MARKER" ]; then
  echo "BLOCKED: no followup-scope check for task $GID. Your context may predate operator comments (a watcher resume compacts the session from a PRE-followup summary), so recalled history can never establish 'no new scope'. Run: $CHECK — then: if it lists operator asks newer than the run-report watermark, they are THIS run's deliverable (followup-scope-is-the-deliverable); deliver or explicitly surface them before Complete. If it lists none, retry Complete." >&2
  exit 2
fi

# Freshness: the marker must cover the live newest comment. Best-effort — any
# failure here fails OPEN (marker exists, Asana/API may be down).
TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
if [ -n "$TOKEN" ]; then
  LIVE_NEWEST="$(curl -sS --max-time 15 -H "Authorization: Bearer $TOKEN" \
    "https://app.asana.com/api/1.0/tasks/$GID/stories?opt_fields=created_at,resource_subtype" 2>/dev/null \
    | jq -r '[.data[]? | select(.resource_subtype == "comment_added") | .created_at] | sort | last // empty' 2>/dev/null || true)"
  MARKER_NEWEST="$(jq -r '.newest_comment_at // empty' "$MARKER" 2>/dev/null || true)"
  if [ -n "$LIVE_NEWEST" ] && [ "$LIVE_NEWEST" != "$MARKER_NEWEST" ]; then
    echo "BLOCKED: stale followup-scope check for task $GID — comment(s) landed after your last check (marker knows $MARKER_NEWEST, live newest is $LIVE_NEWEST). Re-run: $CHECK — address any new operator asks per followup-scope-is-the-deliverable, then retry Complete." >&2
    exit 2
  fi
fi

exit 0
