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
#   5. Second report DOC in the same session: one run segment produces ONE
#      report doc, updated and re-attached in place (stable slug/ordinal). A
#      second doc with a different slug splinters the record (2 runs in the
#      2026-08-19 cohort attached parallel report docs). Cross-segment followup
#      reports (new session id) pass untouched. Marker: /tmp/agent-report-doc-<gid>.
#   6. Dead GitHub citations: every cited github.com PR/issue/comment/commit URL
#      is resolved via gh api; a definitive HTTP 404 blocks (a 2026-08-19 report
#      cited a PR comment that does not exist anywhere on the PR). Network and
#      rate-limit errors fail OPEN — only proven-nonexistent artifacts block.
#      Asana and other external URLs are skipped (presigned churn, anti-bot).
#
# ALSO auto-fills traceability fields before linting, since every one is fully
# determined by state the hook can read and none by agent recollection:
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
#   iteration          1-based report ordinal: count of agent-run-report*
#                      attachments already on the task + 1. Also normalized into
#                      the attach NAME (agent-run-report-NN-<slug>.md, via
#                      updatedInput) and an H1 title (# Run report NN: <slug>,
#                      inserted when the report has no H1), so which followup
#                      turn a report belongs to is obvious from the attachment
#                      list alone (operator request 2026-07-29; Maya's four
#                      ad-hoc suffixes were unorderable at a glance).
#   model / effort     what this segment actually ran, from the task's last
#                      version stamp (versions/<gid>.jsonl) — ground truth, not
#                      the Asana request fields.
#   agent_lane / tdd   live Asana field values at attach (asana-field-value.sh);
#                      tdd complements tdd_doc so "no TDD owed" (none) is
#                      distinguishable from "owed but missing" (tdd + tdd_doc
#                      none).
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
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# Gate BOTH attach paths: asana-task-update.sh --attach-file, and direct curl
# to the Asana attachments API (runs fall back to curl when the script or MCP
# misbehaves — two 2026-08 reports reached Asana unlinted through that side
# door, em dashes intact).
case "$CMD_M" in
  *asana-task-update.sh*--attach-file*) ;;
  *api.asana.com*attachments*) ;;
  *) exit 0 ;;
esac
case "$CMD" in
  *agent-run-report*) ;;
  *) exit 0 ;;
esac

