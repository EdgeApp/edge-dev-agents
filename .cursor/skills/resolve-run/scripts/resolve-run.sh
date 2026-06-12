#!/usr/bin/env bash
# resolve-run.sh — resolve orchestrated agent run(s) into a compact JSON evidence manifest.
#
# Modes:
#   --since <ISO-date>   discover runs spawned at/after date (watcher log + worktrees), resolve each
#   --gid <task-gid>     resolve a single run
#   --list               with --since: print gid + name + spawned_at only (no deep resolution)
#
# Output: JSON array of manifests on stdout (the ONLY stdout). Diagnostics on stderr.
# Exit: 0 = ok (possibly empty array), 1 = error, 2 = usage.
#
# Read-only: never mutates Asana, tmux, slots, pool, or worktrees.
# Never prints credential VALUES; reads token only to query Asana.

set -euo pipefail

WATCHER_LOG="/tmp/asana-watcher.out"
WATCHDOG_LOG="/tmp/session-watchdog.out"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"
PROJECTS_DIR="$HOME/.claude/projects"
CONFIG="$HOME/.config/agent-watcher/asana-config.json"
CRED="$HOME/.config/agent-watcher/credentials.json"

GID="" SINCE="" LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *) echo "usage: resolve-run.sh (--gid <gid> | --since <ISO-date>) [--list]" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] || [ -n "$SINCE" ] || { echo "usage: resolve-run.sh (--gid <gid> | --since <ISO-date>) [--list]" >&2; exit 2; }

command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }

# ---- discovery: gid<TAB>name<TAB>spawned_at from watcher log, plus worktree-dir fallback ----
discover() {
  local since="$1"
  {
    if [ -r "$WATCHER_LOG" ]; then
      # [2026-06-10T00:43:37.043Z] Spawning slot for: NAME (gid=GID, cwd=...)
      sed -n 's/^\[\([^]]*\)\] Spawning slot for: \(.*\) (gid=\([0-9]*\),.*$/\3\t\2\t\1/p' "$WATCHER_LOG" |
        awk -F'\t' -v s="$since" '$3 >= s'
    fi
    # worktree dirs whose mtime is in range (covers runs missing from a rotated log)
    if [ -d "$WORKTREES_ROOT" ]; then
      local cutoff_epoch; cutoff_epoch=$(node -e "process.stdout.write(String(Math.floor(new Date(process.argv[1]).getTime()/1000)))" "$since" 2>/dev/null || echo 0)
      for d in "$WORKTREES_ROOT"/*/; do
        local g; g=$(basename "$d")
        case "$g" in (*[!0-9]*) continue ;; esac
        local m; m=$(stat -f %m "$d" 2>/dev/null || echo 0)
        if [ "$m" -ge "$cutoff_epoch" ]; then printf '%s\t%s\t%s\n' "$g" "" ""; fi
      done
    fi
  } | sort -t$'\t' -k1,1 -u -s | awk -F'\t' '!seen[$1]++'
}

# ---- per-gid resolution ----
asana_fetch() { # $1=gid → JSON {name,status,blocked} (or status=__MISSING__ / __NO_AUTH__)
  local gid="$1" token
  token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)}"
  [ -n "$token" ] || { echo '{"name":null,"status":"__NO_AUTH__","blocked":null}'; return 0; }
  local resp; resp=$(curl -sf --max-time 20 "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=name,custom_fields.name,custom_fields.gid,custom_fields.display_value" \
    -H "Authorization: Bearer $token" 2>/dev/null) || { echo '{"name":null,"status":"__MISSING__","blocked":null}'; return 0; }
  local ag_gid bl_gid
  ag_gid=$(jq -r '.custom_fields.agent_status.field_gid // .custom_fields.agent_status.gid // empty' "$CONFIG" 2>/dev/null)
  bl_gid=$(jq -r '.custom_fields.blocked.field_gid // .custom_fields.blocked.gid // empty' "$CONFIG" 2>/dev/null)
  echo "$resp" | jq -c --arg ag "$ag_gid" --arg bl "$bl_gid" '{
    name: .data.name,
    status: (first(.data.custom_fields[]? | select((.gid == $ag) or ((.name // "") | ascii_downcase | test("agent.?status"))) | .display_value) // null),
    blocked: (first(.data.custom_fields[]? | select((.gid == $bl) or ((.name // "") | ascii_downcase == "blocked")) | .display_value) // null)
  }'
}

find_transcript() { # $1=gid → newest jsonl whose FIRST asana URL gid equals the target
  # (mirrors resume-task.sh semantics: a later MENTION of the gid in another session
  #  must not match — six runs once resolved to one shared interactive transcript)
  local gid="$1" best="" best_m=0 f m first_url
  for f in "$PROJECTS_DIR"/*"$gid"*/*.jsonl "$PROJECTS_DIR"/*git*/*.jsonl; do
    [ -r "$f" ] || continue
    first_url=$(head -c 16384 "$f" | grep -oE 'app\.asana\.com[A-Za-z0-9/._-]*' | head -1 || true)
    [ -n "$first_url" ] || continue
    # the task gid is the LAST long numeric segment of the URL (handles /0/<proj>/<task> and /f suffix)
    echo "$first_url" | grep -oE '[0-9]{12,}' | tail -1 | grep -qx "$gid" || continue
    m=$(stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ]; then best="$f"; best_m=$m; fi
  done
  echo "$best"
}

resolve_one() { # $1=gid $2=name-hint $3=spawned-hint → one manifest JSON on stdout
  local gid="$1" name_hint="$2" spawned="$3"

  local session_state="gone" tmux_session=""
  if tmux has-session -t "claude-asana-$gid" 2>/dev/null; then session_state="live"; tmux_session="claude-asana-$gid"
  elif tmux has-session -t "done-asana-$gid" 2>/dev/null; then session_state="retired"; tmux_session="done-asana-$gid"; fi

  local worktree="" repo="" branch=""
  if [ -d "$WORKTREES_ROOT/$gid" ]; then
    worktree=$(find "$WORKTREES_ROOT/$gid" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    [ -n "$worktree" ] && repo=$(basename "$worktree") && branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  local transcript; transcript=$(find_transcript "$gid")
  local win_start="" win_end="" prs="[]" revive_pings=0 operator_msgs=0
  if [ -n "$transcript" ]; then
    # first/last lines are often timestamp-less meta records (mode, bridge-session);
    # take the first and last lines that carry a timestamp
    win_start=$(grep -m1 -o '"timestamp":"[^"]*"' "$transcript" 2>/dev/null | cut -d'"' -f4 || true)
    win_end=$(tail -300 "$transcript" | grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)
    prs=$(grep -oE 'https://github\.com/[A-Za-z0-9._/-]+/pull/[0-9]+' "$transcript" 2>/dev/null | grep -viE 'github\.com/(owner/repo|org/repo|example)' | sort -u | head -5 | jq -R . | jq -cs . || true)
    [ -n "$prs" ] || prs="[]"
    # actual watchdog pings arrive as a user message whose content STARTS with the marker;
    # the marker also appears mid-sentence in one-shot SKILL.md rule text read into the
    # transcript — that must not count, so anchor on the JSON key boundary
    revive_pings=$(grep -cE '"(content|text)":"<watchdog-revive-ping>' "$transcript" 2>/dev/null || true)
    revive_pings=${revive_pings:-0}
    # mid-run human nudges: operator messages are prefixed "Operator:" by convention
    # (same JSON key anchoring as above)
    operator_msgs=$(grep -cE '"(content|text)":"Operator:' "$transcript" 2>/dev/null || true)
    operator_msgs=${operator_msgs:-0}
  fi

  local asana; asana=$(asana_fetch "$gid" || true)
  [ -n "$asana" ] || asana='{"name":null,"status":null,"blocked":null}'

  local slot
  slot=$(node "$HOME/.config/agent-watcher/lib/slots.js" get --task-gid "$gid" 2>/dev/null | jq -c . 2>/dev/null || true)
  [ -n "$slot" ] || slot="null"
  local pool_entry="null"
  if [ -r "$STATE_DIR/pool.json" ]; then
    pool_entry=$(jq -c --arg g "$gid" '[.[] | select(.task_gid == $g)] | first // null' "$STATE_DIR/pool.json" 2>/dev/null || true)
    [ -n "$pool_entry" ] || pool_entry="null"
  fi

  local watchdog_mentions=0
  if [ -r "$WATCHDOG_LOG" ]; then
    watchdog_mentions=$(grep -c "$gid" "$WATCHDOG_LOG" 2>/dev/null || true)
    watchdog_mentions=${watchdog_mentions:-0}
  fi
  local forensics="[]"
  if [ -d "$STATE_DIR/forensics" ]; then
    forensics=$(find "$STATE_DIR/forensics" -type f -name "*.txt" 2>/dev/null | head -5 | jq -R . | jq -cs . || true)
    [ -n "$forensics" ] || forensics="[]"
  fi

  local run_report=""
  run_report=$(find "$WORKTREES_ROOT/$gid" /tmp -maxdepth 3 \( -iname "*run-report*" -o -iname "*report*$gid*" \) -type f 2>/dev/null | head -1 || true)
  [ -z "$run_report" ] && run_report="asana-attachment"

  # durable release receipt written by the watchdog at retirement (O1/O6 evidence)
  local release_receipt="null"
  if [ -r "$STATE_DIR/releases/$gid.json" ]; then
    release_receipt=$(jq -c . "$STATE_DIR/releases/$gid.json" 2>/dev/null || true)
    [ -n "$release_receipt" ] || release_receipt="null"
  fi

  jq -cn \
    --arg gid "$gid" --arg name_hint "$name_hint" --arg spawned "$spawned" \
    --arg session_state "$session_state" --arg tmux_session "$tmux_session" \
    --arg transcript "$transcript" --arg ws "$win_start" --arg we "$win_end" \
    --arg worktree "$worktree" --arg repo "$repo" --arg branch "$branch" \
    --argjson prs "$prs" --argjson asana "$asana" --argjson slot "$slot" --argjson pool "$pool_entry" \
    --arg run_report "$run_report" --argjson revive "$revive_pings" --argjson operator "$operator_msgs" --argjson wd "$watchdog_mentions" \
    --argjson release_receipt "$release_receipt" \
    --argjson forensics "$forensics" --arg state_dir "$STATE_DIR" --arg watchdog_log "$WATCHDOG_LOG" --arg watcher_log "$WATCHER_LOG" \
    '{
      gid: $gid,
      task_name: ($asana.name // (if $name_hint == "" then null else $name_hint end)),
      spawned_at: (if $spawned == "" then null else $spawned end),
      asana: { status: $asana.status, blocked: $asana.blocked },
      in_flight: (($asana.status != null) and ($asana.status != "Complete") and ($session_state == "live")),
      session: { state: $session_state, tmux: (if $tmux_session == "" then null else $tmux_session end) },
      transcript: (if $transcript == "" then null else $transcript end),
      window: { start: (if $ws == "" then null else $ws end), end: (if $we == "" then null else $we end) },
      worktree: (if $worktree == "" then null else $worktree end),
      repo: (if $repo == "" then null else $repo end),
      branch: (if $branch == "" then null else $branch end),
      prs: $prs,
      slot: $slot,
      pool_entry: $pool,
      run_report: $run_report,
      release_receipt: $release_receipt,
      signals: { revive_pings_in_transcript: $revive, operator_messages: $operator, watchdog_log_mentions: $wd, forensics_files: $forensics },
      logs: { watcher: $watcher_log, watchdog: $watchdog_log,
              runaway_guard: ($state_dir + "/runaway-guard.log"),
              memory_monitor: "/tmp/memory-monitor.log",
              mem_trace_dir: ($state_dir + "/oom-repro/logs"),
              forensics_dir: ($state_dir + "/forensics") }
    }'
}

# ---- main ----
if [ -n "$GID" ]; then
  resolve_one "$GID" "" "" | jq -cs .
  exit 0
fi

rows=$(discover "$SINCE")
if [ "$LIST" -eq 1 ]; then
  echo "$rows" | jq -Rn '[inputs | select(length > 0) | split("\t") | {gid: .[0], name: (.[1] // ""), spawned_at: (.[2] // "")}]'
  exit 0
fi

out="["; first=1
while IFS=$'\t' read -r g n s; do
  [ -n "$g" ] || continue
  echo "resolving $g (${n:-?})" >&2
  m=$(resolve_one "$g" "$n" "$s") || { echo "WARN: failed to resolve $g" >&2; continue; }
  [ $first -eq 1 ] && first=0 || out="$out,"
  out="$out$m"
done <<< "$rows"
out="$out]"
echo "$out" | jq -c .
