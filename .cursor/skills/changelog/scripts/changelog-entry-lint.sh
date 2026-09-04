#!/usr/bin/env bash
# changelog-entry-lint.sh -- mechanical shape checks for CHANGELOG entry lines.
# Companion to ~/.cursor/skills/changelog/SKILL.md; run by lint-md-on-write.sh
# on every CHANGELOG.md write vector, so an agent that over-writes an entry is
# told at write time rather than at review.
#
# Usage: changelog-entry-lint.sh [file] [--fragment]   (stdin when no file)
# Only lines shaped like entries are judged: '- ' bullets, optionally indented.
# Every other line (headings, blank lines, wrapped continuation text) passes
# through; a continuation line is itself a finding on its parent entry's length.
# --fragment: the input is a shell command (sed -i / perl -pi expression)
# rather than file content. Literal \n sequences are split into lines and each
# entry is cut at the quote that closes the expression, so the trailing
# "/' CHANGELOG.md" is not counted against the entry.
#
# Checks:
#   HARD  length over MAX_LEN characters (leading whitespace excluded). 140
#         admits every entry the repos wrote before agents and rejects nearly
#         every mechanism narrative since.
#   HARD  mechanism tail: ', so ', ' so that ', ', since ', ', because ',
#         ' because ', ', which ' after the type prefix. The clause after the
#         connective is the WHY, and the why lives in the commit body.
#   HARD  second sentence: a sentence terminator followed by a capital.
#         'deprecated:' entries are exempt: the repos' own convention is
#         "deprecated: X. Use Y instead."
#   HARD  wrapped continuation: a text line directly under an entry that is
#         neither an entry, a heading, nor blank (file mode only).
#   WARN  no 'type:' prefix (added/changed/fixed/removed/deprecated/security).
#         Older repos wrote bare bullets; warn so a repo that still does is not
#         blocked.
# Output: one 'HARD <n>: <why>: <entry>' or 'WARN ...' line per finding.
# Exit 0 clean, 1 any HARD, 2 usage error.
set -uo pipefail

MAX_LEN="${CHANGELOG_MAX_LEN:-140}"
SRC=/dev/stdin FRAGMENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fragment) FRAGMENT=1 ;;
    -*) echo "changelog-entry-lint: unknown flag $1" >&2; exit 2 ;;
    *) SRC="$1" ;;
  esac
  shift
done
[ -r "$SRC" ] || { echo "changelog-entry-lint: cannot read $SRC" >&2; exit 2; }

normalize() {
  if [ "$FRAGMENT" = 1 ]; then
    # Split literal \n, lift each embedded entry to its own line, cut at the
    # quote that ends the shell expression.
    sed -e 's/\\n/\
/g' | sed -nE 's/^.*(- ([a-z]+: )?[^"'"'"']*).*$/\1/p' | sed -E 's/[[:space:]]*(\/|\\n)?[[:space:]]*$//'
  else
    cat
  fi
}

HARD=0
n=0
prev_entry=""
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n+1))
  entry="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
  case "$entry" in
    "- "*) ;;
    ""|"#"*) prev_entry=""; continue ;;
    *)
      if [ "$FRAGMENT" = 0 ] && [ -n "$prev_entry" ]; then
        echo "HARD $n: wrapped continuation of the entry above (one entry is one line): ${entry:0:90}"; HARD=1
      fi
      prev_entry=""; continue ;;
  esac
  prev_entry="$entry"
  short="${entry:0:90}"; [ ${#entry} -gt 90 ] && short="$short..."
  if [ ${#entry} -gt "$MAX_LEN" ]; then
    echo "HARD $n: entry is ${#entry} chars, cap $MAX_LEN (one clause; the why goes in the commit body): $short"; HARD=1
  fi
  body="${entry#- }"
  body="${body#*: }"   # drop 'type: ' when present
  if printf '%s' "$body" | grep -qE '(, so |, since |, because | so that | because |, which )'; then
    echo "HARD $n: entry explains its mechanism after a connective (drop the clause, keep the outcome): $short"; HARD=1
  fi
  if [ "${entry#- deprecated: }" = "$entry" ] && printf '%s' "$body" | grep -qE '[.!?][[:space:]]+[A-Z]'; then
    echo "HARD $n: entry has a second sentence (one line, one clause): $short"; HARD=1
  fi
  if ! printf '%s' "$entry" | grep -qE '^- (added|changed|fixed|removed|deprecated|security): '; then
    echo "WARN $n: entry lacks a 'type:' prefix (added/changed/fixed/removed/deprecated/security): $short"
  fi
done < <(normalize < "$SRC")
exit $HARD
