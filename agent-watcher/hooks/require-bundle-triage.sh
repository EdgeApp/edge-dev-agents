#!/usr/bin/env bash
# require-bundle-triage.sh — PreToolUse(Bash).
# The "my edit isn't applying" tell lives in prose (which hooks can't see), but
# the flail that follows it is command-shaped. Two gates:
#
# 1. HARD DENY hand-written RCT_jsLocation pins (`defaults write ... RCT_jsLocation`).
#    Packager pinning is OWNED by ios-rn-build.sh's cached-launch path (which pins
#    + terminates + relaunches so the pin actually takes). A mid-debug hand pin is
#    how the 2026-07-22 swapter run wedged rendering and lost ~2h. Reads are fine.
#
# 2. Cache-escalation moves (`--reset-cache`, metro-cache dir nukes) require a
#    FRESH bundle-ownership.sh triage (marker < 15 min). A cache nuke cannot fix
#    a wrong-port fetch — ownership is the first question, and the triage answers
#    it deterministically in one call.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Gate 1: RCT_jsLocation WRITES (never reads/deletes; delete restores default).
if printf '%s' "$CMD" | grep -qE 'defaults[[:space:]]+write[^|;&]*RCT_jsLocation'; then
  echo "BLOCKED: never hand-write RCT_jsLocation. Packager pinning is owned by ios-rn-build.sh (cached-launch pins + terminates + relaunches so it takes effect). If the app is loading the wrong bundle, run ~/.config/agent-watcher/bundle-ownership.sh --udid <udid> --worktree <your-repo-worktree> — its verdict names the squatter or the missing Metro and the fix is to own the port the app already reads, not to redirect the app." >&2
  exit 2
fi

# Gate 2: cache escalations need a fresh triage marker.
if printf '%s' "$CMD" | grep -qE -- '--reset-cache|rm[[:space:]]+-r?[rf]+[^|;&]*(metro-cache|metro-[*]|/metro-)'; then
  MARKER="/tmp/agent-bundle-triage-$AGENT_TASK_GID.json"
  FRESH=0
  if [ -f "$MARKER" ]; then
    TS=$(jq -r '.ts // empty' "$MARKER" 2>/dev/null || true)
    if [ -n "$TS" ]; then
      AGE=$(( $(date +%s) - $(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s 2>/dev/null || echo 0) ))
      [ "$AGE" -ge 0 ] && [ "$AGE" -lt 900 ] && FRESH=1
    fi
  fi
  if [ "$FRESH" != 1 ]; then
    echo "BLOCKED: cache-reset is an ESCALATION, and 'my edit isn't applying' is an ownership question before it is a cache question. Run ~/.config/agent-watcher/bundle-ownership.sh --udid <udid> --worktree <your-repo-worktree> first (marker must be <15 min old): MISMATCH/NO_METRO verdicts mean a cache nuke cannot help — fix port ownership per the remedy it prints. Only an OK verdict makes cache/reload escalation meaningful." >&2
    exit 2
  fi
fi
exit 0
