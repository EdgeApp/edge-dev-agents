#!/usr/bin/env bash
# tdd-stamp.sh — stamp a committed TDD with the fingerprint of the code it
# documents, so freshness is checkable without reading git history.
#
# WHY: the TDD rides in the branch's FIRST commit (tdd doc-rides-the-first-
# commit) and every revision is folded into it, so "last commit touching
# src/docs is older than the last code commit" is true on every healthy branch
# and can no longer mean "stale". The stamp ties the doc to the code TREE
# instead: a hash over every blob at HEAD outside src/docs. Fold, rebase and
# reorder leave the tree alone, so the stamp survives them; any later code
# change moves the tree and the Complete gate (require-tdd-current.sh) blocks
# until the doc is re-read and re-stamped.
#
# Usage:
#   tdd-stamp.sh <repo-dir> <doc-path>            # write/replace the stamp
#   tdd-stamp.sh <repo-dir> --fingerprint         # print HEAD's code fingerprint
#   tdd-stamp.sh <repo-dir> <doc-path> --check    # exit 0 when stamp == HEAD, 1 when
#                                                 # stale, 3 when the doc has no stamp
#   tdd-stamp.sh <repo-dir> <doc-path> --fold     # stamp, then commit the doc as a
#                                                 # fixup of the branch's FIRST commit
#                                                 # (lint-commit.sh, body names the
#                                                 # fingerprint) and slot it; no-op
#                                                 # when the stamp is already current
#                                                 # and the doc is committed
#
# The stamp is one HTML comment placed right after the metadata table (invisible
# in the rendered doc, survives tdd-lint):
#   <!-- tdd-code-fingerprint: <40 hex> -->
# Stamp AFTER the last code commit of the turn and BEFORE committing the doc
# (the doc commit itself changes only src/docs, which the fingerprint excludes).
# Callers of --fold: the tdd skill on the doc's first write (before pr-create),
# and pr-finalize-fixups.sh before every push when the doc was edited since the
# remote head, so a run never re-stamps by hand between rounds.
#
# Exit codes: 0 ok, 1 stale (--check) or error, 2 usage, 3 no stamp (--check)
set -euo pipefail

REPO="${1:-}"; DOC="${2:-}"; MODE="${3:-write}"
[[ -n "$REPO" && -d "$REPO/.git" || -f "$REPO/.git" ]] || { echo "Usage: tdd-stamp.sh <repo-dir> <doc-path>|--fingerprint [--check]" >&2; exit 2; }

fingerprint() {
  git -C "$REPO" ls-tree -r HEAD 2>/dev/null | awk '$4 !~ /^src\/docs\//' | git hash-object --stdin
}
FP="$(fingerprint)"
[[ -n "$FP" ]] || { echo "tdd-stamp: cannot read HEAD tree in $REPO" >&2; exit 1; }

if [[ "$DOC" == "--fingerprint" ]]; then echo "$FP"; exit 0; fi
[[ -n "$DOC" ]] || { echo "Usage: tdd-stamp.sh <repo-dir> <doc-path>|--fingerprint [--check]" >&2; exit 2; }
DOC_PATH="$DOC"; [[ "$DOC_PATH" = /* ]] || DOC_PATH="$REPO/$DOC"
[[ -f "$DOC_PATH" ]] || { echo "tdd-stamp: no such doc $DOC_PATH" >&2; exit 1; }

STAMPED="$(grep -oE '<!-- tdd-code-fingerprint: [0-9a-f]{40} -->' "$DOC_PATH" | head -1 | grep -oE '[0-9a-f]{40}' || true)"

if [[ "$MODE" == "--check" ]]; then
  [[ -n "$STAMPED" ]] || { echo "no-stamp"; exit 3; }
  if [[ "$STAMPED" == "$FP" ]]; then echo "current $FP"; exit 0; fi
  echo "stale doc=$STAMPED head=$FP"; exit 1
fi

# write: replace an existing stamp, else insert after the metadata table (the
# first blank line following the first table row), else append.
node - "$DOC_PATH" "$FP" <<'JS'
const fs = require('fs')
const [path, fp] = process.argv.slice(2)
let s = fs.readFileSync(path, 'utf8')
const stamp = `<!-- tdd-code-fingerprint: ${fp} -->`
const re = /<!-- tdd-code-fingerprint: [0-9a-f]{40} -->/
if (re.test(s)) {
  s = s.replace(re, stamp)
} else {
  const lines = s.split('\n'); const out = []
  let placed = false, inTable = false
  for (const l of lines) {
    out.push(l)
    if (placed) continue
    if (l.startsWith('|')) inTable = true
    else if (inTable && l.trim() === '') { out.push(stamp, ''); placed = true }
  }
  if (!placed) out.push('', stamp)
  s = out.join('\n')
}
fs.writeFileSync(path, s)
console.log(`>> tdd-stamp: ${path} stamped ${fp}`)
JS

if [[ "$MODE" == "--fold" ]]; then
  DOC_REL="${DOC_PATH#$REPO/}"
  if git -C "$REPO" diff --quiet HEAD -- "$DOC_REL" 2>/dev/null && git -C "$REPO" cat-file -e "HEAD:$DOC_REL" 2>/dev/null; then
    echo ">> tdd-stamp: $DOC_REL already committed with this stamp; nothing to fold"; exit 0
  fi
  UPSTREAM="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    || echo "origin/$(git -C "$REPO" remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
    || echo "origin/master")"
  [[ -z "$UPSTREAM" || "$UPSTREAM" == "origin/" ]] && UPSTREAM="origin/master"
  MB="$(git -C "$REPO" merge-base "$UPSTREAM" HEAD 2>/dev/null || true)"
  FIRST="$(git -C "$REPO" rev-list --reverse "${MB:+$MB..}HEAD" 2>/dev/null | head -1)"
  [[ -n "$FIRST" ]] || { echo "tdd-stamp: no branch commit to fold the doc into (upstream $UPSTREAM)" >&2; exit 1; }
  ( cd "$REPO" && "$HOME/.cursor/skills/lint-commit.sh" --fixup "$FIRST" --for auto \
      -m "Stamp the design doc with the fingerprint of the code tree it documents ($FP)" "$DOC_REL" ) >&2
  # Slot only when the doc fixup is still at the tip (lint-commit may already
  # have folded it; an unrelated fixup at HEAD is not ours to move).
  if git -C "$REPO" log -1 --format=%s | grep -q '^fixup! ' \
     && git -C "$REPO" diff --name-only HEAD~1 HEAD -- "$DOC_REL" | grep -q .; then
    ( cd "$REPO" && "$HOME/.cursor/skills/slot-fixup.sh" ) >&2 || exit 1
  fi
  echo ">> tdd-stamp: $DOC_REL folded into $(git -C "$REPO" rev-parse --short "$FIRST")"
fi
