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
python3 - "$DOC_PATH" "$FP" <<'EOF'
import re,sys
path,fp=sys.argv[1],sys.argv[2]
s=open(path).read()
stamp=f'<!-- tdd-code-fingerprint: {fp} -->'
if re.search(r'<!-- tdd-code-fingerprint: [0-9a-f]{40} -->', s):
    s=re.sub(r'<!-- tdd-code-fingerprint: [0-9a-f]{40} -->', stamp, s, count=1)
else:
    lines=s.split('\n'); out=[]; placed=False; in_table=False
    for i,l in enumerate(lines):
        out.append(l)
        if not placed:
            if l.startswith('|'): in_table=True
            elif in_table and l.strip()=='' :
                out.append(stamp); out.append(''); placed=True
    if not placed:
        out.append(''); out.append(stamp)
    s='\n'.join(out)
open(path,'w').write(s)
print(f'>> tdd-stamp: {path} stamped {fp}')
EOF
