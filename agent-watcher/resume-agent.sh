#!/usr/bin/env bash
# resume-agent.sh — Find and resume a watcher-spawned claude session.
#
# Watcher-spawned sessions have a unique signature:
#   (a) project dir is enc(~/git) — e.g. -Users-<user>-git (cwd was ~/git when spawned)
#   (b) the first user message starts with `/one-shot --yolo`
# Filtering on both excludes other claude sessions (this desktop app's history,
# ad-hoc terminal sessions, etc.) that may incidentally mention the same term.
#
# Usage:
#   resume-agent.sh                 # picks the most recent watcher session
#   resume-agent.sh <term> [term..] # filter; ALL words must appear (case-insensitive)
#                                   # in the transcript HEAD (task URL/name/prompt
#                                   # region), so generic words don't match everything
#   resume-agent.sh --list          # list candidates as "Asana: <task name>"
#                                   # (the same title the desktop session list
#                                   # shows); do not resume
#   resume-agent.sh <term> --chat   # DISCUSSION MODE: fork the matched transcript into
#                                   # a watchdog-covered tmux session with remote
#                                   # control armed (talk to a past run from anywhere,
#                                   # no slot provisioning, original conversation
#                                   # untouched). Session/RC name: chat-<slug>,
#                                   # slugged from the search term, else the
#                                   # transcript's Asana task name, else the uuid.
#                                   # Resumes FULL-FIDELITY by default: chat exists to
#                                   # continue the conversation's details (drafts, exact
#                                   # wording), which a summary resume compresses away.
#                                   # Pass --summary to opt into the cheaper compact
#                                   # resume. (Orch resumes are separate: resume-task/
#                                   # spawn-test-session keep the summary default.)
#   resume-agent.sh <term> --latest # skip the ambiguity guard: silently take the
#                                   # newest transcript among multi-task matches
#   resume-agent.sh --uuid <id> [--chat [--in-place]] [--chrome]
#                                   # exact transcript selection (any kind, any project
#                                   # dir - chat forks/interactive transcripts have no
#                                   # /one-shot signature and only resolve this way;
#                                   # /resume-session resolves via session-index.sh).
#                                   # --in-place: continue the SAME conversation (no
#                                   # fork) - for dead discussion forks.
#   resume-agent.sh <task-gid> --recover
#                                   # before resuming, if the task's slot is gone
#                                   # but Asana shows it in-flight, re-provision the
#                                   # worktree + sim + Metro port (slot re-allocate).
#                                   # Default (no --recover) just `claude --resume`.
#
# When a term matches transcripts of MORE THAN ONE task, the script LISTS them and
# exits 1 instead of silently taking the newest (pass --latest to override).
# Multiple transcripts of the SAME task (fork chains) resolve to the newest.
#
# Exit codes:
#   0 = matched + resumed (or listed, with --list)
#   1 = no match / ambiguous across tasks / search produced no candidates

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
DO_LIST=false
PORCELAIN=false
RECOVER=false
CHAT=false
LATEST=false
SUMMARY=false
IN_PLACE=false
CHROME=false
ANCHOR_NAME=""
UUID=""
TERM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) DO_LIST=true; shift ;;
    --porcelain) PORCELAIN=true; shift ;;       # with --list: machine-readable TSV (for session-tui.js)
    --tui) exec node "$HOME/.config/agent-watcher/session-tui.js" ;;
    --recover) RECOVER=true; shift ;;
    --chat) CHAT=true; shift ;;
    --latest) LATEST=true; shift ;;
    --summary) SUMMARY=true; shift ;;
    --in-place) IN_PLACE=true; shift ;;         # with --chat: continue the SAME conversation (no fork).
    --chrome) CHROME=true; shift ;;             # spawn with the Chrome extension bridge enabled.
    --name) ANCHOR_NAME="$2"; shift 2 ;;        # with --chat: resurrect as the NAMED ANCHOR claude-asana-<name> (never idle-reaped) instead of a chat.
                                                # For resuming a DEAD DISCUSSION FORK: forking a fork
                                                # duplicates history again and pollutes future search.
    --uuid) UUID="${2:-}"; shift 2 ;;           # exact transcript selection; bypasses matching entirely
                                                # (the /resume-session skill resolves via session-index
                                                # and passes the uuid here)
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *) TERM="${TERM:+$TERM }$1"; shift ;;       # multi-word terms accumulate
  esac
done

