#!/usr/bin/env bash
# completion-judge.sh -- run the COMPLETION JUDGE on a task: collect the evidence
# bundle (completion-evidence.sh), reuse the cached verdict when the bundle hash is
# unchanged, otherwise spawn a fresh headless Opus judge OUTSIDE the run's context,
# write the verdict, and log provenance. Contract: ~/.cursor/skills/completion-judge.
#
# Usage:
#   completion-judge.sh --gid <gid> --event complete|pr-create|block [--reason "<text>"]
#                       [--offline] [--force] [--quiet]
#   completion-judge.sh --gid <gid> --event qa-plan|qa-passed|qa-blocked|qa-failed [--force] [--quiet]
# QA events (the qa-run skill's plan gate and verdict gate) run the same judge with the
# QA rubric (~/.cursor/skills/qa-run/references/rubric.md: P dims for qa-plan, V dims
# for the verdicts), the QA bundle (qa-run/scripts/qa-evidence.sh), and their own
# verdict file /tmp/agent-qa-verdict-<gid>-<event>.json. Operator comment overrides,
# the true-blocker list and the tested options belong to the completion events only.
# Exit: 0 allow | 1 deny (failed items on stdout) | 3 judge unavailable (no verdict
#       written; reason on stderr: a timeout, a judge error, an unparseable verdict,
#       or an allow that leaves a rubric dimension unanswered) | 2 usage
# Files:
#   /tmp/agent-completion-evidence-<gid>.md   the bundle
#   /tmp/agent-completion-verdict-<gid>.json  the verdict, bound to evidence_hash
#   $XDG_STATE_HOME/agent-watcher/judge/<gid>.jsonl  provenance: one line per judge
#       call (ts, event, hash, verdict, cost, duration, nonce). A verdict whose nonce
#       has no provenance line was not written by this script. An operator-ordered
#       skip is a `"verdict":"override"` line carrying the directive text and its
#       event, written here for an ordered Asana comment and by the gate hook when
#       an operator waiver file is consumed: a completion event with neither a
#       verdict nor an override line for it went around the gate.
# Env: COMPLETION_JUDGE_MODEL (opus), COMPLETION_JUDGE_EFFORT (high),
#      COMPLETION_JUDGE_DEADLINE seconds (480) for the WHOLE run: the clock starts
#      before the evidence step, and the judge call gets what the evidence step
#      left. Keep it under the gate hook timeout, a timed-out hook fails OPEN.
#      COMPLETION_JUDGE_OFFLINE=1, COMPLETION_JUDGE_LOG_DIR.
set -uo pipefail
T0=$(date +%s)

GID="" EVENT="" REASON="" BASE_ARG="" FORCE=0 QUIET=0 OFFLINE="${COMPLETION_JUDGE_OFFLINE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --base) BASE_ARG="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "completion-judge: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] && [ -n "$EVENT" ] || { echo "usage: completion-judge.sh --gid <gid> --event complete|pr-create|block [--reason R] [--base <branch>] [--offline] [--force]" >&2; exit 2; }

H="$HOME/.config/agent-watcher"
SK="$HOME/.cursor/skills/completion-judge/references"
VERDICT="/tmp/agent-completion-verdict-$GID.json"
EVIDENCE_SH="$H/completion-evidence.sh"
DIM_RE='^### J[0-9]+'
WORK="/tmp/agent-judge-$GID"
QA_EVENT=0
case "$EVENT" in
  qa-plan|qa-passed|qa-blocked|qa-failed)
    QA_EVENT=1
    SK="$HOME/.cursor/skills/qa-run/references"
    VERDICT="/tmp/agent-qa-verdict-$GID-$EVENT.json"
    EVIDENCE_SH="$HOME/.cursor/skills/qa-run/scripts/qa-evidence.sh"
    WORK="/tmp/agent-judge-qa-$GID"
    if [ "$EVENT" = qa-plan ]; then DIM_RE='^### P[0-9]+'; else DIM_RE='^### V[0-9]+'; fi ;;
