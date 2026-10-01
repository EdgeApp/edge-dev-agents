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
#   renew   --repo R --owner O [--ttl 1800]
#       held by O and unexpired -> extend TTL, exit 0
#       held by another owner, or O's lease already expired (reapable) -> exit 1
#       no lease file (nothing held)  -> exit 3, silent
#     Long waits inside a land (verify-repo.sh steps, pr-merge-watch.sh and
#     watch-pr.sh polls) call renew so a live train never outlives its TTL; a
#     dead session stops renewing and its lease still expires. Renew never
#     resurrects an expired lease: another session may already be reaping it,
#     so the caller re-acquires instead.
#   release --repo R --owner O    only the owner releases; missing lock is fine -> exit 0
#   status  --repo R              prints the lock JSON or "free"
#
# Run-level hold (--hold on acquire/release):
#   acquire --hold --repo R --owner O --ttl 21600   marks the lease {"hold":true}
#   release --hold --repo R --owner O               clears it (end of the land run)
#   A plain release by the owner KEEPS a held lease, so the per-call
#   acquire/release pairs inside prepare/automerge/publish never open a gap
#   between pr-land steps. Every renewal (acquire-as-owner, renew) sets
#   expires = max(current, now + TTL): a 30-min inner renewal never shortens the
#   run-level hold. Readers (refresh-master-build.sh, refresh-main-checkouts.sh)
#   skip while any unexpired lease exists, held or not.
#
# Lock file: $XDG_STATE_HOME/agent-watcher/land-locks/<repo>.json
# Owner id: pass $AGENT_SESSION_UUID (orch) or any stable token (operator shell).

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/land-locks"
CMD="${1:-}"; shift || true
REPO="" OWNER="" TTL=1800 HOLD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --hold) HOLD=1; shift ;;
    *) echo "repo-land-lock: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$CMD" && -n "$REPO" ]] || { echo "usage: repo-land-lock.sh <acquire|renew|release|status> --repo <name> [--owner <id>] [--ttl <s>] [--hold]" >&2; exit 2; }
REPO="${REPO##*/}"   # accept owner/name, key by name
LOCK="$STATE_DIR/$REPO.json"
mkdir -p "$STATE_DIR"
NOW=$(date +%s)
# Extend-only expiry; --hold additionally marks the lease as a run-level hold.
EXTEND='.expires = ([.expires // 0, $ex] | max)'
[[ -n "$HOLD" ]] && EXTEND="$EXTEND | .hold = true"

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
            "{owner:\$o, ts:\$ts} | $EXTEND" > "$LOCK" ) 2>/dev/null; then
        echo "repo-land-lock: lost the acquire race on $REPO — wait and retry." >&2
        exit 75
      fi
    else
      # renewal (ours)
      jq -c --argjson ex "$((NOW+TTL))" "$EXTEND" "$LOCK" > "$LOCK.tmp" 2>/dev/null && mv "$LOCK.tmp" "$LOCK"
    fi
    echo "repo-land-lock: $REPO leased to $OWNER for ${TTL}s${HOLD:+ (run-level hold)}"
    ;;
  renew)
    [[ -n "$OWNER" ]] || { echo "repo-land-lock: renew needs --owner" >&2; exit 2; }
    [[ -f "$LOCK" ]] || exit 3
    CUR_OWNER=$(jq -r '.owner // ""' "$LOCK" 2>/dev/null || echo "")
    EXPIRES=$(jq -r '.expires // 0' "$LOCK" 2>/dev/null || echo 0)
    if [[ "$CUR_OWNER" != "$OWNER" ]]; then
      echo "repo-land-lock: NOT renewing $REPO: held by ${CUR_OWNER:-<unreadable>}, not $OWNER" >&2
      exit 1
    fi
    # 5s margin: an acquire racing the expiry may be reaping this file right now.
    if [[ $((NOW + 5)) -ge "$EXPIRES" ]]; then
      echo "repo-land-lock: NOT renewing $REPO: lease owned by $OWNER is expired (expires=$EXPIRES, now=$NOW); re-acquire" >&2
      exit 1
    fi
    jq -c --argjson ex "$((NOW+TTL))" '.expires = ([.expires // 0, $ex] | max)' "$LOCK" > "$LOCK.tmp.$$" 2>/dev/null && mv "$LOCK.tmp.$$" "$LOCK" || { rm -f "$LOCK.tmp.$$"; exit 1; }
    ;;
  release)
    if [[ -f "$LOCK" ]]; then
      CUR_OWNER=$(jq -r '.owner // ""' "$LOCK" 2>/dev/null || echo "")
      if [[ -z "$OWNER" || "$CUR_OWNER" == "$OWNER" ]]; then
        if [[ -z "$HOLD" && "$(jq -r '.hold // false' "$LOCK" 2>/dev/null)" == "true" ]]; then
          echo "repo-land-lock: $REPO kept (run-level hold; release --hold ends it)"
          exit 0
        fi
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
