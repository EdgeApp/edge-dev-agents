#!/usr/bin/env bash
# require-skill-read-for-scripts.sh — PreToolUse hook (matcher: Bash). Blocks
# executing a skill's companion script before the owning SKILL.md entered this
# run's context. A companion script is one STEP of its skill's contract; bare
# invocation ships the step without the contract around it (asana-get-context
# run bare fetches attachments nobody then opens — the 08-24/08-26 planning
# misses). Complements the substitution blocks (block-raw-asana-api,
# block-raw-gh-writes): those catch improvised REPLACEMENTS for a script,
# this catches the script itself used contract-blind.
#
# Ownership: any execution-position path skills/<name>/scripts/*.sh requires
# <name>'s marker. Shared top-level scripts with one governing skill are
# mapped explicitly below; unmapped shared scripts are exempt (no single
# owner). An invocation whose only arguments are --help or -h is exempt (usage
# text, no step executed).
#
# PHASE SLICES (2026-09-16): /one-shot outgrew the re-attach budget and split
# into a core SKILL.md plus one reference file per phase, so the whole contract
# is no longer in context for every segment; only the core is. A phase's rules
# now arrive the same way a skill's do: the phase's FIRST companion-script call
# requires that phase's slice (unit `one-shot:<slice>`), and the deny delivers
# it. Without this the split would silently relax every moved rule, which is
# how a gate erodes into a formality. The map below is the whole list; a script
# with no entry requires nothing from it and stays quiet.
#
# Markers come from mark-skill-read.sh and
# inject-run-context.sh; on the would-block path the transcript is scanned for
# proof the current body is already in context (slash-command delivery,
# post-compaction re-injection, paged Reads), which writes the marker and
# allows (lib/skill-read-gate.sh, skill_read_credit_from_transcript).
#
# PER-SEGMENT BLAME. What a unit is required BY is decided one command segment
# at a time (split at top-level `;`, `&&`, `||`, newline in the mention-stripped
# view), and the deny quotes the segments that carry the gated call. The set of
# units required is unchanged -- a gate that let an unread contract through
# would be no gate -- but a deny that only says "this command" makes the agent
# re-derive a whole compound command it had right.
#
# A deny (exit 2) cancels the WHOLE Bash command, so the message says so: an
# agent that assumes the rest of a compound command ran loses that work. When an
# earlier segment writes a file with a heredoc, the message says that write was
# cancelled too: re-running only the gated call then fails on the missing file,
# which is how one block turns into two.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat 2>/dev/null || true)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view: a heredoc/echo that merely quotes a script path must
# not fire. Fail-open to raw if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# Command segments of the stripped view, paired with their raw text (for the
# deny message) and whether a heredoc opens before them. One record per line:
# <b64 stripped> <b64 raw> <heredoc-before 0|1>. Fails open to one whole-command
# record, which is the pre-2026-09-16 behaviour.
SEGS=$(CMD_RAW="$CMD" CMD_STRIPPED="$CMD_M" python3 -c '
import base64, os, re
raw = os.environ["CMD_RAW"]; s = os.environ["CMD_STRIPPED"]
if len(s) != len(raw): s = raw
HD = re.compile(r"(?<!<)<<(?!<)-?[ \t]*[\x27\"]?\w")
cuts, depth, start, i = [], 0, 0, 0
while i < len(s):
    c = s[i]
    if c == "(": depth += 1
    elif c == ")": depth = max(0, depth - 1)
    elif depth == 0:
        if s.startswith("&&", i) or s.startswith("||", i):
            cuts.append((start, i)); i += 2; start = i; continue
        if c in ";\n":
            cuts.append((start, i)); i += 1; start = i; continue
    i += 1
cuts.append((start, len(s)))
b = lambda t: base64.b64encode(t.encode()).decode()
for a, e in cuts:
    if s[a:e].strip():
        print(b(s[a:e]), b(raw[a:e].strip()), 1 if HD.search(raw[:a]) else 0)
' 2>/dev/null) || SEGS=""
[ -n "$SEGS" ] || SEGS="$(printf '%s' "$CMD_M" | base64 | tr -d '\n') $(printf '%s' "$CMD" | base64 | tr -d '\n') 0"

EXEC_POS='(^|[;&|(]|\$\(|\b(bash|sh|source)[[:space:]]+)[[:space:]]*[^[:space:]]*'
# Arguments up to the next command separator; help-only when nothing but
# --help/-h (plus stderr/stdout redirections) follows the script path.
ARGS_TAIL='[^;&|)]*'
HELP_ONLY='^[[:space:]]*(--help|-h)([[:space:]]+[0-9]*>.*)?[[:space:]]*$'

# invocations <script-regex> : prints each execution-position invocation of
# the script with its argument tail, one per line, skipping help-only ones.
invocations() {
  printf '%s' "$SEG_M" | grep -oE "${EXEC_POS}$1${ARGS_TAIL}" | while IFS= read -r inv; do
    tail=$(printf '%s' "$inv" | sed -E "s#^.*$1##")
    printf '%s' "$tail" | grep -qE "$HELP_ONLY" || printf '%s\n' "$inv"
  done
}

# need <script-regex> <unit>... : require each unit when the script is invoked
# in the segment under inspection.
need() {
  local re="$1"; shift
  [ -n "$(invocations "$re")" ] && SEG_NEEDED="$SEG_NEEDED $*"
  return 0
}

# segment_units : the units $SEG_M requires, into $SEG_NEEDED.
segment_units() {
  SEG_NEEDED=""
# Skill-directory scripts: owner is the directory name.
for sk in $(invocations 'skills/[a-z0-9-]+/scripts/[^[:space:]]+\.sh' | grep -oE 'skills/[a-z0-9-]+/scripts' | sed -E 's|skills/([a-z0-9-]+)/scripts|\1|' | sort -u); do
  SEG_NEEDED="$SEG_NEEDED $sk"
done

# Shared top-level scripts with one governing skill, and the /one-shot phase
# slice each script's step belongs to. Verified against the real paths:
#   ~/.cursor/skills/{asana-get-context,lint-commit}.sh
#   ~/.config/agent-watcher/{setup-task-workspace,set-tested,update-status,
#                            check-followup-scope}.sh
#   ~/.cursor/skills/{build-and-test,pr-create,one-shot,pr-land,cheese,
#                     asana-task-update}/scripts/*.sh
need 'asana-get-context\.sh([[:space:]]|$)'        task-review one-shot:intake
need 'setup-task-workspace\.sh([[:space:]]|$)'     one-shot:implementation
need 'lint-commit\.sh([[:space:]]|$)'              im one-shot:implementation
need 'set-tested\.sh([[:space:]]|$)'               one-shot:testing
# build-and-test's drive scripts: the ones that build or drive the app on the
# sim (select-ios-sim.sh / slot-preflight.sh only pick and check a slot).
need '(capture-buy-quote|ios-rn-build|ios-rn-build-wait)\.sh([[:space:]]|$)' one-shot:testing
need 'asana-review-field\.sh([[:space:]]|$)'       one-shot:review
need 'pr-create\.sh([[:space:]]|$)'                one-shot:pr
need 'watch-pr\.sh([[:space:]]|$)'                 one-shot:watch
need 'pr-land-[a-z-]+\.sh([[:space:]]|$)'          one-shot:landing
need 'cheese-build\.sh([[:space:]]|$)'             one-shot:landing
need 'check-followup-scope\.sh([[:space:]]|$)'     one-shot:followup

# Argument-sensitive entries. The run-report attach is asana-task-update.sh
# --attach-file of an agent-run-report file (same two-part test
# require-clean-run-report.sh uses); a plan attach goes through the same flag
# and is NOT the report phase.
case "$SEG_M" in
  *asana-task-update.sh*--attach-file*)
    # The report filename is often a variable assigned in an earlier segment, so
    # the agent-run-report half stays whole-command: narrowing it to the segment
    # would let an unread report phase through.
    case "$CMD_M" in *agent-run-report*) SEG_NEEDED="$SEG_NEEDED one-shot:report" ;; esac
    ;;
