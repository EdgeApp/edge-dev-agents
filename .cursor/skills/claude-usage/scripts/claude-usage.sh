#!/usr/bin/env bash
# claude-usage.sh: read the Claude subscription's usage windows (5-hour session, 7-day weekly,
# per-model weekly) from GET https://api.anthropic.com/api/oauth/usage, authenticated with the
# OAuth access token Claude Code already stores (macOS Keychain "Claude Code-credentials", else
# ~/.claude/.credentials.json).
#
# READ-ONLY ON CREDENTIALS. The script never refreshes the token. Refresh tokens rotate: a refresh
# done here would hand every running Claude Code session a dead refresh token unless the new pair
# were written back exactly as Claude Code writes it. A stale access token therefore yields
# error=token_stale (exit 1). --wake is the only recovery path: it runs one tiny headless
# `claude -p` so Claude Code performs its own refresh and Keychain write, then retries once.
# Agent callers never need --wake (their own session refreshed the token seconds earlier);
# launchd callers (agent-watcher, site-orch) pass it because an idle box has nobody refreshing.
#
# The token is read and sent inside Node, so it never reaches argv, `ps`, or stdout.
#
# SHARED STATE: every successful fetch writes the compact summary to $CLAUDE_USAGE_STATE
# (default /tmp/claude-usage-state.json) atomically. Both orchestrators read it; any caller
# within --max-age seconds (default 60) reuses it instead of hitting the endpoint.
#
# Usage:
#   claude-usage.sh [--max-age S] [--wake]       compact JSON summary (cached if fresh)
#   claude-usage.sh --raw [--wake]                full endpoint response (always fetches)
#   claude-usage.sh --cached                      state file only, never fetches
#   claude-usage.sh check [--five-hour N] [--seven-day N] [--max-age S] [--wake]
#                                                 exit 0 under every given threshold, 3 over one
#
# Compact summary: {"ok":true,"fetched_at":"<iso>","five_hour":{"pct":8,"resets_at":"<iso>",
#   "resets_epoch":N},"seven_day":{...},"scoped":[{"model":"Fable","pct":38,"resets_at":...}],
#   "locked":false,"locked_until":null}
# locked=true when any window is at 100% or carries a locked_reason; locked_until is the latest
# reset among the locked windows (the moment new requests succeed again).
#
# Exit codes: 0 ok (check: under thresholds), 1 error (JSON {"ok":false,"error":...} on stdout),
# 2 usage error, 3 check: a threshold is met or exceeded (one-line JSON reason on stdout).
set -euo pipefail

MODE=summary MAX_AGE=60 WAKE=0 FIVE="" SEVEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    check) MODE=check ;;
    --raw) MODE=raw ;;
    --cached) MODE=cached ;;
    --wake) WAKE=1 ;;
    --max-age) MAX_AGE="$2"; shift ;;
    --five-hour) FIVE="$2"; shift ;;
    --seven-day) SEVEN="$2"; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "claude-usage.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

STATE="${CLAUDE_USAGE_STATE:-/tmp/claude-usage-state.json}"

MODE="$MODE" MAX_AGE="$MAX_AGE" WAKE="$WAKE" FIVE="$FIVE" SEVEN="$SEVEN" STATE="$STATE" exec node -e '
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process")
const { MODE, MAX_AGE, WAKE, FIVE, SEVEN, STATE } = process.env

function out(obj, code) { process.stdout.write(JSON.stringify(obj) + "\n"); process.exit(code) }
function fail(error, detail) { out({ ok: false, error, ...(detail ? { detail } : {}) }, 1) }