# --recover: re-provision a missing slot for an in-flight task before resuming.
# No-op unless TERM is a bare task GID and the slot is actually gone.
recover_slot() {
  local gid="$1"
  [[ "$gid" =~ ^[0-9]+$ ]] || { echo ">> resume-agent: --recover needs a numeric task GID; skipping" >&2; return 0; }

  local existing
  existing=$(node "$DIR/lib/slots.js" get --task-gid "$gid" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$existing" ]]; then
    echo ">> resume-agent: slot for $gid already present; no recovery needed" >&2
    return 0
  fi

  local cfg="$DIR/asana-config.json" cred="$DIR/credentials.json"
  [[ -f "$cfg" && -f "$cred" ]] || { echo ">> resume-agent: missing config/credentials; cannot recover" >&2; return 0; }
  local token field_gid status repo
  token=$(jq -r .asana_token "$cred")
  field_gid=$(jq -r .custom_fields.agent_status.gid "$cfg")
  status=$(curl -sS -H "Authorization: Bearer $token" \
    "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=custom_fields.gid,custom_fields.enum_value.name" 2>/dev/null \
    | jq -r --arg f "$field_gid" '.data.custom_fields[]? | select(.gid==$f) | .enum_value.name // ""')

  case "$status" in
    Planning|Developing|Reviewing|Testing)
      repo=$(jq -r '.watcher.default_repo // "edge-react-gui"' "$cfg")
      echo ">> resume-agent: slot for $gid missing but Asana=$status → re-provisioning ($repo)" >&2
      local wt sim
      wt=$("$DIR/setup-task-workspace.sh" --task-gid "$gid" --repo "$repo" | tail -1)
      sim=$("$DIR/clone-ios-sim.sh" --name "agent-sim-$gid" | tail -1)
      node "$DIR/lib/slots.js" allocate --task-gid "$gid" --worktree-path "$wt" --sim-udid "$sim" >/dev/null
      echo ">> resume-agent: re-provisioned slot for $gid (wt=$wt sim=$sim)" >&2
      ;;
    *)
      echo ">> resume-agent: task $gid not in-flight (status='${status:-unknown}'); skipping re-allocation" >&2
      ;;
  esac
}

# Watcher-spawned sessions live under one of two shapes:
#   ~/.claude/projects/<enc(~/git)>/<uuid>.jsonl
#     (legacy: pre-parallelization, cwd was ~/git/)
#   ~/.claude/projects/<enc(~/git)>--agent-worktrees-<task-gid>-<repo>/<uuid>.jsonl
#     (current: per-task worktree under ~/git/.agent-worktrees/<gid>/<repo>/)
# claude encodes a project dir by replacing every "/" and "." in the cwd with "-".
# Derive the prefix from $HOME so this works under any macOS user (not just "jontz").
# Both shapes share the enc(~/git) prefix, so one glob catches them all.
ENC_GIT_PREFIX=$(printf '%s' "$HOME/git" | sed 's#[/.]#-#g')
CANDIDATES=()
shopt -s nullglob
for d in "$HOME/.claude/projects/$ENC_GIT_PREFIX"*; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*.jsonl; do
    [[ -f "$f" ]] || continue
    if head -20 "$f" | grep -q '"/one-shot --yolo' ; then
      CANDIDATES+=("$f")
    fi
  done
done
shopt -u nullglob

