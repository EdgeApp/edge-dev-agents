#!/usr/bin/env bash
set -euo pipefail

# changelog-union-merge.sh — mechanically resolve a CHANGELOG.md rebase,
# cherry-pick or merge conflict by union-merging each conflict hunk.
#
# DEFAULT (rebase / cherry-pick) mode. CHANGELOG conflicts in that workflow are
# always the same shape: upstream added entry lines where ours sit. Resolution
# is deterministic — keep BOTH sides (upstream first, ours after), drop
# exact-duplicate lines (a stale branch can carry entries upstream already has),
# and order entries within the merged hunk by type (added → changed →
# deprecated → fixed → removed → security). Non-entry lines (headings, blanks)
# keep their position. A hunk whose two sides disagree on their SECTION
# HEADINGS is refused, because a blind union would scramble sections.
#
# RELEASE-MERGE mode (--release-merge), added 2026-08-26 for /develop-staging.
# The develop→staging release merge produces a hunk shape the default mode
# always refuses: develop carries whole release sections (`## 4.51.0 (staging)`,
# plus any hotfix sections) that staging has never seen, so the two sides'
# heading lists differ by construction. This mode merges the two heading
# sequences in order, unions the entries of sections BOTH sides carry, and
# inserts one-sided sections whole. It still refuses anything genuinely
# ambiguous: if resolving would require REORDERING sections (each side's next
# heading appears later on the other side), it bails exactly like the default.
# The flag is opt-in and changes nothing when absent, so pr-land's behavior is
# untouched.
#
# Usage: changelog-union-merge.sh <repo-dir> [--release-merge] [--continue]
#   --release-merge  allow heading-superset hunks (develop→staging shape)
#   --continue       after resolving, `git add CHANGELOG.md` and continue the
#                    in-progress rebase / cherry-pick / merge non-interactively
# Exit: 0 = resolved (and continued, with --continue), 1 = no conflict
#       markers found / unresolvable hunk / continue failed, 2 = usage

repo_dir="${1:-}"
[ -n "$repo_dir" ] || { echo "usage: changelog-union-merge.sh <repo-dir> [--release-merge] [--continue]" >&2; exit 2; }
shift
do_continue=""
release_merge=""
while [ $# -gt 0 ]; do
  case "$1" in
    --continue) do_continue=1 ;;
    --release-merge) release_merge=1 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

file="$repo_dir/CHANGELOG.md"
[ -f "$file" ] || { echo "no CHANGELOG.md in $repo_dir" >&2; exit 1; }
grep -q '^<<<<<<< ' "$file" || { echo "no conflict markers in $file" >&2; exit 1; }

node -e '
const fs = require("fs");
const file = process.argv[1];
const releaseMerge = process.argv[2] === "1";
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

// ---- release-merge helpers (only reachable with --release-merge) ------------

// A section is identified by its version token, not its whole heading, so
// `## 4.51.0 (staging)` and `## 4.51.0 (2026-08-26)` are the SAME section.
const sectionKey = (h) => {
  const m = h.match(/^##\s+(\S+)/);
  return m ? m[1] : h;
};
const isDated = (h) => /\(\d{4}-\d{2}-\d{2}\)/.test(h);
// A dated heading outranks a `(staging)` placeholder for the same version;
// otherwise develop (theirs) wins, since dating a release happens on develop.
const pickHeading = (ourH, theirH) => {
  if (isDated(ourH) && !isDated(theirH)) return ourH;
  return theirH;
};

const splitSections = (ls) => {
  const pre = [];
  const secs = [];
  for (const l of ls) {
    if (/^## /.test(l)) secs.push({ heading: l, body: [] });
    else (secs.length ? secs[secs.length - 1].body : pre).push(l);
  }
  return { pre, secs };
};

// Give a body the canonical shape (one blank, entries, one blank) when it is
// nothing but blanks and entry lines. Bodies carrying prose are left alone.
const normalizeBody = (body) => {
  const entries = body.filter((l) => l.trim() !== "");
  if (entries.length === 0) return [""];
  if (!entries.every((l) => /^- /.test(l))) return body;
  return ["", ...entries, ""];
};

// Order-preserving merge of the two sides section sequences. Returns null when
// resolving would require reordering, which is not mechanically safe.
function mergeSectionSequences(ours, theirs) {
  const o = splitSections(ours);
  const t = splitSections(theirs);
  const oKeys = o.secs.map((s) => sectionKey(s.heading));
  const tKeys = t.secs.map((s) => sectionKey(s.heading));
  const merged = [];
  let i = 0;
  let j = 0;
  while (i < o.secs.length || j < t.secs.length) {
    if (i < o.secs.length && j < t.secs.length && oKeys[i] === tKeys[j]) {
      merged.push({
        heading: pickHeading(o.secs[i].heading, t.secs[j].heading),
        body: normalizeBody(unionMerge(o.secs[i].body, t.secs[j].body))
      });
      i++; j++; continue;
    }
    const theirsOnly = j < t.secs.length && !oKeys.slice(i).includes(tKeys[j]);
    if (theirsOnly) { merged.push(t.secs[j]); j++; continue; }
    const oursOnly = i < o.secs.length && !tKeys.slice(j).includes(oKeys[i]);
    if (oursOnly) { merged.push(o.secs[i]); i++; continue; }
    return null;
  }
  const outLines = [...unionMerge(o.pre, t.pre)];
  const headings = [];
  for (const s of merged) {
    outLines.push(s.heading);
    headings.push(s.heading);
    outLines.push(...s.body);
  }
  return { lines: outLines, headings };
}

// ---- main hunk walk ---------------------------------------------------------

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
    // bail for hand resolution, unless --release-merge is in effect.
    if (oh.length !== th.length || oh.some((h, k) => h !== th[k])) {
      if (!releaseMerge) {
        console.error("hunk spans a section heading and the two sides disagree on the headings — resolve by hand");
        process.exit(1);
      }
      const merged = mergeSectionSequences(ours, theirs);
      if (merged === null) {
        console.error("release-merge: the two sides order their release sections differently — resolve by hand");
        process.exit(1);
      }
      touched.add(curSection);
      for (const h of merged.headings) touched.add(h);
      pushOut(merged.lines);
      continue;
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
// Release merges splice whole sections together, which can leave a run of blank
// lines at a seam. Collapse those runs — release-merge only, so the default
// mode byte-for-byte matches what it produced before this mode existed.
let final = deduped;
if (releaseMerge) {
  final = [];
  for (const line of deduped) {
    if (line.trim() === "" && final.length && final[final.length - 1].trim() === "") continue;
    final.push(line);
  }
}
fs.writeFileSync(file, final.join("\n"));
' "$file" "${release_merge:-0}"

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
  elif [ -f "$(gitdir_path MERGE_HEAD)" ]; then
    GIT_EDITOR=true git merge --continue
  else
    echo "no rebase, cherry-pick or merge in progress" >&2; exit 1
  fi
fi
