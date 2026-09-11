#!/usr/bin/env bash
# actions-ledger.sh — durable state for the cohort report's remediation classes,
# so recurrence and "approved but unbuilt" are counted by script across cohorts
# instead of re-derived by the synthesizer from memory.
#
# Ledger: ~/agent-evals/actions-ledger.json (override ACTIONS_LEDGER). One entry
# per class id: {id, tier, type, title, dims, status, first_seen, cohorts[],
# runs{gid: window_end}, approved_at, fixed_at, fixed_ref, declined_at, notes}.
# Tiers come from ~/.cursor/skills/agent-eval/references/tiers.md (a class with
# dims takes the lowest tier number among them; a class without dims must be
# given one). Statuses: proposed -> approved -> built (-> declined at any point).
#
# Usage:
#   actions-ledger.sh snapshot                       # JSON: open classes with computed
#                                                    #   recurrence, for the synthesizer prompt
#   actions-ledger.sh record --cohort <date> --actions <file.json>
#       file: [{class_id, type, title, tier?, dims?, gids?, window_ends?}] as the
#       workflow returned them; merges into the ledger (new ids created, known ids
#       gain the cohort and its gids)
#   actions-ledger.sh set <class_id> <proposed|approved|built|declined> [--ref <text>] [--date <YYYY-MM-DD>]
#   actions-ledger.sh rank [--tier N]                # markdown, grouped by tier; within a tier:
#                                                    #   approved-unbuilt first, then recurrence
#                                                    #   since the last fix, descending
#   actions-ledger.sh tier-of <A3,A9,...>            # prints the tier number for a dim list
# Recurrence since fix = runs whose window_end is after fixed_at (all runs when
# never fixed). A built class that recurs after its fix is rendered REGRESSED.
# Exit 1 on a bad argument or unknown class id; 2 when tiers.md is missing.
set -euo pipefail
LEDGER="${ACTIONS_LEDGER:-$HOME/agent-evals/actions-ledger.json}"
TIERS="${ACTIONS_TIERS:-$HOME/.cursor/skills/agent-eval/references/tiers.md}"
[ -r "$TIERS" ] || { echo "actions-ledger: tiers table missing at $TIERS" >&2; exit 2; }
CMD="${1:-}"; shift || true
exec node -e '
  const fs=require("fs"); const path=require("path");
  const [ledgerPath,tiersPath,cmd,...argv]=process.argv.slice(1);
  const today=new Date().toISOString().slice(0,10);
  const opt=(name)=>{const i=argv.indexOf(name);return i>=0?argv[i+1]:undefined};
  const die=(m)=>{console.error("actions-ledger: "+m);process.exit(1)};
  // ---- tiers ----
  const tiers=[];
  for(const line of fs.readFileSync(tiersPath,"utf8").split("\n")){
    const c=line.split("|").map(s=>s.trim()); if(c.length<6||!/^\d$/.test(c[1]))continue;
    tiers.push({tier:+c[1],name:c[2],dims:new Set(c[4].split(",").map(s=>s.trim()).filter(Boolean))});
  }
  const tierOf=(dims)=>{let t=null;for(const d of dims||[])for(const r of tiers)if(r.dims.has(d)&&(t===null||r.tier<t))t=r.tier;return t};
  const tierName=(n)=>(tiers.find(t=>t.tier===n)||{}).name||("tier "+n);
  // ---- ledger io ----
  const load=()=>{try{return JSON.parse(fs.readFileSync(ledgerPath,"utf8"))}catch(e){return {classes:{}}}};
  const save=(l)=>{fs.mkdirSync(path.dirname(ledgerPath),{recursive:true});fs.writeFileSync(ledgerPath,JSON.stringify(l,null,2)+"\n")};
  const computed=(c)=>{
    const runs=Object.entries(c.runs||{});
    const since=c.fixed_at?runs.filter(([g,w])=>(w||"")>c.fixed_at).length:runs.length;
    const approvedUnbuilt=c.status==="approved";
    const regressed=c.status==="built"&&since>0;
    return {...c,recurrence:runs.length,recurrence_since_fix:since,approved_unbuilt:approvedUnbuilt,regressed};
  };
  const order=(a,b)=>(b.approved_unbuilt-a.approved_unbuilt)||(b.regressed-a.regressed)||(b.recurrence_since_fix-a.recurrence_since_fix)||((a.first_seen||"")<(b.first_seen||"")?-1:1);
  if(cmd==="tier-of"){const t=tierOf((argv[0]||"").split(","));if(t===null)die("no tier for "+argv[0]);console.log(t);process.exit(0)}
  if(cmd==="snapshot"){
    const l=load(); const open=Object.values(l.classes).filter(c=>c.status!=="declined").map(computed).sort(order);
    console.log(JSON.stringify({tiers:tiers.map(t=>({tier:t.tier,name:t.name})),classes:open.map(c=>({id:c.id,tier:c.tier,type:c.type,title:c.title,dims:c.dims,status:c.status,recurrence:c.recurrence,recurrence_since_fix:c.recurrence_since_fix,approved_unbuilt:c.approved_unbuilt,regressed:c.regressed,cohorts:c.cohorts,fixed_at:c.fixed_at||null,fixed_ref:c.fixed_ref||null}))}));
    process.exit(0);
  }
  if(cmd==="record"){
    const cohort=opt("--cohort"),file=opt("--actions"); if(!cohort||!file)die("record needs --cohort <date> --actions <file>");
    let acts; try{acts=JSON.parse(fs.readFileSync(file,"utf8"))}catch(e){die("cannot read "+file+": "+e.message)}
    if(!Array.isArray(acts))die("actions file must be a JSON array");
    const l=load(); let created=0,updated=0;
    for(const a of acts){
      const id=(a.class_id||"").trim().toLowerCase().replace(/[^a-z0-9-]+/g,"-").replace(/^-|-$/g,""); if(!id){console.error("skip: action without class_id: "+JSON.stringify(a).slice(0,120));continue}
      const dims=Array.isArray(a.dims)?a.dims:[]; let c=l.classes[id];
      let tier=a.tier!=null?+a.tier:tierOf(dims); if(tier===null&&c)tier=c.tier;
      if(!(tier>=1&&tier<=4)){console.error("skip "+id+": no tier (give tier or dims)");continue}
      if(!c){c=l.classes[id]={id,tier,type:a.type||"infra-fix",title:a.title||id,dims,status:"proposed",first_seen:cohort,cohorts:[],runs:{}};created++}else updated++;
      if(!c.cohorts.includes(cohort))c.cohorts.push(cohort);
      for(const d of dims)if(!c.dims.includes(d))c.dims.push(d);
      const gids=Array.isArray(a.gids)?a.gids:[]; const we=a.window_ends||{};
      for(const g of gids)if(g)c.runs[g]=we[g]||c.runs[g]||null;
      if(a.title&&!c.title)c.title=a.title;
    }
    save(l); console.log(JSON.stringify({ledger:ledgerPath,cohort,created,updated}));
    process.exit(0);
  }
  if(cmd==="set"){
    const [id,status]=argv; const ok=["proposed","approved","built","declined"]; if(!ok.includes(status))die("status must be one of "+ok.join("|"));
    const l=load(); const c=l.classes[id]; if(!c)die("unknown class id "+id);
    const date=opt("--date")||today; c.status=status;
    if(status==="approved")c.approved_at=date;
    if(status==="built"){c.fixed_at=date;c.fixed_ref=opt("--ref")||c.fixed_ref||null;c.approved_at=c.approved_at||date}
    if(status==="declined"){c.declined_at=date;if(opt("--ref"))c.notes=opt("--ref")}
    save(l); console.log(JSON.stringify({id,status,fixed_at:c.fixed_at||null,fixed_ref:c.fixed_ref||null}));
    process.exit(0);
  }
  if(cmd==="rank"){
    const only=opt("--tier")?+opt("--tier"):null; const l=load();
    const all=Object.values(l.classes).map(computed);
    const out=[];
    for(const t of tiers){
      if(only&&t.tier!==only)continue;
      const rows=all.filter(c=>c.tier===t.tier&&c.status!=="declined").sort(order); if(!rows.length)continue;
      out.push("### Tier "+t.tier+": "+t.name);
      for(const c of rows){
        const flag=c.approved_unbuilt?"APPROVED, UNBUILT":c.regressed?"REGRESSED after "+c.fixed_at:c.status==="built"?"built "+c.fixed_at+(c.fixed_ref?" ("+c.fixed_ref+")":""):c.status;
        out.push("- ["+c.type+"] `"+c.id+"` "+c.title+" | "+flag+" | "+c.recurrence_since_fix+" run(s) since fix, "+c.recurrence+" total across "+c.cohorts.length+" cohort(s)"+(c.dims.length?" | "+c.dims.join(", "):""));
      }
      out.push("");
    }
    console.log(out.join("\n").trim()||"(ledger empty)");
    process.exit(0);
  }
  die("unknown command "+cmd+"; see header");
' "$LEDGER" "$TIERS" "$CMD" "$@"
