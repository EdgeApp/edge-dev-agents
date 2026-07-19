#!/usr/bin/env bash
# session-index.sh — one structured inventory of claude sessions: live tmux panes
# AND on-disk transcripts (runs, chat forks, interactive), joined across the four
# identity spaces (Asana task gid/name, transcript uuid, tmux name, RC name).
#
# Consumed by the /resume-session skill; also human-readable with jq.
#
# Usage:
#   session-index.sh                 # full inventory, JSON on stdout
#   session-index.sh --grep <phrase> # only transcripts containing <phrase>, each hit
#                                    # classified authored|echo (a hit inside a compact
#                                    # -summary record is an ECHO of another session's
#                                    # text, not authorship — the trap that mis-resolved
#                                    # the nym-letter session, 2026-07-17)
#
# Output: JSON {generated_at, live: [...], transcripts: [...]}
#   live:        {tmux, kind, rc_name, resume_uuid, created}
#   transcripts: {uuid, project_dir, kind(run|chat|interactive), task_gid, task_name,
#                 fork_parent, mtime, birth, bytes, live_tmux, grep: {authored, echo}}
# Fork lineage comes from $STATE_DIR/chat-forks.jsonl (written by resume-agent --chat
# at fork time; forward-only — pre-registry forks show fork_parent null).
#
# Exit: 0 ok, 1 error, 2 usage.
set -euo pipefail

GREP_PHRASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --grep) GREP_PHRASE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||' >&2; exit 0 ;;
    *) echo "usage: session-index.sh [--grep <phrase>]" >&2; exit 2 ;;
  esac
done

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
export GREP_PHRASE STATE_DIR

# tmux inventory + per-pane claude args (uuid + rc name), TSV to the node joiner.
TMUX_TSV=""
if tmux list-sessions -F '#{session_name}\t#{session_created}' >/dev/null 2>&1; then
  while IFS=$'\t' read -r name created; do
    [ -n "$name" ] || continue
    pid=$(tmux list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
    args=""
    if [ -n "$pid" ]; then
      for c in $(pgrep -P "$pid" 2>/dev/null); do
        a=$(ps -o command= -p "$c" 2>/dev/null || true)
        case "$a" in *claude*) args="$a"; break ;; esac
      done
    fi
    TMUX_TSV="${TMUX_TSV}${name}\t${created}\t${args}\n"
  done < <(tmux list-sessions -F "$(printf '#{session_name}\t#{session_created}')" 2>/dev/null)
fi
export TMUX_TSV

# Bash 3.2 cannot nest a heredoc inside "$(...)"; self-extract the node payload.
NODE_CODE=$(sed -n '/^#__NODE__$/,$p' "$0" | tail -n +2)
exec node -e "$NODE_CODE"
#__NODE__
const fs = require('fs')
const path = require('path')
const os = require('os')
const { execSync } = require('child_process')

const HOME = os.homedir()
const PROJECTS = path.join(HOME, '.claude/projects')
const STATE_DIR = process.env.STATE_DIR
const PHRASE = process.env.GREP_PHRASE || ''
const SENTINEL = 'This session is being continued from a previous conversation'

// fork registry (forward-only)
const forkParent = {}
try {
  for (const line of fs.readFileSync(path.join(STATE_DIR, 'chat-forks.jsonl'), 'utf8').split('\n')) {
    if (!line.trim()) continue
    try { const r = JSON.parse(line); if (r.child) forkParent[r.child] = r.parent || null } catch {}
  }
} catch {}

// live tmux (TSV from bash: name \t created \t claude-args)
const live = []
const liveByUuid = {}
for (const row of (process.env.TMUX_TSV || '').split('\\n')) {
  const [name, created, args] = row.split('\\t')
  if (!name) continue
  const kind = /^claude-asana-chat-/.test(name) ? 'chat'
    : /^claude-asana-\d+$/.test(name) ? 'run'
    : /^done-asana-\d+$/.test(name) ? 'retired'
    : /^claude-/.test(name) ? 'anchor' : 'other'
  const uuid = (args || '').match(/--resume\s+([0-9a-f-]{36})/)?.[1] || null
  const rc = (args || '').match(/--remote-control\s+(\S+)/)?.[1] || null
  live.push({ tmux: name, kind, rc_name: rc, resume_uuid: uuid, created: created ? new Date(Number(created) * 1000).toISOString() : null })
  if (uuid) liveByUuid[uuid] = name
}

