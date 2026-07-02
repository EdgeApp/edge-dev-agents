#!/usr/bin/env bash
# spawn-test-session.sh — Start a tmux session running `claude --rc`, matching the
# spawn pattern the watchdog expects (pane survives claude exit via `exec bash`).
#
# TWO MODES:
#
# 1. SLOT MODE (parallel agent lane) — triggered by --slot-index:
#      spawn-test-session.sh --yolo --slot-index <N> --task-gid <gid> \
#        --sim-udid <udid> --metro-port <port> --worktree-path <path> --label "<rc-label>"
#    The wrapper bash exports $AGENT_SIM_UDID and $AGENT_METRO_PORT so build-and-test
#    and debugger scripts inherit the slot's sim + Metro port transparently, and cwd
#    is the slot's worktree (NOT ~/git). Session is named claude-asana-<task-gid>.
#    The watcher (not this script) sends the /one-shot prompt once RC is ready.
#
# 2. LEGACY MODE (manual smoke tests) — when --slot-index is omitted:
#      spawn-test-session.sh [--yolo] [session-id] [initial-prompt]
#    cwd is ~/git, no per-slot env. Preserved so existing manual workflows still work.
#
# --resume <session-id>: re-attach an EXISTING claude session instead of starting
#    fresh (no initial prompt). Compose with SLOT MODE to give the resumed session
#    the slot's sim + Metro env — exactly what a bare `claude --resume` lacks:
#      spawn-test-session.sh --yolo --slot-index <N> --task-gid <gid> \
#        --sim-udid <udid> --metro-port <port> --worktree-path ~/git --resume <session-id>
#    CWD must match the session's original launch dir (orch sessions launch in ~/git).
#
# Exit codes: 0 = session spawned, 1 = error (session exists, missing tooling).

set -euo pipefail

YOLO=false
SLOT_INDEX=""
TASK_GID=""
SIM_UDID=""
METRO_PORT=""
WORKTREE_PATH=""
LABEL=""
RESUME_ID=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yolo|-y)        YOLO=true; shift ;;
    --slot-index)     SLOT_INDEX="$2";    shift 2 ;;
    --task-gid)       TASK_GID="$2";       shift 2 ;;
    --sim-udid)       SIM_UDID="$2";       shift 2 ;;
    --metro-port)     METRO_PORT="$2";     shift 2 ;;
    --worktree-path)  WORKTREE_PATH="$2";  shift 2 ;;
    --label)          LABEL="$2";          shift 2 ;;
    --resume)         RESUME_ID="$2";      shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

