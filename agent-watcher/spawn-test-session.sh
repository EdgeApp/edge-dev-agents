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
# Model pin: config .watcher.agent_model forces what spawned sessions START on
# (e.g. claude-opus-4-8[1m] = Opus 4.8 with 1M context). Empty/absent = the
# server-side default alias. Quoted in the invoke — [1m] is a glob class.
AGENT_MODEL="$(jq -r '.watcher.agent_model // empty' "$HOME/.config/agent-watcher/asana-config.json" 2>/dev/null)"
MODEL_FLAG=""
[[ -n "$AGENT_MODEL" ]] && MODEL_FLAG="--model \"$AGENT_MODEL\" "
if [[ -n "$RESUME_ID" ]]; then
  # RESUME MODE: re-attach an existing claude session instead of starting fresh.
  # No initial prompt — the restored conversation IS the state. Composes with slot
  # mode, so the resumed session inherits AGENT_SIM_UDID/AGENT_METRO_PORT (the env a
  # bare `claude --resume` would lack). CWD must match the session's original launch
  # dir for --resume to resolve it; slot mode already sets CWD from --worktree-path
  # (the watcher passes ~/git), which is where orch sessions launch.
  CLAUDE_INVOKE="claude ${YOLO_FLAG}${CHROME_FLAG}${MCP_FLAG}${MODEL_FLAG}--rc --resume $RESUME_ID"
else
  CLAUDE_INVOKE="claude ${YOLO_FLAG}${CHROME_FLAG}${MCP_FLAG}${MODEL_FLAG}--rc \"$ESC_PROMPT\""
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

echo "Spawned tmux session: $SESSION${YOLO:+ (yolo)}"
if [[ -n "$SLOT_INDEX" ]]; then
  echo "  slot $SLOT_INDEX  |  cwd $CWD  |  sim ${SIM_UDID:-none}  |  metro ${METRO_PORT:-8081}"
fi
echo "  Attach locally: tmux attach -t $SESSION"
echo "  Kill session:   tmux kill-session -t $SESSION"
echo "  (inner cmd:     $TMPSCRIPT)"