# Extract the attached file path: --attach-file form, else curl's file=@ form.
REPORT="$(printf '%s' "$CMD" | sed -nE 's/.*--attach-file[= ]+"?([^" ]+)"?.*/\1/p')"
[ -n "$REPORT" ] || REPORT="$(printf '%s' "$CMD" | sed -nE 's/.*file=@"?([^";]+)"?.*/\1/p' | head -1)"
REPORT="${REPORT/#\~/$HOME}"
[ -s "$REPORT" ] || { echo "BLOCKED: --attach-file path '$REPORT' not readable — attach the actual report file." >&2; exit 2; }

# Doc identity: slug from --attach-name, else the file basename. Computed early
# because both the second-doc check (5) and the ordinal/H1 logic below need it.
SLUG=$(printf '%s' "$CMD" | sed -E 's/.*--attach-name[= ]+"?agent-run-report-?([^" ]*)\.md"?.*/\1/; s/^[0-9]+-//')
[ -n "$SLUG" ] && [ "$SLUG" != "$CMD" ] || SLUG=$(basename "$REPORT" .md | sed -E "s/^agent-run-report-?//; s/^$AGENT_TASK_GID-?//; s/^[0-9]+-//")
SESS=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

# 5. One report doc per run segment. A second attach in the SAME session with a
#    DIFFERENT slug is a parallel report doc — blocked; update the existing doc
#    and re-attach it instead. A new session (followup segment) resets the marker.
DOCMARK="/tmp/agent-report-doc-$AGENT_TASK_GID"
if [ -s "$DOCMARK" ] && [ -n "$SESS" ]; then
  read -r PREV_SESS PREV_SLUG < "$DOCMARK" || true
  if [ "${PREV_SESS:-}" = "$SESS" ] && [ -n "${PREV_SLUG:-}" ] && [ "$PREV_SLUG" != "$SLUG" ]; then
    echo "BLOCKED: this session already attached report doc '$PREV_SLUG'; attaching a second doc ('$SLUG') splinters the run record. One segment produces ONE report: fold this content into the existing doc and re-attach it under the SAME name (its iteration ordinal stays stable on re-attach, per the watermark rule)." >&2
    exit 2
  fi
fi

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
set_frontmatter tdd "$TDD_FIELD"

# Segment ground truth from the last version stamp; live lane field.
STAMP=$(tail -1 "${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions/$AGENT_TASK_GID.jsonl" 2>/dev/null || true)
if [ -n "$STAMP" ]; then
  set_frontmatter model "$(printf '%s' "$STAMP" | jq -r '.model // empty' 2>/dev/null || true)"
  set_frontmatter effort "$(printf '%s' "$STAMP" | jq -r '.effort // empty' 2>/dev/null || true)"
fi
set_frontmatter agent_lane "$("$HOME/.cursor/skills/asana-field-value.sh" "$AGENT_TASK_GID" "agent_lane" 2>/dev/null || echo "none")"

# Iteration ordinal + normalized attach name + H1 title.
# RE-ATTACH STABILITY: a report already stamped with `iteration: N` KEEPS N —
# the watermark rule legitimately re-attaches the same report after posting
# owed comments, and recomputing minted a phantom ordinal (houdini 2026-07-30:
# the same report attached as -17- then -18-, frontmatter still 17). Only an
# unstamped report gets a fresh ordinal: max existing name ordinal + 1
# (falling back to attachment count + 1 for the pre-scheme era), over the same
# attachment set the watermark reads, so ordinals survive worktree pruning.
ITER=$(grep -m1 -E '^iteration: "?[0-9]+' "$REPORT" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
ATOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
if [ -z "$ITER" ] && [ -n "$ATOKEN" ]; then
  NAMES=$(curl -sf --max-time 20 -H "Authorization: Bearer $ATOKEN" \
    "https://app.asana.com/api/1.0/tasks/$AGENT_TASK_GID/attachments?opt_fields=name" 2>/dev/null \
    | jq -r '.data[]? | .name | select(test("^agent-run-report.*\\.md$"))' 2>/dev/null || true)
  if [ -n "$NAMES" ]; then
    MAXORD=$(printf '%s\n' "$NAMES" | sed -nE 's/^agent-run-report-([0-9]+)-.*/\1/p' | sort -n | tail -1)
    if [ -n "$MAXORD" ]; then
      ITER=$((MAXORD + 1))
    else
      N=$(printf '%s\n' "$NAMES" | grep -c . || true)
      case "$N" in (*[!0-9]*|"") ;; (*) ITER=$((N + 1)) ;; esac
    fi
  else
    ITER=1
  fi
fi
if [ -n "$ITER" ]; then
  set_frontmatter iteration "$ITER"
  # H1 title when the report has none: "# Run report NN: <slug>" (SLUG computed
  # once above, shared with the second-doc check).
  if ! grep -qE '^# Run report ' "$REPORT"; then
    awk -v t="# Run report $ITER: ${SLUG:-report}" '
      { print }
      !done && $0 == "---" && NR > 1 { print ""; print t; done=1 }
    ' "$REPORT" > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  fi
  # Visible stamp under the H1: frontmatter is hidden by markdown previews
  # (operator, 2026-07-30), so the traceability facts get one rendered line.
  if ! grep -q '^_iteration ' "$REPORT"; then
    fmv() { grep -m1 "^$1:" "$REPORT" | sed -E 's/^[^:]+: *"?([^"]*)"?.*/\1/'; }
    # TDD suffix computed OUTSIDE the substitution: a failing `[ ... ] &&` as
    # the last substitution in an assignment returns 1 and set -e killed the
    # whole hook on every non-TDD task (2026-07-31: fields filled, then no
    # stamp, no name ordinal, and NO LINT — exit 1 does not even block).
    TDD_SUFFIX=""
    if [ "$(fmv tdd)" = "tdd" ]; then TDD_SUFFIX=" · [TDD]($(fmv tdd_doc))"; fi
    STAMPLINE="_iteration $ITER · $(fmv model)@$(fmv effort) · generated $(fmv generated) · session $(fmv claude_session_id | cut -c1-8)${TDD_SUFFIX}_"
    awk -v s="$STAMPLINE" '
      { print }
      !done && /^# Run report / { print ""; print s; done=1 }
    ' "$REPORT" > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  fi
fi

# 0. Conflict narration policy (operator, 2026-07-29). Two tiers:
#    a) UPFRONT conflict status (outside a landing context) is noise, always.
#    b) Within a landing context, only NON-TRIVIAL conflicts are worth words —
#       CHANGELOG conflicts happen on nearly every land and resolve
#       mechanically (changelog-union-merge.sh), so narrating one is noise
#       even mid-landing. Block with the lines; the fix is deletion.
CONFLICT_LINES="$(grep -nE 'CONFLICTING|mergeStateStatus|merge[- ]?conflict' "$REPORT" || true)"
CONFLICT_NOISE="$(printf '%s\n' "$CONFLICT_LINES" | grep -viE 'pr-land|landing|land[- ]time|cherry.pick|rebased? at land' || true)"
CHANGELOG_NOISE="$(printf '%s\n' "$CONFLICT_LINES" | grep -iE 'changelog' || true)"
if [ -n "$CONFLICT_NOISE" ]; then
  FAIL+="- Upfront conflict-status narration (conflicts are a landing-time concern owned by pr-land; delete these lines unless they describe the landing itself):
$(echo "$CONFLICT_NOISE" | head -4 | sed 's/^/    /')
"
fi
if [ -n "$CHANGELOG_NOISE" ]; then
  FAIL+="- CHANGELOG-conflict narration (trivial: it conflicts on nearly every land and changelog-union-merge.sh resolves it mechanically — delete; only NON-trivial conflicts earn a mention, and only in landing context):
$(echo "$CHANGELOG_NOISE" | head -4 | sed 's/^/    /')
"
fi

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
#     --semantic (2026-08-19): the haiku judge tier for courtesy enders /
#     forward references; attach is a terminal boundary, latency is fine.
SLOP="$("$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh" "$REPORT" --semantic 2>/dev/null | grep '^HARD' | grep -v 'em dash' | head -6 || true)"
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

# 6. Dead GitHub citations (see header; check 5 ran before the auto-fill).
#    Shapes resolved: issuecomment / discussion_r anchors, pull, issues, commit.
#    ONLY "HTTP 404" from gh api blocks; every other failure (network, rate
#    limit, auth) fails open. Capped at 15 unique URLs so a link-heavy report
#    cannot stall the attach.
if command -v gh >/dev/null 2>&1; then
  DEAD=""
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    OR=$(printf '%s' "$u" | sed -E 's#https://github\.com/([^/]+/[^/]+)(/.*)?$#\1#')
    [ "$OR" != "$u" ] || continue
    UPATH="${u%%\#*}"
    API=""
    case "$u" in
      *#issuecomment-[0-9]*)  API="repos/$OR/issues/comments/${u##*#issuecomment-}" ;;
      *#discussion_r[0-9]*)   API="repos/$OR/pulls/comments/${u##*#discussion_r}" ;;
      *) case "$UPATH" in
           */pull/[0-9]*)   API="repos/$OR/pulls/$(printf '%s' "$UPATH" | sed -E 's#.*/pull/([0-9]+).*#\1#')" ;;
           */issues/[0-9]*) API="repos/$OR/issues/$(printf '%s' "$UPATH" | sed -E 's#.*/issues/([0-9]+).*#\1#')" ;;
           */commit/*)      API="repos/$OR/commits/$(printf '%s' "$UPATH" | sed -E 's#.*/commit/([0-9a-fA-F]+).*#\1#')" ;;
         esac ;;
    esac
    [ -n "$API" ] || continue
    GHERR=$(gh api "$API" --silent 2>&1 >/dev/null) || {
      if printf '%s' "$GHERR" | grep -q "HTTP 404"; then DEAD+="    $u
"; fi
    }
  done < <(grep -oE 'https://github\.com/[^][ )>"`]+' "$REPORT" | sed 's/[.,;:]*$//' | sort -u | head -15)
  if [ -n "$DEAD" ]; then
    FAIL+="- Dead GitHub citations (the cited artifact returns HTTP 404 — it does not exist; fix the link or remove the claim it supports):
$DEAD"
  fi
fi

if [ -z "$FAIL" ]; then
  # Record this segment's report doc identity for the second-doc check (5):
  # session id + slug. Re-attaches (same slug) rewrite it harmlessly. NOT a
  # bare `[ -n ] &&` — a false test as the last command would trip set -e
  # (same failure shape as the TDD_SUFFIX incident above).
  if [ -n "$SESS" ]; then printf '%s %s\n' "$SESS" "$SLUG" > "$DOCMARK"; fi
  # Allow path: normalize the attach NAME to agent-run-report-NN-<slug>.md via
  # updatedInput, so the attachment list orders itself. Idempotent: a name
  # already carrying the computed ordinal passes untouched.
  if [ -n "$ITER" ] && [ -n "${SLUG:-}" ]; then
    WANT="agent-run-report-$ITER-$SLUG.md"
    CUR=$(printf '%s' "$CMD" | sed -E 's/.*--attach-name[= ]+"?([^" ]+)"?.*/\1/')
    if [ "$CUR" != "$CMD " ] && [ -n "$CUR" ] && [ "$CUR" != "$WANT" ]; then
      NEW_CMD=$(printf '%s' "$CMD" | sed -E "s/(--attach-name[= ]+\"?)[^\" ]+(\"?)/\1$WANT\2/")
      jq -n --arg c "$NEW_CMD" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $c}}}'
    fi
  fi
  exit 0
fi

echo "BLOCKED: run report $REPORT violates the template contract:
${FAIL}Fix: RE-READ the template ($TEMPLATE), rewrite the report against it, then retry the attach. Do not delete facts to pass the lint — fix the form only." >&2
exit 2