# --uuid: exact selection replaces the candidate machinery entirely (any project
# dir, any kind — chat forks and interactive transcripts carry no /one-shot
# signature and are invisible to the matcher above; the /resume-session skill
# resolves them via session-index.sh and passes the uuid here).
if [[ -n "$UUID" ]]; then
  CANDIDATES=()
  shopt -s nullglob
  for f in "$HOME/.claude/projects"/*/"$UUID.jsonl"; do CANDIDATES+=("$f"); done
  shopt -u nullglob
  [[ ${#CANDIDATES[@]} -gt 0 ]] || { echo ">> resume-agent: no transcript found for uuid $UUID" >&2; exit 1; }
  TERM=""   # bypass term filtering and the ambiguity guard
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "No watcher-spawned sessions found in ~/.claude/projects/${ENC_GIT_PREFIX}*" >&2
  exit 1
fi

first_gid_of() { head -c 16384 "$1" | grep -oE 'app\.asana\.com[A-Za-z0-9/._-]*' | head -1 | grep -oE '[0-9]{12,}' | tail -1 || true; }

# ─── Asana task-name resolution (shared by --list and term matching) ──────────
# A transcript records only the task URL, never the name, so a human-readable
# title has to come from Asana. ONE batch call covers the agent project's recent
# tasks; anything older (or in another project) falls back to a single per-gid
# GET, memoized so a repeat lookup in the same run is free. Every failure path
# yields "" so callers degrade to transcript-derived text instead of erroring —
# --list must still work offline.
GID_NAMES=""
GID_NAMES_LOADED=false
GID_NAME_CACHE="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/asana-task-names.tsv"
GID_NAME_CACHE_TTL=21600   # 6h — task names are near-static; staleness costs nothing

# Append gid<TAB>name to the on-disk cache (newest wins on read).
cache_gid_name() {
  [[ -n "$1" && -n "$2" ]] || return 0
  mkdir -p "$(dirname "$GID_NAME_CACHE")" 2>/dev/null || return 0
  printf '%s\t%s\n' "$1" "$2" >> "$GID_NAME_CACHE" 2>/dev/null || true
}

load_gid_names() {
  $GID_NAMES_LOADED && return 0
  GID_NAMES_LOADED=true
  # Warm from the disk cache FIRST, so a network stall degrades to slightly stale
  # names rather than to no names at all. A cold/stale cache then refreshes below.
  local now age=999999
  now=$(date +%s)
  if [[ -f "$GID_NAME_CACHE" ]]; then
    GID_NAMES=$(cat "$GID_NAME_CACHE" 2>/dev/null || true)
    age=$(( now - $(stat -f %m "$GID_NAME_CACHE" 2>/dev/null || echo 0) ))
  fi
  [[ $age -lt $GID_NAME_CACHE_TTL ]] && return 0

  local cred="$DIR/credentials.json" cfg="$DIR/asana-config.json" token proj
  token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$cred" 2>/dev/null)}"
  proj=$(jq -r '.project_gid // empty' "$cfg" 2>/dev/null)
  [[ -n "$token" && -n "$proj" ]] || return 0
  # Paginate: one page is only the newest ~100 tasks, which left every older
  # session falling through to a serial per-gid GET. Each page gets one retry —
  # a single timed-out page (Asana returns HTTP 000 on a stall) used to abort the
  # whole map and silently degrade --list into 59 sequential requests.
  local url="https://app.asana.com/api/1.0/projects/$proj/tasks?opt_fields=name&limit=100"
  local resp page=0 offset fresh=""
  while [[ -n "$url" && $page -lt 8 ]]; do
    resp=$(curl -sf --max-time 10 "$url" -H "Authorization: Bearer $token" 2>/dev/null || true)
    [[ -n "$resp" ]] || resp=$(curl -sf --max-time 10 "$url" -H "Authorization: Bearer $token" 2>/dev/null || true)
    [[ -n "$resp" ]] || break
    fresh=$(printf '%s\n%s' "$fresh" "$(printf '%s' "$resp" | jq -r '.data[]? | .gid + "\t" + .name' 2>/dev/null || true)")
    offset=$(printf '%s' "$resp" | jq -r '.next_page.offset // empty' 2>/dev/null || true)
    [[ -n "$offset" ]] || break
    url="https://app.asana.com/api/1.0/projects/$proj/tasks?opt_fields=name&limit=100&offset=$offset"
    page=$((page + 1))
  done
  [[ -n "${fresh//[[:space:]]/}" ]] || return 0
  # Fresh entries first so `!seen` keeps the current name for a renamed task.
  GID_NAMES=$(printf '%s\n%s' "$fresh" "$GID_NAMES" | awk -F'\t' 'NF==2 && !seen[$1]++')
  mkdir -p "$(dirname "$GID_NAME_CACHE")" 2>/dev/null || return 0
  printf '%s\n' "$GID_NAMES" > "$GID_NAME_CACHE.tmp" 2>/dev/null && mv "$GID_NAME_CACHE.tmp" "$GID_NAME_CACHE" 2>/dev/null || true
}

name_of_gid() { # $1=gid → Asana task name ("" when unresolvable)
  local g="$1" nm="" token
  [[ -n "$g" ]] || return 0
  load_gid_names
  [[ -n "$GID_NAMES" ]] && nm=$(printf '%s\n' "$GID_NAMES" | awk -F'\t' -v g="$g" '$1==g {print $2; exit}')
  if [[ -z "$nm" ]]; then
    token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$DIR/credentials.json" 2>/dev/null)}"
    if [[ -n "$token" ]]; then
      nm=$(curl -sf --max-time 10 "https://app.asana.com/api/1.0/tasks/$g?opt_fields=name" \
        -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.data.name // empty' 2>/dev/null || true)
      if [[ -n "$nm" ]]; then
        GID_NAMES=$(printf '%s\n%s\t%s' "$GID_NAMES" "$g" "$nm")
        cache_gid_name "$g" "$nm"   # a task outside the project window resolves once, not every run
      fi
    fi
  fi
  printf '%s' "$nm"
}

# ─── Live tmux state (for --list) ────────────────────────────────────────────
# A listed run can be in one of four states, and they are NOT interchangeable:
#   running (claude-asana-<gid>)  watched, holds a concurrency slot
#   retired (done-asana-<gid>)    completion sweep renamed it; claude still alive
#                                 and attachable, slot/sim/Metro already freed
#   dead    (pane, no claude)     the watchdog logs these and deliberately does
#                                 NOT auto-resume (that was the OOM fork-storm)
#   none                          transcript on disk only
# The fork subtlety: a pane launched with --fork-session WRITES to a new uuid, not
# the one in its argv, so "some pane is resuming this uuid" does NOT mean this
# transcript is live. Attributing a live discussion to the pristine run transcript
# is what makes an operator resume the pre-fork state and create a second
# divergent copy, so the child is resolved from the fork registry and reported as
# a fork of the run, never as the run itself being live.
FORK_REGISTRY="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/chat-forks.jsonl"
TMUX_STATE=""   # gid \t state \t rc_name
TMUX_FORKS=""   # parent_uuid \t child_uuid \t rc_name
TMUX_LOADED=false
load_tmux_state() {
  $TMUX_LOADED && return 0
  TMUX_LOADED=true
  tmux list-sessions -F '#{session_name}' >/dev/null 2>&1 || return 0
  local name pid args a c rc ruuid fork alive gid child st
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    args=""; alive=false
    # All panes across ALL windows (-s), and children resolved via ps, NOT
    # pgrep -P: macOS pgrep silently excludes the caller's own ancestors, so a
    # --list run from inside a claude pane reported its own session as dead.
    for pid in $(tmux list-panes -s -t "$name" -F '#{pane_pid}' 2>/dev/null || true); do
      for c in $(ps -axo pid=,ppid= | awk -v p="$pid" '$2==p {print $1}'); do
        a=$(ps -ww -o command= -p "$c" 2>/dev/null || true)
        case "$a" in claude\ *|*/claude\ *|claude) args="$a"; alive=true; break ;; esac
      done
      $alive && break
    done
    rc=$(printf '%s' "$args" | grep -oE -- '--remote-control [^ ]+' | awk '{print $2}' | head -1 || true)
    ruuid=$(printf '%s' "$args" | grep -oE -- '--resume [0-9a-f-]{36}' | awk '{print $2}' | head -1 || true)
    fork=false; printf '%s' "$args" | grep -q -- '--fork-session' && fork=true
    gid=""
    if [[ "$name" =~ ^claude-asana-([0-9]{12,})$ ]]; then
      gid="${BASH_REMATCH[1]}"; st=running
    elif [[ "$name" =~ ^done-asana-([0-9]{12,})$ ]]; then
      gid="${BASH_REMATCH[1]}"; st=retired
    fi
    if [[ -n "$gid" ]]; then
      $alive || st=dead
      TMUX_STATE=$(printf '%s\n%s\t%s\t%s' "$TMUX_STATE" "$gid" "$st" "$rc")
    fi
    if $alive && $fork && [[ -n "$ruuid" ]]; then
      child=$(grep -F "\"parent\":\"$ruuid\"" "$FORK_REGISTRY" 2>/dev/null | tail -1 \
        | sed -E 's/.*"child":"([0-9a-f-]{36})".*/\1/' || true)
      TMUX_FORKS=$(printf '%s\n%s\t%s\t%s' "$TMUX_FORKS" "$ruuid" "${child:-unknown}" "$rc")
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
}

