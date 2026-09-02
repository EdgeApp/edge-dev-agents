#!/usr/bin/env bash
# skill-read-gate.sh — shared deny-with-body delivery for the skill-read gates.
# Source this; do not execute it.
#
# A skill's contract must be in context before its steps run. The gates that
# enforce this (require-skill-read-for-scripts.sh on companion scripts,
# lint-md-on-write.sh and slack-prose-gate.sh on outward prose) share one
# mechanism: when the marker for the skill is absent, the deny message IS the
# skill body, and the marker is written at delivery so the retry passes. One
# round trip, and a partial read can never stand in for the body. Bodies over
# BODY_CAP get a pointer instead, WITHOUT a marker, so the gate still demands a
# full read for them.
#
# Markers: /tmp/agent-skill-read-<gid>-<skill> (mark-skill-read.sh and
# inject-run-context.sh write them too; inject-run-context.sh expires them at
# segment and compaction boundaries). All functions no-op unless
# AGENT_TASK_GID is set, so interactive sessions are never gated.

SKILL_READ_BODY_CAP="${SKILL_READ_BODY_CAP:-50000}"

# skill_read_missing <skill>... : prints the subset with no marker (space-separated).
skill_read_missing() {
  [ -n "${AGENT_TASK_GID:-}" ] || return 0
  local sk out=""
  for sk in "$@"; do
    [ -f "/tmp/agent-skill-read-$AGENT_TASK_GID-$sk" ] || out="$out $sk"
  done
  printf '%s' "${out# }"
}

# skill_read_deliver <skill>... : prints the delivery block (body or pointer) to
# stdout and writes the marker for every body delivered in full.
skill_read_deliver() {
  local sk skf
  for sk in "$@"; do
    skf="$HOME/.cursor/skills/$sk/SKILL.md"
    echo
    if [ -f "$skf" ] && [ "$(wc -c < "$skf")" -le "$SKILL_READ_BODY_CAP" ]; then
      echo "===== /$sk contract (~/.cursor/skills/$sk/SKILL.md, delivered in full) ====="
      cat "$skf"
      [ -n "${AGENT_TASK_GID:-}" ] && touch "/tmp/agent-skill-read-$AGENT_TASK_GID-$sk" 2>/dev/null || true
    else
      echo "===== /$sk contract is too large to deliver here: Read ~/.cursor/skills/$sk/SKILL.md IN FULL (no offset/limit), then re-run. Partial reads do not unlock this gate. ====="
    fi
  done
}