// transcripts across ALL project dirs (runs, chat forks, interactive, desktop)
const transcripts = []
let dirs = []
try { dirs = fs.readdirSync(PROJECTS).filter(d => { try { return fs.statSync(path.join(PROJECTS, d)).isDirectory() } catch { return false } }) } catch {}
for (const d of dirs) {
  if (d === 'subagents') continue
  let files = []
  try { files = fs.readdirSync(path.join(PROJECTS, d)).filter(f => f.endsWith('.jsonl')) } catch { continue }
  for (const f of files) {
    const p = path.join(PROJECTS, d, f)
    let st; try { st = fs.statSync(p) } catch { continue }
    const uuid = f.replace(/\.jsonl$/, '')
    // head-based classification (50 lines, bounded read)
    let head = ''
    try {
      const fd = fs.openSync(p, 'r'); const buf = Buffer.alloc(1024 * 1024)
      const n = fs.readSync(fd, buf, 0, buf.length, 0); fs.closeSync(fd)
      head = buf.slice(0, n).toString('utf8').split('\n').slice(0, 50).join('\n')
    } catch {}
    const isRun = head.includes('"/one-shot --yolo')
    const gid = (head.match(/app\.asana\.com[A-Za-z0-9/._-]*/) || [''])[0].match(/[0-9]{12,}/g)?.pop() || null
    const kind = isRun ? 'run' : (uuid in forkParent ? 'chat' : 'interactive')
    const entry = {
      uuid, project_dir: d, kind, task_gid: gid, task_name: null,
      fork_parent: forkParent[uuid] ?? null,
      mtime: st.mtime.toISOString(), birth: (st.birthtime || st.mtime).toISOString(),
      bytes: st.size, live_tmux: liveByUuid[uuid] || null,
    }
    if (PHRASE) {
      // full-file scan, line-classified: echo = hit inside a compact-summary record
      let authored = 0, echo = 0
      try {
        const data = fs.readFileSync(p, 'utf8')
        if (!data.includes(PHRASE)) continue
        for (const line of data.split('\n')) {
          if (!line.includes(PHRASE)) continue
          let rec = null; try { rec = JSON.parse(line) } catch {}
          const isEcho = rec?.type === 'summary' || line.includes(SENTINEL)
          if (isEcho) echo++; else authored++
        }
      } catch { continue }
      if (authored + echo === 0) continue
      entry.grep = { authored, echo }
    }
    transcripts.push(entry)
  }
}

// task names: ONE batch call for the agent project (only gids get names; best-effort)
const gids = new Set(transcripts.map(t => t.task_gid).filter(Boolean))
if (gids.size > 0) {
  try {
    const cred = JSON.parse(fs.readFileSync(path.join(HOME, '.config/agent-watcher/credentials.json'), 'utf8'))
    const cfg = JSON.parse(fs.readFileSync(path.join(HOME, '.config/agent-watcher/asana-config.json'), 'utf8'))
    if (cred.asana_token && cfg.project_gid) {
      const out = execSync(
        `curl -sf --max-time 20 "https://app.asana.com/api/1.0/projects/${cfg.project_gid}/tasks?opt_fields=name&limit=100" -H "Authorization: Bearer ${cred.asana_token}"`,
        { encoding: 'utf8' })
      const map = {}
      for (const t of JSON.parse(out).data || []) map[t.gid] = t.name
      for (const t of transcripts) if (t.task_gid && map[t.task_gid]) t.task_name = map[t.task_gid]
    }
  } catch {}
}

// Lineage demotion for grep mode: a --fork-session child DUPLICATES the parent's
// records verbatim (a 50MB fork is a full copy, not a compact summary), so its
// hits look authored line-by-line. When a registered fork's parent also hits with
// >= authored count, the fork's hits are INHERITED text, not new discussion —
// mark them so the consumer prefers the original. A fork with MORE authored hits
// than its parent genuinely discussed the phrase further and is not demoted.
if (PHRASE) {
  const hitByUuid = {}
  for (const t of transcripts) if (t.grep) hitByUuid[t.uuid] = t.grep
  for (const t of transcripts) {
    if (!t.grep || !t.fork_parent) continue
    const p = hitByUuid[t.fork_parent]
    if (p && p.authored >= t.grep.authored) t.grep.inherited_from = t.fork_parent
  }
}

transcripts.sort((a, b) => (a.mtime < b.mtime ? 1 : -1))
console.log(JSON.stringify({ generated_at: new Date().toISOString(), live, transcripts: PHRASE ? transcripts : transcripts.slice(0, 200) }))
