#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Lints an agent-run-report file at the attach
# boundary, per one-shot's report-as-attachment template contract.
#
# Why: report FORM regresses after compaction. The template's inline style rules
# (no reversibility annotations, no em dashes, full section set) only bind when
# the template is in context; followup reports written from remembered shape
# reverted to the pre-fix "Reversible." trailer 5x on 2026-07-09 with the rule's
# one-line summary in fresh context. Prose keeps losing to pattern reversion;
# this gate makes the enumerable violations mechanically unshippable.
#
# Checks (against the CURRENT template, headings read dynamically so the gate
# never drifts from the template):
#   1. Reversibility annotations: any standalone "Reversible" (IRREVERSIBLE
#      notes are allowed — that is the one case worth flagging, per template).
#   2. Em dashes (U+2014): banned in run reports (writing-style em-dash-free list).
#   3. Missing "## " sections vs the template.
#   4. Undeclared hack-forced screenshots: this run captured a HACKED-named
#      proof frame (build-and-test hack-verify-visual-changes) but the report
#      never marks it. A forced frame reads as organic evidence unless it is
#      labelled, so the label is mechanical, not a matter of recollection.
#
# ALSO auto-fills three traceability fields before linting, since all three are
# fully determined by state the hook can read and none by agent recollection:
#   claude_session_id  the CC session that wrote the report, from the hook's own
#                      stdin. Names the transcript exactly, so an eval stops
#                      guessing at it (resolve-run's find_transcript is a
#                      heuristic scan; a run that resumed changes session id).
#   generated          attach time, UTC. `started`/`ended` describe the WORK;
#                      this dates the DOCUMENT.
#   tdd_doc            the TDD permalink PINNED at the branch commit as of this
#                      report (tdd-doc-links.sh), so the report keeps pointing at
#                      the doc state it audited even after the branch moves on.
#                      The PR body carries the branch-HEAD form instead
#                      (ensure-tdd-pr-link.sh) — operator ruling 2026-07-28.
#
# FORMATTER-READY: these checks define the form contract a future form-only
# formatter subagent would enforce (draft in, facts immutable, form normalized).
# If that subagent lands, it runs BEFORE this gate; the gate stays as backstop.
#
# Scope: no-op (exit 0) unless AGENT_TASK_GID is set. Exit 2 = block (stderr -> model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Only gate: asana-task-update.sh ... --attach-file <path> with a run-report name.
case "$CMD" in
  *asana-task-update.sh*--attach-file*) ;;
  *) exit 0 ;;
esac
case "$CMD" in
  *agent-run-report*) ;;
  *) exit 0 ;;
esac