# Optionally filter by search term(s): every word must match, case-insensitively,
# against the session's TASK IDENTITY — its gid + its Asana task NAME (fetched in
# ONE batch call for the whole agent project). Transcript-body matching is
# deliberately avoided: a generic word ("swap") appears in nearly every transcript,
# which made ambiguous matches resolve to an unrelated session; and the transcript
# HEAD carries only the task URL, never the name. Falls back to head-region
# matching only if the Asana lookup is unavailable.
if [[ -n "$TERM" ]]; then
  identity_of() { # $1=file → "gid<space>task name" (falls back to head region)
    local g; g=$(first_gid_of "$1")
    local nm; nm=$(name_of_gid "$g")
    if [[ -n "$nm" ]]; then printf '%s %s' "$g" "$nm"; else printf '%s %s' "$g" "$(head -c 65536 "$1" | tr -d '\0')"; fi
  }
  FILTERED=()
  for f in "${CANDIDATES[@]}"; do
    id=$(identity_of "$f")
    ok=true
    for w in $TERM; do
      printf '%s' "$id" | grep -qi -- "$w" || { ok=false; break; }
    done
    $ok && FILTERED+=("$f")
  done
  if [[ ${#FILTERED[@]} -eq 0 ]]; then
    echo "No watcher-spawned session's task gid/name matches: $TERM" >&2
    echo "(use --list to see all candidates)" >&2
    exit 1
  fi
  CANDIDATES=("${FILTERED[@]}")
fi

# Ambiguity guard: if the surviving candidates span MORE THAN ONE task (by the
# first asana URL's gid), listing beats guessing — a silent newest-mtime pick
# resumes an unrelated run. Fork chains of one task still auto-resolve to newest.
if [[ -n "$TERM" ]] && ! $LATEST && ! $DO_LIST; then
  DISTINCT=$(for f in "${CANDIDATES[@]}"; do first_gid_of "$f"; done | sort -u | grep -c . || true)
  if [[ "$DISTINCT" -gt 1 ]]; then
    echo "Ambiguous: '$TERM' matches sessions of $DISTINCT different tasks. Narrow the term, or pass --latest:" >&2
    for f in "${CANDIDATES[@]}"; do
      printf "  %s  gid=%s  %s\n" "$(date -r "$(stat -f %m "$f")" '+%m-%d %H:%M')" "$(first_gid_of "$f")" "$(basename "$f" .jsonl)" >&2
    done
    exit 1
  fi
fi

# Sort by mtime desc; emit one line per candidate: mtime + UUID + gid + prompt preview.
emit_candidates() {
  for f in "${CANDIDATES[@]}"; do
    mtime=$(stat -f "%m" "$f")
    uuid=$(basename "$f" .jsonl)
    gid=$(first_gid_of "$f")
    # Find the first user `/one-shot ...` line and pull a short preview of the prompt.
    # `grep -m1` closes the pipe early; head/sed upstream die SIGPIPE (141), which
    # `set -eo pipefail` turns into a silent abort mid-listing. Absorb it.
    preview=$( (head -30 "$f" | grep -m1 '"/one-shot --yolo' | sed -E 's/.*"(\/one-shot --yolo [^"]{0,80})[^"]*".*/\1/' | head -c 100) 2>/dev/null || true)
    printf "%s\t%s\t%s\t%s\n" "$mtime" "$uuid" "$gid" "$preview"
  done | sort -rn
}

# --list renders the SAME title the desktop session list shows: resume-task.sh
# labels a spawned session "Asana: <task name>", so reconstructing that string
# from the gid makes the two lists say the same thing. The raw `/one-shot --yolo
# <url>` preview identifies nothing at a glance, so it is only the fallback for
# when Asana is unreachable or the task is gone.
if $DO_LIST; then
  load_tmux_state
  # --porcelain: one TSV row per transcript, newest first, no header. Contract
  # (consumed by session-tui.js — update both together):
  #   mtime_epoch \t uuid \t gid \t state \t rc \t fork_child \t fork_rc \t title
  # state is running/retired/dead/"" (same four states as the human list); title
  # is the resolved "Asana: <name>" or the /one-shot preview fallback.
  if $PORCELAIN; then
    while IFS=$'\t' read -r mtime uuid gid preview; do
      [[ -n "$mtime" ]] || continue
      nm=$(name_of_gid "$gid")
      if [[ -n "$nm" ]]; then title="Asana: $nm"; else title="${preview:-}"; fi
      state=""; rc=""
      if [[ -n "$gid" ]]; then
        row=$(printf '%s\n' "$TMUX_STATE" | awk -F'\t' -v g="$gid" '$1==g {print; exit}')
        state=$(printf '%s' "$row" | cut -f2); rc=$(printf '%s' "$row" | cut -f3)
      fi
      fork_child=$(printf '%s\n' "$TMUX_FORKS" | awk -F'\t' -v u="$uuid" '$1==u {print $2; exit}')
      fork_rc=$(printf '%s\n' "$TMUX_FORKS" | awk -F'\t' -v u="$uuid" '$1==u {print $3; exit}')
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$mtime" "$uuid" "$gid" "$state" "$rc" "$fork_child" "$fork_rc" "$title"
    done < <(emit_candidates)
    exit 0
  fi
  echo "Watcher-spawned sessions (newest first):"
  echo "  ● running   ◐ retired (alive, attachable)   ✗ dead pane"
  while IFS=$'\t' read -r mtime uuid gid preview; do
    [[ -n "$mtime" ]] || continue
    ts=$(date -r "$mtime" '+%Y-%m-%d %H:%M:%S')
    nm=$(name_of_gid "$gid")
    if [[ -n "$nm" ]]; then title="Asana: $nm"; else title="${preview:-(title unavailable)}"; fi

    state=""; rc=""
    if [[ -n "$gid" ]]; then
      row=$(printf '%s\n' "$TMUX_STATE" | awk -F'\t' -v g="$gid" '$1==g {print; exit}')
      state=$(printf '%s' "$row" | cut -f2); rc=$(printf '%s' "$row" | cut -f3)
    fi
    fork_child=$(printf '%s\n' "$TMUX_FORKS" | awk -F'\t' -v u="$uuid" '$1==u {print $2; exit}')
    fork_rc=$(printf '%s\n' "$TMUX_FORKS" | awk -F'\t' -v u="$uuid" '$1==u {print $3; exit}')

    case "$state" in
      running) sym="●" ;;
      retired) sym="◐" ;;
      dead)    sym="✗" ;;
      *)       sym=" " ;;
    esac
    notes="$state"
    [[ -n "$rc" ]] && notes="${notes:+$notes }rc=$rc"
    # A live fork means THIS transcript is frozen and the conversation moved on;
    # say so with the child uuid, which is what --uuid must be given to reach it.
    # When the fork runs in THIS session's own pane, its rc is the same string
    # already printed above — don't say it twice.
    [[ -n "$fork_rc" && "$fork_rc" == "$rc" ]] && fork_rc=""
    [[ -n "$fork_child" ]] && notes="${notes:+$notes }-> live fork $fork_child${fork_rc:+ rc=$fork_rc}"
    [[ -n "$notes" ]] && notes="   [$notes]"
    printf "  %s %s  %s  %s%s\n" "$sym" "$ts" "$uuid" "$title" "$notes"
  done < <(emit_candidates)
  exit 0
