#!/usr/bin/env bash
# pr-commit-stats.sh — zero-LLM commit-shape facts for one PR head, so the
# commit-discipline and followup-threads dimensions (fixup body, Fixup-for kind,
# one fixup per target and kind, subject length) grade from numbers instead of
# a grader re-reading git log.
# Usage:
#   pr-commit-stats.sh <pr-url>                 # gh api .../pulls/N/commits
#   pr-commit-stats.sh --from-json <file.json>  # the same API payload, for tests
# Output (JSON): {pr, commits, fixups:{total, bodyless:[sha], untagged:[sha],
#   over_one_per_target_kind:[{target,kind,n,shas}]}, subjects_over_50:[sha],
#   newest_commit_at}
# Fixup facts: subject "fixup! X" targets X (nested "fixup! fixup! X" folds to X);
# body = message lines after the subject minus the Fixup-for trailer; kind = the
# trailer value or "untagged". Exit 1 when the PR cannot be fetched.
set -euo pipefail
if [ "${1:-}" = "--from-json" ]; then PAYLOAD=$(cat "$2"); PR="${3:-fixture}"; else
  PR="${1:?pr url}"
  if [[ "$PR" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    PAYLOAD=$(gh api --paginate "repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/pulls/${BASH_REMATCH[3]}/commits" 2>/dev/null | jq -cs 'add') || { echo "pr-commit-stats: fetch failed for $PR" >&2; exit 1; }
  else echo "pr-commit-stats: not a PR url: $PR" >&2; exit 1; fi
fi
printf '%s' "$PAYLOAD" | node -e '
  let raw=""; process.stdin.on("data",d=>raw+=d).on("end",()=>{
    const pr=process.argv[1]; let commits=[]; try{commits=JSON.parse(raw)||[]}catch(e){commits=[]}
    const fix={total:0,bodyless:[],untagged:[]}; const groups={}; const over50=[]; let newest=null;
    for(const c of commits){
      const sha=(c.sha||"").slice(0,7); const msg=(c.commit&&c.commit.message)||"";
      const when=c.commit&&c.commit.author&&c.commit.author.date; if(when&&(!newest||when>newest))newest=when;
      const lines=msg.split("\n"); const subject=lines[0]||"";
      const m=subject.match(/^((?:fixup! )+)(.*)$/);
      if(subject.length>50&&!m) over50.push(sha);
      if(!m)continue;
      fix.total++;
      const target=m[2].trim();
      const trailer=(msg.match(/^Fixup-for:\s*(\w+)\s*$/m)||[])[1]||"untagged";
      const body=lines.slice(1).filter(l=>!/^Fixup-for:/.test(l)).join("\n").trim();
      if(!body)fix.bodyless.push(sha);
      if(trailer==="untagged")fix.untagged.push(sha);
      const k=target+" "+trailer; (groups[k]=groups[k]||{target,kind:trailer,n:0,shas:[]});
      groups[k].n++; groups[k].shas.push(sha);
    }
    fix.over_one_per_target_kind=Object.values(groups).filter(g=>g.n>1);
    console.log(JSON.stringify({pr,commits:commits.length,fixups:fix,subjects_over_50:over50,newest_commit_at:newest}));
  });
' "$PR"
