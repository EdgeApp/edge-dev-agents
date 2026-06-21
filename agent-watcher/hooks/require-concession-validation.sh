#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Gates every CONCESSION from the prescribed bar in
# orchestrated agent sessions behind the concession-validator. A concession is any of:
#   1. a FORMAL block:    `update-status.sh ... --blocked yes`
#   2. a DOWNGRADE-finalize: `pr-create.sh` or `update-status.sh ... Complete` while
#      the run did NOT reach the prescribed in-app success — the latest attempt-log
#      entry is `blocked:`/`failed:`/`loss:` (a wall), or a /tmp/agent-test-blocker
#      note is being used. This is the silent-downgrade the formal-block gate missed:
#      "test hit the documented Fabric crash, so I verified a weaker way and Complete."
# Each requires a FRESH (<30min) `legitimate:true` verdict whose reason_hash matches
# THIS concession's reason, written by /concession-validator. No verdict → exit 2.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 = allow. Exit 2 = block (stderr
# fed to the model). A clean run (latest attempt-log result starts "success", no note)
# is NOT a concession and passes untouched.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

GID="$AGENT_TASK_GID"
ALOG="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/attempts/$GID.jsonl"
NOTE="/tmp/agent-test-blocker-$GID.md"
VERDICT="/tmp/agent-concession-verdict-$GID.json"

# Determine whether this command is a gated concession, and its reason.
KIND="" REASON=""
case "$CMD" in
  *update-status.sh*--blocked*yes*)
    KIND="block"
    REASON=$(printf '%s' "$CMD" | node -e 'const s=require("fs").readFileSync(0,"utf8");const m=s.match(/--reason\s+("([^"]*)"|\x27([^\x27]*)\x27|(\S+))/);process.stdout.write(m?(m[2]!==undefined?m[2]:m[3]!==undefined?m[3]:m[4]||""):"")' 2>/dev/null || true)
    if [ -z "$REASON" ]; then
      echo "BLOCKED: a --blocked yes write must carry --reason \"<the claimed blocker>\" so the concession-validator can judge it. Add --reason and retry." >&2
      exit 2
    fi
    ;;
  *pr-create.sh*|*update-status.sh*Complete*)
    # Finalize action: is the run conceding (didn't reach prescribed in-app success)?
    LAST_RESULT=""
    [ -s "$ALOG" ] && LAST_RESULT=$(jq -rs 'map(.result // "") | last // ""' "$ALOG" 2>/dev/null || echo "")
    # Also read the run-report's `verified:` frontmatter. At Complete the report
    # already exists (one-shot step 7 writes /tmp/agent-run-report-<gid>-*.md before
    # setting Complete), so a run that logged a SUCCESS attempt but never verified the
    # actual change in-app (the "drove the OLD baked bundle / verified a weaker way"
    # bypass — TON) declares `verified: not-run|partial` even though LAST_RESULT is
    # success. That is still a downgrade; let /concession-validator adjudicate it
    # (it applies the repo-aware carve-outs, e.g. backend-repo legitimacy).
    REPORT=$(ls -t /tmp/agent-run-report-"$GID"-*.md 2>/dev/null | head -1)
    VERIFIED=""
    [ -n "$REPORT" ] && VERIFIED=$(awk -F': *' 'tolower($1)=="verified"{print tolower($2); exit}' "$REPORT" 2>/dev/null | tr -d ' \r')
    if printf '%s' "$LAST_RESULT" | grep -qiE '^(blocked|failed|loss):'; then
      KIND="downgrade"; REASON="$LAST_RESULT"
    elif printf '%s' "$VERIFIED" | grep -qxE '(not-run|partial)'; then
      KIND="downgrade"; REASON="run-report verified:$VERIFIED — finalizing without an in-app verification of the change"
    elif [ -s "$NOTE" ]; then
      KIND="downgrade"; REASON=$(head -1 "$NOTE" 2>/dev/null || echo "test-blocker note")
    else
      exit 0  # latest attempt is a success AND the report verifies pass — not a concession
    fi
    ;;
  *) exit 0 ;;
esac

REASON_HASH=$(printf '%s' "$REASON" | shasum -a 256 | cut -c1-16)

if [ -s "$VERDICT" ]; then
  V_OK=$(jq -r '.legitimate // false' "$VERDICT" 2>/dev/null || echo false)
  V_HASH=$(jq -r '.reason_hash // ""' "$VERDICT" 2>/dev/null || echo "")
  V_TS=$(jq -r '.ts // ""' "$VERDICT" 2>/dev/null || echo "")
  V_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$V_TS" +%s 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$V_OK" = "true" ] && [ "$V_HASH" = "$REASON_HASH" ] && [ "$V_EPOCH" -gt 0 ] && [ $((NOW - V_EPOCH)) -lt 1800 ]; then
    exit 0  # fresh, reason-bound approval — allow the concession
  fi
fi

if [ "$KIND" = "block" ]; then
  HEAD="BLOCKED: this block is not validated."
else
  HEAD="BLOCKED: you are finalizing without reaching the prescribed in-app success — the run's last attempt was a wall ($REASON). That downgrade (verify a weaker way / skip the in-app drive and Complete) is a CONCESSION and must be validated, exactly like a formal block."
fi
echo "$HEAD Run the concession-validator on THIS reason:
  /concession-validator $GID \"$REASON\"
It judges the reason against the true-blocker / fallback taxonomy (and the attempt-log) and writes $VERDICT. If it returns legitimate:false you are NOT entitled to concede — do what its what_to_try says (apply the documented workaround for a known gotcha like the Fabric SIGSEGV, swap-to-fund, build the missing scaffolding, link the unmerged dep, re-drive the action) and reach the real success. A funds/provider/crash concession requires a GENUINE attempt logged via log-attempt.sh (result loss:/failed:/blocked:) AND no documented continue-workaround — predicting or bailing early is not a wall." >&2
exit 2
