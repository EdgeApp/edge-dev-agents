#!/usr/bin/env bash
set -euo pipefail

# changelog-union-merge.sh — mechanically resolve a CHANGELOG.md rebase or
# cherry-pick conflict by union-merging each conflict hunk.
#
# CHANGELOG conflicts in this workflow are always the same shape: upstream
# added entry lines where ours sit. Resolution is deterministic — keep BOTH
# sides (upstream first, ours after), drop exact-duplicate lines (a stale
# branch can carry entries upstream already has), and order entries within
# the merged hunk by type (added → changed → deprecated → fixed → removed →
# security). Non-entry lines (headings, blanks) keep their position.
#
# Usage: changelog-union-merge.sh <repo-dir> [--continue]
#   --continue  after resolving, `git add CHANGELOG.md` and continue the
#               in-progress rebase/cherry-pick non-interactively
# Exit: 0 = resolved (and continued, with --continue), 1 = no conflict
#       markers found / continue failed, 2 = usage

repo_dir="${1:-}"
[ -n "$repo_dir" ] || { echo "usage: changelog-union-merge.sh <repo-dir> [--continue]" >&2; exit 2; }
do_continue=""
[ "${2:-}" = "--continue" ] && do_continue=1

file="$repo_dir/CHANGELOG.md"
[ -f "$file" ] || { echo "no CHANGELOG.md in $repo_dir" >&2; exit 1; }
grep -q '^<<<<<<< ' "$file" || { echo "no conflict markers in $file" >&2; exit 1; }

node -e '
const fs = require("fs");
const file = process.argv[1];
const TYPE_ORDER = ["added", "changed", "deprecated", "fixed", "removed", "security"];
const typeRank = (line) => {
  const m = line.match(/^- (\w+):/);
  const i = m ? TYPE_ORDER.indexOf(m[1]) : -1;
  return i === -1 ? TYPE_ORDER.length : i;
};

const lines = fs.readFileSync(file, "utf8").split("\n");
const out = [];
const touched = new Set();   // sections whose content a conflict hunk modified
let curSection = "__top__";  // heading of the section currently being emitted

function unionMerge(ours, theirs) {
  // During rebase, HEAD (ours) is upstream and theirs is the branch commit —
  // union keeps upstream first, then branch lines not already present.
  const seen = new Set(ours.filter((l) => l.trim() !== ""));
  const merged = [...ours];
  for (const l of theirs) {
    if (l.trim() === "" || seen.has(l)) continue;
    seen.add(l);
    merged.push(l);
  }
  merged.sort((a, b) => typeRank(a) - typeRank(b)); // stable: preserves order within a type
  return merged;
}

function pushOut(seg) {
  for (const l of seg) {
    if (/^## /.test(l)) curSection = l;
    out.push(l);
  }
}

let i = 0;
while (i < lines.length) {
  if (!lines[i].startsWith("<<<<<<< ")) {
    if (/^## /.test(lines[i])) curSection = lines[i];
    out.push(lines[i]); i++; continue;
  }
  i++; // skip <<<<<<<
  const ours = [];
  while (i < lines.length && !lines[i].startsWith("=======")) { ours.push(lines[i]); i++; }
  i++; // skip =======
  const theirs = [];
  while (i < lines.length && !lines[i].startsWith(">>>>>>> ")) { theirs.push(lines[i]); i++; }
  i++; // skip >>>>>>>

  const headingsOf = (ls) => ls.filter((l) => /^## /.test(l));
  const oh = headingsOf(ours);
  const th = headingsOf(theirs);
  if (oh.length || th.length) {
    // Hunk spans section heading(s). Mechanically resolvable when BOTH sides
    // carry the SAME headings in the SAME order (the common rebase shape:
    // entries added around a release boundary both sides agree on): split each
    // side into per-heading segments and union them pairwise. If the sides
    // disagree on the headings themselves, the union would scramble sections —
    // bail for hand resolution.
    if (oh.length !== th.length || oh.some((h, k) => h !== th[k])) {
      console.error("hunk spans a section heading and the two sides disagree on the headings — resolve by hand");
      process.exit(1);
    }
    const split = (ls) => {
      const segs = [[]];
      for (const l of ls) {
        if (/^## /.test(l)) segs.push([l]);
        else segs[segs.length - 1].push(l);
      }
      return segs;
    };
    const os = split(ours);
    const ts = split(theirs);
    touched.add(curSection);
    pushOut(unionMerge(os[0], ts[0]));
    for (let k = 1; k < os.length; k++) {
      const heading = os[k][0];
      pushOut([heading]);
      touched.add(heading);
      pushOut(unionMerge(os[k].slice(1), ts[k].slice(1)));
    }
    continue;
  }

  touched.add(curSection);
  pushOut(unionMerge(ours, theirs));
}
// Section-scoped dedupe: a hunk-local union cannot see an identical entry that
// already sits elsewhere in the SAME section, so dedupe entry lines per section
// — but ONLY in sections a hunk actually touched. A whole-file dedupe silently
// deleted pre-existing duplicates from long-released sections during the
// 2026-07-14 Banxa land; historical sections are immutable record, not ours to
// clean.
const deduped = [];
let sectionSeen = new Set();
let inTouched = touched.has("__top__");
for (const line of out) {
  if (/^## /.test(line)) { sectionSeen = new Set(); inTouched = touched.has(line); }
  if (inTouched && /^- /.test(line)) {
    if (sectionSeen.has(line)) continue;
    sectionSeen.add(line);
  }
  deduped.push(line);
}
fs.writeFileSync(file, deduped.join("\n"));
' "$file"

echo "resolved: $file"

if [ -n "$do_continue" ]; then
  cd "$repo_dir"
  git add CHANGELOG.md
  # git-path resolves correctly in worktrees, where .git is a file not a dir.
  gitdir_path() { git rev-parse --git-path "$1"; }
  if [ -d "$(gitdir_path rebase-merge)" ] || [ -d "$(gitdir_path rebase-apply)" ]; then
    GIT_EDITOR=true git rebase --continue
  elif [ -f "$(gitdir_path CHERRY_PICK_HEAD)" ]; then
    GIT_EDITOR=true git cherry-pick --continue
  else
    echo "no rebase or cherry-pick in progress" >&2; exit 1
  fi
fi
