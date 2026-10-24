#!/usr/bin/env bash
set -euo pipefail

# point-release-ship.sh — ship an edge-react-gui point release (X.Y.Z, Z > 0).
#
# The release is whatever Asana marks for it: every task whose "Release (4.x.x)"
# field is "Y.Z" (4.52.1 -> "52.1"). point-release-plan.js resolves those tasks
# to develop commits: a GUI PR's own commits, or for a dependency PR the develop
# commit that pinned the published version carrying it. Each change already
# exists on develop; this script brings it to master and staging and cuts the
# release:
#
#   develop  "X.Y.Z version bump": the release's CHANGELOG entries move out of
#            "Unreleased (develop)" into a dated "## X.Y.Z (date)" section in
#            the shared entry type order (release-lib.js sortEntries), any
#            "(staging)" heading master already dated takes master's date, and
#            package.json/package-lock.json move to X.Y.Z when develop is still
#            on the X.Y line.
#   master   the picks (cherry-pick -x), then a "X.Y.Z version bump" commit with
#            the same CHANGELOG section and the version.
#   staging  the picks, then develop's bump carried over as a cherry-pick: the
#            same CHANGELOG transform applied to staging's file (develop's hunk
#            does not apply to it) and a "(cherry picked from commit <sha>)"
#            trailer naming develop's bump.
#
# Then the parity gate: master and staging must have received the same change
# (CHANGELOG.md aside) and all three branches the same X.Y.Z section, in the
# shared entry type order (release-lib.js orderErrors). A real run
# verifies master and staging, pushes develop, staging, master (never forced),
# then the lightweight vX.Y.Z tag on master's bump commit. What it pushes is
# the commits the dry run published as inspection tags when the rebuild
# matches them (same base, tree, and commit contents), else the rebuild.
#
# Everything happens in THROWAWAY git worktrees on temp branches. The caller's
# checkout is never touched. staging-cherry-pick.sh is not reused: it checks
# out staging in the caller's repo.
#
# Commits are made with hooks off (core.hooksPath=/dev/null): the picks already
# passed develop's checks, the bump commits touch CHANGELOG and version only,
# and a real run runs the full repo verify on master and staging before any push.
#
# Usage: point-release-ship.sh --version X.Y.Z [options]
#   --version X.Y.Z      the point release to ship (required)
#   --repo <path>        default: $EDGE_GUI_DIR or ~/git/edge-react-gui
#   --date YYYY-MM-DD    release date for the CHANGELOG heading (default: today)
#   --dry-run            do everything except the pushes and the vX.Y.Z tag
#   --yes                skip the interactive push confirmation
#   --skip-task <gid>    leave this Asana task out of the release (repeatable)
#   --pick <sha>         add a develop commit to the picks (repeatable)
#   --entries-file <f>   CHANGELOG entries for the section, one "- kind: text"
#                        per line, replacing the generated list
#   --build-config-ready the master build server already carries the config the
#                        picks' schema change needs
#   --master/--staging/--develop <branch>   default: master/staging/develop
#   --remote <name>      default: origin
#   --keep-workspace     leave the temp worktrees for inspection
#   --no-publish         skip the dry-run inspection tags
#   --tag-prefix <ns>    namespace for those tags (default: dryrun); refuses v*
#
# A re-run after a partial push is safe: a develop bump already on the remote is
# reused, picks staging or master already carry are skipped, and pushes that
# change nothing succeed as no-ops.
#
# Exit: 0 done, 1 error, 2 needs operator input.
# The last line is always `RESULT: <verdict>`:
#   ok                done (pushed and tagged, or a clean dry run)
#   unmerged          a release task has an open PR (a real run only)
#   not-on-develop    a release task's change cannot be found on develop
#   conflicts         a pick conflicted outside CHANGELOG.md
#   parity-mismatch   master and staging received different changes
#   build-config      the picks change the build config schema
#   aborted           operator declined the push
#   error             anything else

REPO="${EDGE_GUI_DIR:-$HOME/git/edge-react-gui}"
VERSION=""
REL_DATE=""
DRY_RUN=""
ASSUME_YES=""
MASTER="master"
STAGING="staging"
DEVELOP="develop"
REMOTE="origin"
KEEP_WS=""
PUBLISH=1
TAG_PREFIX="dryrun"
BUILD_CONFIG_READY=""
ENTRIES_FILE=""
SKIP_TASKS=()
EXTRA_PICKS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2#v}"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --date) REL_DATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-task) SKIP_TASKS+=("$2"); shift 2 ;;
    --pick) EXTRA_PICKS+=("$2"); shift 2 ;;
    --entries-file) ENTRIES_FILE="$2"; shift 2 ;;
    --build-config-ready) BUILD_CONFIG_READY=1; shift ;;
    --master) MASTER="$2"; shift 2 ;;
    --staging) STAGING="$2"; shift 2 ;;
    --develop) DEVELOP="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --keep-workspace) KEEP_WS=1; shift ;;
    --no-publish) PUBLISH=""; shift ;;
    --tag-prefix) TAG_PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '4,74p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo "RESULT: error"; exit 1 ;;
  esac
done

