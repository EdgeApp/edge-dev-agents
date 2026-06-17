#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Gates `update-status.sh ... --blocked yes` in
# orchestrated agent sessions behind the blocker-validator: a block may only be set
# when a FRESH verdict approving THIS reason exists. Deterministic counterpart to the
# true-blocker prose rules that runs keep skipping by yielding prematurely.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Only fires on a --blocked yes write.
#
# Verdict contract (/tmp/agent-blocker-verdict-<gid>.json, written by /blocker-validator):
#   { "legitimate": true, "reason_hash": "<16-hex>", "ts": "<ISO8601>" }
# The verdict is accepted only if legitimate==true AND its reason_hash matches the
# hash of the reason on THIS command (an approval can't be reused for a different
# block) AND it is fresh (< 30 min old, so a stale prior approval can't carry over).
# Exit 0 = allow. Exit 2 = block (stderr fed back to the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Only gate a --blocked yes write via update-status.sh.
case "$CMD" in
  *update-status.sh*--blocked*yes*) ;;
  *) exit 0 ;;
esac

GID="$AGENT_TASK_GID"
# Extract the claimed --reason from the command. BSD sed backrefs are unreliable for
# matched-quote extraction, so parse in node (handles "...", '...', or a bare token).
REASON=$(printf '%s' "$CMD" | node -e 'const s=require("fs").readFileSync(0,"utf8");const m=s.match(/--reason\s+("([^"]*)"|\x27([^\x27]*)\x27|(\S+))/);process.stdout.write(m?(m[2]!==undefined?m[2]:m[3]!==undefined?m[3]:m[4]||""):"")' 2>/dev/null || true)

if [ -z "$REASON" ]; then
  echo "BLOCKED: a --blocked yes write must carry --reason \"<the claimed blocker>\" so the block-validation gate can judge it. Add --reason and retry; if the validator (/blocker-validator $GID \"<reason>\") rules it legitimate it will pass." >&2
  exit 2
fi

REASON_HASH=$(printf '%s' "$REASON" | shasum -a 256 | cut -c1-16)
VERDICT="/tmp/agent-blocker-verdict-$GID.json"

if [ -s "$VERDICT" ]; then
  V_OK=$(jq -r '.legitimate // false' "$VERDICT" 2>/dev/null || echo false)
  V_HASH=$(jq -r '.reason_hash // ""' "$VERDICT" 2>/dev/null || echo "")
  V_TS=$(jq -r '.ts // ""' "$VERDICT" 2>/dev/null || echo "")
  V_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$V_TS" +%s 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$V_OK" = "true" ] && [ "$V_HASH" = "$REASON_HASH" ] && [ "$V_EPOCH" -gt 0 ] && [ $((NOW - V_EPOCH)) -lt 1800 ]; then
    exit 0  # fresh, reason-bound approval — allow the block
  fi
fi

echo "BLOCKED: this block is not validated. Before setting blocked=Yes, run the blocker-validator on THIS reason:
  /blocker-validator $GID \"$REASON\"
It judges the reason against the true-blocker taxonomy (and the attempt-log) and writes $VERDICT. If it returns legitimate:false you are NOT blocked — do what its what_to_try says (e.g. swap-to-fund, build the missing maestro flow, link the unmerged dep, attempt the action) and continue. Only re-run this block if the validator approved THIS exact reason. A funds/provider block additionally requires a real attempt logged via log-attempt.sh (result loss:/failed:/blocked:) — predicting a wall is not hitting it." >&2
exit 2
