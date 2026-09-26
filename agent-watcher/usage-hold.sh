#!/usr/bin/env bash
# usage-hold.sh -- the single oracle for the agent-watcher's Claude-usage gates, and the writer
# of the usage PAUSE stamp. Called once per watcher tick (asana-watcher.js); consumers of the
# stamp only read the file.
#
# Two gates, both configured in asana-config.json `watcher.usage_hold` (feature off when absent):
#   {"spawn": {"five_hour": 85, "seven_day": 85}, "pause": {"seven_day": 85}}
#   spawn  At or over any spawn threshold, the watcher starts no new session; tasks stay Pending.
#   pause  At or over any pause threshold, running orch sessions checkpoint and stop. This
#          writes /tmp/agent-usage-pause.json ({window,pct,threshold,resets_at,since}); under
#          every pause threshold it removes the stamp. `since` survives while the pause holds
#          so the watchdog pings each session once per pause.
# The 5h window only gates spawns: a running session that hits 5h at 100% is stopped by the API
# itself (StopFailure -> hooks/record-api-error-stop.sh marks it type=quota) and resumed by
# session-watchdog.js after the reset. The 7d pause exists to stop BEFORE the API does, leaving
# the operator headroom for interactive sessions.
#
# Stamp consumers (read the file, never re-derive it):
#   session-watchdog.js                  sends <usage-pause> once per session, the resume ping
#                                        when the stamp clears, and exempts paused panes from
#                                        the idle reaper
#   hooks/require-continuation-or-block.sh  allows the stop while the stamp exists
#
# Unknown usage (claude-usage.sh exit 1: stale token, network) fails OPEN for spawns and leaves
# the pause stamp as it was, so a blip neither blocks work nor flaps paused sessions.
#
# Usage: usage-hold.sh      prints {"spawn_hold":bool,"paused":bool,"reason":"..."}; exit 0
set -uo pipefail

CFG="${AGENT_WATCHER_CONFIG:-$HOME/.config/agent-watcher/asana-config.json}"
USAGE="$HOME/.cursor/skills/claude-usage/scripts/claude-usage.sh"
STAMP="${AGENT_USAGE_PAUSE_STAMP:-/tmp/agent-usage-pause.json}"

HOLD="$(jq -c '.watcher.usage_hold // empty' "$CFG" 2>/dev/null)"
if [ -z "$HOLD" ]; then
  rm -f "$STAMP"
  echo '{"spawn_hold":false,"paused":false,"reason":"usage_hold not configured"}'
  exit 0
fi

SUMMARY="$("$USAGE" --wake 2>/dev/null)"; RC=$?

HOLD="$HOLD" SUMMARY="$SUMMARY" RC="$RC" STAMP="$STAMP" exec node -e '
const fs = require("fs")
const hold = JSON.parse(process.env.HOLD)
const stamp = process.env.STAMP
const out = o => { process.stdout.write(JSON.stringify(o) + "\n"); process.exit(0) }
let prev = null
try { prev = JSON.parse(fs.readFileSync(stamp, "utf8")) } catch {}
let s = null
try { s = JSON.parse(process.env.SUMMARY) } catch {}
if (process.env.RC !== "0" || !s || !s.ok) {
  out({ spawn_hold: false, paused: !!prev, reason: "usage unknown (" + (s?.error || "no output") + "); failing open" })
}
const over = (gate) => {
  for (const [key, win] of [["five_hour", "five_hour"], ["seven_day", "seven_day"]]) {
    const t = gate?.[key]
    if (t != null && s[win] && s[win].pct >= t) return { window: win, pct: s[win].pct, threshold: t, resets_at: s[win].resets_at }
  }
  return null
}
const p = over(hold.pause)
if (p) {
  const next = { ...p, since: prev?.since || new Date().toISOString() }
  const tmp = stamp + "." + process.pid
  fs.writeFileSync(tmp, JSON.stringify(next) + "\n"); fs.renameSync(tmp, stamp)
} else if (prev) {
  fs.rmSync(stamp, { force: true })
}
const sp = over(hold.spawn) || p
const fmt = o => o.window + " " + o.pct + "% >= " + o.threshold + "% (resets " + o.resets_at + ")"
out({ spawn_hold: !!sp, paused: !!p, reason: sp ? fmt(sp) : "under thresholds (5h " + s.five_hour?.pct + "%, 7d " + s.seven_day?.pct + "%)" })
'