esac
. "$H/lib/judge-log.sh"
LOG_DIR="$(judge_log_dir)"
MODEL="${COMPLETION_JUDGE_MODEL:-opus}"
EFFORT="${COMPLETION_JUDGE_EFFORT:-high}"
DEADLINE="${COMPLETION_JUDGE_DEADLINE:-480}"
mkdir -p "$LOG_DIR" 2>/dev/null

# Jev shadow, blocker path (log only, no Jev call): every block event mirrors one
# row with the blocker REASON beside the verdict to ~/.config/jev/shadow/blocker/,
# because the judge cache keeps no reason text. rc 0 allow, 1 deny, 3 unavailable.
JUDGE_PATH=fresh
shadow_blocker_row() {
  local rc=$1 root="${JEV_SHADOW_ROOT:-$HOME/.config/jev/shadow}" v
  [ "$EVENT" = block ] && [ ! -f "$root/OFF" ] || return 0
  case "$rc" in 0) v=allow ;; 1) v=deny ;; 3) v=unavailable ;; *) return 0 ;; esac
  mkdir -p "$root/blocker" 2>/dev/null && jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gid "$GID" \
    --arg v "$v" --arg via "$JUDGE_PATH" --arg reason "$REASON" --arg hash "${HASH:-}" \
    '{ts:$ts,gid:$gid,verdict:$v,via:$via,reason:$reason,evidence_hash:$hash}' >> "$root/blocker/decisions.jsonl" 2>/dev/null
  return 0
}
trap 'shadow_blocker_row $?' EXIT

fail_unavailable() { # fail_unavailable <why>
  printf '{"ts":"%s","gid":"%s","event":"%s","evidence_hash":"%s","nonce":"%s","verdict":"unavailable","error":%s,"duration_s":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GID" "$EVENT" "${HASH:-}" "${NONCE:-}" "$(printf '%s' "$1" | jq -Rs .)" "$(( $(date +%s) - T0 ))" >> "$LOG_DIR/$GID.jsonl"
  echo "completion-judge: judge unavailable: $1" >&2; exit 3; }

# run_bounded <secs> <cmd...>: run cmd in its own process group and kill the group
# at the limit (rc 124). macOS ships no timeout(1).
run_bounded() {
  perl -e 'my $t=shift; my $pid=fork; defined $pid or exit 127;
if(!$pid){ setpgrp(0,0); exec @ARGV; exit 127 }
$SIG{ALRM}=sub{ kill "TERM",-$pid; sleep 1; kill "KILL",-$pid; exit 124 };
alarm $t; waitpid $pid,0; exit($? & 127 ? 128+($? & 127) : $? >> 8)' "$@"
}

# 1. Evidence, inside the deadline
EV_ARGS=(--gid "$GID" --event "$EVENT")
[ -n "$REASON" ] && EV_ARGS+=(--reason "$REASON")
[ -n "$BASE_ARG" ] && EV_ARGS+=(--base "$BASE_ARG")
[ "$OFFLINE" = 1 ] && EV_ARGS+=(--offline)
EV_OUT=$(mktemp "${TMPDIR:-/tmp}/judge-evidence.XXXXXX")
run_bounded "$DEADLINE" "$EVIDENCE_SH" "${EV_ARGS[@]}" > "$EV_OUT"
EV_RC=$?; EV=$(cat "$EV_OUT"); rm -f "$EV_OUT"
EV_S=$(( $(date +%s) - T0 ))
[ "$EV_RC" = 124 ] && fail_unavailable "evidence gathering timed out at the ${DEADLINE}s deadline, before the judge was called"
[ "$EV_RC" = 0 ] || { echo "completion-judge: evidence collection failed" >&2; exit 3; }
BUNDLE=${EV#path=}; BUNDLE=${BUNDLE%% hash=*}; HASH=${EV##*hash=}

# ORDERED OVERRIDE IN A COMMENT. Operator comments in the segment's scope are read with the same grammar
# as session prompts (hooks/lib/operator-directives.sh): bypass covers every event,
# complete covers complete/pr-create, stop covers block. The override is per EVENT
# and each one writes its own provenance line: no waiver file is dropped, so nothing
# skips an event the comment was never read against.
MARKER="/tmp/agent-followup-scope-$GID.json"
if [ "$QA_EVENT" = 0 ] && [ -s "$MARKER" ] && . "$H/hooks/lib/operator-directives.sh" 2>/dev/null; then
  while IFS=$'\t' read -r c_ts c_text; do
    [ -n "$c_text" ] || continue
    kinds=$(printf '%s' "$c_text" | directive_kinds)
    hit=""
    case " $kinds " in *" bypass "*) hit=bypass ;; esac
    [ -z "$hit" ] && case "$EVENT" in complete|pr-create) case " $kinds " in *" complete "*) hit=complete ;; esac ;; block) case " $kinds " in *" stop "*) hit=stop ;; esac ;; esac
    [ -n "$hit" ] || continue
    judge_log_override "$GID" "$EVENT" "$hit" "operator comment" "$c_text" "$HASH" "$c_ts"
    JUDGE_PATH=override
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
  JUDGE_PATH=cached
  jq '. + {cached: true}' "$VERDICT" > "$VERDICT.tmp" && mv -f "$VERDICT.tmp" "$VERDICT"
  [ "$QUIET" = 1 ] && { [ "$(jq -r .verdict "$VERDICT")" = allow ] && exit 0 || exit 1; }
  print_verdict "$VERDICT"; exit $?
