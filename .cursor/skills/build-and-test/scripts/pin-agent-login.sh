#!/usr/bin/env bash
# pin-agent-login.sh: pin a gui checkout's YOLO auto-login to the roster's
# default role (the `agent` account). Workspace init does this for a worktree;
# a run that drives an app built from a checkout it did not initialize (a
# Task-shape run on the primary checkout) calls this before its first drive
# (references/drive.md `agent-account-first`).
#
# Usage: pin-agent-login.sh [--check] [<gui-checkout>]     (default: $PWD)
#   --check   report only; change nothing
#
# YOLO_* lives in config.json on develop and env.json on older branches; both
# are handled when present. The app reads them at bundle time: after a pin run
# `metro-fresh.sh --file config.json`, then relaunch (YOLO auto-login signs in).
#
# Output: one line per file, `<file>: <role>|unpinned|not-a-roster-account`,
# then `PINNED=<role>` or `CHECK=ok|drift`. Never prints a username or PIN.
# Exit: 0 = pinned to the default role (or --check found it so)
#       1 = --check found a file unpinned or on another account
#       2 = usage error, roster missing, or no config file in the checkout
set -euo pipefail

CHECK=false
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=true ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
const [dir, rosterPath, check] = process.argv.slice(1)
const roster = JSON.parse(fs.readFileSync(rosterPath, "utf8"))
const role = roster.defaultRole
const acct = roster.roster[role]
if (acct == null) { console.error("pin-agent-login: roster has no default role"); process.exit(2) }
const roleOf = name => {
  if (name == null || name === "") return "unpinned"
  const hit = Object.keys(roster.roster).find(r => roster.roster[r].username === name)
  return hit == null ? "not-a-roster-account" : hit
}
const files = ["config.json", "env.json"].filter(f => fs.existsSync(path.join(dir, f)))
if (files.length === 0) { console.error("pin-agent-login: no config.json or env.json in " + dir); process.exit(2) }
let drift = false
for (const f of files) {
  const p = path.join(dir, f)
  const env = JSON.parse(fs.readFileSync(p, "utf8"))
  const before = roleOf(env.YOLO_USERNAME)
  if (check === "true") {
    console.log(f + ": " + before)
    if (before !== role) drift = true
    continue
  }
  env.YOLO_USERNAME = acct.username
  env.YOLO_PIN = acct.pin
  fs.writeFileSync(p, JSON.stringify(env, null, 2) + "\n")
  console.log(f + ": " + before + " -> " + role)
}
if (check === "true") { console.log("CHECK=" + (drift ? "drift" : "ok")); process.exit(drift ? 1 : 0) }
console.log("PINNED=" + role)
' "$DIR" "$ROSTER" "$CHECK"
