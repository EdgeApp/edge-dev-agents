#!/usr/bin/env bash
set -euo pipefail

# staging-release-merge.sh — cut a release by merging develop into staging:
# bump the version, open the new CHANGELOG release section, date the release the
# bump retires, merge, prove the two branches end up equivalent, then push.
#
# Everything happens in a THROWAWAY git worktree on temp branches cut from
# <remote>/<develop> and <remote>/<staging>. The caller's checkout, HEAD, index
# and working tree are never touched, so --dry-run leaves zero residue and any
# abort is recoverable by deleting the worktree.
#
# Usage: staging-release-merge.sh [options]
#   --repo <path>        repo to release (default: $EDGE_GUI_DIR or ~/git/edge-react-gui)
#   --version X.Y.Z      explicit version (default: minor bump of develop's version)
#   --prev-date <date>   YYYY-MM-DD for a release still marked (staging) (default:
#                        the commit date of its vX.Y.Z tag, else today with a warning)
#   --dry-run            do everything except the two pushes
#   --yes                skip the interactive push confirmation
#   --allow <glob>       parity path the operator has cleared (repeatable)
#   --resolve-theirs <p> take develop's side for this conflicted path (repeatable)
#   --develop <branch>   default: develop
#   --staging <branch>   default: staging
#   --remote <name>      default: origin
#   --keep-workspace     leave the temp worktree in place for inspection
#
# Exit: 0 done, 1 error, 2 needs operator input.
# The last line is always `RESULT: <verdict>`:
#   ok                done (pushed, or a clean dry run)
#   conflicts         merge conflicts outside CHANGELOG.md
#   parity-mismatch   staging and develop differ outside CHANGELOG.md
#   aborted           operator declined the push
#   error             anything else

REPO="${EDGE_GUI_DIR:-$HOME/git/edge-react-gui}"
VERSION=""
PREV_DATE=""
DRY_RUN=""
ASSUME_YES=""
DEVELOP="develop"
STAGING="staging"
REMOTE="origin"
KEEP_WS=""
ALLOW=()
RESOLVE_THEIRS=()
SAFE=""
UNSAFE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --prev-date) PREV_DATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --allow) ALLOW+=("$2"); shift 2 ;;
    --resolve-theirs) RESOLVE_THEIRS+=("$2"); shift 2 ;;
    --develop) DEVELOP="$2"; shift 2 ;;
    --staging) STAGING="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --keep-workspace) KEEP_WS=1; shift ;;
    -h|--help) sed -n '4,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo "RESULT: error"; exit 1 ;;
  esac
done

say()  { printf '>> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }
RESULT_PRINTED=""
finish() {
  # The kept-workspace note prints HERE, not from the EXIT trap, so that
  # `RESULT:` is always the last line a caller reads.
  [ -n "${KEEP_WS:-}" ] && [ -n "${WT:-}" ] && [ -d "$WT" ] && say "workspace kept at $WT"
  RESULT_PRINTED=1
  printf '\nRESULT: %s\n' "$1"
  exit "$2"
}
die()   { printf '!! %s\n' "$*" >&2; finish error 1; }

CHANGELOG_RESOLVER="$HOME/.cursor/skills/pr-land/scripts/changelog-union-merge.sh"
LINT_COMMIT="$HOME/.cursor/skills/lint-commit.sh"
TMPROOT="${TMPDIR:-/tmp}"; TMPROOT="${TMPROOT%/}"
# Dotted and PID-scoped: concurrent runs never clobber each other's logs, and the
# names stay clear of the `staging-release-merge-*` workspace glob.
BUMP_LOG="$TMPROOT/staging-release-merge.$$.bump.log"
MERGE_LOG="$TMPROOT/staging-release-merge.$$.merge.log"

# ---------------------------------------------------------------- preflight --
hdr "Preflight"
[ -e "$REPO/.git" ] || die "not a git repo: $REPO"
[ -x "$CHANGELOG_RESOLVER" ] || die "missing changelog resolver: $CHANGELOG_RESOLVER"
[ -x "$LINT_COMMIT" ] || die "missing commit script: $LINT_COMMIT"
REPO="$(cd "$REPO" && pwd)"
say "repo $REPO"

git -C "$REPO" fetch --quiet --tags "$REMOTE" "$DEVELOP" "$STAGING" || die "fetch failed"
DEV_REF="$REMOTE/$DEVELOP"
STG_REF="$REMOTE/$STAGING"
git -C "$REPO" rev-parse --verify --quiet "$DEV_REF" >/dev/null || die "no such ref: $DEV_REF"
git -C "$REPO" rev-parse --verify --quiet "$STG_REF" >/dev/null || die "no such ref: $STG_REF"
say "$DEV_REF $(git -C "$REPO" rev-parse --short "$DEV_REF")  $STG_REF $(git -C "$REPO" rev-parse --short "$STG_REF")"

read_json_field() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=process.argv[1].split(".").reduce((o,k)=>(o||{})[k],JSON.parse(s));console.log(v==null?"":v)})' "$1"; }
CUR_VERSION="$(git -C "$REPO" show "$DEV_REF:package.json" | read_json_field version)"
[ -n "$CUR_VERSION" ] || die "could not read version from $DEV_REF:package.json"
if [ -z "$VERSION" ]; then
  VERSION="$(node -e 'const p=process.argv[1].split(".").map(Number);if(p.length!==3||p.some(isNaN))process.exit(1);console.log([p[0],p[1]+1,0].join("."))' "$CUR_VERSION")" \
    || die "cannot minor-bump a non-semver version: $CUR_VERSION"