fi

# 3. Fresh judgment in a clean headless context
command -v claude >/dev/null 2>&1 || { echo "completion-judge: claude binary not on PATH" >&2; exit 3; }
[ -s "$SK/rubric.md" ] || { echo "completion-judge: rubric missing at $SK/rubric.md" >&2; exit 3; }
if [ "$QA_EVENT" = 0 ]; then
TRUE_BLOCKERS=$(grep -o '<rule id="yolo-true-blockers">.*</rule>' "$HOME/.cursor/skills/one-shot/references/blocking.md" 2>/dev/null | head -1)
[ -n "$TRUE_BLOCKERS" ] || { echo "completion-judge: yolo-true-blockers rule not found in one-shot references/blocking.md" >&2; exit 3; }
TESTED_OPTIONS=$(sed -n '/^# Options (multi-select/,/^# Exit:/p' "$H/set-tested.sh" | sed -e '$d' -e 's/^# \{0,1\}//')
[ -n "$TESTED_OPTIONS" ] || { echo "completion-judge: tested option block not found in set-tested.sh" >&2; exit 3; }
fi
NONCE=$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || date +%s%N)
mkdir -p "$WORK"
PROMPT="$WORK/prompt.md"
if [ "$QA_EVENT" = 1 ]; then
{
  cat "$SK/rubric.md"
  printf '\n\n---\n\n# EVIDENCE BUNDLE (the only facts you have)\n\n'
  cat "$BUNDLE"
  printf '\n\n---\nJudge the `%s` event for task %s now. Answer only the %s dimensions. Return only the JSON object in a ```json fence.\n' "$EVENT" "$GID" "$( [ "$EVENT" = qa-plan ] && echo P || echo V )"
} > "$PROMPT"
else
{
  cat "$SK/rubric.md"
  printf '\n\n---\n\n'
  [ -s "$SK/concession-taxonomy.md" ] && cat "$SK/concession-taxonomy.md"
  # The ONE list of true blockers, from its owner (one-shot blocking.md), verbatim:
  # the taxonomy's allow section points here instead of keeping its own copy.
  printf '\n\n## one-shot `yolo-true-blockers` (verbatim)\n\n%s\n' "$TRUE_BLOCKERS"
  # The ONE definition of each `tested` option and its artifact (rubric J4).
  printf '\n\n## `tested` options (verbatim from set-tested.sh)\n\n%s\n' "$TESTED_OPTIONS"
  printf '\n\n---\n\n# EVIDENCE BUNDLE (the only facts you have)\n\n'
  cat "$BUNDLE"
  printf '\n\n---\nJudge the `%s` event for task %s now. Return only the JSON object in a ```json fence.\n' "$EVENT" "$GID"
} > "$PROMPT"
fi

