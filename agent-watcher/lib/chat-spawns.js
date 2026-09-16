// chat-spawns.js — the spawned-session registry: which transcript uuid a
// prompt-spawned chat or anchor (spawn-chat-session.sh) writes to, under which
// tmux and RC name. A prompt-spawned claude has no --resume in its argv and its
// first message is a brief pointer, not /one-shot, so without this record the
// transcript is invisible to resume-agent --list (and the Fleet page) once the
// pane is gone, and a --uuid resume cannot restore the original name.
//
// File: $STATE_DIR/chat-spawns.jsonl, one line per spawn:
//   {"uuid","rc","tmux","anchor":bool,"brief","created"}
// Writers: spawn-chat-session.sh (append on spawn). Readers: resume-agent.sh
// (jq, same file), lib/fleet-model.js, session-watchdog.js.
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const { STATE_DIR } = require('./slots.js')

const FILE = path.join(STATE_DIR, 'chat-spawns.jsonl')

// { byUuid, byRc, byTmux } — latest entry wins for every key.
function load () {
  const byUuid = new Map(); const byRc = new Map(); const byTmux = new Map()
  let text = ''
  try { text = fs.readFileSync(FILE, 'utf8') } catch { return { byUuid, byRc, byTmux } }
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    try {
      const j = JSON.parse(line)
      if (!j.uuid) continue
      byUuid.set(j.uuid, j)
      if (j.rc) byRc.set(j.rc, j)
      if (j.tmux) byTmux.set(j.tmux, j)
    } catch { /* skip bad line */ }
  }
  return { byUuid, byRc, byTmux }
}

// The exact command that brings a reaped spawned session back under its name.
function resumeCommand (entry) {
  return `resume-agent.sh --uuid ${entry.uuid} --chat --in-place`
}

module.exports = { FILE, load, resumeCommand }