PHASES="Preflight Tasks Workspace Develop-bump Master-picks Master-bump Staging-picks Staging-bump Parity Build-config Verify Reviewed Push Tag"
# shellcheck source=../../release-merge-lib.sh
. "$HOME/.cursor/skills/release-merge-lib.sh"
# Entry type order, entry shape and the app version bump, shared with
# changelog-union-merge.sh, verify-repo.sh and staging-release-merge.sh.
RELEASE_LIB="$HOME/.cursor/skills/release-lib.js"

HERE="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="${TMPDIR:-/tmp}"; TMPROOT="${TMPROOT%/}"
LOG="$TMPROOT/point-release.$$.log"
BUILD_CONFIG_FILES="src/envConfig.ts src/configKeysSchema.ts"
NOHOOKS=(-c core.hooksPath=/dev/null)
WT=""
WTS=()

# ---------------------------------------------------------------- preflight --
hdr "Preflight"
case "$VERSION" in
  [0-9]*.[0-9]*.[1-9]*) ;;
  "") die "--version X.Y.Z is required" ;;
  *) die "$VERSION is not a point release (X.Y.Z with Z > 0); X.Y.0 ships through /staging-master" ;;
esac
[ -e "$REPO/.git" ] || die "not a git repo: $REPO"
REPO="$(cd "$REPO" && pwd)"
LINE="${VERSION%.*}"
PATCH="${VERSION##*.}"
PREV="$LINE.$((PATCH - 1))"

git -C "$REPO" fetch --quiet --tags "$REMOTE" "$MASTER" "$STAGING" "$DEVELOP" || die "fetch failed"
for b in "$MASTER" "$STAGING" "$DEVELOP"; do
  git -C "$REPO" rev-parse --verify --quiet "$REMOTE/$b" >/dev/null || die "no such ref: $REMOTE/$b"
done
ver_of() { git -C "$REPO" show "$1:package.json" | read_json_field version; }
MASTER_V="$(ver_of "$REMOTE/$MASTER")"
STAGING_V="$(ver_of "$REMOTE/$STAGING")"
DEVELOP_V="$(ver_of "$REMOTE/$DEVELOP")"
[ "$MASTER_V" = "$PREV" ] || die "$MASTER is at $MASTER_V; $VERSION ships onto $PREV"
if [ -n "$(git -C "$REPO" ls-remote --tags "$REMOTE" "refs/tags/v$VERSION")" ]; then
  die "tag v$VERSION already exists on $REMOTE; $VERSION is already released"
fi
if git -C "$REPO" rev-parse --verify --quiet "refs/tags/v$VERSION" >/dev/null; then
  die "a local tag v$VERSION exists that $REMOTE does not have; delete it (git tag -d v$VERSION) and re-run"
fi
REL_DATE="${REL_DATE:-$(date +%Y-%m-%d)}"
case "$REL_DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "--date must be YYYY-MM-DD, got: $REL_DATE" ;;
esac
if [ -n "$ENTRIES_FILE" ]; then
  [ -s "$ENTRIES_FILE" ] || die "--entries-file $ENTRIES_FILE is missing or empty"
  bad="$(node -e 'const { ENTRY_RE } = require(process.argv[1]); console.log(require("fs").readFileSync(process.argv[2], "utf8").split("\n").filter((l) => l && !ENTRY_RE.test(l)).join("\n"))' "$RELEASE_LIB" "$ENTRIES_FILE")"
  [ -z "$bad" ] || die "--entries-file lines must read '- <kind>: <text>'; bad: $(head -1 <<< "$bad")"
fi
say "release $VERSION dated $REL_DATE; $MASTER $MASTER_V, $STAGING $STAGING_V, $DEVELOP $DEVELOP_V"
step Preflight ok "$MASTER $MASTER_V -> $VERSION; $STAGING $STAGING_V, $DEVELOP $DEVELOP_V; date $REL_DATE"

# -------------------------------------------------------------------- tasks --
hdr "Release tasks (Asana Release ${VERSION#*.})"
PLAN="$TMPROOT/point-release.$$.plan.json"
plan_args=(--repo "$REPO" --version "$VERSION" --remote "$REMOTE" --master "$MASTER" --develop "$DEVELOP")
for g in "${SKIP_TASKS[@]+"${SKIP_TASKS[@]}"}"; do plan_args+=(--skip-task "$g"); done
for p in "${EXTRA_PICKS[@]+"${EXTRA_PICKS[@]}"}"; do plan_args+=(--pick "$p"); done
node "$HERE/point-release-plan.js" "${plan_args[@]}" >"$PLAN" 2>>"$LOG" \
  || { tail -5 "$LOG" >&2; die "could not resolve the release tasks (log: $LOG)"; }
