#!/usr/bin/env bash
# repo-land-lock.sh — per-repo LAND mutex, serializing rebase/merge/publish trains.
#
# Why: land-on-approval means two approved tasks in the SAME repo can finalize
# concurrently, and pr-land's sequential-rebase discipline is per-invocation —
# two sessions interleaving local rebase+push trains against one base branch
# race each other (lost rebases, double publishes). This lock makes the repo the
# unit of landing: one land train per repo at a time, machine-wide.
#
# Lease semantics (never wedges the fleet):
#   acquire --repo R --owner O [--ttl 1800]
#       free, or expired, or already OURS (renew)  -> exit 0
#       held by another live owner                 -> exit 75 (EX_TEMPFAIL: wait+retry)
#   release --repo R --owner O    only the owner releases; missing lock is fine -> exit 0
#   status  --repo R              prints the lock JSON or "free"
#
# Lock file: $XDG_STATE_HOME/agent-watcher/land-locks/<repo>.json
# Owner id: pass $AGENT_SESSION_UUID (orch) or any stable token (operator shell).

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/land-locks"
CMD="${1:-}"; shift || true
REPO="" OWNER="" TTL=1800
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    *) echo "repo-land-lock: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$CMD" && -n "$REPO" ]] || { echo "usage: repo-land-lock.sh <acquire|release|status> --repo <name> [--owner <id>] [--ttl <s>]" >&2; exit 2; }
REPO="${REPO##*/}"   # accept owner/name, key by name
LOCK="$STATE_DIR/$REPO.json"
mkdir -p "$STATE_DIR"
NOW=$(date +%s)

case "$CMD" in
  acquire)
    [[ -n "$OWNER" ]] || { echo "repo-land-lock: acquire needs --owner" >&2; exit 2; }
    if [[ -f "$LOCK" ]]; then
      CUR_OWNER=$(jq -r '.owner // ""' "$LOCK" 2>/dev/null || echo "")
      EXPIRES=$(jq -r '.expires // 0' "$LOCK" 2>/dev/null || echo 0)
      if [[ "$CUR_OWNER" == "$OWNER" ]]; then
        : # ours — renew below
      elif [[ "$NOW" -lt "$EXPIRES" ]]; then
        echo "repo-land-lock: $REPO is being landed by another session (owner $CUR_OWNER, lease expires in $((EXPIRES-NOW))s). Wait and retry — do NOT start a second land train." >&2
        exit 75
      else
        echo "repo-land-lock: reaping expired lease on $REPO (owner $CUR_OWNER)" >&2
        rm -f "$LOCK"
      fi
    fi
    if [[ ! -f "$LOCK" ]]; then
      if ! ( set -C; jq -nc --arg o "$OWNER" --argjson ts "$NOW" --argjson ex "$((NOW+TTL))" \
            '{owner:$o, ts:$ts, expires:$ex}' > "$LOCK" ) 2>/dev/null; then
        echo "repo-land-lock: lost the acquire race on $REPO — wait and retry." >&2
        exit 75
      fi
    else
      # renewal (ours)
      jq -c --argjson ex "$((NOW+TTL))" '.expires=$ex' "$LOCK" > "$LOCK.tmp" 2>/dev/null && mv "$LOCK.tmp" "$LOCK"
    fi
    echo "repo-land-lock: $REPO leased to $OWNER for ${TTL}s"
    ;;
  release)
    if [[ -f "$LOCK" ]]; then
      CUR_OWNER=$(jq -r '.owner // ""' "$LOCK" 2>/dev/null || echo "")
      if [[ -z "$OWNER" || "$CUR_OWNER" == "$OWNER" ]]; then
        rm -f "$LOCK"; echo "repo-land-lock: $REPO released"
      else
        echo "repo-land-lock: NOT releasing $REPO — held by $CUR_OWNER, not $OWNER" >&2
        exit 1
      fi
    fi
    ;;
  status)
    [[ -f "$LOCK" ]] && cat "$LOCK" || echo "free"
    ;;
  *) echo "repo-land-lock: unknown command $CMD" >&2; exit 2 ;;
esac
