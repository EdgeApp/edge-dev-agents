#!/usr/bin/env bash
# nudge-flow-library.sh — PreToolUse(mcp__maestro__run).
# Fires ONCE per run, on the FIRST inline-yaml maestro MCP drive: if that first
# flow does not compose library subflows (no runFlow), block it with the flow
# index so the library is in context AT THE DRIVE MOMENT. Every later call
# passes untouched (marker file), and a first call that already uses runFlow
# passes too. Why: 5 of 8 recent sim sessions never touched the library and two
# re-derived select-swap-pair tap-by-tap inline — the prose rule loses to
# discoverability, so the first drive pays one bounce to load the index.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
MARKER="/tmp/agent-flow-lib-nudged-$AGENT_TASK_GID"
[ -f "$MARKER" ] && exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in mcp__maestro__*) ;; *) exit 0 ;; esac
YAML=$(printf '%s' "$INPUT" | jq -r '.tool_input.yaml // empty' 2>/dev/null || true)
[ -n "$YAML" ] || exit 0

touch "$MARKER"
if printf '%s' "$YAML" | grep -q "runFlow"; then exit 0; fi

cat >&2 <<'MSG'
FIRST DRIVE OF THIS RUN — one-time flow-library check (subsequent calls are not
blocked). Before hand-deriving taps, COMPOSE the parameterized subflows in
~/.cursor/skills/build-and-test/maestro/common/ via runFlow (works inline too):
  login-if-needed.yaml            logged-in account incl. PIN entry
  dismiss-startup-modals.yaml     clear survey/notification/update modals
  select-swap-pair.yaml           Exchange -> wallets -> amount -> quote
                                  (SRC_WALLET, DST_WALLET, FIAT_AMOUNT, PROVIDER)
  confirm-slider.yaml             the confirm slider gesture (SOLVED)
Full index + params: "Flow library" section, sim-testing-playbook.md.
Re-issue this exact call if none of these apply (this gate fires only once);
otherwise re-issue with runFlow composing the relevant subflows.
MSG
exit 2