function readToken() {
  let raw = null
  if (process.platform === "darwin") {
    try { raw = cp.execFileSync("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }) } catch {}
  }
  if (!raw) { try { raw = fs.readFileSync(path.join(os.homedir(), ".claude", ".credentials.json"), "utf8") } catch {} }
  if (!raw) return null
  try { return JSON.parse(raw).claudeAiOauth?.accessToken || null } catch { return null }
}

async function fetchUsage() {
  const token = readToken()
  if (!token) return { error: "no_credentials" }
  let res
  try {
    res = await fetch("https://api.anthropic.com/api/oauth/usage", {
      headers: { Authorization: "Bearer " + token, "anthropic-beta": "oauth-2025-04-20" },
      signal: AbortSignal.timeout(15000),
    })
  } catch (e) { return { error: "network", detail: String(e.message || e) } }
  if (res.status === 401) return { error: "token_stale" }
  if (!res.ok) return { error: "http_" + res.status }
  try { return { data: await res.json() } } catch { return { error: "bad_json" } }
}

// Nudge Claude Code into its own token refresh. Orch env vars are stripped so no orch hook
// treats this child as a task session.
function wake() {
  const env = { ...process.env }
  for (const k of Object.keys(env)) if (k === "AGENT_TASK_GID" || k.startsWith("ORCH_")) delete env[k]
  try {
    cp.execFileSync("claude", ["-p", "ok", "--model", "haiku", "--max-turns", "1"], { cwd: os.tmpdir(), env, stdio: "ignore", timeout: 90000 })
  } catch {}
}

async function fetchWithWake() {
  let r = await fetchUsage()
  if (r.error === "token_stale" && WAKE === "1") { wake(); r = await fetchUsage() }
  return r
}

function win(w) {
  if (!w || typeof w.utilization !== "number") return null
  const epoch = w.resets_at ? Math.floor(Date.parse(w.resets_at) / 1000) : null
  return { pct: Math.round(w.utilization), resets_at: w.resets_at || null, resets_epoch: epoch, locked: w.utilization >= 100 || !!w.locked_reason }
}

function summarize(d) {
  const five = win(d.five_hour), seven = win(d.seven_day)
  const scoped = (d.limits || []).filter(l => l.kind === "weekly_scoped").map(l => ({
    model: l.scope?.model?.display_name || l.scope?.model?.id || "unknown",
    pct: l.percent, resets_at: l.resets_at || null, locked: l.percent >= 100,
  }))
  const lockedWins = [five, seven].filter(w => w && w.locked)
  const until = lockedWins.map(w => w.resets_at).filter(Boolean).sort().pop() || null
  const strip = w => w && { pct: w.pct, resets_at: w.resets_at, resets_epoch: w.resets_epoch }
  return {
    ok: true, fetched_at: new Date().toISOString(),
    five_hour: strip(five), seven_day: strip(seven), scoped,
    locked: lockedWins.length > 0, locked_until: until,
  }
}

function readState() { try { return JSON.parse(fs.readFileSync(STATE, "utf8")) } catch { return null } }
function writeState(s) {
  const tmp = STATE + "." + process.pid + ".tmp"
  fs.writeFileSync(tmp, JSON.stringify(s) + "\n")
  fs.renameSync(tmp, STATE)
}

async function current() {
  const s = readState()
  if (s && s.ok && Date.now() - Date.parse(s.fetched_at) < Number(MAX_AGE) * 1000) return s
  const r = await fetchWithWake()
  if (r.error) fail(r.error, r.detail)
  const sum = summarize(r.data)
  writeState(sum)
  return sum
}

;(async () => {
  if (MODE === "cached") {
    const s = readState()
    if (!s) fail("no_state")
    out(s, 0)
  }
  if (MODE === "raw") {
    const r = await fetchWithWake()
    if (r.error) fail(r.error, r.detail)
    writeState(summarize(r.data))
    out(r.data, 0)
  }
  const s = await current()
  if (MODE === "check") {
    const over = []
    if (FIVE !== "" && s.five_hour && s.five_hour.pct >= Number(FIVE)) over.push({ window: "five_hour", pct: s.five_hour.pct, threshold: Number(FIVE), resets_at: s.five_hour.resets_at })
    if (SEVEN !== "" && s.seven_day && s.seven_day.pct >= Number(SEVEN)) over.push({ window: "seven_day", pct: s.seven_day.pct, threshold: Number(SEVEN), resets_at: s.seven_day.resets_at })
    if (over.length) out({ over: true, windows: over }, 3)
    out({ over: false, five_hour: s.five_hour?.pct, seven_day: s.seven_day?.pct }, 0)
  }
  out(s, 0)
})()
'
