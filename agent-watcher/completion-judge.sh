#!/usr/bin/env bash
# completion-judge.sh -- run the COMPLETION JUDGE on a task: collect the evidence
# bundle (completion-evidence.sh), reuse the cached verdict when the bundle hash is
# unchanged, otherwise spawn a fresh headless Opus judge OUTSIDE the run's context,
# write the verdict, and log provenance. Contract: ~/.cursor/skills/completion-judge.
#
# Usage:
#   completion-judge.sh --gid <gid> --event complete|pr-create|block [--reason "<text>"]
#                       [--offline] [--force] [--quiet]
# Exit: 0 allow | 1 deny (failed items on stdout) | 3 judge unavailable (no verdict
#       written; reason on stderr) | 2 usage
# Files:
#   /tmp/agent-completion-evidence-<gid>.md   the bundle
#   /tmp/agent-completion-verdict-<gid>.json  the verdict, bound to evidence_hash
#   $XDG_STATE_HOME/agent-watcher/judge/<gid>.jsonl  provenance: one line per judge
#       call (ts, event, hash, verdict, cost, duration, nonce). A verdict whose nonce
#       has no provenance line was not written by this script.
# Env: COMPLETION_JUDGE_MODEL (opus), COMPLETION_JUDGE_EFFORT (high),
#      COMPLETION_JUDGE_DEADLINE seconds (480; keep under the gate hook timeout, a
#      timed-out hook fails OPEN), COMPLETION_JUDGE_OFFLINE=1, COMPLETION_JUDGE_LOG_DIR.
set -uo pipefail

GID="" EVENT="" REASON="" FORCE=0 QUIET=0 OFFLINE="${COMPLETION_JUDGE_OFFLINE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "completion-judge: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] && [ -n "$EVENT" ] || { echo "usage: completion-judge.sh --gid <gid> --event complete|pr-create|block [--reason R] [--offline] [--force]" >&2; exit 2; }

H="$HOME/.config/agent-watcher"
SK="$HOME/.cursor/skills/completion-judge/references"
VERDICT="/tmp/agent-completion-verdict-$GID.json"
LOG_DIR="${COMPLETION_JUDGE_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/judge}"
MODEL="${COMPLETION_JUDGE_MODEL:-opus}"
EFFORT="${COMPLETION_JUDGE_EFFORT:-high}"
DEADLINE="${COMPLETION_JUDGE_DEADLINE:-480}"
mkdir -p "$LOG_DIR" 2>/dev/null

# 1. Evidence
EV_ARGS=(--gid "$GID" --event "$EVENT")
[ -n "$REASON" ] && EV_ARGS+=(--reason "$REASON")
[ "$OFFLINE" = 1 ] && EV_ARGS+=(--offline)
EV=$("$H/completion-evidence.sh" "${EV_ARGS[@]}") || { echo "completion-judge: evidence collection failed" >&2; exit 3; }
BUNDLE=${EV#path=}; BUNDLE=${BUNDLE%% hash=*}; HASH=${EV##*hash=}

# ORDERED OVERRIDE IN A COMMENT. Operator comments in the segment's scope are read with the same grammar
# as session prompts (hooks/lib/operator-directives.sh): bypass covers every event,
# complete covers complete/pr-create, stop covers block. The waiver file is written
# so the gate's own pass-through carries it for the rest of the segment.
MARKER="/tmp/agent-followup-scope-$GID.json"
if [ -s "$MARKER" ] && . "$H/hooks/lib/operator-directives.sh" 2>/dev/null; then
  while IFS=$'\t' read -r c_ts c_text; do
    [ -n "$c_text" ] || continue
    kinds=$(printf '%s' "$c_text" | directive_kinds)
    hit=""
    case " $kinds " in *" bypass "*) hit=bypass ;; esac
    [ -z "$hit" ] && case "$EVENT" in complete|pr-create) case " $kinds " in *" complete "*) hit=complete ;; esac ;; block) case " $kinds " in *" stop "*) hit=stop ;; esac ;; esac
    [ -n "$hit" ] || continue
    printf 'operator override (%s) from Asana comment %s: %s\n' "$hit" "$c_ts" "$(printf '%s' "$c_text" | head -c 300 | tr '\n' ' ')" > "/tmp/agent-judge-waiver-$GID" 2>/dev/null || true
    printf '{"ts":"%s","gid":"%s","event":"%s","evidence_hash":"%s","nonce":"override","verdict":"override","override":%s,"comment_at":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GID" "$EVENT" "$HASH" "$(printf '%s' "$hit" | jq -Rs .)" "$c_ts" >> "$LOG_DIR/$GID.jsonl"
    echo "verdict: allow ($EVENT) by OPERATOR OVERRIDE: Asana comment $c_ts orders '$hit' ($(printf '%s' "$c_text" | head -c 160 | tr '\n' ' '))"
    exit 0
  done < <(jq -r '(.segment_comments // .comments // [])[] | select(.authored == "operator") | [.created_at, (.text | gsub("[\t\n]"; " "))] | @tsv' "$MARKER" 2>/dev/null)
