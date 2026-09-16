#!/usr/bin/env bash
# fleet-panel.sh -- deterministic half of the Fleet artifact: render the page,
# apply the requests a viewer queued on it (resume a transcript as a chat
# session), and keep the request ledger. The Claude session that owns the
# artifact (the `fleet` anchor, skill /fleet-panel) does only what needs the
# Artifact tool: read the live page, hand its state here, publish the result.
#
# Files (all in ~/.config/agent-watcher):
#   fleet-state.json    request ledger: {"requests":[{id,kind,uuid,title,at,status,rc,tmux,note,doneAt}]}
#   fleet-panel.json    {"url": "<artifact url>"} written by the skill at init
#   fleet-panel.log     one line per request applied
#
# Usage:
#   fleet-panel.sh render [--out /tmp/fleet-page.html]     render from the current fleet + ledger
#   fleet-panel.sh extract-state <page.html>                print the page's embedded state JSON
#   fleet-panel.sh apply <incoming-state.json> [--out /tmp/fleet-page.html]
#         merge the page's requests into the ledger (new ids only), execute every
#         pending one in order, then render. A resume request runs
#         resume-agent.sh --uuid <uuid> --chat; the uuid must be one the page
#         itself listed (snapshotUuids), so nothing a viewer types can execute.
#         Prints APPLIED <id> <status> <rc> per request and RENDERED <path>.
# Exit: 0 ok (individual request failures are recorded, not fatal); 1 usage or
#       render failure.
set -uo pipefail
DIR="$HOME/.config/agent-watcher"
STATE="$DIR/fleet-state.json"
LOG="$DIR/fleet-panel.log"
OUT="/tmp/fleet-page.html"
cmd="${1:-}"; shift || true
[ -f "$STATE" ] || echo '{"requests":[]}' > "$STATE"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

render() {
  node "$DIR/fleet-page.js" --state "$STATE" --out "$OUT" || { echo "render failed" >&2; return 1; }
  echo "RENDERED $OUT"
}

extract_state() {
  local f="$1"
  node -e '
    const s = require("fs").readFileSync(process.argv[1], "utf8");
    const m = s.match(/<script type="application\/json" id="state">([\s\S]*?)<\/script>/);
    if (!m) { console.error("no #state block in page"); process.exit(1) }
    process.stdout.write(m[1].replace(/<\\\//g, "</"))
  ' "$f"
}

apply() {
  local incoming="$1"
  [ -r "$incoming" ] || { echo "incoming state not readable: $incoming" >&2; return 1; }
  # 1. merge: append requests whose id the ledger has not seen; keep the page's snapshotUuids
  node -e '
    const fs = require("fs");
    const ledger = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const page = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const seen = new Set((ledger.requests || []).map(r => r.id));
    let added = 0;
    for (const r of (page.requests || [])) {
      if (!r || typeof r.id !== "string" || seen.has(r.id)) continue;
      const clean = { id: r.id, kind: r.kind === "resume" ? "resume" : "refresh", at: String(r.at || new Date().toISOString()), status: "pending",
                      title: String(r.title || "").slice(0, 120), uuid: typeof r.uuid === "string" ? r.uuid : "" };
      ledger.requests = (ledger.requests || []).concat([clean]); seen.add(r.id); added++;
    }
    ledger.snapshotUuids = Array.isArray(page.snapshotUuids) ? page.snapshotUuids.filter(u => typeof u === "string") : (ledger.snapshotUuids || []);
    ledger.requests = ledger.requests.slice(-60);
    fs.writeFileSync(process.argv[1], JSON.stringify(ledger, null, 2));
    console.error(`merged ${added} new request(s)`);
  ' "$STATE" "$incoming" || return 1

  # 2. execute pending requests in order
  local ids
  ids=$(node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log((l.requests||[]).filter(r=>r.status==="pending").map(r=>r.id).join("\n"))' "$STATE")
  for id in $ids; do
    local kind uuid title
    kind=$(node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const r=l.requests.find(r=>r.id===process.argv[2]);console.log(r.kind)' "$STATE" "$id")
    uuid=$(node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const r=l.requests.find(r=>r.id===process.argv[2]);console.log(r.uuid||"")' "$STATE" "$id")
    title=$(node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const r=l.requests.find(r=>r.id===process.argv[2]);console.log(r.title||"")' "$STATE" "$id")
    set_status() { node -e '
      const fs=require("fs");const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const r=l.requests.find(r=>r.id===process.argv[2]);
      r.status=process.argv[3]; if(process.argv[4]) r.rc=process.argv[4]; if(process.argv[5]) r.tmux=process.argv[5]; if(process.argv[6]) r.note=process.argv[6];
      if(r.status==="done"||r.status==="error") r.doneAt=new Date().toISOString();
      fs.writeFileSync(process.argv[1], JSON.stringify(l,null,2))' "$STATE" "$id" "$@"; }
    if [ "$kind" = "refresh" ]; then
      set_status done "" "" "fleet re-read"
      echo "APPLIED $id done refresh"; log "$id refresh done"; continue
    fi
    # validate: uuid must be one the page listed, and must look like a uuid
    if ! printf '%s' "$uuid" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
       || ! node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((l.snapshotUuids||[]).includes(process.argv[2])?0:1)' "$STATE" "$uuid"; then
      set_status error "" "" "transcript not in the page's own list; refresh and retry"
      echo "APPLIED $id error not-listed"; log "$id resume $uuid REJECTED not in snapshot"; continue
    fi
    set_status running
    local before after new rc out rcode
    before=$(tmux ls -F '#{session_name}' 2>/dev/null | grep '^claude-asana-' | sort)
    out=$("$DIR/resume-agent.sh" --uuid "$uuid" --chat 2>&1); rcode=$?
    after=$(tmux ls -F '#{session_name}' 2>/dev/null | grep '^claude-asana-' | sort)
    new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
    if [ -z "$new" ]; then
      # already-exists path: resume-agent prints the existing session name
      new=$(printf '%s' "$out" | grep -oE 'claude-asana-chat-[a-z0-9-]+' | head -1)
    fi
    if [ "$rcode" -eq 0 ] && [ -n "$new" ]; then
      rc="${new#claude-asana-}"
      set_status done "$rc" "$new" ""
      echo "APPLIED $id done $rc"; log "$id resume $uuid -> $new"
    else
      local note; note=$(printf '%s' "$out" | grep -v '^\s*$' | tail -1 | cut -c1-200)
      set_status error "" "" "${note:-resume-agent exited $rcode}"
      echo "APPLIED $id error"; log "$id resume $uuid FAILED rc=$rcode: $note"
    fi
  done
  render
}

case "$cmd" in
  render)
    while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2 ;; *) shift ;; esac; done
    render ;;
  extract-state) [ -n "${1:-}" ] || { echo "usage: fleet-panel.sh extract-state <page.html>" >&2; exit 1; }; extract_state "$1" ;;
  apply)
    incoming="${1:-}"; shift || true
    while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2 ;; *) shift ;; esac; done
    [ -n "$incoming" ] || { echo "usage: fleet-panel.sh apply <incoming-state.json> [--out <file>]" >&2; exit 1; }
    apply "$incoming" ;;
  *) echo "usage: fleet-panel.sh render|extract-state|apply ..." >&2; exit 1 ;;
esac