fi
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "--version must be X.Y.Z, got: $VERSION" ;;
esac
say "version $CUR_VERSION -> $VERSION"

# ------------------------------------------------- manual-checklist warnings --
# Crowdin syncs and the checkpoint / chain-registry publishes are release
# checklist steps this script cannot perform. Report them so a release is never
# silently short one; never block on them.
hdr "Checklist preconditions (warnings only)"
if command -v gh >/dev/null 2>&1; then
  for r in EdgeApp/edge-react-gui EdgeApp/edge-login-ui-rn; do
    n="$(gh pr list --repo "$r" --state open --search 'New Crowdin updates in:title' --json number --jq 'length' 2>/dev/null || echo "")"
    if [ -n "$n" ] && [ "$n" != "0" ]; then
      warn "$r has an open \"New Crowdin updates\" PR. Close and delete it, re-sync Crowdin, merge the fresh PR first."
    else
      say "$r: no open Crowdin PR"
    fi
  done
else
  warn "gh not available, skipped the Crowdin PR check"
fi

DEV_PKG="$(git -C "$REPO" show "$DEV_REF:package.json")"
for pkg in react-native-zcash react-native-piratechain edge-currency-accountbased; do
  have="$(printf '%s' "$DEV_PKG" | read_json_field "dependencies.$pkg" | sed 's/^[\^~]//')"
  latest="$(curl -fsS --max-time 10 "https://registry.npmjs.org/$pkg/latest" 2>/dev/null | read_json_field version || echo "")"
  if [ -n "$have" ] && [ -n "$latest" ] && [ "$have" != "$latest" ]; then
    warn "$pkg: develop pins $have, the registry has $latest (a checkpoint or chain-registry publish may be outstanding)"
  elif [ -n "$have" ]; then
    say "$pkg: $have (current)"
  fi
done

# --------------------------------------------------------------- workspace ---
STAMP="$(git -C "$REPO" rev-parse --short "$DEV_REF")"
WT="$TMPROOT/staging-release-merge-$STAMP-$$"
TMP_DEV="staging-release/$VERSION-develop"
TMP_STG="staging-release/$VERSION-staging"

