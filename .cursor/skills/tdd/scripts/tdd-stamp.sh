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
#
# The stamp is one HTML comment placed right after the metadata table (invisible
# in the rendered doc, survives tdd-lint):
#   <!-- tdd-code-fingerprint: <40 hex> -->
# Stamp AFTER the last code commit of the turn and BEFORE committing the doc
# (the doc commit itself changes only src/docs, which the fingerprint excludes).
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
