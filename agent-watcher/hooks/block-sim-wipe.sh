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
# Jev shadow, log only (lib/jev-shadow.sh): on a raw trigger hit, log execute-vs-quote beside this hook's decision.
. "$HOME/.config/agent-watcher/lib/jev-shadow.sh" 2>/dev/null && jev_shadow_cmd_trap block-sim-wipe "simctl uninstall or simctl erase" 'simctl[[:space:]]+(uninstall|erase)' "$CMD" || true

# The line is read through cmd-parse.sh: a simctl command counts wherever the
# line runs one (behind xcrun and its options, in a loop body, inside `bash -c`
# text) and nowhere the line only names one. The verb is the first argument
# after simctl's own options. When the line cannot be read, the text match the
# hook had before decides.
HOOKS="$HOME/.config/agent-watcher/hooks"
WIPE=no
if RECS=$(printf '%s' "$CMD" | "$HOOKS/cmd-parse.sh" 2>/dev/null); then
  printf '%s' "$RECS" | jq -e -s '
    any(.[]; select(.name == "simctl" and (.opaque | not))
      | .argv[1:] as $a
      | [range(0; $a | length) as $i
          | select(($a[$i] | startswith("-") | not)
                   and ($i == 0 or (($a[$i - 1] == "--set" or $a[$i - 1] == "--profiles") | not)))
          | $a[$i]][0]
      | . == "uninstall" or . == "erase")' >/dev/null 2>&1 && WIPE=yes
else
  CMD_M=$(printf '%s' "$CMD" | "$HOOKS/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
  if printf '%s' "$CMD_M" | grep -qE '(^|[;&|][[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)(xcrun[[:space:]]+)?simctl[[:space:]]+(uninstall|erase)([[:space:]]|$)' \
     && ! printf '%s' "$CMD_M" | grep -qE '^(grep|rg|cat|sed|awk|echo|printf)[[:space:]]'; then
    WIPE=yes
  fi
fi
if [ "$WIPE" = yes ]; then
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
