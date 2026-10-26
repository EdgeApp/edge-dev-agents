# lib.sh: shared helpers for the qa-run scripts. Source it; it defines variables
# and functions only.
#
# State lives in QA_DIR=$XDG_STATE_HOME/agent-watcher/qa/<gid>/ (one QA pass):
#   snapshot.json  worktree snapshot taken at the first qa-start (HEAD, porcelain,
#                  dep links, app config hashes); qa-verdict.sh refuses a verdict
#                  until the tree matches it again
#   pinned.json    {repo_dir, sha, pr_url} recorded at the first qa-start
#   plan.md        the plan the qa-plan gate approved (copied by qa-gate.sh)
#   approved       written by qa-gate.sh on a cases plan; holds the lane. qa-start.sh
#                  returns PHASE=run once it exists, in the same session
#   run-started    written by qa-start.sh at the first PHASE=run (the attempt-log
#                  window the verdict judge reads starts here)
#   verdict.json   written by qa-verdict.sh after the verdict posts
#   respawns       watcher respawn counter
# Outside the pass dir (survives a fresh pass):
#   qa/ledger-<gid>.jsonl  one line per posted verdict; Failed lines count toward
#                          the auto re-arm cap (watcher.qa_rearm_cap)

QA_H="$HOME/.config/agent-watcher"
QA_CFG="$QA_H/asana-config.json"
QA_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/qa"
QA_SCRIPTS="$HOME/.cursor/skills/qa-run/scripts"

qa_dir() { printf '%s/%s\n' "$QA_ROOT" "$1"; }
qa_plan_file() { printf '/tmp/qa-plan-%s.md\n' "$1"; }
qa_ledger() { printf '%s/ledger-%s.jsonl\n' "$QA_ROOT" "$1"; }

qa_token() {
  printf '%s' "${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$QA_H/credentials.json")}"
}

# qa_asana_get <path>: GET https://app.asana.com/api/1.0/<path>, body on stdout.
qa_asana_get() {
  curl -sf --max-time 30 -H "Authorization: Bearer $(qa_token)" "https://app.asana.com/api/1.0/$1"
}

# qa_field <task-json> <field-name>: the enum option name of an agent_* field, or empty.
qa_field() {
  local fgid
  fgid=$(jq -r --arg f "$2" '.custom_fields[$f].gid // empty' "$QA_CFG")
  [ -n "$fgid" ] || return 0
  printf '%s' "$1" | jq -r --arg g "$fgid" '.data.custom_fields[]? | select(.gid==$g) | (.enum_value.name // empty)'
}

# qa_task_json <gid>: name, notes, custom fields, permalink.
qa_task_json() {
  qa_asana_get "tasks/$1?opt_fields=name,notes,permalink_url,custom_fields.gid,custom_fields.enum_value.name,custom_fields.multi_enum_values.name"
}

# qa_lanes <task-json>: the agent_lane option names, comma-joined (empty when unset).
qa_lanes() {
  local fgid
  fgid=$(jq -r '.custom_fields.agent_lane.gid // empty' "$QA_CFG")
  [ -n "$fgid" ] || return 0
  printf '%s' "$1" | jq -r --arg g "$fgid" '[.data.custom_fields[]? | select(.gid==$g) | .multi_enum_values[]?.name] | join(",")'
}

# qa_attachments <gid>: one "<gid>\t<name>\t<created_at>" line per attachment.
qa_attachments() {
  qa_asana_get "tasks/$1/attachments?opt_fields=name,created_at&limit=100" \
    | jq -r '.data[]? | [.gid, .name, .created_at] | @tsv'
}

# qa_repo_dir <gid>: the dev worktree repo dir QA tests: the first repo whose branch
# has a pull request (edge-react-gui checked first), else the first repo dir with a
# .git (edge-react-gui first), or nothing. A task whose only PR is in another repo
# (a server or plugin fix) has an untouched edge-react-gui worktree beside it.
# lib/qa-queue.js devRepoDir makes the same pick for the session cwd.
qa_repo_dir() {
  local root="$HOME/git/.agent-worktrees/$1" d dirs=()
  [ -d "$root" ] || return 0
  [ -e "$root/edge-react-gui/.git" ] && dirs+=("$root/edge-react-gui")
  for d in "$root"/*/; do
    d="${d%/}"; [ "$d" = "$root/edge-react-gui" ] && continue
    [ -e "$d/.git" ] && dirs+=("$d")
  done
  [ ${#dirs[@]} -gt 0 ] || return 0
  for d in "${dirs[@]}"; do
    (cd "$d" && gh pr view --json url -q .url >/dev/null 2>&1) && { printf '%s\n' "$d"; return 0; }
  done
  printf '%s\n' "${dirs[0]}"
}

# qa_snapshot <repo-dir>: JSON of the tree state the verdict must match.
qa_snapshot() {
  (
    cd "$1" || exit 1
    head=$(git rev-parse HEAD 2>/dev/null)
    porc=$(git status --porcelain --untracked-files=no 2>/dev/null | shasum -a 256 | cut -c1-16)
    # Dependency link state: every symlinked package under node_modules and its target.
    links=$(find node_modules -maxdepth 2 -type l 2>/dev/null | sort | while read -r f; do printf '%s -> %s\n' "$f" "$(readlink "$f")"; done | shasum -a 256 | cut -c1-16)
    cfg=""
    for f in config.json env.json keys.json; do
      if [ -f "$f" ]; then cfg="$cfg $f:$(shasum -a 256 "$f" | cut -c1-16)"; else cfg="$cfg $f:none"; fi
    done
    jq -cn --arg head "$head" --arg porc "$porc" --arg links "$links" --arg cfg "${cfg# }" \
      '{head:$head, porcelain:$porc, dep_links:$links, configs:$cfg}'
  )
}

# qa_snapshot_diff <saved.json> <repo-dir>: prints the differing keys; empty = match.
qa_snapshot_diff() {
  local now
  now=$(qa_snapshot "$2") || { echo "snapshot-unreadable"; return 0; }
  jq -rn --argjson a "$(cat "$1")" --argjson b "$now" \
    '[$a|keys[]|select($a[.] != $b[.])]|join(" ")'
}

# qa_failed_count <gid>: Failed verdicts already posted on this task.
qa_failed_count() {
  local l
  l=$(qa_ledger "$1")
  [ -f "$l" ] || { echo 0; return 0; }
  grep -c '"verdict":"Failed"' "$l" || true
}

qa_rearm_cap() { jq -r '.watcher.qa_rearm_cap // 2' "$QA_CFG"; }

# qa_kill_self_later <gid> [<seconds>]: kill this QA session after a delay, detached,
# so the current turn can finish printing. A QA session is never retired.
qa_kill_self_later() {
  nohup bash -c "sleep ${2:-45}; tmux kill-session -t qa-asana-$1 2>/dev/null" >/dev/null 2>&1 &
}
