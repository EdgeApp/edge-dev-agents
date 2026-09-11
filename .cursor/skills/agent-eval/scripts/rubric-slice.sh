#!/usr/bin/env bash
# rubric-slice.sh — print the agent-eval rubric restricted to one profile's
# dimensions (or an explicit list), so a targeted grader reads a few rows
# instead of the whole table. Section headers, the preamble (verdict legend,
# era paragraph) and the trailing sections (nudge accounting, evidence sources,
# known gaps) are kept; dimension rows outside the set are dropped.
# Usage:
#   rubric-slice.sh <profile>            # dims parsed from agent-eval/SKILL.md <profile id="...">
#   rubric-slice.sh --dims A3,A9,A20     # explicit list
# Exit 1 when the profile is unknown or names no dimension present in the rubric.
set -euo pipefail
SK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUBRIC="$SK/references/rubric.md"
SKILL="$SK/SKILL.md"
[ $# -ge 1 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
if [ "$1" = "--dims" ]; then DIMS="${2:-}"; LABEL="dims $DIMS"; else
  PROFILE="$1"; LABEL="profile $PROFILE"
  DIMS=$(node -e '
    const fs=require("fs"); const [skill,id]=process.argv.slice(1);
    const s=fs.readFileSync(skill,"utf8");
    const m=s.match(new RegExp("<profile id=\""+id+"\">([\\s\\S]*?)</profile>"));
    if(!m){process.exit(1)}
    const set=new Set((m[1].match(/\b[AO]\d+\b/g)||[]));
    process.stdout.write([...set].join(","));
  ' "$SKILL" "$PROFILE") || { echo "rubric-slice: unknown profile '$PROFILE' in $SKILL" >&2; exit 1; }
fi
[ -n "$DIMS" ] || { echo "rubric-slice: no dimensions for $LABEL" >&2; exit 1; }
node -e '
  const fs=require("fs"); const [rubric,dims,label]=process.argv.slice(1);
  const keep=new Set(dims.split(",").map(s=>s.trim()).filter(Boolean));
  const out=[]; let hit=0;
  for(const line of fs.readFileSync(rubric,"utf8").split("\n")){
    const m=line.match(/^\|\s*\*{0,2}([AO]\d+)\b/);
    if(m){ if(keep.has(m[1])){out.push(line);hit++;} continue; }
    out.push(line);
  }
  if(!hit){console.error("rubric-slice: none of "+dims+" found in "+rubric);process.exit(1)}
  console.log("<!-- rubric slice: "+label+" ("+hit+" of "+keep.size+" dimensions present) -->");
  console.log(out.join("\n").replace(/\n{3,}/g,"\n\n"));
' "$RUBRIC" "$DIMS" "$LABEL"
