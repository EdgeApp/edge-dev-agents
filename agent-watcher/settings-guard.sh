#!/usr/bin/env bash
# settings-guard.sh — keep ~/.claude/settings.json's pinned keys equal to
# ~/.claude/settings.canonical.json, and restart sessions that started before
# the canonical file last changed.
#
# WHY: a claude process rewrites the WHOLE settings.json from its in-memory copy
# when a command such as /fast or /model saves a setting. A process that has
# been up for weeks writes back the hooks it loaded at startup, silently
# dropping every registration added since. Restarting sessions is not enough on
# its own (a restart loads whatever the file holds, clobbered or not), so the
# file is guarded, and stale sessions are restarted so their next settings
# write carries current content.
#
# Pinned keys = the top-level keys present in the canonical file (today: hooks,
# env, attribution). The canonical file is the source of truth for them; every
# other key (model, fastMode, effortLevel, modelSettings, theme, plugins,
# notification toggles) belongs to the CLI and passes through untouched. To pin
# another key, add it to the canonical file. Intentional edits to pinned keys go
# to the canonical file; redirect-settings-writes.sh blocks agent writes to
# settings.json that touch them, and this script reverts any that get through.
#
# Each run (launchd: WatchPaths on both files + StartInterval backstop):
#   1. Merge: settings.json with every pinned key replaced by its canonical
#      value. Skip the pass when either file is not valid JSON (mid-write).
#   2. If that differs from settings.json, write it (temp + mv) and log what was
#      restored: hook registrations by command, other pinned keys by name.
#   3. When the canonical content hash changed since the last run, record the
#      change time. Every live interactive session in a tmux pane that started
#      before it is restarted with restart-session-in-place.sh (idle-gated,
#      resumes the same conversation and tells it to continue its work), at most
#      RESTART_CAP in flight at once; a failed restart is logged once.
#      Orchestrated task sessions (tmux name claude-asana-<gid> /
#      done-asana-<gid>) are skipped: the watchdog owns them.
#
# Env overrides (tests): SG_SETTINGS, SG_CANON, SG_STATE_DIR, SG_SESSIONS_DIR,
# SG_RESTART_CMD (default restart-session-in-place.sh), SG_NO_TMUX=1 (run the
# restart command directly instead of via tmux run-shell -b), SG_RESTART_CAP.
# Exit: 0 always unless a file is unreadable in a way that needs attention (1).
set -uo pipefail

SETTINGS="${SG_SETTINGS:-$HOME/.claude/settings.json}"
CANON="${SG_CANON:-$HOME/.claude/settings.canonical.json}"
STATE_DIR="${SG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher}"
SESSIONS_DIR="${SG_SESSIONS_DIR:-$HOME/.claude/sessions}"
RESTART_CMD="${SG_RESTART_CMD:-$HOME/.config/agent-watcher/restart-session-in-place.sh}"
RESTART_CAP="${SG_RESTART_CAP:-2}"
STATE="$STATE_DIR/settings-guard.json"
LOG="$STATE_DIR/settings-guard.log"
mkdir -p "$STATE_DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

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

# ── 3. Restart sessions older than the last canonical change ─────────────────
hash=$(jq -S -c . "$CANON" | shasum -a 256 | cut -c1-16)
now_ms=$(( $(date +%s) * 1000 ))
[[ -f "$STATE" ]] || printf '{"hash":"%s","changedAt":%s,"requested":{}}\n' "$hash" "$now_ms" > "$STATE"
old_hash=$(jq -r '.hash // ""' "$STATE")
if [[ "$hash" != "$old_hash" ]]; then
  jq --arg h "$hash" --argjson t "$now_ms" '.hash = $h | .changedAt = $t | .requested = {} | .reported = {}' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  log "CANONICAL changed (hash $hash); sessions started before now will be restarted"
fi
changed_at=$(jq -r '.changedAt' "$STATE")

# Restarts still in flight (log has no OK:/FAIL: yet) count against the cap, so
# a burst of passes (every save under ~/.claude retriggers this job) cannot
# restart every session at once. A finished FAIL is logged here once.
inflight=0
for p in $(jq -r '.requested | keys[]' "$STATE" 2>/dev/null); do
  rlog="/tmp/restart-session-$p.log"
  if grep -q 'FAIL: session stayed busy' "$rlog" 2>/dev/null; then
    # Nothing was killed; forget the request so a later pass tries again.
    log "RESTART deferred pid=$p: session stayed busy; will retry"
    jq --arg p "$p" 'del(.requested[$p])' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    rm -f "$rlog"
  elif grep -q 'FAIL:' "$rlog" 2>/dev/null; then
    if ! jq -e --arg p "$p" '.reported[$p] != null' "$STATE" >/dev/null 2>&1; then
      log "RESTART FAILED pid=$p: $(grep 'FAIL:' "$rlog" | tail -1 | cut -c1-200)"
      jq --arg p "$p" '.reported[$p] = true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
  elif [[ -n "$(find "$rlog" -mmin -16 2>/dev/null)" ]] && ! grep -q 'OK:' "$rlog"; then
    # Only a log written in the last 16 min counts (the restart script gives up
    # after 15 min busy + 90 s); a job that never started cannot block the cap.
    inflight=$((inflight + 1))
  fi
done

launched=$inflight
for rec in "$SESSIONS_DIR"/*.json; do
  [[ -f "$rec" ]] || continue
  (( launched >= RESTART_CAP )) && break
  row=$(jq -r 'select(.kind == "interactive" and (.tmux // "") != "") | [.pid, .startedAt, .tmux, (.sessionId // "")] | @tsv' "$rec" 2>/dev/null) || continue
  [[ -n "$row" ]] || continue
  IFS=$'\t' read -r pid started tmuxref sid <<< "$row"
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  (( started < changed_at )) || continue
  kill -0 "$pid" 2>/dev/null || continue
  tname="${tmuxref%%:*}"
  [[ "$tname" =~ ^(claude|done)-asana-[0-9]+$ ]] && continue
  jq -e --arg p "$pid" '.requested[$p] != null' "$STATE" >/dev/null 2>&1 && continue
  rm -f "/tmp/restart-session-$pid.log"   # a reused pid's old OK: must not read as done
  note="settings-guard restarted this session because pinned settings (hooks/env) changed after it started; it now runs the current hooks"
  if [[ "${SG_NO_TMUX:-0}" == 1 ]]; then
    "$RESTART_CMD" --pid "$pid" --note "$note" >/dev/null 2>&1 &
  else
    tmux run-shell -b "$(printf '%q' "$RESTART_CMD") --pid $pid --note $(printf '%q' "$note")" 2>/dev/null \
      || { log "RESTART pid=$pid ($tname): tmux run-shell failed"; continue; }
  fi
  jq --arg p "$pid" --argjson t "$now_ms" '.requested[$p] = $t' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  log "RESTART requested pid=$pid ($tname, session ${sid:0:8}); log /tmp/restart-session-$pid.log"
  launched=$((launched + 1))
done
exit 0