fi

print_verdict() { # print_verdict <file> -> stdout summary; returns 0 allow / 1 deny
  node -e '
const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
const fails=(v.items||[]).filter(i=>i.status==="fail");
const asks=(v.asks||[]).filter(a=>a.status==="unaddressed");
console.log(`verdict: ${v.verdict} (${v.event}, evidence ${v.evidence_hash}, ${v.cached?"cached":"fresh"}) ${v.summary||""}`);
for(const a of asks) console.log(`  ask UNADDRESSED [${a.source||"?"}]: ${a.ask}\n    evidence: ${a.evidence||""}`);
for(const f of fails) console.log(`  FAIL ${f.id} ${f.dimension}: ${f.evidence||""}\n    what_to_do: ${f.what_to_do||""}`);
process.exit(v.verdict==="allow"?0:1)' "$1"; }

# 2. Cached verdict for this exact evidence
if [ "$FORCE" != 1 ] && [ -s "$VERDICT" ] && [ "$(jq -r '.evidence_hash // empty' "$VERDICT" 2>/dev/null)" = "$HASH" ] \
   && [ "$(jq -r '.event // empty' "$VERDICT" 2>/dev/null)" = "$EVENT" ]; then
  jq '. + {cached: true}' "$VERDICT" > "$VERDICT.tmp" && mv -f "$VERDICT.tmp" "$VERDICT"
  [ "$QUIET" = 1 ] && { [ "$(jq -r .verdict "$VERDICT")" = allow ] && exit 0 || exit 1; }
  print_verdict "$VERDICT"; exit $?
fi

# 3. Fresh judgment in a clean headless context
command -v claude >/dev/null 2>&1 || { echo "completion-judge: claude binary not on PATH" >&2; exit 3; }
[ -s "$SK/rubric.md" ] || { echo "completion-judge: rubric missing at $SK/rubric.md" >&2; exit 3; }
NONCE=$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || date +%s%N)
WORK="/tmp/agent-judge-$GID"; mkdir -p "$WORK"
PROMPT="$WORK/prompt.md"
{
  cat "$SK/rubric.md"
  printf '\n\n---\n\n'
  [ -s "$SK/concession-taxonomy.md" ] && cat "$SK/concession-taxonomy.md"
  printf '\n\n---\n\n# EVIDENCE BUNDLE (the only facts you have)\n\n'
  cat "$BUNDLE"
  printf '\n\n---\nJudge the `%s` event for task %s now. Return only the JSON object in a ```json fence.\n' "$EVENT" "$GID"
} > "$PROMPT"