cleanup() {
  if [ -n "$KEEP_WS" ]; then
    [ -z "$RESULT_PRINTED" ] && say "workspace kept at $WT"
    return 0
  fi
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO" branch -D "$TMP_DEV" "$TMP_STG" >/dev/null 2>&1 || true
  rm -rf "$WT" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

hdr "Workspace"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$REPO" branch -D "$TMP_DEV" "$TMP_STG" >/dev/null 2>&1 || true
git -C "$REPO" worktree add --quiet -b "$TMP_DEV" "$WT" "$DEV_REF" || die "worktree add failed"
say "worktree $WT on $TMP_DEV"

# The repo's precommit chain runs on both the bump and the merge commit, and it
# needs artifacts that are gitignored and so absent from a fresh worktree.
# node_modules must be a REAL directory: react-native's jest asset transformer
# builds snapshot image paths relative to its own location inside node_modules,
# so a symlink resolves them against the caller's checkout and every image
# snapshot fails. Clone it (APFS clone-on-write costs seconds and little disk).
if [ ! -e "$WT/node_modules" ] && [ -d "$REPO/node_modules" ]; then
  say "cloning node_modules (a symlink breaks image snapshots)"
  cp -c -R "$REPO/node_modules" "$WT/node_modules" 2>/dev/null \
    || cp -R "$REPO/node_modules" "$WT/node_modules" \
    || die "could not stage node_modules"
fi
for p in .husky/_ src/plugins/contracts; do
  [ -e "$WT/$p" ] && continue
  [ -e "$REPO/$p" ] || continue
  mkdir -p "$(dirname "$WT/$p")"
  ln -s "$REPO/$p" "$WT/$p"
  say "linked $p"
done
# Copied rather than linked so nothing the hooks do can write into the caller's
# checkout. Without these, the precommit tsc fails on unresolvable modules.
for p in env.json src/controllers/edgeProvider/client/rolledUp.js src/controllers/edgeProvider/injectThisInWebView.js; do
  [ -e "$WT/$p" ] && continue
  [ -e "$REPO/$p" ] || { warn "missing $p in $REPO, the precommit hooks may fail"; continue; }
  mkdir -p "$(dirname "$WT/$p")"
  cp "$REPO/$p" "$WT/$p"
  say "copied $p"
done

# ------------------------------------------------------------------- bump ----
hdr "Version bump on $DEVELOP"
node - "$WT" "$VERSION" "$PREV_DATE" <<'NODE' || exit 1
const fs = require("fs");
const { execFileSync } = require("child_process");
const [wt, version, prevDateArg] = process.argv.slice(2);

const pj = `${wt}/package.json`;
fs.writeFileSync(pj, fs.readFileSync(pj, "utf8").replace(/("version":\s*)"[^"]+"/, `$1"${version}"`));

// The lockfile carries the version twice, at the root and under packages[""].
const pl = `${wt}/package-lock.json`;
if (fs.existsSync(pl)) {
  let n = 0;
  fs.writeFileSync(pl, fs.readFileSync(pl, "utf8").replace(/("version":\s*)"[^"]+"/g, (m, p) => (n++ < 2 ? `${p}"${version}"` : m)));
}

const cl = `${wt}/CHANGELOG.md`;
const lines = fs.readFileSync(cl, "utf8").split("\n");

// A release still marked `(staging)` shipped, and this bump is what retires it.
// Its release date is the commit date of its tag.
const tagDate = (v) => {
  try {
    return execFileSync("git", ["-C", wt, "log", "-1", "--format=%ad", "--date=short", `v${v}`], { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch { return ""; }
};
const today = new Date().toISOString().slice(0, 10);
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^##\s+(\d+\.\d+\.\d+)\s+\(staging\)\s*$/);
  if (!m) continue;
  let d = prevDateArg || tagDate(m[1]);
  if (!d) { d = today; console.log(`!! no tag v${m[1]}, dated the previous release ${d} (override with --prev-date)`); }
  lines[i] = `## ${m[1]} (${d})`;
  console.log(`>> dated previous release ${m[1]} -> ${d}`);
}

// Open the new release section: everything accumulated under the unreleased
// heading becomes this release's entries.
const at = lines.findIndex((l) => /^##\s+Unreleased\b/.test(l));
if (at === -1) { console.error("!! no `## Unreleased` heading in CHANGELOG.md"); process.exit(1); }
lines.splice(at + 1, 0, "", `## ${version} (staging)`);
fs.writeFileSync(cl, lines.join("\n"));
console.log(`>> opened release section ${version} (staging)`);
NODE

rc=0
( cd "$WT" && "$LINT_COMMIT" -m "Bump version to v$VERSION" package.json package-lock.json CHANGELOG.md ) >"$BUMP_LOG" 2>&1 || rc=$?
if [ $rc -ne 0 ]; then
  tail -30 "$BUMP_LOG" >&2
  die "bump commit failed (full log: $BUMP_LOG)"
fi
say "bump commit $(git -C "$WT" rev-parse --short HEAD)"
git -C "$WT" --no-pager show --stat --oneline HEAD | sed 's/^/   /'

# ------------------------------------------------------------------ merge ----
hdr "Merge $DEVELOP into $STAGING"
git -C "$WT" switch --quiet -c "$TMP_STG" "$STG_REF" || die "could not branch $TMP_STG from $STG_REF"
rc=0
git -C "$WT" merge --no-ff -m "Merge branch '$DEVELOP' into $STAGING" "$TMP_DEV" >"$MERGE_LOG" 2>&1 || rc=$?

if [ $rc -ne 0 ]; then
  CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"
  say "conflicts:"; printf '%s\n' "$CONFLICTS" | sed 's/^/   /'

  # Take develop's side for paths the operator has already cleared. --theirs is
  # a silent no-op once a path has been `git add`ed, so this runs before
  # anything stages a conflicted file.
  for p in "${RESOLVE_THEIRS[@]+"${RESOLVE_THEIRS[@]}"}"; do
    if printf '%s\n' "$CONFLICTS" | grep -qx -- "$p"; then
      git -C "$WT" checkout --theirs -- "$p"
      git -C "$WT" add -- "$p"
      say "resolved (develop's side, operator-cleared): $p"
    else
      warn "--resolve-theirs $p: not conflicted, ignored"
    fi
  done

  REMAINING="$(git -C "$WT" diff --name-only --diff-filter=U | grep -v '^CHANGELOG\.md$' || true)"
  if [ -n "$REMAINING" ]; then
    hdr "STOP: conflicts outside CHANGELOG.md"
    echo "Conflicts here are normal on a release cut: staging accumulates hotfix"
    echo "commits that reach develop through different commits, so the histories"
    echo "disagree about lines that agree in substance. In the diffs below, the"
    echo "HEAD side is $STAGING and the other side is $DEVELOP."
    echo
    echo "Each file is classified by whether develop already contains everything"
    echo "staging has. CHANGELOG.md is resolved automatically and is not listed."
    echo
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      verdict="$(node - "$WT/$f" <<'NODE'
// Classify a conflicted file: does taking develop's side lose anything staging
// has? A purely textual subset test is not enough. A dependency pin that moved
// on BOTH branches (staging took a hotfix bump, develop went further) has no
// line in common, yet develop supersedes staging and taking develop's side is
// correct. Calling that "staging carries content develop lacks" tells the
// operator to downgrade develop, which is never right, and it would fire on
// package.json / package-lock.json / Podfile.lock at every single release.
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");

const VER = /\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?/g;
// Lockfiles and Podfile.lock distinguish the same entry by CHECKSUM rather than
// by version, so blank those too or every lockfile hunk reads as missing
// content. A line that differs only in a version or a checksum is the same
// entry at a different revision, not something only staging has.
const HASH = /\b(?:sha\d+-[A-Za-z0-9+/=]{20,}|[0-9a-f]{32,})\b/g;
// Strip version and checksum tokens so the same entry matches across revisions.
const shape = (l) => l.trim().replace(HASH, "\u0000H\u0000").replace(VER, "\u0000V\u0000");
const versionsOf = (l) => (l.trim().replace(HASH, "").match(VER) || []);
const cmpVer = (a, b) => {
  const pa = a.split(/[.+-]/).map(Number);
  const pb = b.split(/[.+-]/).map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (Number.isNaN(x) || Number.isNaN(y)) return 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
};

let i = 0, hunks = 0, superseded = 0;
const missing = [];
while (i < lines.length) {
  if (!lines[i].startsWith("<<<<<<< ")) { i++; continue; }
  i++; const ours = [];
  while (i < lines.length && !lines[i].startsWith("=======")) ours.push(lines[i++]);
  i++; const theirs = [];
  while (i < lines.length && !lines[i].startsWith(">>>>>>> ")) theirs.push(lines[i++]);
  i++; hunks++;

  const devExact = new Set(theirs.map((l) => l.trim()).filter(Boolean));
  const devByShape = new Map();
  for (const l of theirs) {
    if (!l.trim()) continue;
    const k = shape(l);
    if (!devByShape.has(k)) devByShape.set(k, []);
    devByShape.get(k).push(l);
  }

  for (const raw of ours) {
    const l = raw.trim();
    if (!l || devExact.has(l)) continue;
    // Same entry, different version: develop wins as long as it is not older.
    const twins = devByShape.get(shape(raw)) || [];
    const sv = versionsOf(raw);
    const newerOnDevelop = twins.some((t) => {
      const tv = versionsOf(t);
      return tv.length === sv.length && sv.every((v, n) => cmpVer(v, tv[n]) <= 0);
    });
    if (newerOnDevelop) { superseded++; continue; }
    if (missing.length < 3) missing.push(l);
  }
}

if (missing.length) {
  console.log(`${hunks} hunk(s): staging carries content develop lacks, back-port it to develop first`);
  for (const m of missing) console.log(`         only on staging: ${m.slice(0, 110)}`);
} else if (superseded) {
  console.log(`${hunks} hunk(s): develop supersedes staging (${superseded} entr(y/ies) at a newer version), taking develop's side loses nothing`);
} else {
  console.log(`${hunks} hunk(s): develop is a superset of staging, taking develop's side loses nothing`);
}
NODE
)"
      printf '  %s\n' "$f"
      printf '%s\n' "$verdict" | sed 's/^/      /'
      case "$verdict" in
        *"loses nothing"*) SAFE="$SAFE --resolve-theirs $f" ;;
        *) UNSAFE=1 ;;
      esac
      git -C "$WT" --no-pager diff -- "$f" | sed -n '1,60p' | sed 's/^/      /'
      echo
    done <<< "$REMAINING"

    if [ -n "$SAFE" ]; then
      echo "Files whose classification says develop loses nothing can be cleared"
      echo "in one re-run:"
      echo
      echo "  $0${DRY_RUN:+ --dry-run}$SAFE"
      echo
    fi
    if [ -n "$UNSAFE" ]; then
      echo "At least one file carries content only staging has. Back-port that to"
      echo "$DEVELOP before cutting the release; do not clear it with --resolve-theirs."
      echo
    fi
    finish conflicts 2
  fi

  if git -C "$WT" diff --name-only --diff-filter=U | grep -qx 'CHANGELOG.md'; then
    say "resolving CHANGELOG.md with the release-merge union"
    "$CHANGELOG_RESOLVER" "$WT" --release-merge || die "CHANGELOG conflict is not mechanically resolvable, resolve it by hand in $WT"
    git -C "$WT" add CHANGELOG.md
  fi
  rc=0
  GIT_EDITOR=true git -C "$WT" merge --continue >>"$MERGE_LOG" 2>&1 || rc=$?
  if [ $rc -ne 0 ]; then
    tail -30 "$MERGE_LOG" >&2
    die "merge --continue failed (full log: $MERGE_LOG)"
  fi
fi
say "merge commit $(git -C "$WT" rev-parse --short HEAD)"

# ----------------------------------------------------------------- parity ----
hdr "Parity gate: $STAGING vs $DEVELOP"
DIFF_PATHS="$(git -C "$WT" diff --name-only "$TMP_DEV" || true)"
if [ -z "$DIFF_PATHS" ]; then
  say "trees are identical"
else
  say "differing paths:"; printf '%s\n' "$DIFF_PATHS" | sed 's/^/   /'
fi

BLOCKING=""
while IFS= read -r p; do
  [ -z "$p" ] && continue
  [ "$p" = "CHANGELOG.md" ] && continue
  cleared=""
  for g in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    case "$p" in $g) cleared=1 ;; esac
  done
  if [ -n "$cleared" ]; then say "allowed by operator: $p"; continue; fi
  BLOCKING="$BLOCKING$p"$'\n'
done <<< "$DIFF_PATHS"

if [ -n "$BLOCKING" ]; then
  hdr "STOP: non-CHANGELOG differences between $STAGING and $DEVELOP"
  echo "The push is aborted: the two branches would not be equivalent. Back-port"
  echo "each path to the branch that lacks it, or clear it with --allow <glob>."
  echo
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    printf '  %s\n' "$p"
    git -C "$WT" --no-pager diff "$TMP_DEV" -- "$p" | sed -n '1,40p' | sed 's/^/      /'
    echo
  done <<< "$BLOCKING"
  echo "The repo's precommit chain regenerates eslint.config.mjs and"
  echo "src/locales/strings on every commit, so either can appear here purely as"
  echo "an artifact of the merge commit rather than as real drift."
  finish parity-mismatch 2
fi
say "parity clean (CHANGELOG.md is the only expected difference)"

# ------------------------------------------------------------------- push ----
hdr "Push"
echo "  $TMP_DEV -> $REMOTE/$DEVELOP   ($(git -C "$WT" rev-parse --short "$TMP_DEV"))"
echo "  $TMP_STG -> $REMOTE/$STAGING   ($(git -C "$WT" rev-parse --short "$TMP_STG"))"
if [ -n "$DRY_RUN" ]; then
  hdr "DRY RUN, nothing was pushed"
  say "release $VERSION is ready; re-run without --dry-run to push"
  finish ok 0
fi
if [ -z "$ASSUME_YES" ]; then
  printf 'Push both branches? [y/N] '
  read -r reply
  case "$reply" in
    [yY]*) ;;
    *) say "declined by operator, nothing pushed"; finish aborted 2 ;;
  esac
fi
git -C "$WT" push "$REMOTE" "$TMP_DEV:$DEVELOP" || die "push to $DEVELOP failed"
git -C "$WT" push "$REMOTE" "$TMP_STG:$STAGING" || die "push to $STAGING failed"
say "pushed $DEVELOP and $STAGING"
say "release $VERSION is on $STAGING"
finish ok 0
