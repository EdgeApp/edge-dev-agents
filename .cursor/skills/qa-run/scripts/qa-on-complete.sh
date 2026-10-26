#!/usr/bin/env bash
# qa-on-complete.sh: the dev run's QA hook at agent_status=Complete. Called by
# ~/.config/agent-watcher/update-status.sh after a successful Complete write in a
# dev session (never in a qa-asana session), best-effort.
#
# Usage: qa-on-complete.sh --task-gid <gid> [--blocked yes|no]
#
#   agent_qa=Fixing, not blocked  -> Fixed (the dev followup retested the failed cases)
#   agent_qa=Fixing, blocked      -> Blocked (the fix itself hit a true blocker; the
#                                    operator owns the loop from here)
#   agent_qa unset, first Complete -> Pending, and the dev worktree's native app cache
#                                    key is pinned so the QA pass reuses the build
#   anything else                  -> no change (QA runs once per task)
# First Complete = deliverable PR, not blocked, a sim lane (agent_lane unset or
# containing iOS Sim, the watcher's needsSim: the QA session gets a pool sim, and a
# no-sim dev run relies on its own testing), the dev worktree exists, and the task
# carries at most one run report. An older task re-completing with agent_qa unset is
# therefore not queued.
# Exit: 0 always unless usage (2); every outcome is one stdout line.
set -uo pipefail
source "$HOME/.cursor/skills/qa-run/scripts/lib.sh"
source "$QA_H/lib/attach-names.sh"

GID="" BLOCKED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task-gid) GID="$2"; shift 2 ;;
    --blocked) BLOCKED="$2"; shift 2 ;;
    *) echo "qa-on-complete: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] || { echo "usage: qa-on-complete.sh --task-gid <gid> [--blocked yes|no]" >&2; exit 2; }
[ "${AGENT_MODE:-}" = qa ] && exit 0

TASK=$(qa_task_json "$GID") || { echo ">> QA: WARN, task read failed; agent_qa unchanged"; exit 0; }
QA=$(qa_field "$TASK" agent_qa)
DELIV=$(qa_field "$TASK" agent_deliverable)

if [ "$QA" = Fixing ]; then
  if [ "$BLOCKED" = yes ]; then
    "$QA_H/set-agent-field.sh" "$GID" agent_qa Blocked >/dev/null && echo ">> QA: agent_qa Fixing -> Blocked (the fix run ended blocked)"
  else
    "$QA_H/set-agent-field.sh" "$GID" agent_qa Fixed >/dev/null && echo ">> QA: agent_qa Fixing -> Fixed"
  fi
  exit 0
fi
[ -z "$QA" ] || { echo ">> QA: agent_qa=$QA, not queued again"; exit 0; }
case "$DELIV" in Task*) echo ">> QA: Task deliverable, no QA"; exit 0 ;; esac
[ "$BLOCKED" = yes ] && { echo ">> QA: blocked Complete, no QA"; exit 0; }
LANES=$(qa_lanes "$TASK")
[ -z "$LANES" ] || [[ ",$LANES," == *",iOS Sim,"* ]] || { echo ">> QA: no-sim lane ($LANES), no QA"; exit 0; }
REPO_DIR=$(qa_repo_dir "$GID")
[ -n "$REPO_DIR" ] || { echo ">> QA: no dev worktree, no QA"; exit 0; }
NREP=$(qa_attachments "$GID" | cut -f2 | grep -cE "$REPORT_ATTACH_RE" || true)
[ "$NREP" -le 1 ] || { echo ">> QA: not the first Complete ($NREP run reports), no QA"; exit 0; }

"$QA_H/set-agent-field.sh" "$GID" agent_qa Pending >/dev/null || { echo ">> QA: WARN, agent_qa=Pending write failed"; exit 0; }
B="$HOME/.cursor/skills/build-and-test/scripts/lib"
KEY=$(source "$B/native-deps-hash.sh" && source "$B/native-app-cache.sh" && native_app_cache_key "$REPO_DIR" 2>/dev/null)
if [ -n "$KEY" ]; then
  PINS="${NATIVE_APP_CACHE_DIR:-$HOME/Library/Caches/agent-native-apps}/.pins"
  mkdir -p "$PINS" && printf '%s\n' "$KEY" > "$PINS/$GID"
  echo ">> QA: agent_qa=Pending (queued); native app cache key $KEY pinned"
else
  echo ">> QA: agent_qa=Pending (queued); no cache key for this tree, QA builds once"
fi
