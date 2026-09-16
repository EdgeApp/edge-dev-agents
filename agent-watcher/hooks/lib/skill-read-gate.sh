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
# UNITS. Every function below takes "units", not only skill names. A unit is
# either a bare skill (`pr-land` -> ~/.cursor/skills/pr-land/SKILL.md) or one
# reference slice of a skill (`one-shot:watch` ->
# ~/.cursor/skills/one-shot/references/watch.md). Slices exist because a skill
# whose body outgrew the re-attach budget was split into a core plus per-phase
# reference files: the phase's rules bind only once that phase's slice is in
# context, which is exactly what this gate delivers. A unit has no `:` unless it
# names a slice, so the two forms never collide.
#
# Markers: /tmp/agent-skill-read-<key>-<unit>, where <key> is AGENT_TASK_GID
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

# skill_read_missing <unit>... : prints the subset with no marker (space-separated).
skill_read_key() { printf '%s' "${SKILL_READ_KEY:-${AGENT_TASK_GID:-}}"; }

skill_read_missing() {
  local key sk out=""
  key=$(skill_read_key); [ -n "$key" ] || return 0
  for sk in "$@"; do
    # A unit with no file on disk is unsatisfiable: nothing can be delivered and
    # nothing can be read, so demanding it would deny the caller forever with an
    # unactionable pointer. Treat it as satisfied; a slice that went missing is
    # caught by tests/one-shot-slice-gates.test.py, not by wedging a live run.
    [ -f "$(skill_read_path "$sk")" ] || continue
    [ -f "/tmp/agent-skill-read-$key-$sk" ] || out="$out $sk"
  done
  printf '%s' "${out# }"
}

# skill_read_path <unit> : the file the unit names (see UNITS above).
skill_read_path() {
  case "$1" in
    *:*) printf '%s' "$HOME/.cursor/skills/${1%%:*}/references/${1#*:}.md" ;;
    *)   printf '%s' "$HOME/.cursor/skills/$1/SKILL.md" ;;
  esac
}

# skill_read_label <unit> : how the delivery header names the unit.
skill_read_label() {
  case "$1" in
    *:*) printf '/%s %s phase contract' "${1%%:*}" "${1#*:}" ;;
    *)   printf '/%s contract' "$1" ;;
  esac
}

# skill_read_credit_from_transcript <transcript_path> <unit>... : writes the
# marker for every unit whose complete current body the transcript proves is
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

# skill_read_deliver <unit>... : prints the delivery block (body or pointer) to
# stdout and writes the marker for every body delivered in full. Slices are
# small by construction, so they always take the deliver-in-full branch.
skill_read_deliver() {
  local sk skf disp n
  for sk in "$@"; do
    skf=$(skill_read_path "$sk")
    disp="~${skf#$HOME}"
    echo
    if [ -f "$skf" ] && [ "$(wc -c < "$skf")" -le "$SKILL_READ_BODY_CAP" ]; then
      echo "===== $(skill_read_label "$sk") ($disp, delivered in full) ====="
      cat "$skf"
      [ -n "$(skill_read_key)" ] && touch "/tmp/agent-skill-read-$(skill_read_key)-$sk" 2>/dev/null || true
    else
      n=$(wc -l < "$skf" 2>/dev/null | tr -d ' ')
      echo "===== $(skill_read_label "$sk") is too large to deliver here: Read $disp in pages (offset/limit) until every line 1-${n:-?} has been shown, then re-run. A single Read of this file is cut at the token cap; the gate unlocks once your Reads together cover every line. ====="
    fi
  done
}
