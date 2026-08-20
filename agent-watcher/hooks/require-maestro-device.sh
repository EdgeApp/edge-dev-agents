#!/usr/bin/env bash
# require-maestro-device.sh — PreToolUse (Bash + mcp__maestro__* + Write|Edit).
# TARGET-AWARE device gating for maestro drives in slot sessions. The hazard is
# always the same: driving a device other than the one you think (cross-slot
# contention, the daemon re-latch). What "the right device" means depends on
# the TARGET PLATFORM, which this hook classifies per call:
#
#   iOS (slot sim):  CLI drives must pin --device to $AGENT_SIM_UDID and the
#                    sim must be Booted. With concurrent runs multiple sims are
#                    booted and an unpinned driver attaches arbitrarily; a
#                    downed slot sim makes the MCP daemon re-latch onto some
#                    other booted device (the 2026-07-22 swapter wrong-sim
#                    hour). --driver-host-port (METRO+1000) is also required:
#                    parallel slots' iOS drivers contend on the default port.
#   Android:         CLI drives must pin --device to an adb serial that is
#                    ATTACHED (adb get-state == device). The iOS slot sim's
#                    state is irrelevant and the booted guard must NOT fire
#                    (2026-08-20 zano/xmr run: an Android drive was blocked for
#                    an unbooted iOS sim and the run downgraded itself to raw
#                    uiautomator). --driver-host-port is NOT required: it is
#                    iOS-driver isolation (see maestro-mcp-wrapper.sh); Android
#                    drives go through adb. Emulators are not slot-tracked (no
#                    AGENT_ANDROID_SERIAL exists), so "attached" is the
#                    strongest check available.
#   MCP daemon:      maestro-mcp-wrapper.sh launches the daemon with a GLOBAL
#                    --device $AGENT_SIM_UDID, and maestro 2.6 IGNORES the
#                    per-call device_id param. Every MCP call in a slot session
#                    therefore drives the BOUND iOS SIM no matter what
#                    device_id says: a call naming any other device (e.g. an
#                    Android serial) is blocked as targeting a device the
#                    daemon cannot reach — the CLI is the Android path
#                    (`maestro --device <serial> test|hierarchy|studio`).
#                    Calls naming the slot sim (or nothing) get the booted
#                    guard, because a downed bound sim means re-latch.
#
# Scope: no-ops unless AGENT_SIM_UDID is set. Exit 0 allow, exit 2 block.
set -uo pipefail

[ -n "${AGENT_SIM_UDID:-}" ] || exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

IOS_UDID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

# iOS booted guard: the slot sim must be Booted before anything drives it.
booted_guard() {
  xcrun simctl list devices 2>/dev/null | grep "$AGENT_SIM_UDID" | grep -q "(Booted)" && return 0
  echo "BLOCKED: your slot sim $AGENT_SIM_UDID is NOT booted — driving now hits some OTHER booted device (the maestro daemon re-latches when its bound sim goes down; see the 2026-07-22 swapter wrong-sim hour). Boot it first (xcrun simctl boot $AGENT_SIM_UDID && xcrun simctl bootstatus $AGENT_SIM_UDID -b), and if the sim was rebooted after the maestro MCP server started, verify a screenshot against 'xcrun simctl io $AGENT_SIM_UDID screenshot' before trusting MCP output." >&2
  exit 2
}

# Android attached guard: the named serial must be attached and authorized.
android_guard() { # $1 = adb serial
  local state
  state=$(adb -s "$1" get-state 2>/dev/null || echo "absent")
  [ "$state" = "device" ] && return 0
  echo "BLOCKED: Android target '$1' is not attached (adb get-state: $state). Check 'adb devices' for the live serial (an emulator restart changes nothing, but a died emulator or unauthorized physical device shows here), then re-run with the correct --device." >&2
  exit 2
}

case "$TOOL" in
  mcp__maestro__*)
    # The daemon is BOUND to the slot sim; per-call device_id is ignored on
    # this host (wrapper launches with a global --device). A call naming a
    # DIFFERENT device would silently drive the bound sim instead.
    DEVICE_ID=$(printf '%s' "$INPUT" | jq -r '.tool_input.device_id // empty' 2>/dev/null || true)
    if [ -n "$DEVICE_ID" ] && [ "$DEVICE_ID" != "$AGENT_SIM_UDID" ]; then
      echo "BLOCKED: this session's maestro MCP daemon is bound to iOS slot sim $AGENT_SIM_UDID at startup and maestro IGNORES the per-call device_id — this call would drive the bound sim, NOT '$DEVICE_ID'. For a non-slot-sim target (e.g. an Android emulator or physical device) use the maestro CLI, which honors the flag: maestro --device $DEVICE_ID test <flow>  (hierarchy/studio work the same way; screenshots: adb -s $DEVICE_ID exec-out screencap -p)." >&2
      exit 2
    fi
    booted_guard
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac
[ -n "$CMD" ] || exit 0

# Only gate maestro test/record/studio/hierarchy runs (global flags may sit
# between `maestro` and the subcommand); `maestro --help`, mcp, etc. pass.
echo "$CMD_M" | grep -qE '\bmaestro\b[^|;&]*[[:space:]](test|record|studio|hierarchy)([[:space:]]|$)' || exit 0

# Extract the --device/--udid value (first one; comma lists take the first).
DEV=$(printf '%s' "$CMD" | sed -nE 's/.*--(device|udid)[= ]+"?([^" ,]+)"?.*/\2/p' | head -1)

if [ -z "$DEV" ]; then
  echo "BLOCKED: maestro run has no --device. Multiple devices can be live on this host (parallel slot sims, Android emulators, physical devices) and an unpinned run attaches to an arbitrary one — it may drive ANOTHER slot's app. iOS slot work: maestro --device $AGENT_SIM_UDID --driver-host-port \$((AGENT_METRO_PORT + 1000)) test <flow>. Android work: maestro --device <adb-serial> test <flow> (serial from 'adb devices'; no driver port needed). Note the maestro MCP daemon is bound to the iOS slot sim and ignores per-call device_id — the CLI is the only Android path." >&2
  exit 2
fi

if printf '%s' "$DEV" | grep -qE "$IOS_UDID_RE"; then
  # iOS target: must be THIS slot's sim, booted, with a pinned driver port.
  if [ "$DEV" != "$AGENT_SIM_UDID" ]; then
    echo "BLOCKED: --device $DEV is an iOS sim that is NOT this session's slot sim ($AGENT_SIM_UDID) — driving a neighbor slot's sim is the cross-slot contention this gate exists for. Use \$AGENT_SIM_UDID." >&2
    exit 2
  fi
  booted_guard
  if [ -n "${AGENT_METRO_PORT:-}" ] && ! echo "$CMD_M" | grep -q -- '--driver-host-port'; then
    echo "BLOCKED: iOS maestro run is missing --driver-host-port — parallel slots' iOS drivers contend on the default port. Use: maestro --device $AGENT_SIM_UDID --driver-host-port \$((AGENT_METRO_PORT + 1000)) test <flow>." >&2
    exit 2
  fi
else
  # Android target (adb serial): attached is the strongest available check;
  # emulators are not slot-tracked. No booted guard (the iOS sim is not
  # involved) and no --driver-host-port (iOS-driver isolation only).
  android_guard "$DEV"
fi
exit 0