# pj <js-expr over p>: print an expression over the plan, one line per array item.
pj() { node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=new Function("p","return ("+process.argv[2]+")")(p);if(Array.isArray(v))v.forEach(x=>console.log(x));else if(v!=null)console.log(v)' "$PLAN" "$1"; }

N_TASKS="$(pj 'p.tasks.length')"
[ "$N_TASKS" -gt 0 ] || die "no Asana task is marked Release $(pj 'p.option'); nothing to ship"
pj 'p.tasks.map(t=>`  ${t.skipped?"[skipped] ":""}${t.name}  (${t.url})`+t.prs.map(r=>`\n      ${r.url}  ${r.state.toLowerCase()}${r.note?", "+r.note:""}`).join(""))'
echo
echo "  picks, in develop order:"
pj 'p.picks.length?p.picks.map(c=>`    ${c.short} ${c.subject}  [${c.source}]`):["    none"]'
DEP_LINES="$(pj 'p.deps.map(d=>`    ${d.repo} ${d.from} -> ${d.to} (carries ${d.versions.slice().reverse().join(", ")})`)')"
if [ -n "$DEP_LINES" ]; then
  echo "  dependency versions riding along (every entry below ships):"
  printf '%s\n' "$DEP_LINES"
fi
echo

BLOCKERS="$(pj 'p.blockers.map(b=>`  ${b.reason}`)')"
if [ -n "$BLOCKERS" ]; then
  hdr "STOP: release changes not found on $DEVELOP"
  printf '%s\n' "$BLOCKERS"
  echo
  echo "Land each change on $DEVELOP first, name a commit with --pick, or leave the"
  echo "task out with --skip-task <gid>."
  step Tasks stopped "$(grep -c . <<< "$BLOCKERS") task change(s) not on $DEVELOP"
  finish not-on-develop 2
fi
UNMERGED="$(pj 'p.unmerged.map(u=>`  ${u.url}  ${u.title}  (task ${u.task}: ${u.taskName})`)')"
N_PICKS="$(pj 'p.picks.length')"
if [ -n "$UNMERGED" ]; then
  if [ -z "$DRY_RUN" ]; then
    hdr "STOP: release tasks with open PRs"
    printf '%s\n' "$UNMERGED"
    echo
    echo "Merge each PR into $DEVELOP and re-run, or ship without its task with"
    echo "--skip-task <gid>."
    step Tasks stopped "$(grep -c . <<< "$UNMERGED") open PR(s); merge them or --skip-task"
    finish unmerged 2
  fi
  say "open PRs, left out of this dry run (a real run stops on them):"
  printf '%s\n' "$UNMERGED"
fi
[ "$N_PICKS" -gt 0 ] || die "no merged change to ship for $VERSION"
SHAS="$(pj 'p.picks.map(c=>c.sha)')"

ENTRIES="$TMPROOT/point-release.$$.entries"
if [ -n "$ENTRIES_FILE" ]; then
  grep -v '^$' "$ENTRIES_FILE" >"$ENTRIES"
  ENTRY_SRC="operator --entries-file"
else
  pj 'p.entries.map(e=>e.text)' >"$ENTRIES"
  ENTRY_SRC="generated from the picks"
fi
[ -s "$ENTRIES" ] || die "no CHANGELOG entries for $VERSION; the picks added none, so pass --entries-file"
node -e 'const fs = require("fs"); const f = process.argv[2]; fs.writeFileSync(f, require(process.argv[1]).sortEntries(fs.readFileSync(f, "utf8").split("\n").filter(Boolean)).join("\n") + "\n")' "$RELEASE_LIB" "$ENTRIES"
echo "  CHANGELOG entries ($ENTRY_SRC):"
sed 's/^/    /' "$ENTRIES"
TASK_DETAIL="$N_PICKS pick(s) from $N_TASKS task(s); $(grep -c . "$ENTRIES") entr(y/ies)"
if [ -n "$UNMERGED" ]; then
  step Tasks warn "$TASK_DETAIL; $(grep -c . <<< "$UNMERGED") open PR(s) left out (a real run stops)"
else
  step Tasks ok "$TASK_DETAIL${SKIP_TASKS[0]+; skipped ${SKIP_TASKS[*]}}"
fi

# --------------------------------------------------------------- workspace ---
cleanup() {
  [ -n "$KEEP_WS" ] && return 0
  local w b
  for w in "${WTS[@]+"${WTS[@]}"}"; do
    git -C "$REPO" worktree remove --force "$w" >/dev/null 2>&1 || true
    rm -rf "$w" >/dev/null 2>&1 || true
  done
  for b in "$MASTER" "$STAGING" "$DEVELOP"; do
    git -C "$REPO" branch -D "point-release/$VERSION-$b" >/dev/null 2>&1 || true
  done
  return 0
}
trap cleanup EXIT

hdr "Workspace"
# new_wt <branch>: sets NEW_WT. Not a $(...) function: WTS (read by cleanup)
# and die must run in this shell.
NEW_WT=""
new_wt() {
  local path="$TMPROOT/point-release-$VERSION-$1-$$" tmp="point-release/$VERSION-$1"
  git -C "$REPO" worktree remove --force "$path" >/dev/null 2>&1 || true
  git -C "$REPO" branch -D "$tmp" >/dev/null 2>&1 || true
  git -C "$REPO" worktree add --quiet -b "$tmp" "$path" "$REMOTE/$1" >>"$LOG" 2>&1 || die "worktree add for $1 failed (log: $LOG)"
  WTS+=("$path")
  NEW_WT="$path"
}
new_wt "$DEVELOP"; WT_DEV="$NEW_WT"
new_wt "$MASTER"; WT_MASTER="$NEW_WT"
new_wt "$STAGING"; WT_STG="$NEW_WT"
WT="$WT_MASTER"
step Workspace ok "worktrees for $DEVELOP, $MASTER, $STAGING under $TMPROOT"

# ------------------------------------------------------------ shared steps ---
MASTER_CL="$TMPROOT/point-release.$$.master-CHANGELOG.md"
git -C "$REPO" show "$REMOTE/$MASTER:CHANGELOG.md" >"$MASTER_CL"

# changelog_cut <file>: move the entries into a dated X.Y.Z section placed above
# the first release heading older than X.Y.Z, and give every "(staging)" heading
# master already dated master's date. Prints one ">>" line per change and one
# "!! not in Unreleased" line per entry it did not find there (dependency
# entries never are; a GUI entry reworded on develop leaves its old copy).
changelog_cut() {
  node - "$1" "$VERSION" "$REL_DATE" "$ENTRIES" "$MASTER_CL" <<'NODE'
const fs = require("fs");
const [file, version, date, entriesFile, masterFile] = process.argv.slice(2);
const entries = fs.readFileSync(entriesFile, "utf8").split("\n").filter(Boolean);
let lines = fs.readFileSync(file, "utf8").split("\n");
const sv = (v) => v.split(".").map(Number);
const older = (a, b) => { const x = sv(a), y = sv(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i]; return false; };
const HEAD = /^## (\d+\.\d+\.\d+) \((.+)\)$/;
if (lines.some((l) => l.startsWith(`## ${version} (`))) { console.log(`!! already has a ## ${version} section, left as-is`); process.exit(0); }

const masterDates = new Map();
for (const l of fs.readFileSync(masterFile, "utf8").split("\n")) {
  const m = l.match(HEAD);
  if (m && /^\d{4}-\d{2}-\d{2}$/.test(m[2])) masterDates.set(m[1], m[2]);
}
lines = lines.map((l) => {
  const m = l.match(HEAD);
  if (m && m[2] === "staging" && masterDates.has(m[1])) {
    console.log(`>> dated ${m[1]} (staging) -> ${masterDates.get(m[1])}, as on master`);
    return `## ${m[1]} (${masterDates.get(m[1])})`;
  }
  return l;
});

const unrel = lines.findIndex((l) => /^## Unreleased/.test(l));
const nextHead = (from) => { for (let i = from + 1; i < lines.length; i++) if (lines[i].startsWith("## ")) return i; return lines.length; };
if (unrel !== -1) {
  const end = nextHead(unrel);
  for (const e of entries) {
    const at = lines.slice(unrel + 1, end).indexOf(e);
    if (at === -1) { console.log(`!! not in Unreleased: ${e.slice(0, 100)}`); continue; }
    lines.splice(unrel + 1 + at, 1);
  }
  // Exactly one blank line between the (possibly emptied) Unreleased section
  // and whatever follows it.
  let e2 = nextHead(unrel);
  while (e2 - 1 > unrel && lines[e2 - 1] === "" && lines[e2 - 2] === "") { lines.splice(e2 - 1, 1); e2--; }
}
const at = lines.findIndex((l) => { const m = l.match(HEAD); return m && older(m[1], version); });
if (at === -1) { console.error(`no release heading older than ${version}`); process.exit(1); }
lines.splice(at, 0, `## ${version} (${date})`, "", ...entries, "");
console.log(`>> opened ## ${version} (${date}) with ${entries.length} entr(y/ies)`);
fs.writeFileSync(file, lines.join("\n"));
NODE
}

# version_bump <worktree>: move package.json and package-lock.json to X.Y.Z when
# the branch is still on the X.Y line below it; a branch on a later line keeps
# its version.
version_bump() {
  node - "$1" "$VERSION" "$RELEASE_LIB" <<'NODE'
const fs = require("fs");
const [wt, version, lib] = process.argv.slice(2);
const cur = JSON.parse(fs.readFileSync(`${wt}/package.json`, "utf8")).version;
const [a, b, c] = cur.split(".").map(Number);
const [x, y, z] = version.split(".").map(Number);
if (a !== x || b !== y || c >= z) { console.log(`kept ${cur} (not on the ${x}.${y} line below ${version})`); process.exit(0); }
try { require(lib).bumpAppVersion(wt, version); } catch (e) { console.error(e.message); process.exit(1); }
console.log(`${cur} -> ${version}`);
NODE
}

# pick_all <worktree> <branch> <phase>: cherry-pick -x every pick the branch
# lacks. A CHANGELOG.md conflict keeps the branch's file (the bump commit writes
# the release section); any other conflict stops the run. changelog-union-merge.sh
# is not used here: it would carry each pick's develop entries into the branch,
# while the release section comes only from the one entry list, which is what
# keeps master's and staging's sections identical.
PICKED=0; ALREADY=0
pick_all() {
  local wt="$1" br="$2" phase="$3" c files rest
  PICKED=0; ALREADY=0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if [ -n "$(git -C "$wt" log --format=%H -1 --grep="cherry picked from commit $c" "$REMOTE/$br" --)" ] \
      || [ "$(git -C "$wt" cherry HEAD "$c" "$c^" 2>/dev/null | cut -c1)" = "-" ]; then
      ALREADY=$((ALREADY + 1)); say "$br already has $(git -C "$REPO" log -1 --format='%h %s' "$c")"; continue
    fi
    if git -C "$wt" "${NOHOOKS[@]}" cherry-pick -x "$c" >>"$LOG" 2>&1; then
      PICKED=$((PICKED + 1)); say "$br <- $(git -C "$REPO" log -1 --format='%h %s' "$c")"; continue
    fi
    files="$(git -C "$wt" diff --name-only --diff-filter=U)"
    rest="$(grep -v '^CHANGELOG\.md$' <<< "$files" || true)"
    if [ -n "$files" ] && [ -z "$rest" ]; then
      git -C "$wt" checkout --ours -- CHANGELOG.md && git -C "$wt" add CHANGELOG.md
      if git -C "$wt" diff --cached --quiet; then
        git -C "$wt" "${NOHOOKS[@]}" cherry-pick --skip >>"$LOG" 2>&1
        ALREADY=$((ALREADY + 1)); say "$br: $(git -C "$REPO" log -1 --format=%h "$c") is empty once CHANGELOG.md keeps $br's side, skipped"
      else
        GIT_EDITOR=true git -C "$wt" "${NOHOOKS[@]}" cherry-pick --continue >>"$LOG" 2>&1 || die "cherry-pick --continue failed on $br (log: $LOG)"
        PICKED=$((PICKED + 1)); say "$br <- $(git -C "$REPO" log -1 --format=%h "$c"), keeping $br's CHANGELOG.md"
      fi
      continue
    fi
    if [ -z "$files" ] && git -C "$wt" diff --cached --quiet && git -C "$wt" diff --quiet; then
      git -C "$wt" "${NOHOOKS[@]}" cherry-pick --skip >>"$LOG" 2>&1
      ALREADY=$((ALREADY + 1)); say "$br: $(git -C "$REPO" log -1 --format=%h "$c") is already applied (empty pick), skipped"
      continue
    fi
    [ -n "$files" ] || { tail -20 "$LOG" >&2; die "cherry-pick of $c onto $br failed without conflicts (log: $LOG)"; }
    hdr "STOP: $(git -C "$REPO" log -1 --format='%h %s' "$c") conflicts on $br"
    printf '%s\n' "$rest" | sed 's/^/  /'
    echo
    while IFS= read -r f; do
      [ -n "$f" ] && git -C "$wt" --no-pager diff -- "$f" | sed -n '1,30p' | sed 's/^/    /'
    done <<< "$rest"
    echo
    echo "A lockfile or package.json conflict usually means an earlier $DEVELOP commit"
    echo "(a prior pin of the same package) is missing from $br; add it with --pick <sha>."
    echo "Anything else needs the change reworked on $DEVELOP first."
    git -C "$wt" cherry-pick --abort >/dev/null 2>&1 || true
    step "$phase" stopped "$(git -C "$REPO" log -1 --format=%h "$c") conflicts on $(tr '\n' ' ' <<< "$rest")"
    finish conflicts 2
  done <<< "$SHAS"
}

# --------------------------------------------------------------- develop -----
hdr "Develop: $VERSION version bump"
DEV_BUMP="$(git -C "$WT_DEV" log --format=%H -1 --first-parent --grep="^$VERSION version bump\$" "$REMOTE/$DEVELOP" --)"
DEV_NEW=""
if [ -n "$DEV_BUMP" ]; then
  say "$DEVELOP already has $(git -C "$WT_DEV" log -1 --format='%h %s' "$DEV_BUMP")"
  step Develop-bump skipped "already on $REMOTE/$DEVELOP: $(git -C "$WT_DEV" rev-parse --short "$DEV_BUMP")"
else
  CUT_OUT="$(changelog_cut "$WT_DEV/CHANGELOG.md")" || die "could not cut the $VERSION section on $DEVELOP"
  printf '%s\n' "$CUT_OUT"
  VB="$(version_bump "$WT_DEV")" || die "version bump failed on $DEVELOP"
  git -C "$WT_DEV" add CHANGELOG.md package.json package-lock.json
  git -C "$WT_DEV" "${NOHOOKS[@]}" commit --quiet -m "$VERSION version bump" >>"$LOG" 2>&1 || die "develop bump commit failed (log: $LOG)"
  DEV_BUMP="$(git -C "$WT_DEV" rev-parse HEAD)"
  DEV_NEW=1
  MISSED="$(grep -c '^!! not in Unreleased' <<< "$CUT_OUT" || true)"
  if [ "$MISSED" -gt 0 ]; then
    step Develop-bump warn "$(git -C "$WT_DEV" rev-parse --short HEAD); version $VB; $MISSED entr(y/ies) not in Unreleased (expected for dependency entries)"
  else
    step Develop-bump ok "$(git -C "$WT_DEV" rev-parse --short HEAD); version $VB"
  fi
fi
DEV_BUMP_SHORT="$(git -C "$WT_DEV" rev-parse --short "$DEV_BUMP")"

# ---------------------------------------------------------------- master -----
hdr "Master: picks"
pick_all "$WT_MASTER" "$MASTER" Master-picks
step Master-picks ok "$PICKED picked, $ALREADY already present"
hdr "Master: $VERSION version bump"
CUT_OUT="$(changelog_cut "$WT_MASTER/CHANGELOG.md")" || die "could not cut the $VERSION section on $MASTER"
printf '%s\n' "$CUT_OUT"
VB="$(version_bump "$WT_MASTER")" || die "version bump failed on $MASTER"
git -C "$WT_MASTER" add CHANGELOG.md package.json package-lock.json
git -C "$WT_MASTER" "${NOHOOKS[@]}" commit --quiet -m "$VERSION version bump" >>"$LOG" 2>&1 || die "master bump commit failed (log: $LOG)"
MASTER_BUMP="$(git -C "$WT_MASTER" rev-parse HEAD)"
MASTER_BUMP_SHORT="$(git -C "$WT_MASTER" rev-parse --short HEAD)"
step Master-bump ok "$MASTER_BUMP_SHORT; version $VB"

# --------------------------------------------------------------- staging -----
hdr "Staging: picks"
pick_all "$WT_STG" "$STAGING" Staging-picks
STG_PICKED="$PICKED"
step Staging-picks ok "$PICKED picked, $ALREADY already present"
hdr "Staging: develop's bump as a cherry-pick"
STG_BUMPED=""
if grep -q "^## $VERSION (" "$WT_STG/CHANGELOG.md"; then
  step Staging-bump skipped "$STAGING already has a ## $VERSION section"
else
  CUT_OUT="$(changelog_cut "$WT_STG/CHANGELOG.md")" || die "could not cut the $VERSION section on $STAGING"
  printf '%s\n' "$CUT_OUT"
  VB="$(version_bump "$WT_STG")" || die "version bump failed on $STAGING"
  git -C "$WT_STG" add CHANGELOG.md package.json package-lock.json
  git -C "$WT_STG" "${NOHOOKS[@]}" commit --quiet -m "$VERSION version bump" -m "(cherry picked from commit $(git -C "$WT_DEV" rev-parse "$DEV_BUMP"))" >>"$LOG" 2>&1 \
    || die "staging bump commit failed (log: $LOG)"
  STG_BUMPED=1
  step Staging-bump ok "$(git -C "$WT_STG" rev-parse --short HEAD) (cherry-pick -x of $DEV_BUMP_SHORT); version $VB"
fi
STG_HEAD="$(git -C "$WT_STG" rev-parse HEAD)"
STG_SHORT="$(git -C "$WT_STG" rev-parse --short HEAD)"

# ----------------------------------------------------------------- parity ----
# master and staging start from different trees (each may carry commits the
# other lacks), so their DELTAS are compared: the same files changed the same
# way, CHANGELOG.md aside. A staging that already carries the whole release (a
# re-run after a partial push) has no delta left to compare; the section check
# still runs. Then the X.Y.Z section must read identically on all three
# branches, and develop's bump may touch only the CHANGELOG and the version.
hdr "Parity"
delta_id() { git -C "$REPO" diff "$1" "$2" -- . ':(exclude)CHANGELOG.md' | git patch-id --stable | cut -d' ' -f1; }
# awk reads to EOF: an early `exit` SIGPIPEs git show, and pipefail turns that
# into a silent set -e death.
section() { git -C "$REPO" show "$1:CHANGELOG.md" | awk -v h="## $VERSION (" 'index($0,h)==1{on=1;print;next} on&&/^## /{on=0} on{print}'; }
PROBLEMS=""
if [ -n "$STG_BUMPED" ] || [ "$STG_PICKED" -gt 0 ]; then
  M_ID="$(delta_id "$REMOTE/$MASTER" "$MASTER_BUMP")"
  S_ID="$(delta_id "$REMOTE/$STAGING" "$STG_HEAD")"
  if [ "$M_ID" != "$S_ID" ]; then
    PROBLEMS="${PROBLEMS}master and staging received different changes:"$'\n'
    PROBLEMS="$PROBLEMS$(diff <(git -C "$REPO" diff --stat=200 "$REMOTE/$MASTER" "$MASTER_BUMP" -- . ':(exclude)CHANGELOG.md') \
      <(git -C "$REPO" diff --stat=200 "$REMOTE/$STAGING" "$STG_HEAD" -- . ':(exclude)CHANGELOG.md') | sed 's/^/    /' || true)"$'\n'
  fi
fi
SEC_M="$(section "$MASTER_BUMP")"
ORDER="$(node -e 'console.log(require(process.argv[1]).orderErrors(process.argv[2].split("\n"), process.argv[3]).join("\n"))' "$RELEASE_LIB" "$SEC_M" "## $VERSION")"
[ -z "$ORDER" ] || PROBLEMS="${PROBLEMS}the ## $VERSION section is out of type order:"$'\n'"$(sed 's/^/    /' <<< "$ORDER")"$'\n'
for ref in "$STG_HEAD" "$DEV_BUMP"; do
  [ "$(section "$ref")" = "$SEC_M" ] || PROBLEMS="${PROBLEMS}the ## $VERSION section differs between $MASTER and $(git -C "$REPO" rev-parse --short "$ref")"$'\n'
done
DEV_TOUCH="$(git -C "$REPO" diff --name-only "$DEV_BUMP^" "$DEV_BUMP" | grep -vxE 'CHANGELOG\.md|package\.json|package-lock\.json' || true)"
[ -z "$DEV_TOUCH" ] || PROBLEMS="${PROBLEMS}$DEVELOP's bump touches more than CHANGELOG and the version: $DEV_TOUCH"$'\n'
if [ -n "$PROBLEMS" ]; then
  hdr "STOP: parity"
  printf '%s' "$PROBLEMS" | sed 's/^/  /'
  step Parity stopped "$(printf '%s' "$PROBLEMS" | grep -c '^[a-z]' || true) problem(s), listed above"
  finish parity-mismatch 2
fi
CHANGED="$(git -C "$REPO" diff --name-only "$REMOTE/$MASTER" "$MASTER_BUMP" | grep -c . || true)"
step Parity ok "$MASTER and $STAGING got the same change ($CHANGED file(s) on $MASTER); one ## $VERSION section on all three branches"

# ------------------------------------------------------------ build config ---
hdr "Build config"
# shellcheck disable=SC2086
CFG_CHANGES="$(git -C "$REPO" diff --name-status "$REMOTE/$MASTER" "$MASTER_BUMP" -- $BUILD_CONFIG_FILES || true)"
CFG_FLAT="$(tr '\t\n' '  ' <<< "$CFG_CHANGES")"
if [ -z "$CFG_CHANGES" ]; then
  step Build-config ok "no change to $BUILD_CONFIG_FILES"
elif [ -n "$BUILD_CONFIG_READY" ]; then
  step Build-config ok "schema changed ($CFG_FLAT); --build-config-ready passed"
elif [ -n "$DRY_RUN" ]; then
  say "build config schema changed; a real run stops here until --build-config-ready"
  step Build-config warn "schema changed: $CFG_FLAT; a real run needs --build-config-ready"
else
  hdr "STOP: the picks change the build config schema"
  printf '%s\n' "$CFG_CHANGES" | sed 's/^/  /'
  echo
  echo "$MASTER builds read their config from the build server. Once the $MASTER"
  echo "build config is updated, re-run with --build-config-ready."
  step Build-config stopped "schema changed: $CFG_FLAT"
  finish build-config 2
fi

# ----------------------------------------------------------------- verify ----
if [ -n "$DRY_RUN" ]; then
  step Verify dry-run "the full repo verify runs on $MASTER and $STAGING before a real push"
else
  for pair in "$MASTER:$WT_MASTER" "$STAGING:$WT_STG"; do
    br="${pair%%:*}"; wt="${pair#*:}"
    hdr "Verify $br"
    release_ws_prep "$REPO" "$wt"
    VLOG="$TMPROOT/point-release.$$.verify-$br.log"
    rc=0; release_verify "$wt" "$VLOG" || rc=$?
    if [ $rc -eq 1 ]; then
      tail -30 "$VLOG" >&2
      step Verify failed "repo verify failed on $br, log $VLOG"
      die "verify failed on $br; nothing pushed"
    fi
  done
  step Verify ok "repo verify passed on $MASTER and $STAGING"
fi

# --------------------------------------------------------------- reviewed ----
# The real run rebuilds and re-gates everything, then pushes the commits the
# operator reviewed at the inspection tags when the rebuild matches them
# (release-merge-lib.sh release_prefer_reviewed), and the rebuild otherwise.
if [ -n "$DRY_RUN" ]; then
  step Reviewed dry-run "a real run pushes the inspection tags' commits when its rebuild matches them"
else
  TRIPLES=()
  [ -n "$DEV_NEW" ] && TRIPLES+=("$TAG_PREFIX/$VERSION-$DEVELOP" "$REMOTE/$DEVELOP" "$DEV_BUMP")
  TRIPLES+=("$TAG_PREFIX/$VERSION-$STAGING" "$REMOTE/$STAGING" "$STG_HEAD"
            "$TAG_PREFIX/$VERSION-$MASTER" "$REMOTE/$MASTER" "$MASTER_BUMP")
  release_prefer_reviewed "$REPO" "$REMOTE" "${TRIPLES[@]}"
  i=0
  [ -n "$DEV_NEW" ] && { DEV_BUMP="${RELEASE_PUSH[0]}"; i=1; }
  STG_HEAD="${RELEASE_PUSH[$i]}"; MASTER_BUMP="${RELEASE_PUSH[$((i + 1))]}"
  DEV_BUMP_SHORT="$(git -C "$REPO" rev-parse --short "$DEV_BUMP")"
  STG_SHORT="$(git -C "$REPO" rev-parse --short "$STG_HEAD")"
  MASTER_BUMP_SHORT="$(git -C "$REPO" rev-parse --short "$MASTER_BUMP")"
  release_reviewed_step Reviewed "$TAG_PREFIX/$VERSION-*"
fi

# ------------------------------------------------------------- push + tag ----
hdr "Push"
DEV_PUSH=""; [ -n "$DEV_NEW" ] && DEV_PUSH="$DEV_BUMP"
if [ -n "$DEV_PUSH" ]; then echo "  $DEVELOP <- $DEV_BUMP_SHORT"; else echo "  $DEVELOP: nothing new"; fi
echo "  $STAGING <- $STG_SHORT ($(git -C "$REPO" rev-list --count "$REMOTE/$STAGING..$STG_HEAD") commit(s))"
echo "  $MASTER  <- $MASTER_BUMP_SHORT ($(git -C "$REPO" rev-list --count "$REMOTE/$MASTER..$MASTER_BUMP") commit(s))"
echo "  tag v$VERSION -> $MASTER_BUMP_SHORT"
if [ -n "$DRY_RUN" ]; then
  hdr "DRY RUN, nothing pushed and v$VERSION not tagged"
  TAGS=""
  if [ -n "$PUBLISH" ]; then
    case "$TAG_PREFIX" in
      v[0-9]*|"") die "refusing tag prefix '$TAG_PREFIX': it collides with the vX.Y.Z release namespace" ;;
    esac
    for pair in "$MASTER:$MASTER_BUMP" "$STAGING:$STG_HEAD" "$DEVELOP:$DEV_BUMP"; do
      br="${pair%%:*}"; sha="${pair#*:}"; t="$TAG_PREFIX/$VERSION-$br"
      git -C "$REPO" tag -f -a "$t" -m "dry run of point release $VERSION, $br
picks: $(tr '\n' ' ' <<< "$SHAS")
generated by point-release-ship.sh on $(hostname -s) at $(date -u +%Y-%m-%dT%H:%M:%SZ)
NOT A RELEASE. Nothing was pushed to $br." "$sha" >/dev/null
      if git -C "$REPO" push -f "$REMOTE" "refs/tags/$t" >/dev/null 2>&1; then
        TAGS="$TAGS $t"; say "published $t ($(git -C "$REPO" rev-parse --short "$sha"))"
      else
        warn "could not push $t to $REMOTE"
      fi
      git -C "$REPO" tag -d "$t" >/dev/null 2>&1 || true
    done
    echo "  Inspect from any machine:"
    echo "    git fetch $REMOTE --tags --force"
    echo "    git log --oneline $REMOTE/$MASTER..$TAG_PREFIX/$VERSION-$MASTER"
    echo "    git diff $REMOTE/$MASTER $TAG_PREFIX/$VERSION-$MASTER"
    echo "    git diff $REMOTE/$STAGING $TAG_PREFIX/$VERSION-$STAGING"
    echo "    git show $TAG_PREFIX/$VERSION-$DEVELOP"
  fi
  step Push dry-run "nothing pushed${TAGS:+; inspection tags$TAGS}"
  step Tag dry-run "v$VERSION not created"
  finish ok 0
fi
if [ -z "$ASSUME_YES" ]; then
  printf 'Push %s, %s and %s, then tag v%s? [y/N] ' "$DEVELOP" "$STAGING" "$MASTER" "$VERSION"
  read -r reply
  case "$reply" in
    [yY]*) ;;
    *) say "declined by operator, nothing pushed"; step Push declined "operator answered no at the confirmation"; finish aborted 2 ;;
  esac
