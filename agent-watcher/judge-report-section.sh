#!/usr/bin/env bash
# judge-report-section.sh -- print the run report's "## Completion Judge" section
# from the judge provenance log (one row per judge call: event, verdict, failed
# dimensions, summary; override rows name the operator comment). Spliced into the
# report at attach time by hooks/require-clean-run-report.sh, so the agent never
# writes it. Usage: judge-report-section.sh --gid <gid>
# Env: COMPLETION_JUDGE_LOG_DIR overrides the log directory (tests).
set -uo pipefail
GID=""
while [ $# -gt 0 ]; do case "$1" in --gid) GID="$2"; shift 2 ;; *) echo "usage: judge-report-section.sh --gid <gid>" >&2; exit 2 ;; esac; done
[ -n "$GID" ] || { echo "usage: judge-report-section.sh --gid <gid>" >&2; exit 2; }
LOG="${COMPLETION_JUDGE_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/judge}/$GID.jsonl"
echo "## Completion Judge"
echo "<!-- cat: completion-judge -->"
echo "<!-- auto-filled at attach from the judge provenance log; leave as is -->"
if [ ! -s "$LOG" ]; then echo "_No judge call yet._"; exit 0; fi
node -e '
const fs=require("fs");
const rows=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
if(!rows.length){console.log("_No judge call yet._");process.exit(0)}
const esc=s=>String(s||"").replace(/\|/g,"\\|").replace(/\s+/g," ").trim();
console.log("| # | Time (UTC) | Event | Verdict | Failed | Summary |");
console.log("|---|---|---|---|---|---|");
rows.forEach((r,i)=>{
  const t=(r.ts||"").replace(/^\d{4}-/,"").replace("T"," ").replace(/Z$/,"Z");
  let failed="", summary="";
  if(r.verdict==="override"){failed="";summary=`operator override (${r.override||"?"}) via Asana comment ${(r.comment_at||"").replace(/^\d{4}-/,"")}`}
  else if(r.verdict==="unavailable"){summary=`judge unavailable: ${esc(r.error)}`}
  else {failed=(r.fail_ids||[]).join(", ")||(r.fails?`${r.fails} item(s)`:"");summary=esc(r.summary).slice(0,160)}
  console.log(`| ${i+1} | ${t} | ${r.event||""} | ${r.verdict||""} | ${failed} | ${summary} |`);
});
' "$LOG"