fi

if $RECOVER && [[ -n "$TERM" ]]; then
  recover_slot "$TERM"
fi

LATEST_UUID=$(emit_candidates | head -1 | cut -f2)

# Find the matching JSONL file and read the session's original cwd from it.
# claude resumes the conversation by UUID but new tool calls run at the user's
# current shell cwd — for a worktree session, those paths won't resolve unless
# we `cd` to the original cwd first.
LATEST_JSONL=""
for f in "${CANDIDATES[@]}"; do
  if [[ "$(basename "$f" .jsonl)" == "$LATEST_UUID" ]]; then
    LATEST_JSONL="$f"
    break
  fi
done

ORIG_CWD=""
if [[ -n "$LATEST_JSONL" ]]; then
  # cwd is recorded on most JSONL records; the first non-null occurrence is the truth.
  # `head -1` closes the pipe early; for a large history jq is still streaming and
  # dies with SIGPIPE (141). `|| true` absorbs that so `set -e` doesn't abort here.
  ORIG_CWD=$(jq -r 'select(.cwd != null) | .cwd' "$LATEST_JSONL" 2>/dev/null | head -1 || true)
fi

# `claude --resume` scopes session lookup to the project dir derived from cwd.
# A worktree session lives under <worktrees_root>/<gid>/<repo>; claude resolves it
# from that exact dir or from the repos root (~/git), but NOT from $HOME. So: cd to
# the original cwd if it still exists (tool calls hit real files), else fall back to
# the repos root (proven to resolve reaped worktree sessions). Never $HOME.
if [[ -n "$ORIG_CWD" && -d "$ORIG_CWD" ]]; then
  echo ">> resume-agent: cd $ORIG_CWD" >&2
  cd "$ORIG_CWD"