command -v tmux  >/dev/null 2>&1 || { echo "tmux not found"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found"; exit 1; }

# ── Resolve mode ──────────────────────────────────────────────────────────────
if [[ -n "$SLOT_INDEX" ]]; then
  # SLOT MODE
  [[ -n "$TASK_GID" && -n "$WORKTREE_PATH" ]] || {
    echo "slot mode requires --task-gid and --worktree-path" >&2; exit 1; }
  ID="$TASK_GID"
  CWD="$WORKTREE_PATH"
  PROMPT="${LABEL:-Asana task $TASK_GID}"
else
  # LEGACY MODE
  ID="${POSITIONAL[0]:-test-mvp}"
  PROMPT="${POSITIONAL[1]:-MVP test session. Reply "ack" so I can see this from mobile, then wait for further instructions.}"
  CWD="$HOME/git"
fi

SESSION="claude-asana-${ID}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists. Attach with: tmux attach -t $SESSION"
  echo "Or kill with: tmux kill-session -t $SESSION"
  exit 1
fi

# Escape the prompt/label for embedding inside a double-quoted bash string.
ESC_PROMPT="${PROMPT//\\/\\\\}"     # backslash
ESC_PROMPT="${ESC_PROMPT//\"/\\\"}" # double quote
ESC_PROMPT="${ESC_PROMPT//\$/\\\$}" # dollar (prevent var expansion in heredoc)
ESC_PROMPT="${ESC_PROMPT//\`/\\\`}" # backtick (prevent command substitution)

YOLO_FLAG=""
[[ "$YOLO" == true ]] && YOLO_FLAG="--dangerously-skip-permissions "
# --chrome enables the "Claude in Chrome" integration so spawned agents can drive the
# Chrome extension (off by default; the agent box must have Chrome + the extension
# running for it to actually connect).
CHROME_FLAG="--chrome "
# Maestro MCP: gives agents interactive sim-driving tools (tap/swipe/hierarchy/
# screenshot) on a PERSISTENT driver — no ~2-min `maestro test` startup per probe.
# Exploration goes through these tools; the repeatable proof run stays a yaml flow.
# Agents must select the device matching $AGENT_SIM_UDID via the MCP device tools.
MCP_FLAG=""
[[ -f "$HOME/.config/agent-watcher/maestro-mcp.json" ]] && \
  MCP_FLAG="--mcp-config $HOME/.config/agent-watcher/maestro-mcp.json "
# Model + effort pin: what spawned sessions START on (a human can still flip a LIVE
# session per-turn via the RC/desktop picker). Resolution order, both flags:
#   1. Per-task Asana custom field (agent_model / agent_effort) if the task selected one.
#   2. Config default (.watcher.agent_model = claude-opus-4-8[1m], .watcher.agent_effort = high).
# Both the fresh-spawn path (asana-watcher) and the follow-up-resume path (resume-task)
# pass --task-gid, so this ONE resolver covers new tasks and follow-ups alike. The
# per-task lookup is best-effort: no token / API error / unset field → config default.
# Model strings carry [1m] (a glob class), so they stay double-quoted in the invoke.
_CONFIG="$HOME/.config/agent-watcher/asana-config.json"
AGENT_MODEL="$(jq -r '.watcher.agent_model // empty' "$_CONFIG" 2>/dev/null)"
AGENT_EFFORT="$(jq -r '.watcher.agent_effort // "high"' "$_CONFIG" 2>/dev/null)"
if [[ -n "$TASK_GID" ]]; then
  _TOK="$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null || true)"
  _MODEL_FGID="$(jq -r '.custom_fields.agent_model.gid // empty' "$_CONFIG" 2>/dev/null || true)"
  _EFFORT_FGID="$(jq -r '.custom_fields.agent_effort.gid // empty' "$_CONFIG" 2>/dev/null || true)"
  if [[ -n "$_TOK" ]]; then
    _CF="$(curl -sS -H "Authorization: Bearer $_TOK" \
      "https://app.asana.com/api/1.0/tasks/$TASK_GID?opt_fields=custom_fields.gid,custom_fields.enum_value.name" 2>/dev/null || true)"
    if [[ -n "$_CF" ]]; then
      _MSEL="$(printf '%s' "$_CF" | jq -r --arg g "$_MODEL_FGID" '.data.custom_fields[]? | select(.gid==$g) | .enum_value.name // empty' 2>/dev/null || true)"
      _ESEL="$(printf '%s' "$_CF" | jq -r --arg g "$_EFFORT_FGID" '.data.custom_fields[]? | select(.gid==$g) | .enum_value.name // empty' 2>/dev/null || true)"
      if [[ -n "$_MSEL" ]]; then
        _MMAP="$(jq -r --arg l "$_MSEL" '.custom_fields.agent_model.options[$l].model // empty' "$_CONFIG" 2>/dev/null || true)"
        [[ -n "$_MMAP" ]] && AGENT_MODEL="$_MMAP"
      fi
      # The effort option label IS the CLI value; accept only known levels.
      case "$_ESEL" in low|medium|high|xhigh|max) AGENT_EFFORT="$_ESEL" ;; esac
      echo ">> spawn-test-session: model=${AGENT_MODEL:-default} effort=${AGENT_EFFORT} (task $TASK_GID; model_sel='${_MSEL:-unset}' effort_sel='${_ESEL:-unset}')" >&2
    fi
  fi