fi
# develop first, so every change is on develop before it is anywhere else; a
# failure part-way leaves the rest for a re-run.
if [ -n "$DEV_PUSH" ]; then
  git -C "$REPO" push "$REMOTE" "$DEV_PUSH:refs/heads/$DEVELOP" \
    || { step Push failed "$DEVELOP push rejected ($DEVELOP moved?); nothing pushed"; die "push to $DEVELOP failed; re-run"; }
fi
git -C "$REPO" push "$REMOTE" "$STG_HEAD:refs/heads/$STAGING" \
  || { step Push failed "$STAGING push rejected; ${DEV_PUSH:+$DEVELOP is pushed; }re-run"; die "push to $STAGING failed; re-run to finish"; }
git -C "$REPO" push "$REMOTE" "$MASTER_BUMP:refs/heads/$MASTER" \
  || { step Push failed "$MASTER push rejected; $DEVELOP and $STAGING are pushed; re-run"; die "push to $MASTER failed; re-run to finish"; }
step Push ok "${DEV_PUSH:+$DEVELOP <- $DEV_BUMP_SHORT, }$STAGING <- $STG_SHORT, $MASTER <- $MASTER_BUMP_SHORT"

# Lightweight, on master's bump commit: the shape of every earlier point tag.
if ! { git -C "$REPO" tag "v$VERSION" "$MASTER_BUMP" && git -C "$REPO" push "$REMOTE" "refs/tags/v$VERSION"; }; then
  step Tag failed "v$VERSION not pushed"
  die "tag failed; branches are pushed. Finish with: git tag v$VERSION $MASTER_BUMP && git push $REMOTE refs/tags/v$VERSION"
fi
step Tag ok "v$VERSION -> $MASTER_BUMP_SHORT"
for br in "$MASTER" "$STAGING" "$DEVELOP"; do
  git -C "$REPO" push "$REMOTE" ":refs/tags/$TAG_PREFIX/$VERSION-$br" >/dev/null 2>&1 || true
done
finish ok 0