REMAIN=$(( DEADLINE - ($(date +%s) - T0) ))
[ "$REMAIN" -ge 1 ] || fail_unavailable "evidence gathering took ${EV_S}s of the ${DEADLINE}s deadline, no time left for the judge"
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
' "$PROMPT" "$RAW_OUT" "$ERR" "$MODEL" "$EFFORT" "$REMAIN" )
RC=$?

[ "$RC" = 124 ] && fail_unavailable "judge timed out: evidence gathering took ${EV_S}s and the judge call was cut at ${REMAIN}s (whole-run deadline ${DEADLINE}s)"
[ "$RC" = 0 ] || fail_unavailable "claude -p exited $RC: $(head -c 300 "$ERR" | tr '\n' ' ')"

# 4. Parse and validate. An allow must answer every rubric dimension (pass or na).
DIM_IDS=$(grep -oE "$DIM_RE" "$SK/rubric.md" | awk '{print $2}' | tr '\n' ' ')
[ -n "${DIM_IDS// /}" ] || fail_unavailable "no dimension headings matching $DIM_RE found in $SK/rubric.md"
PARSED=$(node -e '
const fs=require("fs");
const [rawPath,gid,event,hash,nonce,model,,dimIds]=process.argv.slice(1);
let wrapper; try{ wrapper=JSON.parse(fs.readFileSync(rawPath,"utf8")) }catch(e){ console.error("wrapper not JSON"); process.exit(1) }
if(wrapper.is_error){ console.error("claude reported error: "+String(wrapper.result||"").slice(0,200)); process.exit(1) }
const text=String(wrapper.result||"");
const m=text.match(/```json\s*([\s\S]*?)```/); const body=m?m[1]:text;
let v; try{ v=JSON.parse(body) }catch(e){ const s=body.lastIndexOf("{"); try{ v=JSON.parse(body.slice(body.indexOf("{"))) }catch(e2){ console.error("verdict not JSON"); process.exit(1) } }
if(!["allow","deny"].includes(v.verdict)||!Array.isArray(v.items)){ console.error("verdict schema invalid"); process.exit(1) }
const fails=v.items.filter(i=>i.status==="fail").length;
if(fails>0&&v.verdict==="allow") v.verdict="deny";
if(v.verdict==="allow"){
  const answered=new Set(v.items.filter(i=>i&&["pass","na"].includes(i.status)).map(i=>String(i.id)));
  const missing=String(dimIds||"").split(/\s+/).filter(Boolean).filter(id=>!answered.has(id));
  if(missing.length){ console.error("allow verdict leaves rubric dimensions unanswered: "+missing.join(", ")); process.exit(1) }
}
const out={gid,event,evidence_hash:hash,nonce,ts:new Date().toISOString(),model,cost_usd:wrapper.total_cost_usd??null,duration_ms:wrapper.duration_ms??null,cached:false,...v};
fs.writeFileSync(process.argv[7],JSON.stringify(out,null,2));
console.log(JSON.stringify({verdict:out.verdict,fails,cost:out.cost_usd,duration_ms:out.duration_ms,fail_ids:v.items.filter(i=>i.status==="fail").map(i=>i.id),summary:String(v.summary||"")}));
' "$RAW_OUT" "$GID" "$EVENT" "$HASH" "$NONCE" "$MODEL" "$VERDICT.tmp" "$DIM_IDS" 2>"$WORK/parse.err") || fail_unavailable "$(cat "$WORK/parse.err")"
mv -f "$VERDICT.tmp" "$VERDICT"

# 5. Provenance
printf '%s' "$PARSED" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gid "$GID" --arg event "$EVENT" --arg hash "$HASH" --arg nonce "$NONCE" --arg model "$MODEL" --arg reason "$REASON" \
  '{ts:$ts,gid:$gid,event:$event,evidence_hash:$hash,nonce:$nonce,verdict:.verdict,fails:.fails,fail_ids:.fail_ids,summary:.summary,cost_usd:.cost,duration_ms:.duration_ms,model:$model} + (if $event == "block" then {reason:$reason} else {} end)' >> "$LOG_DIR/$GID.jsonl"

[ "$QUIET" = 1 ] && { [ "$(jq -r .verdict "$VERDICT")" = allow ] && exit 0 || exit 1; }
print_verdict "$VERDICT"