START=$(date +%s)
RAW_OUT="$WORK/raw.json"; ERR="$WORK/stderr.txt"
# The run's AGENT_TASK_GID must not leak into the judge (its hooks key on it).
( cd "$WORK" && env -u AGENT_TASK_GID -u AGENT_SIM_UDID -u AGENT_METRO_PORT \
    node -e '
const {spawnSync}=require("child_process");
const fs=require("fs");
const [prompt,out,err,model,effort,deadline]=process.argv.slice(1);
const r=spawnSync("claude",["-p","--model",model,"--effort",effort,"--tools","","--setting-sources","","--no-session-persistence","--output-format","json"],
  {input:fs.readFileSync(prompt),timeout:Number(deadline)*1000,maxBuffer:64*1024*1024,encoding:"utf8"});
fs.writeFileSync(out,r.stdout||""); fs.writeFileSync(err,(r.stderr||"")+(r.error?"\n"+String(r.error):""));
process.exit(r.error&&r.error.code==="ETIMEDOUT"?124:(r.status??1));
' "$PROMPT" "$RAW_OUT" "$ERR" "$MODEL" "$EFFORT" "$DEADLINE" )
RC=$?
DUR=$(( $(date +%s) - START ))

fail_unavailable() { # fail_unavailable <why>
  printf '{"ts":"%s","gid":"%s","event":"%s","evidence_hash":"%s","nonce":"%s","verdict":"unavailable","error":%s,"duration_s":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GID" "$EVENT" "$HASH" "$NONCE" "$(printf '%s' "$1" | jq -Rs .)" "$DUR" >> "$LOG_DIR/$GID.jsonl"
  echo "completion-judge: judge unavailable: $1" >&2; exit 3; }

[ "$RC" = 124 ] && fail_unavailable "judge timed out after ${DEADLINE}s"
[ "$RC" = 0 ] || fail_unavailable "claude -p exited $RC: $(head -c 300 "$ERR" | tr '\n' ' ')"

# 4. Parse and validate
PARSED=$(node -e '
const fs=require("fs");
const [rawPath,gid,event,hash,nonce,model]=process.argv.slice(1);
let wrapper; try{ wrapper=JSON.parse(fs.readFileSync(rawPath,"utf8")) }catch(e){ console.error("wrapper not JSON"); process.exit(1) }
if(wrapper.is_error){ console.error("claude reported error: "+String(wrapper.result||"").slice(0,200)); process.exit(1) }
const text=String(wrapper.result||"");
const m=text.match(/```json\s*([\s\S]*?)```/); const body=m?m[1]:text;
let v; try{ v=JSON.parse(body) }catch(e){ const s=body.lastIndexOf("{"); try{ v=JSON.parse(body.slice(body.indexOf("{"))) }catch(e2){ console.error("verdict not JSON"); process.exit(1) } }
if(!["allow","deny"].includes(v.verdict)||!Array.isArray(v.items)){ console.error("verdict schema invalid"); process.exit(1) }
const fails=v.items.filter(i=>i.status==="fail").length;
if(fails>0&&v.verdict==="allow") v.verdict="deny";
const out={gid,event,evidence_hash:hash,nonce,ts:new Date().toISOString(),model,cost_usd:wrapper.total_cost_usd??null,duration_ms:wrapper.duration_ms??null,cached:false,...v};
fs.writeFileSync(process.argv[7],JSON.stringify(out,null,2));
console.log(JSON.stringify({verdict:out.verdict,fails,cost:out.cost_usd,duration_ms:out.duration_ms,fail_ids:v.items.filter(i=>i.status==="fail").map(i=>i.id),summary:String(v.summary||"").slice(0,200)}));
' "$RAW_OUT" "$GID" "$EVENT" "$HASH" "$NONCE" "$MODEL" "$VERDICT.tmp" 2>"$WORK/parse.err") || fail_unavailable "$(cat "$WORK/parse.err")"
mv -f "$VERDICT.tmp" "$VERDICT"

# 5. Provenance
printf '%s' "$PARSED" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gid "$GID" --arg event "$EVENT" --arg hash "$HASH" --arg nonce "$NONCE" --arg model "$MODEL" \
  '{ts:$ts,gid:$gid,event:$event,evidence_hash:$hash,nonce:$nonce,verdict:.verdict,fails:.fails,fail_ids:.fail_ids,summary:.summary,cost_usd:.cost,duration_ms:.duration_ms,model:$model}' >> "$LOG_DIR/$GID.jsonl"

[ "$QUIET" = 1 ] && { [ "$(jq -r .verdict "$VERDICT")" = allow ] && exit 0 || exit 1; }
print_verdict "$VERDICT"
