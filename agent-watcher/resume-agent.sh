#!/usr/bin/env bash
# resume-agent.sh — Find and resume a watcher-spawned claude session.
#
# Watcher-spawned sessions have a unique signature:
#   (a) project dir is enc(~/git) — e.g. -Users-<user>-git (cwd was ~/git when spawned)
#   (b) the first user message starts with `/one-shot --yolo`
# Filtering on both excludes other claude sessions (this desktop app's history,
# ad-hoc terminal sessions, etc.) that may incidentally mention the same term.
#
# For a FRESH discussion session (no transcript to fork) use
# spawn-chat-session.sh --name <slug> --brief-file <path>; it hands the session
# a short pointer to the brief file instead of pasting a long prompt.
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

# Candidate discovery, head facts (task gid, prompt preview), Asana task names,
# term matching and the --list rendering all live in lib/transcript-list.js
# (heads cached by lib/transcript-heads.js, names by lib/task-names.js). A
# candidate is an orch-run transcript under ~/.claude/projects/<enc(~/git)>*;
# listings add prompt-spawned sessions; --uuid selects one transcript anywhere.
LIST_JS="$DIR/lib/transcript-list.js"
if $DO_LIST; then
  LIST_ARGS=(--list)
  $PORCELAIN && LIST_ARGS+=(--porcelain)
  [[ -n "$TERM" ]] && LIST_ARGS+=(--term "$TERM")
  [[ -n "$UUID" ]] && LIST_ARGS+=(--uuid "$UUID")
  exec node "$LIST_JS" "${LIST_ARGS[@]}"
fi

# Prompt-spawned sessions (spawn-chat-session.sh) carry no /one-shot signature;
# lib/chat-spawns.js's registry names them. SPAWN_REG rows:
# uuid \t rc \t anchor(true|false) \t chrome(true|false), later lines win.
SPAWN_REGISTRY="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/chat-spawns.jsonl"
SPAWN_REG=$(jq -r 'select(.uuid) | [.uuid, (.rc // ""), ((.anchor // false) | tostring), ((.chrome // false) | tostring)] | @tsv' "$SPAWN_REGISTRY" 2>/dev/null || true)
spawn_field() { # $1=uuid $2=column (2=rc 3=anchor 4=chrome) -> value ("" when unregistered)
  [[ -n "$SPAWN_REG" ]] || return 0
  printf '%s\n' "$SPAWN_REG" | awk -F'\t' -v u="$1" -v c="$2" '$1==u {v=$c} END {printf "%s", v}'
}