# Extract the attached file path (first token after --attach-file, tolerating quotes).
REPORT="$(printf '%s' "$CMD" | sed -E 's/.*--attach-file[= ]+"?([^" ]+)"?.*/\1/')"
REPORT="${REPORT/#\~/$HOME}"
[ -s "$REPORT" ] || { echo "BLOCKED: --attach-file path '$REPORT' not readable — attach the actual report file." >&2; exit 2; }

TEMPLATE="$HOME/.cursor/skills/one-shot/templates/agent-run-report.md"
FAIL=""

# --- Traceability auto-fill (idempotent; only writes fields left blank) --------
# Rewrites in place rather than blocking: every value here is machine-derivable,
# so a gate that asked the agent for them would only cost a regeneration cycle.
set_frontmatter() { # $1=key $2=value  (no-op on an already-populated key)
  local key="$1" val="$2" f="$REPORT"
  [ -n "$val" ] || return 0
  if grep -qE "^${key}:[[:space:]]*(\"\"|'')?[[:space:]]*(#.*)?$" "$f"; then
    awk -v k="$key" -v v="$val" '
      !done && $0 ~ "^"k":[[:space:]]*(\"\"|\x27\x27)?[[:space:]]*(#.*)?$" { print k": \""v"\""; done=1; next }
      { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  elif ! grep -qE "^${key}:" "$f"; then
    awk -v k="$key" -v v="$val" '
      NR==1 { print; if ($0 == "---") { print k": \""v"\""; ins=1 } ; next }
      { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

set_frontmatter claude_session_id "$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
set_frontmatter generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
set_frontmatter agent_session_uuid "${AGENT_SESSION_UUID:-}"

# TDD permalink, PINNED at the current branch commit (see header). Only when the
# task is TDD-flagged; an unflagged run records `none` so the field is never
# ambiguous between "no TDD owed" and "nobody filled this in".
TDD_FIELD=$("$HOME/.cursor/skills/asana-field-value.sh" "$AGENT_TASK_GID" "TDD?" 2>/dev/null || echo "none")
TDD_URL="none"
if [ "$TDD_FIELD" = "tdd" ]; then
  for d in "$HOME/git/.agent-worktrees/$AGENT_TASK_GID"/*/; do
    [ -d "$d" ] || continue
    u=$("$HOME/.cursor/skills/tdd/scripts/tdd-doc-links.sh" "$d" 2>/dev/null | sed -n 's/^TDD_PINNED_URL=//p') || true
    [ -n "$u" ] && { TDD_URL="$u"; break; }
  done
fi
set_frontmatter tdd_doc "$TDD_URL"

# 1. Reversibility annotations ("Irreversible"/"IRREVERSIBLE" allowed).
REV="$(grep -nE '\bReversible\b' "$REPORT" | grep -viE 'irreversible' || true)"
if [ -n "$REV" ]; then
  FAIL+="- Reversibility annotations (template: reversible is the default; note ONLY irreversible choices):
$(echo "$REV" | head -5 | sed 's/^/    /')
"
fi

# 2. Em dashes: REWRITTEN in place instead of blocked — the top hook-block
#    source across the fleet (10/24 runs in the 2026-07-23 scorecard) and the
#    fix is fully mechanical, so blocking only cost a report-regeneration cycle.
if grep -q $'—' "$REPORT"; then
  sed -i '' -e $'s/ — /: /g' -e $'s/—/-/g' "$REPORT"
  echo ">> require-clean-run-report: auto-rewrote em dashes in $REPORT (spaced -> colon, bare -> hyphen)" >&2
fi

# 2b. Prose slop (banned vocabulary, count-announcement openers) via the shared
#     no-slop lint. Em dashes were already auto-fixed above, so remaining HARD
#     findings here are the non-mechanical-rewrite kind: block with the lines.
#     Corpus-calibrated to ~zero false positives before being made blocking.
SLOP="$("$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh" "$REPORT" 2>/dev/null | grep '^HARD' | grep -v 'em dash' | head -6 || true)"
if [ -n "$SLOP" ]; then
  FAIL+="- No-slop violations (banned vocabulary / count-announcement openers; rewrite the flagged lines):
$(echo "$SLOP" | sed 's/^/    /')
"
fi

# 3. Missing template sections (headings read live from the template).
if [ -f "$TEMPLATE" ]; then
  MISSING=""
  while IFS= read -r h; do
    grep -qF "$h" "$REPORT" || MISSING+="$h, "
  done < <(grep -E '^## ' "$TEMPLATE")
  [ -n "$MISSING" ] && FAIL+="- Missing template sections: ${MISSING%, } (use \`_None observed._\` for empty ones, never omit)
"
fi

# 4. Hack-forced screenshots must be declared with the 🪓 marker.
HACKED_SHOTS="$(ls /tmp/agent-proof-"$AGENT_TASK_GID"-*HACKED*.png 2>/dev/null || true)"
# 🩹 accepted alongside 🪓: reports from runs in flight when the marker changed
if [ -n "$HACKED_SHOTS" ] && ! grep -qE '🪓|🩹|HACK-FORCED' "$REPORT"; then
  FAIL+="- Hack-forced screenshots are not declared in the report. This run captured:
$(echo "$HACKED_SHOTS" | head -5 | sed 's/^/    /')
    Add a 🪓 line in the Testing section per one-shot step 7: the file, the exact hack, that it was reverted (clean git status), and what the frame does NOT prove (the trigger).
"
fi

[ -z "$FAIL" ] && exit 0

echo "BLOCKED: run report $REPORT violates the template contract:
${FAIL}Fix: RE-READ the template ($TEMPLATE), rewrite the report against it, then retry the attach. Do not delete facts to pass the lint — fix the form only." >&2
exit 2