elif [[ -n "$ORIG_CWD" ]]; then
  repos_root=$(jq -r '.watcher.repos_root // empty' "$DIR/asana-config.json" 2>/dev/null)
  repos_root="${repos_root/#\~/$HOME}"
  if [[ -n "$repos_root" && -d "$repos_root" ]]; then
    echo ">> resume-agent: $ORIG_CWD gone (worktree reaped?) — resuming from repos root $repos_root" >&2
    cd "$repos_root"
  else
    echo ">> resume-agent: $ORIG_CWD gone and repos root unavailable — resuming from \$HOME (resume may fail)" >&2
    cd "$HOME"
  fi
fi

if $CHAT; then
  # DISCUSSION MODE: fork the transcript into a watchdog-covered tmux session with
  # remote control, instead of resuming in this terminal. Properties:
  #   - --fork-session: the original conversation is untouched (the watcher's own
  #     resume-task transcript resolution is unaffected by this chat's existence
  #     only until the fork's mtime advances past it — real followup work should
  #     still be re-engaged via agent_status=Pending, never done in the chat).
  #   - session name claude-asana-chat-<slug>: the "claude-asana-" prefix puts it
  #     under session-watchdog RC revive; the NON-GID name keeps the completion
  #     sweep from retiring it when the task is Complete (same pattern as the
  #     main/eval discussion sessions).
  #   - --remote-control chat-<slug>: reachable from the phone session list.
  # --name <anchor> resurrects a session as a NAMED ANCHOR (claude-asana-<name>,
  # RC <name>) instead of a chat. This matters because the watchdog's idle
  # reaper kills `claude-asana-chat-*` after 48h and exempts anchors BY NAME:
  # resurrecting a persistent anchor (main/eval/pokemon/...) with the default
  # chat naming silently DEMOTES it into the reap pool, which is how the "main"
  # chat died 2026-07-26 exactly 48h after its resurrection. Resurrecting an
  # anchor? Pass --name <its original name>.
  # Slug precedence: explicit search term > the transcript's Asana task name >
  # uuid. Term invocations already read fine; --uuid invocations (the TUI keys
  # and /resume-session) used to mint opaque names like chat-52ebc085-..., so
  # resolve the task name via name_of_gid (6h disk cache, then Asana, "" when
  # offline) and slug from that. Any resolution failure falls back to the uuid
  # — a spawn never blocks on Asana. Fork transcripts inherit the parent's
  # history head, so a fork-of-a-run still resolves its task gid.
  SLUG_SRC="$TERM"
  if [[ -z "$SLUG_SRC" && -n "$UUID" && -n "$LATEST_JSONL" ]]; then
    SLUG_SRC=$(name_of_gid "$(first_gid_of "$LATEST_JSONL")")
  fi
  SLUG=$(printf '%s' "${SLUG_SRC:-${UUID:-latest}}" \
    | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | tr -s '-' | cut -c1-24 | sed 's/-*$//')
  [[ -n "$SLUG" ]] || SLUG=$(printf '%s' "${UUID:-latest}" | cut -c1-24)
  RC_NAME="chat-${SLUG}"
  TMUX_NAME="claude-asana-chat-${SLUG}"
  if [[ -n "$ANCHOR_NAME" ]]; then
    RC_NAME="$ANCHOR_NAME"
    TMUX_NAME="claude-asana-${ANCHOR_NAME}"
  fi
  # Name-slugged forks of the same task collide on the tmux name while being
  # genuinely different conversations. Disambiguate by the argv --resume uuid of
  # the existing session's claude: same transcript → fall through to the
  # already-exists report (that IS the answer); different transcript (or a dead
  # pane with no claude) → append a short uuid suffix and spawn a distinct chat.
  pane_resume_uuid() { # $1=tmux session name → its claude's --resume uuid ("" if none)
    local pid c a
    for pid in $(tmux list-panes -s -t "$1" -F '#{pane_pid}' 2>/dev/null || true); do
      for c in $(ps -axo pid=,ppid= | awk -v p="$pid" '$2==p {print $1}'); do
        a=$(ps -ww -o command= -p "$c" 2>/dev/null || true)
        case "$a" in claude\ *|*/claude\ *|claude)
          printf '%s' "$a" | grep -oE -- '--resume [0-9a-f-]{36}' | awk '{print $2}' | head -1
          return 0 ;;
        esac
      done
    done
    return 0
  }
  if [[ -z "$ANCHOR_NAME" ]] && tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    if [[ "$(pane_resume_uuid "$TMUX_NAME")" != "$LATEST_UUID" ]]; then
      SLUG="${SLUG}-$(printf '%s' "$LATEST_UUID" | cut -c1-4)"
      RC_NAME="chat-${SLUG}"
      TMUX_NAME="claude-asana-chat-${SLUG}"
    fi
  fi
  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    echo ">> resume-agent: chat session $TMUX_NAME already exists — attach: tmux attach -t $TMUX_NAME (or find '$RC_NAME' in your remote session list)" >&2
    exit 0
  fi
  CHAT_CWD="$PWD"   # the cwd resolution above already ran
  # --in-place continues the SAME conversation (no fork) — the right mode for a dead
  # DISCUSSION FORK, where forking again would duplicate history a second time and
  # pollute future content search. Default (fork) is right for RUN transcripts.
  FORK_FLAG="--fork-session"
  $IN_PLACE && FORK_FLAG=""
  # Snapshot the project dir so the fork's new transcript uuid is detectable after
  # boot (claude does not print it) — feeds the lineage registry.
  PROJ_ENC=$(printf '%s' "$CHAT_CWD" | sed 's#[/.]#-#g')
  PROJ_DIR="$HOME/.claude/projects/$PROJ_ENC"
  BEFORE_LIST=$(ls "$PROJ_DIR"/*.jsonl 2>/dev/null || true)
  tmux new-session -d -s "$TMUX_NAME" -c "$CHAT_CWD"
  tmux send-keys -t "$TMUX_NAME" C-u   # clear any stray typed text before the command
  CHROME_FLAG=""
  $CHROME && CHROME_FLAG="--chrome"
  tmux send-keys -t "$TMUX_NAME" "claude --resume $LATEST_UUID $FORK_FLAG $CHROME_FLAG --dangerously-skip-permissions --remote-control $RC_NAME" Enter
  # Auto-answer the resume-summary menu (option 1, pre-selected) when it appears.
  for _ in $(seq 1 30); do
    sleep 2
    pane=$(tmux capture-pane -p -t "$TMUX_NAME" 2>/dev/null || true)
    if printf '%s' "$pane" | grep -q "No conversation found"; then
      echo ">> resume-agent: claude could not load $LATEST_UUID from $CHAT_CWD" >&2
      tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
      exit 1
    fi
    if printf '%s' "$pane" | grep -q "Resume from summary"; then
      # Menu order: 1. Resume from summary (highlighted)  2. Resume full session as-is.
      # Chat defaults to FULL (a summary resume compresses away the drafts/details a
      # chat exists to continue); --summary keeps the cheaper compact resume.
      if $SUMMARY; then
        tmux send-keys -t "$TMUX_NAME" Enter
      else
        tmux send-keys -t "$TMUX_NAME" Down
        sleep 1
        tmux send-keys -t "$TMUX_NAME" Enter
      fi
      break
    fi
    printf '%s' "$pane" | grep -qE '(^|\s)/rc(\s|$)|bypass permissions on' && break
  done
  # Lineage registry (forward-only): record the fork's new transcript uuid so
  # session-index.sh can classify it as a chat fork and demote its inherited
  # content-search hits. In-place resumes create no new transcript — skip.
  if ! $IN_PLACE; then
    NEW_JSONL=""
    for _ in 1 2 3 4 5; do
      NEW_JSONL=$(comm -13 <(printf '%s\n' $BEFORE_LIST | sort) <(ls "$PROJ_DIR"/*.jsonl 2>/dev/null | sort) | head -1)
      [[ -n "$NEW_JSONL" ]] && break
      sleep 2
    done
    if [[ -n "$NEW_JSONL" ]]; then
      CHILD=$(basename "$NEW_JSONL" .jsonl)
      mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
      printf '{"child":"%s","parent":"%s","created":"%s","slug":"chat-%s"}\n' \
        "$CHILD" "$LATEST_UUID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SLUG" \
        >> "${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/chat-forks.jsonl"
      echo ">> resume-agent: lineage recorded ($CHILD <- $LATEST_UUID)" >&2
    else
      echo ">> resume-agent: WARNING could not detect the fork's transcript uuid; lineage not recorded" >&2
    fi
  fi
  MODE_DESC="fork of"; $IN_PLACE && MODE_DESC="continuing"
  echo ">> resume-agent: chat session up — tmux: $TMUX_NAME | remote: $RC_NAME | $MODE_DESC $LATEST_UUID"
  exit 0
fi

echo ">> resume-agent: resuming $LATEST_UUID (--dangerously-skip-permissions)"
exec claude --dangerously-skip-permissions --resume "$LATEST_UUID"