# --uuid: exact selection replaces the candidate machinery entirely (any project
# dir, any kind — chat forks and interactive transcripts carry no /one-shot
# signature and are invisible to the matcher; the /resume-session skill
# resolves them via session-index.sh and passes the uuid here).
CANDIDATES=()
if [[ -n "$UUID" ]]; then
  shopt -s nullglob
  for f in "$HOME/.claude/projects"/*/"$UUID.jsonl"; do CANDIDATES+=("$f"); done
  shopt -u nullglob
  [[ ${#CANDIDATES[@]} -gt 0 ]] || { echo ">> resume-agent: no transcript found for uuid $UUID" >&2; exit 1; }
  UUID_TERM="$TERM"   # a term given alongside --uuid still names the chat (e.g. resurrecting a reaped chat-<slug>)
  TERM=""   # bypass term filtering and the ambiguity guard
  LATEST_UUID="$UUID"
else
  # Rows, newest first: path \t mtime \t uuid \t gid \t preview ("-" = empty).
  # Term matching is on task identity (gid + Asana name), never the body.
  CAND_TSV=$(node "$LIST_JS" --candidates ${TERM:+--term "$TERM"}) || exit 1
  while IFS=$'\t' read -r p _; do [[ -n "$p" ]] && CANDIDATES+=("$p"); done <<<"$CAND_TSV"
  LATEST_UUID=$(printf '%s\n' "$CAND_TSV" | head -1 | cut -f3)

  # Ambiguity guard: if the surviving candidates span MORE THAN ONE task (by the
  # head gid), listing beats guessing — a silent newest-mtime pick resumes an
  # unrelated run. Fork chains of one task still auto-resolve to newest.
  if [[ -n "$TERM" ]] && ! $LATEST; then
    DISTINCT=$(printf '%s\n' "$CAND_TSV" | cut -f4 | grep -v '^-$' | sort -u | grep -c . || true)
    if [[ "$DISTINCT" -gt 1 ]]; then
      echo "Ambiguous: '$TERM' matches sessions of $DISTINCT different tasks. Narrow the term, or pass --latest:" >&2
      while IFS=$'\t' read -r _ mtime uuid gid _; do
        [[ "$gid" == "-" ]] && gid=""
        printf "  %s  gid=%s  %s\n" "$(date -r "$mtime" '+%m-%d %H:%M')" "$gid" "$uuid" >&2
      done <<<"$CAND_TSV"
      exit 1
    fi
  fi
fi

if $RECOVER && [[ -n "$TERM" ]]; then
  recover_slot "$TERM"
fi

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
  # resolve the task name (transcript-list --task-name: 6h disk cache, then
  # Asana, "" when offline) and slug from that. Any resolution failure falls back to the uuid
  # — a spawn never blocks on Asana. Fork transcripts inherit the parent's
  # history head, so a fork-of-a-run still resolves its task gid.
  SLUG_SRC="${TERM:-${UUID_TERM:-}}"
  # A registered spawn comes back under the name it was spawned with (anchor
  # shape included) and continues its own transcript: its only writer is gone,
  # and a fork would leave the name on a child the registry does not know.
  SPAWN_RC=""
  if [[ -n "$UUID" ]]; then SPAWN_RC=$(spawn_field "$UUID" 2); fi
  if [[ -n "$SPAWN_RC" ]]; then
    IN_PLACE=true
    [[ "$(spawn_field "$UUID" 4)" == "true" ]] && CHROME=true
    if [[ "$(spawn_field "$UUID" 3)" == "true" ]]; then
      [[ -n "$ANCHOR_NAME" ]] || ANCHOR_NAME="$SPAWN_RC"
    else
      [[ -n "$SLUG_SRC" ]] || SLUG_SRC="${SPAWN_RC#chat-}"
    fi
  fi
  if [[ -z "$SLUG_SRC" && -n "$UUID" && -n "$LATEST_JSONL" ]]; then
    SLUG_SRC=$(node "$LIST_JS" --task-name "$LATEST_JSONL" 2>/dev/null || true)
  fi
  SLUG=$(printf '%s' "${SLUG_SRC:-${UUID:-latest}}" \
    | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | tr -s '-' | cut -c1-24 | sed 's/-*$//')
  [[ -n "$SLUG" ]] || SLUG=$(printf '%s' "${UUID:-latest}" | cut -c1-24)
  RC_NAME="chat-${SLUG}"
  TMUX_NAME="claude-asana-chat-${SLUG}"
  if [[ -n "$ANCHOR_NAME" ]]; then
    RC_NAME="$ANCHOR_NAME"
    TMUX_NAME="claude-asana-${ANCHOR_NAME}"
  elif [[ -n "$SPAWN_RC" && -z "${TERM:-${UUID_TERM:-}}" ]]; then
    # Verbatim, not re-slugged: the 24-char slug cut would rename a longer spawn.
    RC_NAME="$SPAWN_RC"
    TMUX_NAME="claude-asana-${SPAWN_RC}"
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
  # A registered spawn's pane has no --resume in argv, so the uuid comparison
  # below cannot recognize it; a same-name session IS that spawn (never suffix
  # it into a second claude on one transcript).
  if [[ -z "$ANCHOR_NAME" && -z "$SPAWN_RC" ]] && tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
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
  AC_FLAG="$("$DIR/lib/autocompact-flag.sh")"
  tmux send-keys -t "$TMUX_NAME" "claude --resume $LATEST_UUID $FORK_FLAG $CHROME_FLAG $AC_FLAG --dangerously-skip-permissions --remote-control $RC_NAME" Enter
  # Auto-answer the resume-summary menu (option 1, pre-selected) when it appears.
  for _ in $(seq 1 30); do
    sleep 2
    pane=$(tmux capture-pane -p -t "$TMUX_NAME" 2>/dev/null || true)
    if printf '%s' "$pane" | grep -q "No conversation found"; then
      echo ">> resume-agent: claude could not load $LATEST_UUID from $CHAT_CWD" >&2
      tmux kill-session -t "$TMUX_NAME" 2>/dev/null || true
      exit 1
    fi
    # Claude Code >= 2.1.25x refuses to --resume a transcript that its daemon
    # already holds as a background session (desktop app / `claude attach`
    # model). The refusal lands on the shell prompt, so without this check the
    # spawn "succeeds" with an empty pane (main anchor, 2026-09-01).
    if printf '%s' "$pane" | grep -q "is running as a background session"; then
      SHORT=$(printf '%s' "$LATEST_UUID" | cut -c1-8)
      echo ">> resume-agent: $LATEST_UUID is held by the claude daemon as a background session; run 'claude stop $SHORT' first (or 'claude attach $SHORT' to use it there), then retry" >&2
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
