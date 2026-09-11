#!/usr/bin/env bash
# era.sh — split references/era.md into the rows in effect for a run and the
# rows that postdate it, so graders never compare dates by hand.
# Usage: era.sh <window-end ISO date or datetime> [--table <era.md>]
# Output (JSON): {"as_of":"YYYY-MM-DD","in_effect":[{shipped,dims,name,mechanism,after}],
#                 "not_yet":[{shipped,dims,name,mechanism,before}]}
# An empty or unparsable date puts every row in in_effect (grade the current
# expectation) and sets as_of to null. Exit 2 when the table is missing.
set -euo pipefail
SK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$SK/references/era.md"; ASOF="${1:-}"
[ "${2:-}" = "--table" ] && TABLE="$3"
[ -r "$TABLE" ] || { echo "era.sh: table missing at $TABLE" >&2; exit 2; }
node -e '
  const fs=require("fs"); const [table,asofRaw]=process.argv.slice(1);
  const d=(asofRaw||"").match(/^\d{4}-\d{2}-\d{2}/); const asof=d?d[0]:null;
  const rows=[];
  for(const line of fs.readFileSync(table,"utf8").split("\n")){
    const c=line.split("|").map(s=>s.trim());
    if(c.length<7||!/^\d{4}-\d{2}-\d{2}$/.test(c[1]))continue;
    rows.push({shipped:c[1],dims:c[2].split(",").map(s=>s.trim()).filter(Boolean),name:c[3],mechanism:c[4],before:c[5],after:c[6]});
  }
  const inEffect=[],notYet=[];
  for(const r of rows){
    if(!asof||r.shipped<=asof) inEffect.push({shipped:r.shipped,dims:r.dims,name:r.name,mechanism:r.mechanism,after:r.after});
    else notYet.push({shipped:r.shipped,dims:r.dims,name:r.name,mechanism:r.mechanism,before:r.before});
  }
  console.log(JSON.stringify({as_of:asof,in_effect:inEffect,not_yet:notYet}));
' "$TABLE" "$ASOF"
