#!/usr/bin/env bash
# pin-agent-login.sh: pin a gui checkout's YOLO auto-login to the roster's
# default role (the `agent` account) and set its agent test mode
# (`AGENT_TEST_MODE` in config.json: no post-login modals, no notification
# cards, no LogBox warning toast). Workspace init does this for a worktree;
# a run that drives an app built from a checkout it did not initialize (a
# Task-shape run on the primary checkout) calls this before its first drive
# (references/drive.md `agent-account-first`).
#
# Usage: pin-agent-login.sh [--check] [--agent-test-mode on|off] [<gui-checkout>]
#   <gui-checkout>      default: $PWD
#   --check             report only; change nothing
#   --agent-test-mode   default on. `off` is for a run whose change is on a
#                       surface the mode hides; pass it to every pin and
#                       check of that run.
#
# YOLO_* lives in config.json on develop and env.json on older branches; both
# are handled when present. AGENT_TEST_MODE goes in config.json only, and a
# branch whose src/configKeysSchema.ts lacks the key ignores it. The app reads
# these at bundle time: after a pin run `metro-fresh.sh --file config.json`,
# then relaunch (YOLO auto-login signs in).
#
# Output: one line per file, `<file>: <username> (<role>)|unpinned|<username>
# (not-a-roster-account)`, with ` agent-test-mode=on|off` on the config.json
# line, then `PINNED=<username> (<role>) agent-test-mode=on|off` or
# `CHECK=ok|drift`.
# Exit: 0 = pinned to the default role with the asked test mode (or --check
#           found it so)
#       1 = --check found a file unpinned or on another account, or
#           config.json on the other test mode
#       2 = usage error, roster missing, or no config file in the checkout
set -euo pipefail

CHECK=false
TEST_MODE=on
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=true ;;
    --agent-test-mode)
      TEST_MODE="${2:-}"
      case "$TEST_MODE" in
        on|off) shift ;;
        *) echo "pin-agent-login: --agent-test-mode takes on or off" >&2; exit 2 ;;
      esac ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "pin-agent-login: unknown flag $1" >&2; exit 2 ;;
    *) DIR="$1" ;;
  esac
  shift
done
DIR="${DIR:-$PWD}"
ROSTER="$HOME/.config/edge-secrets/test-accounts.json"
[ -f "$ROSTER" ] || { echo "pin-agent-login: roster not found at $ROSTER" >&2; exit 2; }
[ -d "$DIR" ] || { echo "pin-agent-login: no such checkout: $DIR" >&2; exit 2; }

exec node -e '
const fs = require("fs")
const path = require("path")
const [dir, rosterPath, check, testMode] = process.argv.slice(1)
const wantMode = testMode === "on"
const modeLabel = on => " agent-test-mode=" + (on ? "on" : "off")
const roster = JSON.parse(fs.readFileSync(rosterPath, "utf8"))
const role = roster.defaultRole
const acct = roster.roster[role]
if (acct == null) { console.error("pin-agent-login: roster has no default role"); process.exit(2) }
const roleOf = name => {
  if (name == null || name === "") return "unpinned"
  const hit = Object.keys(roster.roster).find(r => roster.roster[r].username === name)
  return hit == null ? "not-a-roster-account" : hit
}
const show = name => (name == null || name === "" ? "unpinned" : name + " (" + roleOf(name) + ")")
const files = ["config.json", "env.json"].filter(f => fs.existsSync(path.join(dir, f)))
if (files.length === 0) { console.error("pin-agent-login: no config.json or env.json in " + dir); process.exit(2) }
let drift = false
for (const f of files) {
  const p = path.join(dir, f)
  const env = JSON.parse(fs.readFileSync(p, "utf8"))
  const beforeName = env.YOLO_USERNAME
  const before = roleOf(beforeName)
  const hasMode = f === "config.json"
  const beforeMode = env.AGENT_TEST_MODE === true
  if (check === "true") {
    console.log(f + ": " + show(env.YOLO_USERNAME) + (hasMode ? modeLabel(beforeMode) : ""))
    if (before !== role || (hasMode && beforeMode !== wantMode)) drift = true
    continue
  }
  env.YOLO_USERNAME = acct.username
  env.YOLO_PIN = acct.pin
  if (hasMode) env.AGENT_TEST_MODE = wantMode
  fs.writeFileSync(p, JSON.stringify(env, null, 2) + "\n")
  console.log(f + ": " + show(beforeName) + " -> " + show(acct.username) + (hasMode ? modeLabel(wantMode) : ""))
}
if (check === "true") { console.log("CHECK=" + (drift ? "drift" : "ok")); process.exit(drift ? 1 : 0) }
console.log("PINNED=" + show(acct.username) + modeLabel(wantMode))
' "$DIR" "$ROSTER" "$CHECK" "$TEST_MODE"
