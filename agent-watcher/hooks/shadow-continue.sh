#!/usr/bin/env bash
# Stop hook for Jev routing SHADOW runs (AGENT_SHADOW=1): the shadow's counterpart of
# require-continuation-or-block.sh, which keys on AGENT_TASK_GID and so never sees a shadow.
# A shadow is `claude -p`, where ending the turn ends the run. Without this gate a backgrounded
# build plus an "I'll check back" turn end ends the run with no report, which grades the
# harness instead of the model.
#
# Allows the stop once $AGENT_SHADOW_ROOT/report.md exists; otherwise emits decision:block up
# to 3 times (counter in the shadow root), then allows so a stuck shadow still exits.
set -uo pipefail
[ "${AGENT_SHADOW:-}" = "1" ] || exit 0
ROOT="${AGENT_SHADOW_ROOT:-}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0
[ -s "$ROOT/report.md" ] && exit 0   # .stop-blocks stays: the launcher records it as nudges
N=$(cat "$ROOT/.stop-blocks" 2>/dev/null || echo 0); case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1))
[ "$N" -gt 3 ] && exit 0
printf '%s' "$N" > "$ROOT/.stop-blocks"
cat <<JSON
{"decision":"block","reason":"This is a headless one-pass run: ending your turn ends the run, and nothing will wake you. $ROOT/report.md does not exist yet, so the run is not finished (stop ${N}/3). If you backgrounded a build, install or test and meant to check back, wait for it now INSIDE this turn with a bounded blocking poll, for example: timeout 1500 bash -c 'until <done-check>; do sleep 10; done', and act on a stall (frozen log, no child processes). Then finish the plan's verification and write report.md (Summary, Changes, Verification, Unresolved). If something truly cannot be done, say so under Unresolved and write the report."}
JSON
exit 0
