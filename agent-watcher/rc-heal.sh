#!/usr/bin/env bash
# rc-heal.sh — pinned-anchor RC healing, and NOTHING else.
#
# WHAT THIS IS: the healing slice of the orch's session-watchdog.js, lifted out so a
# machine can host a pinned (remote-control) anchor session without running the Asana
# control plane. No task pickup, no Asana reads/writes, no slots/sims/Metro, no
# worktree GC, no idle reaping. It tends the anchors in rc-heal.json and touches
# nothing else on the box.
#
# WHY IT EXISTS (2026-08-29): eddy (the orch host) is down; jontz needs one pinned
# session that stays reachable from the phone. The full watchdog would be wrong here —
# its non-healing sweeps (retire, prune worktrees, reap Metros/sims, restart fseventsd)
# assume the watcher's resources exist.
#
# THREE FAILURE MODES, one remedy each (mirrors session-watchdog.js):
#   1. tmux session gone (reboot, killed server)  -> recreate + start claude.
#   2. session alive, claude dead in the pane     -> revive in place (session-tui's `i`).
#   3. claude alive, RC bridge DEAD + pane idle   -> kill+respawn (watchdog Variant 1:
#      the /remote-control slash command no longer exists, so only a fresh process
#      re-arms the bridge). An RC indicator that is UP is never touched — a half-open
#      bridge is the operator's to reconnect on next attach.
#
# TRANSCRIPT IDENTITY: the anchor's session id is MINTED here and passed as
# --session-id on first spawn, then --resume <id> forever after. The watchdog scrapes
# `--resume` out of argv and falls back to newest-jsonl-by-mtime; that fallback can
# resolve to a DIFFERENT session's transcript on a box where other claude sessions run
# in the same cwd. Minting removes the guess. (Worth porting back to eddy.)
#
# STORM GUARDS (this spawns claude; the watchdog's last spawn path OOM'd the box):
#   - one anchor, one remedy, one spawn per tick;
#   - kill is verified DEAD before any replacement spawn (never spawn on top of a live
#     process): count goes 1 -> 0 -> 1, never additive;
#   - per-anchor cooldowns bound retries (respawn 6h, dead-revive 10m);
#   - a pane parked at a human-choice prompt is NEVER revived (the remedy would answer
#     the dialog blindly).
#
# COEXISTENCE with the full session-watchdog.js (if that ever runs on this host):
#   - list the anchor in asana-config.json `watcher.persistent_anchors`, or the
#     watchdog's 72h idle reaper kills it as an "unlisted anchor";
#   - the watchdog reaps a DEAD anchor pane after 10 min (DEAD_ANCHOR_REAP_MS), so keep
#     this tick at 5 min: rc-heal revives the pane before that reaper sees it twice;
#   - both revive a dead RC bridge. Their guards (verified-dead-before-spawn + cooldowns)
#     make a double-fire safe, but prefer running ONE of them per anchor.
#
# USAGE
#   rc-heal.sh                 one tick (launchd com.jontz.rc-heal, every 5 min)
#   rc-heal.sh --status        report only, change nothing
#   rc-heal.sh --dry-run       decide + log, change nothing
#   rc-heal.sh --force <name>  skip idle + cooldown gates for that anchor
#   veto: touch /tmp/rc-heal-hold   (all)  or /tmp/rc-heal-hold-<name>
set -uo pipefail

DIR="$HOME/.config/agent-watcher"
ST="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
STATE="$ST/rc-heal-state.json"
CFG="$DIR/rc-heal.json"
LOG="$ST/rc-heal.log"

IDLE_S="${RC_HEAL_IDLE_S:-1200}"                    # pane must be static this long before a bridge revive
RESPAWN_COOLDOWN_S="${RC_HEAL_RESPAWN_COOLDOWN_S:-21600}"
REVIVE_COOLDOWN_S="${RC_HEAL_REVIVE_COOLDOWN_S:-600}"
ARM_WAIT_S="${RC_HEAL_ARM_WAIT_S:-45}"
KILL_WAIT_S=15

MODE=tick; FORCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) MODE=status; shift ;;
    --dry-run) MODE=dry; shift ;;
    --force) FORCE="${2:-}"; shift 2 ;;
    *) echo "rc-heal: unknown arg $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$ST"
[[ -f "$STATE" ]] || echo '{}' > "$STATE"
NOW=$(date +%s)