fi
MODEL_FLAG=""
[[ -n "$AGENT_MODEL" ]] && MODEL_FLAG="--model \"$AGENT_MODEL\" "
EFFORT_FLAG=""
[[ -n "$AGENT_EFFORT" ]] && EFFORT_FLAG="--effort $AGENT_EFFORT "
if [[ -n "$RESUME_ID" ]]; then
  # RESUME MODE: re-attach an existing claude session instead of starting fresh.
  # No initial prompt — the restored conversation IS the state. Composes with slot
  # mode, so the resumed session inherits AGENT_SIM_UDID/AGENT_METRO_PORT (the env a
  # bare `claude --resume` would lack). CWD must match the session's original launch
  # dir for --resume to resolve it; slot mode already sets CWD from --worktree-path
  # (the watcher passes ~/git), which is where orch sessions launch.
  CLAUDE_INVOKE="claude ${YOLO_FLAG}${CHROME_FLAG}${MCP_FLAG}${MODEL_FLAG}${EFFORT_FLAG}--rc --resume $RESUME_ID"
else
  CLAUDE_INVOKE="claude ${YOLO_FLAG}${CHROME_FLAG}${MCP_FLAG}${MODEL_FLAG}${EFFORT_FLAG}--rc \"$ESC_PROMPT\""
fi

# Build the per-slot env exports (empty in legacy mode).
ENV_EXPORTS=""

# Session hygiene (always, both modes): things the inner `exec bash` shell would
# otherwise lack because it isn't a login shell that sources the full profile.
#   - ASANA_TOKEN: spawned shells didn't get it, so asana-get-context/asana-task-update
#     used to fail on first call; export it from credentials.json up front.
#   - ASANA_GITHUB_SECRET: the Asana↔GitHub widget secret used by asana-task-update
#     --attach-pr. The .zshrc loader only reaches interactive shells, not this exec
#     bash, so export it here too — else agents fall back to a comment, never attach.
#   - LANG: headless shells often have no locale → CocoaPods `pod install` crashes
#     with "Unicode Normalization not appropriate for ASCII-8BIT". Pin UTF-8.
#   - PATH: ensure nvm node + maestro resolve even without an interactive profile.
_AW_CRED="$HOME/.config/agent-watcher/credentials.json"
if [[ -f "$_AW_CRED" ]]; then
  _AW_TOKEN="$(jq -r '.asana_token // empty' "$_AW_CRED" 2>/dev/null)"
  [[ -n "$_AW_TOKEN" ]] && ENV_EXPORTS+="export ASANA_TOKEN=\"$_AW_TOKEN\"
"
  _AW_GHSEC="$(jq -r '.asana_github_secret // empty' "$_AW_CRED" 2>/dev/null)"
  [[ -n "$_AW_GHSEC" ]] && ENV_EXPORTS+="export ASANA_GITHUB_SECRET=\"$_AW_GHSEC\"
"
fi
ENV_EXPORTS+="export LANG=\"\${LANG:-en_US.UTF-8}\"
export PATH=\"\$HOME/.maestro/bin:\$PATH\"
"
# Android SDK: export ANDROID_HOME/ANDROID_SDK_ROOT so an Android-called-out task can
# run `./gradlew :app:assembleDebug` without per-run setup (proposal: 1215776835822945).
# Auto-detect the installed SDK; only export if a real SDK dir exists.
for _AW_SDK in "$HOME/Library/Android/sdk" "/opt/homebrew/share/android-commandlinetools" "/usr/local/share/android-commandlinetools"; do
  if [[ -d "$_AW_SDK/platform-tools" || -d "$_AW_SDK/cmdline-tools" ]]; then
    ENV_EXPORTS+="export ANDROID_HOME=\"$_AW_SDK\"
