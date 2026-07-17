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
#   resume-agent.sh --list          # list candidates; do not resume
#   resume-agent.sh <term> --chat   # DISCUSSION MODE: fork the matched transcript into
#                                   # a watchdog-covered tmux session with remote
#                                   # control armed (talk to a past run from anywhere,
#                                   # no slot provisioning, original conversation
#                                   # untouched). Session/RC name: chat-<slug>.
#                                   # Resumes FULL-FIDELITY by default: chat exists to
#                                   # continue the conversation's details (drafts, exact
#                                   # wording), which a summary resume compresses away.
#                                   # Pass --summary to opt into the cheaper compact
#                                   # resume. (Orch resumes are separate: resume-task/
#                                   # spawn-test-session keep the summary default.)
#   resume-agent.sh <term> --latest # skip the ambiguity guard: silently take the
#                                   # newest transcript among multi-task matches
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
RECOVER=false
CHAT=false
LATEST=false
SUMMARY=false
TERM=""
for arg in "$@"; do
  case "$arg" in
    --list) DO_LIST=true ;;
    --recover) RECOVER=true ;;
    --chat) CHAT=true ;;
    --latest) LATEST=true ;;
    --summary) SUMMARY=true ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *) TERM="${TERM:+$TERM }$arg" ;;   # multi-word terms accumulate
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

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "No watcher-spawned sessions found in ~/.claude/projects/${ENC_GIT_PREFIX}*" >&2
  exit 1
fi

first_gid_of() { head -c 16384 "$1" | grep -oE 'app\.asana\.com[A-Za-z0-9/._-]*' | head -1 | grep -oE '[0-9]{12,}' | tail -1 || true; }

# Optionally filter by search term(s): every word must match, case-insensitively,
# against the session's TASK IDENTITY — its gid + its Asana task NAME (fetched in
# ONE batch call for the whole agent project). Transcript-body matching is
# deliberately avoided: a generic word ("swap") appears in nearly every transcript,
# which made ambiguous matches resolve to an unrelated session; and the transcript
# HEAD carries only the task URL, never the name. Falls back to head-region
# matching only if the Asana lookup is unavailable.
if [[ -n "$TERM" ]]; then
  GID_NAMES=""
  cred="$DIR/credentials.json"; cfg="$DIR/asana-config.json"
  token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$cred" 2>/dev/null)}"
  proj=$(jq -r '.project_gid // empty' "$cfg" 2>/dev/null)
  if [[ -n "$token" && -n "$proj" ]]; then
    GID_NAMES=$(curl -sf --max-time 20 "https://app.asana.com/api/1.0/projects/$proj/tasks?opt_fields=name&limit=100" \
      -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.data[] | .gid + "\t" + .name' 2>/dev/null || true)
  fi
  identity_of() { # $1=file → "gid<space>task name" (falls back to head region)
    local g; g=$(first_gid_of "$1")
    local nm=""
    [[ -n "$GID_NAMES" && -n "$g" ]] && nm=$(printf '%s\n' "$GID_NAMES" | awk -F'\t' -v g="$g" '$1==g {print $2; exit}')
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

# Sort by mtime desc; emit one line per candidate with timestamp + UUID + first prompt preview.
emit_candidates() {
  for f in "${CANDIDATES[@]}"; do
    mtime=$(stat -f "%m" "$f")
    uuid=$(basename "$f" .jsonl)
    # Find the first user `/one-shot ...` line and pull a short preview of the prompt.
    # `grep -m1` closes the pipe early; head/sed upstream die SIGPIPE (141), which
    # `set -eo pipefail` turns into a silent abort mid-listing. Absorb it.
    preview=$( (head -30 "$f" | grep -m1 '"/one-shot --yolo' | sed -E 's/.*"(\/one-shot --yolo [^"]{0,80})[^"]*".*/\1/' | head -c 100) 2>/dev/null || true)
    printf "%s\t%s\t%s\n" "$mtime" "$uuid" "$preview"
  done | sort -rn
}

if $DO_LIST; then
  echo "Watcher-spawned sessions (newest first):"
  emit_candidates | awk -F'\t' '{
    t=$1; u=$2; p=$3
    cmd="date -r " t " +\"%Y-%m-%d %H:%M:%S\""
    cmd | getline ts
    close(cmd)
    printf "  %s  %s  %s\n", ts, u, p
  }'
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
  SLUG=$(printf '%s' "${TERM:-latest}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-24)
  TMUX_NAME="claude-asana-chat-${SLUG}"
  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    echo ">> resume-agent: chat session $TMUX_NAME already exists — attach: tmux attach -t $TMUX_NAME (or find 'chat-$SLUG' in your remote session list)" >&2
    exit 0
  fi
  CHAT_CWD="$PWD"   # the cwd resolution above already ran
  tmux new-session -d -s "$TMUX_NAME" -c "$CHAT_CWD"
  tmux send-keys -t "$TMUX_NAME" "claude --resume $LATEST_UUID --fork-session --dangerously-skip-permissions --remote-control chat-$SLUG" Enter
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
  echo ">> resume-agent: chat session up — tmux: $TMUX_NAME | remote: chat-$SLUG | fork of $LATEST_UUID"
  exit 0
fi

echo ">> resume-agent: resuming $LATEST_UUID (--dangerously-skip-permissions)"
exec claude --dangerously-skip-permissions --resume "$LATEST_UUID"