esac
# update-status.sh: --blocked is the blocked completion whatever status rides
# with it; a plain Complete is the finalize gate.
US_TAIL=$(invocations 'update-status\.sh([[:space:]]|$)')
if [ -n "$US_TAIL" ]; then
  if printf '%s' "$US_TAIL" | grep -qE -- '--blocked'; then
    SEG_NEEDED="$SEG_NEEDED one-shot:blocking"
  elif printf '%s' "$US_TAIL" | grep -qE '[[:space:]]Complete([[:space:]]|$)'; then
    SEG_NEEDED="$SEG_NEEDED one-shot:finalize"
  fi
fi
}

# Walk the segments: NEEDED is their union, BLAME records which segment asked
# for each unit (`<unit> <b64 raw segment> <heredoc-before>`).
NEEDED=""; BLAME=""
while read -r B64M B64RAW HD; do
  [ -n "${B64M:-}" ] || continue
  SEG_M=$(printf '%s' "$B64M" | base64 -d 2>/dev/null) || continue
  segment_units
  for u in $SEG_NEEDED; do
    NEEDED="$NEEDED $u"
    BLAME="$BLAME$u $B64RAW ${HD:-0}
"
  done
done <<SEGRECORDS
$SEGS
SEGRECORDS

[ -n "${NEEDED// /}" ] || exit 0

# Deny-with-body: the mechanism and its rationale live in lib/skill-read-gate.sh,
# shared with the outward-prose gates (lint-md-on-write.sh, slack-prose-gate.sh).
. "$HOME/.config/agent-watcher/hooks/lib/skill-read-gate.sh"
MISSING=$(skill_read_missing $NEEDED)
[ -n "$MISSING" ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
skill_read_credit_from_transcript "$TRANSCRIPT" $MISSING
MISSING=$(skill_read_missing $MISSING)
[ -n "$MISSING" ] || exit 0

# The segments that asked for a still-missing unit, and whether any of them sits
# behind a heredoc whose write the deny cancels.
BLAMED=""; HEREDOC_BEFORE=0
for u in $MISSING; do
  while read -r b64 hd; do
    [ -n "${b64:-}" ] || continue
    [ "${hd:-0}" = "1" ] && HEREDOC_BEFORE=1
    case " $BLAMED " in *" $b64 "*) ;; *) BLAMED="$BLAMED $b64" ;; esac
  done <<BLAMEROWS
$(printf '%s' "$BLAME" | awk -v u="$u" '$1 == u { print $2, $3 }')
BLAMEROWS
done

{
  echo "BLOCKED: this command was DENIED AS A WHOLE and NOTHING in it ran (every other part of a compound command, heredoc writes included, was cancelled too). Act on the contract below, then re-run the ENTIRE command."
  if [ -n "$BLAMED" ]; then
    echo
    echo "Only this part of the command is gated; it calls a script that is a step of a skill or phase contract not yet in this session's context:"
    for b64 in $BLAMED; do printf '%s' "$b64" | base64 -d 2>/dev/null | sed 's/^/    /'; echo; done
  fi
  if [ "$HEREDOC_BEFORE" = "1" ]; then
    echo "An earlier segment writes a file with a heredoc. That write did NOT happen either, so re-running only the gated call would fail on a file that is not there: re-run the whole command, heredoc included."
  fi
  skill_read_deliver $MISSING
} >&2
exit 2