export ANDROID_SDK_ROOT=\"$_AW_SDK\"
"
    break
  fi
done
# Heap bump for every node process in the agent shell: lint-staged/eslint in the
# (now-working) husky pre-commit hook SIGABRTs on default heap under parallel
# slots (seen on the Wallet/Seed-Import run, 2026-06-10). 8GB per node process is
# comfortable on the 128GB box at 4 concurrent slots.
ENV_EXPORTS+="export NODE_OPTIONS=\"\${NODE_OPTIONS:---max-old-space-size=8192}\"
"
# A stable UUID for this agent run, exported so the agent can stamp it into the
# plan + run-report docs for traceability. Logged here so the watcher records the
# task→session-uuid mapping.
AGENT_SESSION_UUID="$(uuidgen 2>/dev/null || true)"
if [[ -n "$AGENT_SESSION_UUID" ]]; then
  ENV_EXPORTS+="export AGENT_SESSION_UUID=\"$AGENT_SESSION_UUID\"
"
  echo ">> spawn-test-session: agent session uuid $AGENT_SESSION_UUID (task ${TASK_GID:-?})" >&2
fi
if [[ -n "$SLOT_INDEX" ]]; then
  [[ -n "$TASK_GID" ]]   && ENV_EXPORTS+="export AGENT_TASK_GID=\"$TASK_GID\"
"
  [[ -n "$SIM_UDID" ]]   && ENV_EXPORTS+="export AGENT_SIM_UDID=\"$SIM_UDID\"
"
  [[ -n "$METRO_PORT" ]] && ENV_EXPORTS+="export AGENT_METRO_PORT=\"$METRO_PORT\"
"
fi

# Write the inner command to a temp script; tmux execs it directly. The script
# lives in /tmp until macOS cleans it up — `exec bash` never returns, so we cannot
# reliably delete it ourselves without risking a race.
TMPSCRIPT=$(mktemp -t claude-spawn.XXXXXX)
cat > "$TMPSCRIPT" <<EOF
#!/usr/bin/env bash
${ENV_EXPORTS}cd "$CWD"
$CLAUDE_INVOKE
echo "[claude exited at \$(date)]"
exec bash
EOF
chmod +x "$TMPSCRIPT"

tmux new-session -d -s "$SESSION" "bash $TMPSCRIPT"

# RESUME path only: `claude --resume` on a LARGE session (orchestration sessions run
# 400k+ tokens) shows an interactive menu — "Resume from summary (recommended) / Resume
# full session as-is / Don't ask again" — that would WEDGE this headless session at the
# choice (the watcher/operator sees a session with RC up but no progress). Auto-answer it
# by confirming the highlighted default (Enter = "Resume from summary": preserves the
# prior run's context as a compact summary, leaving context headroom for the followup
# work; far cheaper than resuming 400k+ tokens full). Bounded poll; no-op for a fresh
# spawn (no RESUME_ID) where the watcher sends the /one-shot prompt itself.
if [[ -n "$RESUME_ID" ]]; then
  for _ in $(seq 1 30); do
    sleep 2
    _pane="$(tmux capture-pane -t "$SESSION" -p 2>/dev/null || true)"
    if printf '%s' "$_pane" | grep -q "Resume from summary\|Resume full session"; then
      tmux send-keys -t "$SESSION" Enter
      echo ">> spawn-test-session: auto-answered the resume-summary menu (Enter = resume from summary)" >&2
      break
    fi
  done
fi

echo "Spawned tmux session: $SESSION${YOLO:+ (yolo)}"
if [[ -n "$SLOT_INDEX" ]]; then
  echo "  slot $SLOT_INDEX  |  cwd $CWD  |  sim ${SIM_UDID:-none}  |  metro ${METRO_PORT:-8081}"
fi
echo "  Attach locally: tmux attach -t $SESSION"
echo "  Kill session:   tmux kill-session -t $SESSION"
echo "  (inner cmd:     $TMPSCRIPT)"
