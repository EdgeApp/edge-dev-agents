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
# marker from a previous cycle cannot cover comments that arrived after it,
# AND zero github_blocking_threads in the marker — unresolved review threads on
# an OWNED open PR (ANY author: the Maya re-fire re-Completed past an OPEN human
# thread on 2026-07-29 because the old gate wording filtered to Bot authors).
# Resolving them updates the marker via a re-run of the check, which is the
# retry path the deny message prescribes.
# Fail-open on API/network errors WHEN a marker exists (Asana being down should not
# wedge the fleet; without network update-status.sh would fail anyway).
#
# Scope: no-op (exit 0) unless AGENT_TASK_GID is set. Exit 2 = block (stderr -> model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# Only gate: update-status.sh ... Complete for THIS session's task.
case "$CMD_M" in
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

# Watermark ordering: AGENT-authored (🥋-marked) comments newer than the report
# attach mean the watermark is not last — invisible to the next run's scope
# check and report arithmetic (one-shot report-as-attachment: post the comment,
# then RE-ATTACH so the watermark lands last). 3 A9 BADs + 2 MINORs in the
# 2026-08-19 report-eval cohort; enforcement approved 2026-07-29, built here.
AGENT_AFTER="$(jq -r '.agent_comments_after_watermark // 0' "$MARKER" 2>/dev/null || echo 0)"
if [ "$AGENT_AFTER" -gt 0 ] 2>/dev/null; then
  echo "BLOCKED: $AGENT_AFTER agent-authored comment(s) postdate the run-report attachment, so the report is no longer the watermark — the next run's scope check cannot see anything below it. Re-attach the report (same file via asana-task-update.sh --attach-file; its iteration ordinal stays stable on re-attach), re-run: $CHECK — then retry Complete." >&2
  exit 2
fi

# GitHub-side scope: the marker's own record blocks. No live re-fetch here — the
# check script owns that; a re-run after resolving threads refreshes the count.
GH_BLOCKING="$(jq -r '.github_blocking_threads // 0' "$MARKER" 2>/dev/null || echo 0)"
if [ "$GH_BLOCKING" -gt 0 ] 2>/dev/null; then
  echo "BLOCKED: your followup-scope check recorded $GH_BLOCKING unresolved review thread(s) on an OWNED open PR — that is THIS run's scope (human threads count: a reviewer's comments are the re-arm reason even with zero Asana activity). Address each per pr-address reply-then-resolve, re-run: $CHECK — then retry Complete once it records zero blocking threads." >&2
  exit 2
fi

# Reviewer-bot completeness: Complete may not rest on a ready HEAD the bots
# never ran on (the 2026-08-06 cohort's two A3 gate FAILs). watch-pr writes the
# outage waiver when a reviewer is genuinely unavailable; its presence exempts.
GH_BOTS="$(jq -r '.github_bots_incomplete // 0' "$MARKER" 2>/dev/null || echo 0)"
if [ "$GH_BOTS" -gt 0 ] 2>/dev/null && [ ! -s "/tmp/agent-bot-unavailable-$GID" ]; then
  echo "BLOCKED: $GH_BOTS reviewer-bot check(s) missing or not completed-clean on an OWNED ready PR HEAD. Complete requires the bots to have RUN AND CONCLUDED there (success/skipped): if the PR just flipped ready, run watch-pr.sh and let them finish; a red bot means findings to address first. A genuine bot outage is waived automatically when watch-pr records reviewer-unavailable. Re-run: $CHECK — then retry Complete." >&2
  exit 2
fi

exit 0
