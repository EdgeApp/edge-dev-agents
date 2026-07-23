#!/usr/bin/env bash
# block-sim-wipe.sh — PreToolUse(Bash).
# `simctl uninstall` deletes the app's DATA container — including the logged-in
# test account, which needs a manual login to re-provision. `simctl erase` wipes
# the whole device. Agents must never run either bare: the 2026-07-21
# wallet-cache run used `uninstall && install` as an install-failure fallback,
# wiped its account, then parked 87 minutes on a destructive-command dialog
# improvising a container restore by hand. Enforcement-over-prose: the sanctioned
# paths are scripts, so this gate never fires on legitimate work.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Match a real invocation (start of command or after ; & | && ||), not the string
# appearing inside a grep/cat/echo of some file or message.
if printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)(xcrun[[:space:]]+)?simctl[[:space:]]+(uninstall|erase)([[:space:]]|$)' \
   && ! printf '%s' "$CMD" | grep -qE '^(grep|rg|cat|sed|awk|echo|printf)[[:space:]]'; then
  cat >&2 <<'MSG'
BLOCKED: `simctl uninstall` deletes the app's data container (the logged-in test
account — not re-provisionable without a manual login), and `simctl erase` wipes
the whole sim. Account-safe alternatives:
  - Upgrade/install a build: in-place `simctl install` preserves the account. If
    it fails ("Could not hardlink copy"), use the escalation script — it retries
    after a sim reboot and only ever uninstalls WITH an automatic account restore:
      ~/.config/agent-watcher/sim-app-reinstall.sh --udid <udid> --app <path/to/Edge.app>
  - Sim already lost its account (app shows onboarding): restore it from the
    master/pool donor:
      ~/.config/agent-watcher/restore-sim-app-container.sh --to <udid>
MSG
  exit 2
fi
exit 0
