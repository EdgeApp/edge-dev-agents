#!/usr/bin/env bash
# inject-run-context.sh — SessionStart hook (all sources: startup, resume,
# clear, compact). NON-BLOCKING. Injects a bounded block of LIVE ground truth
# at every context boundary, because the first turns after a boundary are when
# the model's beliefs are most likely to be summary-flattened or stale:
# compaction drops negative instructions, identifiers, and provenance, and a
# resume's summary predates whatever comment triggered the resume.
#
# Payload by session kind:
#   ORCH RUN (AGENT_TASK_GID set): live Asana task state, operator comments
#     newer than the last run-report attachment (the followup watermark),
#     attempt-log tail, attached-PR state, slot/worktree env, the mid-run
#     state file (/tmp/agent-state-<gid>.md) if the run keeps one, and
#     re-read pointers for contract files.
#   ANCHOR (tmux claude-asana-<name> with <name> in persistent_anchors):
#     identity line + the anchor's open-threads ledger.
#   Anything else: exits silently.
#
# Every fetch is best-effort with a short timeout; a dead network yields a
# partial block, never a blocked session start. Exit 0 always.
set -uo pipefail

DIR="$HOME/.config/agent-watcher"
ST="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
CRED="$DIR/credentials.json"

cat >/dev/null 2>&1 || true   # drain hook JSON (unused; env + files carry what we need)

emit_run() {
  local gid="$1" tok
  tok=$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)
  echo "[run-context refresh — live-fetched now; TRUST THIS OVER ANY REMEMBERED OR SUMMARIZED CLAIM]"
  echo "Task gid: $gid"

  if [[ -n "$tok" ]]; then
    local task
    task=$(curl -s --max-time 6 -H "Authorization: Bearer $tok" \
      "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=name,completed,custom_fields.name,custom_fields.display_value" 2>/dev/null)
    if [[ -n "$task" ]]; then
      echo "Task: $(jq -r '.data.name // "?"' <<<"$task")"
      jq -r '.data.custom_fields[]? | select(.name == "agent_status" or (.name | test("block|Board State|Force Land"; "i"))) | "  \(.name): \(.display_value // "unset")"' <<<"$task" 2>/dev/null
    fi
    # Followup watermark: comments newer than the last agent-run-report attachment.
    local wm stories nreports
    local atts
    atts=$(curl -s --max-time 6 -H "Authorization: Bearer $tok" \
      "https://app.asana.com/api/1.0/tasks/$gid/attachments?opt_fields=name,created_at" 2>/dev/null)
    wm=$(jq -r '[.data[]? | select(.name | startswith("agent-run-report"))] | sort_by(.created_at) | last | .created_at // "1970-01-01T00:00:00.000Z"' <<<"$atts")
    nreports=$(jq -r '[.data[]? | select(.name | startswith("agent-run-report"))] | length' <<<"$atts" 2>/dev/null || echo 0)
    # Description-staleness hint (one-shot description-current-state): with
    # prior completed runs, the operator prose in the description may predate
    # the delivered reality; the CURRENT STATE section, TDD, and comments
    # supersede it.
    if [[ "${nreports:-0}" -gt 0 ]]; then
      echo "DESCRIPTION STALENESS: this task has $nreports completed run report(s); treat the description's operator prose as potentially stale — its CURRENT STATE section, the TDD, and comments since the watermark supersede it. Reconcile before treating description prose as scope."
    fi
    stories=$(curl -s --max-time 6 -H "Authorization: Bearer $tok" \
      "https://app.asana.com/api/1.0/tasks/$gid/stories?opt_fields=type,created_at,text&limit=100" 2>/dev/null \
      | jq -r --arg wm "$wm" '[.data[]? | select(.type == "comment" and .created_at > $wm)] | .[-5:][] | "  [\(.created_at)] \(.text | gsub("\n"; " ") | .[0:280])"' 2>/dev/null)
    if [[ -n "$stories" ]]; then
      echo "OPERATOR COMMENTS NEWER THAN THE LAST RUN REPORT (undischarged followup scope):"
      echo "$stories"
    else
      echo "No operator comments newer than the last run-report attachment (verified live just now)."
    fi
    # Attached PRs (cap 2): live state via gh.
    curl -s --max-time 6 -H "Authorization: Bearer $tok" \
      "https://app.asana.com/api/1.0/tasks/$gid/attachments?opt_fields=view_url" 2>/dev/null \
      | jq -r '[.data[]?.view_url // empty | select(test("github.com/.*/pull/"))] | unique | .[0:2][]' 2>/dev/null \
      | while read -r pr; do
          local api; api=$(sed -E 's|https://github.com/([^/]+)/([^/]+)/pull/([0-9]+).*|repos/\1/\2/pulls/\3|' <<<"$pr")
          local info; info=$(timeout 8 gh api "$api" --jq '"state=\(.state) draft=\(.draft) mergeable=\(.mergeable_state // "?")"' 2>/dev/null || echo "unreachable")
          echo "PR $pr: $info"
        done
  fi

  local alog="$ST/attempts/$gid.jsonl"
  if [[ -f "$alog" ]]; then
    echo "Attempt-log tail (ground truth for what was actually driven):"
    tail -5 "$alog" | jq -r '"  [\(.ts // .time // "?")] \(.result // .status // "?"): \((.note // .desc // "") | .[0:160])"' 2>/dev/null || tail -5 "$alog" | cut -c1-200 | sed 's/^/  /'
  fi

  echo "Env: sim=${AGENT_SIM_UDID:-unset} metro=${AGENT_METRO_PORT:-unset} cwd=$PWD branch=$(git -C "$PWD" branch --show-current 2>/dev/null || echo n/a) dirty=$(git -C "$PWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

  local sf="/tmp/agent-state-$gid.md"
  if [[ -f "$sf" ]]; then
    echo "--- Mid-run state file ($sf) ---"
    head -c 6000 "$sf"
    echo
  else
    echo "No mid-run state file yet ($sf). Per one-shot mid-run-state-file: create it and keep it current."
  fi

  cat <<'EOF'
Contracts do NOT survive compaction: re-read the run-report template, the task's TDD, and the relevant SKILL.md sections at their point of use, never write from remembered shape. Anything above contradicting your recollection means your recollection is stale.
EOF
}

emit_anchor() {
  local name="$1"
  echo "[anchor-context refresh] You are the '$name' anchor: tmux claude-asana-$name, RC $name."
  local ledger="$HOME/.claude/projects/-Users-eddy/memory/anchor-$name-open-threads.md"
  if [[ -f "$ledger" ]]; then
    echo "--- Open-threads ledger ($ledger) ---"
    head -c 6000 "$ledger"
    echo
  fi
  echo "Treat summarized/remembered session claims as stale; the ledger, MEMORY.md, and live fetches are the truth."
}

if [[ -n "${AGENT_TASK_GID:-}" ]]; then
  emit_run "$AGENT_TASK_GID" 2>/dev/null
elif [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]]; then
  NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
  SHORT="${NAME#claude-asana-}"
  if [[ "$NAME" == claude-asana-* ]] && jq -e --arg n "$SHORT" '.watcher.persistent_anchors | index($n) != null' "$DIR/asana-config.json" >/dev/null 2>&1; then
    emit_anchor "$SHORT" 2>/dev/null
  fi
fi
exit 0