log() { local m="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; echo "$m"; echo "$m" >> "$LOG"; }

sget() { jq -r --arg n "$1" --arg k "$2" '.[$n][$k] // ""' "$STATE" 2>/dev/null; }
sset() { # name key value(json-encoded string or number)
  local tmp="$STATE.tmp.$$"
  jq --arg n "$1" --arg k "$2" --arg v "$3" '.[$n] = ((.[$n] // {}) + {($k): $v})' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

# RC bridge detection — byte-for-byte the watchdog's rule (session-watchdog.js
# rcBridgeUp): new builds put a "/rc" token ON the status footer line; old builds
# print "Remote Control active" in the last few lines. Bounded to the tail so the
# same words scrolled up in the CONVERSATION can never false-match.
rc_up() {
  local content="$1"
  printf '%s\n' "$content" | tail -8 | awk '
    /shift\+tab to cycle|for agents/ && /(^|[[:space:]])\/rc([[:space:]]|$)/ { found=1 }
    END { exit(found ? 0 : 1) }' && return 0
  printf '%s\n' "$content" | tail -3 | grep -q 'Remote Control active'
}

# Parked at a human CHOICE prompt (permission dialog, trust prompt, numbered menu).
# Such a pane is static and looks "hung" to the idle clock, but reviving it discards
# the pending decision. Same three signals as the watchdog's paneAwaitingChoice().
awaiting_choice() {
  printf '%s\n' "$1" | grep -qE '❯[[:space:]]+[0-9]+\.[[:space:]]|No, and tell Claude|Do you want to (proceed|continue|create|trust|allow|make)'
}

# claude-code renames argv[0], so its `comm` is `cli` (or a path ending in /cli), NOT
# `claude`. Matching only /claude/ is what made the watchdog's old death-path fire on
# every tick. Match both, walking descendants of the pane's shell.
claude_pid_under() {
  local pid="$1" depth="${2:-4}" child comm deeper
  [[ "$depth" -le 0 ]] && return 1
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    comm=$(ps -o comm= -p "$child" 2>/dev/null | tr -d ' ')
    if [[ "$comm" == claude || "$comm" == */claude || "$comm" == cli || "$comm" == */cli ]]; then
      echo "$child"; return 0
    fi
    if deeper=$(claude_pid_under "$child" $((depth - 1))); then echo "$deeper"; return 0; fi
  done
  return 1
}

pane_pid() { tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1; }

# The claude invocation for an anchor. First spawn MINTS the id (--session-id); every
# later spawn resumes it. Flags stay identical across heals so the anchor's identity
# (model, effort, RC name) survives a respawn.
claude_cmd() { # cwd name model effort sid mode(new|resume)
  local cwd="$1" name="$2" model="$3" effort="$4" sid="$5" mode="$6" c
  c="cd '$cwd' && claude --dangerously-skip-permissions"
  [[ -n "$model" ]] && c="$c --model '$model'"
  [[ -n "$effort" ]] && c="$c --effort $effort"
  c="$c --remote-control '$name'"
  if [[ "$mode" == new ]]; then c="$c --session-id $sid"; else c="$c --resume $sid"; fi
  echo "$c"
}

# Send a command into the pane's shell and wait for the RC bridge to arm. Callers have
# already verified NO claude is running under the pane.
launch_into_pane() { # sess cmd name
  local sess="$1" cmd="$2" name="$3" i
  tmux send-keys -t "$sess" C-u
  tmux send-keys -t "$sess" "$cmd" Enter
  for ((i = 0; i < ARM_WAIT_S; i++)); do
    if rc_up "$(tmux capture-pane -t "$sess" -p 2>/dev/null)"; then
      log "[$name] bridge armed (/rc footer token present)."
      return 0
    fi
    sleep 1
  done
  log "[$name] launched but no /rc token after ${ARM_WAIT_S}s — cooldown armed, re-checked next tick."
  return 1
}

# Sourceable for testing the pure detectors: `RC_HEAL_LIB=1 source rc-heal.sh` loads
# the functions and stops before the tick.
[[ -n "${RC_HEAL_LIB:-}" ]] && return 0

ANCHORS=$(jq -c '.anchors[]?' "$CFG" 2>/dev/null)
[[ -n "$ANCHORS" ]] || { log "no anchors configured in $CFG"; exit 0; }

while IFS= read -r a; do
  name=$(jq -r '.name' <<<"$a")
  cwd=$(jq -r '.cwd // env.HOME' <<<"$a")
  model=$(jq -r '.model // ""' <<<"$a")
  effort=$(jq -r '.effort // ""' <<<"$a")
  sess="claude-asana-$name"
  forced=false; [[ "$FORCE" == "$name" ]] && forced=true

  if [[ -f /tmp/rc-heal-hold || -f "/tmp/rc-heal-hold-$name" ]]; then
    log "[$name] HELD (veto file) — no action"; continue
  fi

  sid=$(sget "$name" session_id)
  [[ -n "$sid" ]] || { sid=$(uuidgen | tr 'A-Z' 'a-z'); sset "$name" session_id "$sid"; log "[$name] minted session id $sid"; }

  # ── 1. tmux session gone ────────────────────────────────────────────────────
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    if [[ "$MODE" == status ]]; then echo "$name: NO SESSION (would create; sid $sid)"; continue; fi
    # A transcript on disk means the anchor lived before (reboot/killed server) -> resume it.
    mode=new
    ls "$HOME/.claude/projects/"*/"$sid.jsonl" >/dev/null 2>&1 && mode=resume
    cmd=$(claude_cmd "$cwd" "$name" "$model" "$effort" "$sid" "$mode")
    log "[$name] no tmux session → creating and starting claude ($mode $sid)"
    [[ "$MODE" == dry ]] && { log "[$name] DRY: $cmd"; continue; }
    tmux new-session -d -s "$sess" -c "$cwd"
    launch_into_pane "$sess" "$cmd" "$name"
    sset "$name" revivedAt "$NOW"
    continue
  fi

  ppid=$(pane_pid "$sess")
  [[ -n "$ppid" ]] || { log "[$name] could not read pane pid; skipping"; continue; }
  cpid=$(claude_pid_under "$ppid" || true)
  content=$(tmux capture-pane -t "$sess" -p 2>/dev/null)

  # ── 2. pane alive, claude dead ──────────────────────────────────────────────
  if [[ -z "$cpid" ]]; then
    if [[ "$MODE" == status ]]; then echo "$name: session up, CLAUDE DEAD (would revive --resume $sid)"; continue; fi
    last=$(sget "$name" revivedAt); last=${last:-0}
    if ! $forced && [[ $((NOW - last)) -lt $REVIVE_COOLDOWN_S ]]; then
      log "[$name] claude dead but revive cooldown active ($(( (NOW - last) / 60 ))m < $((REVIVE_COOLDOWN_S / 60))m) — likely a crash loop, leaving it"
      continue
    fi
    cmd=$(claude_cmd "$cwd" "$name" "$model" "$effort" "$sid" resume)
    log "[$name] claude gone from the pane → reviving in place (--resume $sid)"
    [[ "$MODE" == dry ]] && { log "[$name] DRY: $cmd"; continue; }
    launch_into_pane "$sess" "$cmd" "$name"
    sset "$name" revivedAt "$NOW"
    continue
  fi

  # ── 3. claude alive: RC bridge + idle gates ─────────────────────────────────
  hash=$(printf '%s' "$content" | shasum -a 256 | cut -c1-16)
  prev_hash=$(sget "$name" hash); prev_ts=$(sget "$name" ts); prev_ts=${prev_ts:-$NOW}
  if [[ "$hash" != "$prev_hash" ]]; then
    sset "$name" hash "$hash"; sset "$name" ts "$NOW"; idle=0
  else
    idle=$((NOW - prev_ts))
  fi
  up=false; rc_up "$content" && up=true
  parked=false; awaiting_choice "$content" && parked=true

  if [[ "$MODE" == status ]]; then
    echo "$name: session up, claude $cpid, bridge $([[ $up == true ]] && echo UP || echo DOWN), idle $((idle / 60))m$([[ $parked == true ]] && echo ', PARKED at a choice prompt')  sid $sid"
    continue
  fi

  $up && { log "[$name] healthy (bridge up, idle $((idle / 60))m)"; continue; }
  $parked && { log "[$name] bridge down but pane is PARKED at a human-choice prompt — not touching it"; continue; }
  if ! $forced && [[ "$idle" -lt "$IDLE_S" ]]; then
    log "[$name] bridge indicator absent but pane changed ${idle}s ago (< ${IDLE_S}s) — session is working, not touching it"
    continue
  fi
  last=$(sget "$name" respawnedAt); last=${last:-0}
  if ! $forced && [[ $((NOW - last)) -lt $RESPAWN_COOLDOWN_S ]]; then
    log "[$name] RC respawn skipped: last attempt $(( (NOW - last) / 60 ))m ago (cooldown $((RESPAWN_COOLDOWN_S / 3600))h)"
    continue
  fi

  draft=$(printf '%s\n' "$content" | grep -E '^❯[[:space:]]+[^[:space:]]' | tail -1 || true)
  [[ -n "$draft" ]] && log "[$name] composer draft will be lost with the respawn (re-send by hand if wanted): $draft"
  log "[$name] RC bridge DOWN + idle $((idle / 60))m → respawn: kill claude $cpid, relaunch --resume $sid"
  [[ "$MODE" == dry ]] && continue
  kill "$cpid" 2>/dev/null
  for ((i = 0; i < KILL_WAIT_S; i++)); do ps -o pid= -p "$cpid" >/dev/null 2>&1 || break; sleep 1; done
  if ps -o pid= -p "$cpid" >/dev/null 2>&1 || claude_pid_under "$ppid" >/dev/null; then
    log "[$name] respawn ABORTED: claude $cpid survived SIGTERM ${KILL_WAIT_S}s — NOT spawning on top of a live process (cooldown armed)"
    sset "$name" respawnedAt "$NOW"
    continue
  fi
  launch_into_pane "$sess" "$(claude_cmd "$cwd" "$name" "$model" "$effort" "$sid" resume)" "$name"
  sset "$name" respawnedAt "$NOW"
done <<< "$ANCHORS"

exit 0
