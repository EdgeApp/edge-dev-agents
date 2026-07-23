#!/usr/bin/env bash
# lane-release.sh — release a run's eagerly-allocated sim when the RESOLVED task
# scope provably never needs one. Called ONCE from one-shot planning, with the
# plan's COMPLETE repo list (never per-worktree: worktree order is not lane
# order, and a mixed gui+reports task must keep its sim regardless of which
# worktree happens first).
#
#   lane-release.sh --task-gid <gid> --repos <a,b,c>   lane union over the list
#   lane-release.sh --task-gid <gid> --land            land-only task: lane none
#                                                      (pr-land verifies via
#                                                      tsc/jest, never a sim,
#                                                      regardless of target repo)
#
# Decision precedence:
#   1. OPERATOR OVERRIDE: the task's `agent_lane` multi-select field, read LIVE.
#      Any selection is authoritative (a task may select several: comparison /
#      parity / QR-provisioning work): "iOS Sim" in the selection -> keep the
#      sim; a non-empty selection WITHOUT "iOS Sim" -> release (Android Sim /
#      Android Device / None need no iOS slot sim). Unset -> fall through to 2.
#   2. Union of `capabilities.sh detect` over the repos. ANY ios-sim member
#      -> keep (exit 0, no action). No sim member -> release the pool sim
#      (release-pool-entry.sh, idempotent). couch members -> reported so the run
#      fail-louds if the host lacks couch. UNCERTAINTY KEEPS THE SIM: empty/
#      missing repo list, unknown repo, detect failure, field fetch failure ->
#      keep. The cheap error is keeping a sim; the expensive one is releasing
#      what a later phase needs.
#
# The decision is recorded at $STATE/lanes/<gid>.json for eval audit.
# Exit: 0 always on a completed decision (keep or release), 2 on usage error.

set -uo pipefail

DIR="$HOME/.config/agent-watcher"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
GID="" REPOS="" LAND=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid) GID="$2"; shift 2 ;;
    --repos) REPOS="$2"; shift 2 ;;
    --land) LAND=1; shift ;;
    *) echo "lane-release: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$GID" ]] || { echo "usage: lane-release.sh --task-gid <gid> (--repos <a,b,c> | --land)" >&2; exit 2; }

# Operator override: agent_lane multi-select, read live (empty on unset/error).
LANE_FIELD=""
TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$DIR/credentials.json" 2>/dev/null)}"
if [[ -n "$TOKEN" ]]; then
  LANE_FIELD=$(curl -sf --max-time 20 -H "Authorization: Bearer $TOKEN" \
    "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.name,custom_fields.display_value" 2>/dev/null \
    | jq -r 'first(.data.custom_fields[]? | select(.name == "agent_lane") | .display_value) // empty' 2>/dev/null || true)
fi

LANES=() DECISION="keep" REASON=""
if [[ -n "$LANE_FIELD" && "$LAND" != 1 ]]; then
  LANES=("operator:$LANE_FIELD")
  if [[ "$LANE_FIELD" == *"iOS Sim"* ]]; then
    DECISION="keep"; REASON="operator agent_lane selects iOS Sim ($LANE_FIELD)"
  else
    DECISION="release"; REASON="operator agent_lane set without iOS Sim ($LANE_FIELD) — no iOS slot sim needed"
  fi
elif [[ "$LAND" == 1 ]]; then
  DECISION="release"; REASON="land-only task: pr-land verifies via repo checks, never a sim"
  LANES=("none")
elif [[ -n "$REPOS" ]]; then
  HAS_SIM=0
  IFS=',' read -ra RLIST <<< "$REPOS"
  for r in "${RLIST[@]}"; do
    r="$(echo "$r" | tr -d '[:space:]')"; [[ -n "$r" ]] || continue
    if [[ ! -d "$HOME/git/$r" ]]; then
      # no local clone: the classifier's feature sniffs cannot run, so a "none"
      # verdict would be a guess — treat as unknown (keeps the sim)
      lane="unknown"
    else
      lane="$("$DIR/capabilities.sh" detect "$r" 2>/dev/null || echo "unknown")"
    fi
    LANES+=("$r:$lane")
    [[ "$lane" == "ios-sim" ]] && HAS_SIM=1
    [[ "$lane" == "unknown" ]] && HAS_SIM=1   # uncertainty keeps the sim
  done
  if [[ ${#LANES[@]} -eq 0 ]]; then
    DECISION="keep"; REASON="empty repo list — uncertainty keeps the sim"
  elif [[ "$HAS_SIM" == 1 ]]; then
    DECISION="keep"; REASON="at least one resolved repo is ios-sim lane (or unknown)"
  else
    DECISION="release"; REASON="no resolved repo needs a simulator"
  fi
else
  DECISION="keep"; REASON="no --repos and not --land — uncertainty keeps the sim"
fi

if [[ "$DECISION" == "release" ]]; then
  "$DIR/release-pool-entry.sh" --task-gid "$GID" >/dev/null 2>&1 || true
fi

mkdir -p "$STATE_DIR/lanes"
jq -nc --arg gid "$GID" --arg d "$DECISION" --arg why "$REASON" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson land "$LAND" \
  --arg lanes "$(IFS=' '; echo "${LANES[*]:-}")" \
  '{gid:$gid, ts:$ts, decision:$d, reason:$why, land_only:($land==1), lanes:($lanes|split(" ")|map(select(length>0)))}' \
  > "$STATE_DIR/lanes/$GID.json" 2>/dev/null || true

echo ">> lane-release: $DECISION — $REASON"
for l in "${LANES[@]:-}"; do [[ -n "$l" ]] && echo ">>   $l"; done
if printf '%s\n' "${LANES[@]:-}" | grep -q ':couch'; then
  echo ">>   NOTE: couch lane present — verify CouchDB is available before integration tests (fail loud if absent)"
fi
