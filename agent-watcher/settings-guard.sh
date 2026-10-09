#!/usr/bin/env bash
# settings-guard.sh — keep ~/.claude/settings.json's pinned keys equal to
# ~/.claude/settings.canonical.json, and report which sessions started before
# the canonical file last changed.
#
# WHY: a claude process rewrites the WHOLE settings.json from its in-memory copy
# when a command such as /fast or /model saves a setting. A process that has
# been up for weeks writes back the hooks it loaded at startup, silently
# dropping every registration added since. This job puts the pinned keys back.
#
# Pinned keys = the top-level keys present in the canonical file. The canonical
# file is the source of truth for them; every other key (model, fastMode,
# effortLevel, modelSettings, theme, plugins, notification toggles) belongs to
# the CLI and passes through untouched. To pin another key, add it to the
# canonical file. Intentional edits to pinned keys go to the canonical file;
# redirect-settings-writes.sh blocks agent writes to settings.json that touch
# them, and this script reverts any that get through.
#
# A canonical edit reaches every session started after it. It restarts NOTHING:
# a session that started earlier keeps what it loaded, and
# hooks/settings-stale-notice.sh tells the operator in that session, once per
# change, what it is missing and how to restart it.
#
# Default run (launchd: WatchPaths on both files + StartInterval backstop):
#   1. Merge: settings.json with every pinned key replaced by its canonical
#      value. Skip the pass when either file is not valid JSON (mid-write).
#   2. If that differs from settings.json, write it (temp + mv) and log what was
#      restored: hook registrations by command, other pinned keys by name.
#   3. When the canonical content hash changed since the last run, record the
#      change time and save a snapshot under <state>/settings-history/<ms>.json
#      (the baseline `--behind` diffs a session against).
#
# Subcommands (no writes to settings):
#   --status              one line per live interactive session that started
#                         before the last canonical change: tmux name or
#                         "desktop", pid, what it is missing.
#   --behind <session-id> prints "<pid>\t<tmux, or - for none>\t<hash>\t<summary>" when that
#                         session started before the last canonical change;
#                         prints nothing when it is current. Exit 0 either way.
#   --restart <tmux-name|pid>  restart one session in place
#                         (restart-session-in-place.sh; tmux sessions only).
#
# Env overrides (tests): SG_SETTINGS, SG_CANON, SG_STATE_DIR, SG_SESSIONS_DIR,
# SG_RESTART_CMD, SG_NO_TMUX=1 (run the restart command directly).
# Exit: 0; 1 on a bad subcommand argument or a failed --restart.
set -uo pipefail

SETTINGS="${SG_SETTINGS:-$HOME/.claude/settings.json}"
CANON="${SG_CANON:-$HOME/.claude/settings.canonical.json}"
STATE_DIR="${SG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher}"
SESSIONS_DIR="${SG_SESSIONS_DIR:-$HOME/.claude/sessions}"
RESTART_CMD="${SG_RESTART_CMD:-$HOME/.config/agent-watcher/restart-session-in-place.sh}"
STATE="$STATE_DIR/settings-guard.json"
LOG="$STATE_DIR/settings-guard.log"
mkdir -p "$STATE_DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
HIST="$STATE_DIR/settings-history"

