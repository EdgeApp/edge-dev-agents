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
# full read for them (paged Reads covering every line count, via
# mark-skill-read.sh and the transcript scan below).
#
# Markers: /tmp/agent-skill-read-<key>-<skill>, where <key> is AGENT_TASK_GID
# in orch runs (mark-skill-read.sh and inject-run-context.sh write them too;
# inject-run-context.sh expires them at segment and compaction boundaries). A
# caller that must gate interactive sessions as well exports SKILL_READ_KEY
# (mark-skill-read.sh uses sess-<session_id> there); without either, every
# function no-ops, so interactive sessions are never gated by default.
#
# Lazy evidence credit: a marker is a cache, not the only proof. Deliveries no
# PostToolUse hook sees (a /skill slash command, compaction's invoked_skills
# re-injection) and markers expired at a boundary while the body is still in
# context are recovered by skill_read_credit_from_transcript, which a gate
# calls on its would-block path only. The proof rules live in
# lib/skill-read-evidence.js; any scan failure credits nothing.

SKILL_READ_BODY_CAP="${SKILL_READ_BODY_CAP:-50000}"
SKILL_READ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# skill_read_missing <skill>... : prints the subset with no marker (space-separated).
skill_read_key() { printf '%s' "${SKILL_READ_KEY:-${AGENT_TASK_GID:-}}"; }

skill_read_missing() {
  local key sk out=""
  key=$(skill_read_key); [ -n "$key" ] || return 0
  for sk in "$@"; do
    [ -f "/tmp/agent-skill-read-$key-$sk" ] || out="$out $sk"
  done
  printf '%s' "${out# }"
}

# skill_read_credit_from_transcript <transcript_path> <skill>... : writes the
# marker for every skill whose complete current body the transcript proves is
# in context (see lib/skill-read-evidence.js). Silent; no-op on a missing
# transcript, missing node, or scan failure (fail closed: nothing credited).
skill_read_credit_from_transcript() {
  local tp="${1:-}" key sk credited
  shift || return 0
  key=$(skill_read_key)
  [ -n "$key" ] && [ -n "$tp" ] && [ -f "$tp" ] && [ "$#" -gt 0 ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  credited=$(node "$SKILL_READ_LIB_DIR/skill-read-evidence.js" scan "$tp" "$@" 2>/dev/null) || return 0
  for sk in $credited; do
    case " $* " in *" $sk "*) touch "/tmp/agent-skill-read-$key-$sk" 2>/dev/null || true ;; esac
  done
}

# skill_read_deliver <skill>... : prints the delivery block (body or pointer) to
# stdout and writes the marker for every body delivered in full.
skill_read_deliver() {
  local sk skf n
  for sk in "$@"; do
    skf="$HOME/.cursor/skills/$sk/SKILL.md"
    echo
    if [ -f "$skf" ] && [ "$(wc -c < "$skf")" -le "$SKILL_READ_BODY_CAP" ]; then
      echo "===== /$sk contract (~/.cursor/skills/$sk/SKILL.md, delivered in full) ====="
      cat "$skf"
      [ -n "$(skill_read_key)" ] && touch "/tmp/agent-skill-read-$(skill_read_key)-$sk" 2>/dev/null || true
    else
      n=$(wc -l < "$skf" 2>/dev/null | tr -d ' ')
      echo "===== /$sk contract is too large to deliver here: Read ~/.cursor/skills/$sk/SKILL.md in pages (offset/limit) until every line 1-${n:-?} has been shown, then re-run. A single Read of this file is cut at the token cap; the gate unlocks once your Reads together cover every line. ====="
    fi
  done
}
