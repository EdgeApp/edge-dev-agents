#!/usr/bin/env bash
# StopFailure hook. The CLI fires StopFailure INSTEAD of Stop when an API error
# (529 overloaded, rate limit, auth failure) ends the turn, so the Stop hook
# (require-continuation-or-block.sh), which is what keeps a --yolo run going, never
# sees that stop. The run then sits at an empty composer with agent_status on a
# phase status until a human or the idle reaper finds it.
#
# StopFailure output and exit codes are ignored, so this hook cannot make the run
# continue. It records the stop in /tmp/agent-apierror-<gid>.json and the watchdog
# (session-watchdog.js, resumeAfterApiError) sends the resume prompt once the pane
# has settled, backing off as `count` grows and escalating to the operator past its
# cap. A normal Stop proves the API is back: require-continuation-or-block.sh
# deletes the marker.
#
# Marker: {"type":"quota"|"api","resets_at":ms|null,"first_at":ms,"last_at":ms,"count":n,
# "error":"...","pinged_at":null}.
# `count` accumulates across consecutive API-error stops (a resume that hits the
# same outage again); `pinged_at` is cleared on every new error so the watchdog
# knows the previous ping was answered and failed again.
#
# Scope: no-op unless AGENT_TASK_GID is a numeric task gid (orch runs only) and
# this is not a headless `claude -p` child spawned by a script.
set -euo pipefail

GID="${AGENT_TASK_GID:-}"
[[ "$GID" =~ ^[0-9]+$ ]] || exit 0
source "$HOME/.config/agent-watcher/hooks/lib/headless-child.sh"
if headless_child; then exit 0; fi

INPUT=$(cat || true)
MARKER="/tmp/agent-apierror-$GID.json"

# Quota or outage? A subscription limit (5h or 7d window at 100%) ends the turn with an error
# too, but retrying on a backoff is pointless until the window resets. claude-usage.sh says
# whether a window is locked and until when; the watchdog then pings once after that reset
# instead of backing off (session-watchdog.js resumeAfterApiError). Unknown usage -> "api".
USAGE_JSON=$("$HOME/.cursor/skills/claude-usage/scripts/claude-usage.sh" --max-age 30 2>/dev/null || true)

INPUT="$INPUT" MARKER="$MARKER" USAGE_JSON="$USAGE_JSON" exec node -e '
const fs = require("fs")
const marker = process.env.MARKER
let input = {}
try { input = JSON.parse(process.env.INPUT || "{}") } catch {}
let prev = null
try { prev = JSON.parse(fs.readFileSync(marker, "utf8")) } catch {}
const now = Date.now()
let usage = null
try { usage = JSON.parse(process.env.USAGE_JSON || "null") } catch {}
const quota = !!(usage && usage.ok && usage.locked && usage.locked_until)
const next = {
  type: quota ? "quota" : "api",
  resets_at: quota ? Date.parse(usage.locked_until) : null,
  first_at: prev?.first_at ?? now,
  last_at: now,
  count: (prev?.count ?? 0) + 1,
  error: String(input.error ?? "unknown"),
  pinged_at: null,
  escalated: prev?.escalated ?? false,
}
fs.writeFileSync(marker, JSON.stringify(next))
'