# What a session that started at <ms> is missing: canonical now vs the newest
# snapshot at or before its start (the oldest snapshot when none is that old,
# so the answer is then a lower bound).
behind_summary() {
  local started="$1" base="" f
  for f in $(ls -1 "$HIST" 2>/dev/null | sort -n); do
    if (( ${f%.json} <= started )); then base="$HIST/$f"; fi
  done
  [[ -n "$base" ]] || base="$HIST/$(ls -1 "$HIST" 2>/dev/null | sort -n | head -1)"
  [[ -f "$base" ]] || { echo "settings changed since it started"; return; }
  jq -rn --slurpfile o "$base" --slurpfile n "$CANON" '
    def cmds($h): [($h // {}) | to_entries[] | .key as $e | .value[]? | .hooks[]? | "\($e) \(.command | split("/") | last)"] | unique;
    (cmds($n[0].hooks) - cmds($o[0].hooks)) as $add | (cmds($o[0].hooks) - cmds($n[0].hooks)) as $del
    | ([ ($n[0] + $o[0]) | keys[] | select(. != "hooks") | select($n[0][.] != $o[0][.]) ]) as $keys
    | [ (if ($add|length) > 0 then "hooks added: " + ($add|join(", ")) else empty end),
        (if ($del|length) > 0 then "hooks removed: " + ($del|join(", ")) else empty end),
        (if ($keys|length) > 0 then "changed: " + ($keys|join(", ")) else empty end) ]
    | if length == 0 then "hook order or options changed" else join("; ") end'
}

# Live interactive sessions that started before the last canonical change, as
# "<pid>\t<tmux-session, or - for none>\t<sessionId>\t<startedAt>" (a bare tab
# pair would collapse under `read`). Orchestrated task
# sessions are left out: a run keeps what it loaded at spawn.
behind_sessions() {
  local changed_at rec row pid started tmuxref sid tname
  changed_at=$(jq -r '.changedAt // 0' "$STATE" 2>/dev/null || echo 0)
  for rec in "$SESSIONS_DIR"/*.json; do
    [[ -f "$rec" ]] || continue
    row=$(jq -r 'select(.kind == "interactive") | [.pid, .startedAt, ((.tmux // "") | if . == "" then "-" else . end), (.sessionId // "-")] | @tsv' "$rec" 2>/dev/null) || continue
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r pid started tmuxref sid <<< "$row"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    (( started < changed_at )) || continue
    kill -0 "$pid" 2>/dev/null || continue
    tname="${tmuxref%%:*}"
    [[ "$tname" =~ ^(claude|done)-asana-[0-9]+$ ]] && continue
    printf '%s\t%s\t%s\t%s\n' "$pid" "$tname" "$sid" "$started"
  done
}

case "${1:-}" in
  --status)
    behind_sessions | while IFS=$'\t' read -r pid tname sid started; do
      [[ "$tname" == "-" ]] && tname="desktop"
      printf '%s\tpid %s\t%s\n' "$tname" "$pid" "$(behind_summary "$started")"
    done
    exit 0 ;;
  --behind)
    [[ -n "${2:-}" ]] || { echo "--behind <session-id>" >&2; exit 1; }
    behind_sessions | while IFS=$'\t' read -r pid tname sid started; do
      [[ "$sid" == "$2" ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$pid" "$tname" "$(jq -r '.hash' "$STATE")" "$(behind_summary "$started")"
    done
    exit 0 ;;
  --restart)
    [[ -n "${2:-}" ]] || { echo "--restart <tmux-name|pid>" >&2; exit 1; }
    target=$(behind_sessions | awk -F'\t' -v t="$2" '$1 == t || $2 == t || $2 == "claude-asana-" t {print $1; exit}')
    [[ -n "$target" ]] || { echo "no behind session matches '$2' (see --status)" >&2; exit 1; }
    note="restarted on request to load the current settings"
    rm -f "/tmp/restart-session-$target.log"
    if [[ "${SG_NO_TMUX:-0}" == 1 ]]; then "$RESTART_CMD" --pid "$target" --note "$note"
    else tmux run-shell -b "$(printf '%q' "$RESTART_CMD") --pid $target --note $(printf '%q' "$note")" || { echo "tmux run-shell failed" >&2; exit 1; }
    fi
    log "RESTART requested by hand pid=$target ($2)"
    echo "restart requested for pid $target; log /tmp/restart-session-$target.log"
    exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 1 ;;
esac


[[ -f "$CANON" ]] || exit 0
jq -e 'type == "object"' "$CANON" >/dev/null 2>&1 || { log "SKIP: canonical file is not a JSON object"; exit 0; }

# ── 1-2. Re-apply pinned keys ────────────────────────────────────────────────
if [[ -f "$SETTINGS" ]]; then
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || { log "SKIP: settings.json is not valid JSON (mid-write?)"; exit 0; }
  merged=$(jq -S --slurpfile c "$CANON" '. as $s | reduce ($c[0] | keys[]) as $k ($s; .[$k] = $c[0][$k])' "$SETTINGS")
else
  merged=$(jq -S . "$CANON")
fi
current=$(jq -S . "$SETTINGS" 2>/dev/null || echo '{}')
if [[ "$merged" != "$current" ]]; then
  # What the write restores, for the log: hook commands present in canonical but
  # missing from settings.json, plus any other pinned key whose value differs.
  report=$(jq -rn --argjson s "$current" --slurpfile c "$CANON" '
    def cmds($h): [($h // {}) | to_entries[] | .key as $e | .value[]? | .hooks[]? | "\($e) \(.command)"];
    (cmds($c[0].hooks) - cmds($s.hooks)) as $missing
    | (cmds($s.hooks) - cmds($c[0].hooks)) as $extra
    | ([$c[0] | keys[] | select(. != "hooks") | select($c[0][.] != $s[.])]) as $keys
    | ([("restored " + ($missing|length|tostring) + " hook registration(s)")] + ($missing | map("  + " + .))
       + (if ($extra|length) > 0 then [("removed " + ($extra|length|tostring) + " unpinned hook registration(s)")] + ($extra | map("  - " + .)) else [] end)
       + (if ($keys|length) > 0 then ["reset pinned key(s): " + ($keys|join(", "))] else [] end)
       + (if ($missing|length) == 0 and ($extra|length) == 0 and ($keys|length) == 0 then ["re-applied pinned hooks (order or fields differed)"] else [] end))
    | .[]')
  tmp="$SETTINGS.guard.$$"
  printf '%s\n' "$merged" > "$tmp" && mv "$tmp" "$SETTINGS"
  log "RESTORE settings.json from canonical:"
  printf '%s\n' "$report" | while IFS= read -r line; do log "  $line"; done
fi

# ── 3. Record a canonical change and keep its snapshot ───────────────────────
hash=$(jq -S -c . "$CANON" | shasum -a 256 | cut -c1-16)
now_ms=$(( $(date +%s) * 1000 ))
mkdir -p "$HIST"
[[ -f "$STATE" ]] || printf '{"hash":"","changedAt":0}\n' > "$STATE"
old_hash=$(jq -r '.hash // ""' "$STATE")
if [[ "$hash" != "$old_hash" ]]; then
  jq -S . "$CANON" > "$HIST/$now_ms.json"
  jq -n --arg h "$hash" --argjson t "$now_ms" '{hash: $h, changedAt: $t}' > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  log "CANONICAL changed (hash $hash); sessions started before now are behind until restarted"
  # Keep the 40 newest snapshots.
  ls -1 "$HIST" | sort -rn | tail -n +41 | while read -r f; do rm -f "$HIST/$f"; done
elif [[ -z "$(ls -1 "$HIST" 2>/dev/null)" ]]; then
  # First run with history: the current canonical is the baseline for the
  # change time already on record.
  jq -S . "$CANON" > "$HIST/$(jq -r '.changedAt // 0' "$STATE").json"
fi
exit 0
