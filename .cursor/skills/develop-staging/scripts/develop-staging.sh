#!/usr/bin/env bash
set -uo pipefail

# develop-staging.sh — run the edge-react-gui release merge from develop into
# staging: bump the version, open the new CHANGELOG release section, date the
# previous one, merge, prove the two branches are at parity, then push.
#
# Everything happens in a THROWAWAY git worktree on temp branches cut from
# origin/<develop> and origin/<staging>. The caller's checkout, HEAD, index and
# working tree are never touched, so a --dry-run leaves zero residue and an
# abort is always recoverable.
#
# Usage: develop-staging.sh [options]
#   --repo <path>        repo to release (default: $EDGE_GUI_DIR or ~/git/edge-react-gui)
#   --version X.Y.Z      explicit version (default: minor bump of develop's version)
#   --prev-date <date>   YYYY-MM-DD for a stale `(staging)` heading (default: the
#                        commit date of tag v<version>, else today with a warning)
#   --dry-run            do everything except the two pushes
#   --yes                skip the interactive push confirmation
#   --allow <glob>       parity path the operator has cleared (repeatable)
#   --resolve-theirs <p> take develop's side for this conflicted path (repeatable)
#   --develop <branch>   default: develop
#   --staging <branch>   default: staging
#   --remote <name>      default: origin
#   --keep-workspace     leave the temp worktree in place for inspection
#
# Exit: 0  done (pushed, or dry run completed clean)
#       10 merge conflicts outside CHANGELOG.md — operator input needed
#       11 parity gate: the post-merge diff carries non-CHANGELOG paths
#       12 preflight failed
#       2  usage

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
    -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '>> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf '!! %s\n' "$*" >&2; exit "${2:-12}"; }

CUM="$HOME/.cursor/skills/pr-land/scripts/changelog-union-merge.sh"
LINT_COMMIT="$HOME/.cursor/skills/lint-commit.sh"

# ---------------------------------------------------------------- preflight --
hdr "Preflight"
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "not a git repo: $REPO"
[ -x "$CUM" ] || die "missing changelog resolver: $CUM"
[ -x "$LINT_COMMIT" ] || die "missing commit script: $LINT_COMMIT"
REPO="$(cd "$REPO" && pwd)"
say "repo $REPO"

git -C "$REPO" fetch --quiet --tags "$REMOTE" "$DEVELOP" "$STAGING" || die "fetch failed"
DEV_REF="$REMOTE/$DEVELOP"
STG_REF="$REMOTE/$STAGING"
git -C "$REPO" rev-parse --verify --quiet "$DEV_REF" >/dev/null || die "no such ref: $DEV_REF"
git -C "$REPO" rev-parse --verify --quiet "$STG_REF" >/dev/null || die "no such ref: $STG_REF"
say "$DEV_REF $(git -C "$REPO" rev-parse --short "$DEV_REF")  $STG_REF $(git -C "$REPO" rev-parse --short "$STG_REF")"

CUR_VERSION="$(git -C "$REPO" show "$DEV_REF:package.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
[ -n "$CUR_VERSION" ] || die "could not read version from $DEV_REF:package.json"
if [ -z "$VERSION" ]; then
  VERSION="$(node -e 'const p=process.argv[1].split(".").map(Number);if(p.length!==3||p.some(isNaN)){process.exit(1)}console.log([p[0],p[1]+1,0].join("."))' "$CUR_VERSION")" \
    || die "cannot minor-bump non-semver version: $CUR_VERSION"
fi
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "--version must be X.Y.Z, got: $VERSION" 2 ;;
esac
say "version $CUR_VERSION -> $VERSION"

# ------------------------------------------------- manual-checklist warnings --
# These steps belong to the release checklist but cannot be driven from here.
# They are reported, never enforced, so a release is never silently short.
hdr "Checklist preconditions (warnings only)"
if command -v gh >/dev/null 2>&1; then
  for r in EdgeApp/edge-react-gui EdgeApp/edge-login-ui-rn; do
    n="$(gh pr list --repo "$r" --state open --search 'New Crowdin updates in:title' --json number --jq 'length' 2>/dev/null)"
    if [ "${n:-0}" != "0" ] && [ -n "${n:-}" ]; then
      warn "$r has an open \"New Crowdin updates\" PR. Close+delete it, re-sync Crowdin, merge the fresh PR first."
    else
      say "$r: no open Crowdin PR"
    fi
  done
else
  warn "gh not available, skipped the Crowdin PR check"
fi

for pkg in react-native-zcash react-native-piratechain edge-currency-accountbased; do
  have="$(git -C "$REPO" show "$DEV_REF:package.json" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const p=JSON.parse(s);console.log(((p.dependencies||{})[process.argv[1]]||"").replace(/^[\^~]/,""))})' "$pkg")"
  latest="$(curl -fsS --max-time 10 "https://registry.npmjs.org/$pkg/latest" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).version)}catch(e){}})')"
  if [ -n "$have" ] && [ -n "$latest" ] && [ "$have" != "$latest" ]; then
    warn "$pkg: develop pins $have, registry latest is $latest (checkpoint/chain-registry publish may be outstanding)"
  elif [ -n "$have" ]; then
    say "$pkg: $have (current)"
  fi
done

# --------------------------------------------------------------- workspace ---
STAMP="$(git -C "$REPO" rev-parse --short "$DEV_REF")"
WT="${TMPDIR:-/tmp}/develop-staging-$STAMP-$$"
TMP_DEV="develop-staging/$VERSION-develop"
TMP_STG="develop-staging/$VERSION-staging"

cleanup() {
  [ -n "$KEEP_WS" ] && { say "workspace kept at $WT"; return; }
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO" branch -D "$TMP_DEV" "$TMP_STG" >/dev/null 2>&1
  rm -rf "$WT" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

hdr "Workspace"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
git -C "$REPO" branch -D "$TMP_DEV" "$TMP_STG" >/dev/null 2>&1
git -C "$REPO" worktree add --quiet -b "$TMP_DEV" "$WT" "$DEV_REF" || die "worktree add failed"
say "worktree $WT on $TMP_DEV"
# The repo's precommit chain (localize, update-eslint-warnings, lint-staged, tsc,
# tests) runs on both the bump and the merge commit, and it needs artifacts that
# are gitignored and therefore absent from a fresh worktree. Without them tsc
# fails on missing `env.json` and `src/plugins/contracts` and the whole run dies
# inside the merge commit. Big trees are symlinked, small generated files are
# copied so nothing the hooks do can write back into the caller's checkout.
for p in node_modules .husky/_ src/plugins/contracts; do
  [ -e "$WT/$p" ] && continue
  [ -e "$REPO/$p" ] || continue
  mkdir -p "$(dirname "$WT/$p")"
  ln -s "$REPO/$p" "$WT/$p" && say "linked $p"
done
for p in env.json src/controllers/edgeProvider/client/rolledUp.js src/controllers/edgeProvider/injectThisInWebView.js; do
  [ -e "$WT/$p" ] && continue
  [ -e "$REPO/$p" ] || { warn "missing $p in $REPO, the precommit hooks may fail"; continue; }
  mkdir -p "$(dirname "$WT/$p")"
  cp "$REPO/$p" "$WT/$p" && say "copied $p"
done

# ------------------------------------------------------------------- bump ----
hdr "Version bump on $DEVELOP"
node - "$WT" "$VERSION" "$PREV_DATE" <<'NODE'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [wt, version, prevDateArg] = process.argv.slice(2);

const pj = `${wt}/package.json`;
fs.writeFileSync(pj, fs.readFileSync(pj, "utf8").replace(/("version":\s*)"[^"]+"/, `$1"${version}"`));

const pl = `${wt}/package-lock.json`;
if (fs.existsSync(pl)) {
  let n = 0;
  fs.writeFileSync(pl, fs.readFileSync(pl, "utf8").replace(/("version":\s*)"[^"]+"/g, (m, p) => (n++ < 2 ? `${p}"${version}"` : m)));
}

const cl = `${wt}/CHANGELOG.md`;
const lines = fs.readFileSync(cl, "utf8").split("\n");

// Date any release still marked `(staging)`: it shipped, and this bump is what
// retires it. The release date is the commit date of its tag.
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

// Open the new release section: everything currently accumulated under the
// unreleased heading becomes this release's entries.
const at = lines.findIndex((l) => /^##\s+Unreleased\b/.test(l));
if (at === -1) { console.error("!! no `## Unreleased` heading in CHANGELOG.md"); process.exit(1); }
lines.splice(at + 1, 0, "", `## ${version} (staging)`);
fs.writeFileSync(cl, lines.join("\n"));
console.log(`>> opened release section ${version} (staging)`);
NODE
[ $? -eq 0 ] || die "changelog/version edit failed"

( cd "$WT" && "$LINT_COMMIT" -m "Bump version to v$VERSION" package.json package-lock.json CHANGELOG.md ) >/tmp/develop-staging-bump.log 2>&1
if [ $? -ne 0 ]; then
  tail -30 /tmp/develop-staging-bump.log >&2
  die "bump commit failed (full log: /tmp/develop-staging-bump.log)"
fi
say "bump commit $(git -C "$WT" rev-parse --short HEAD)"
git -C "$WT" --no-pager show --stat --oneline HEAD | sed 's/^/   /'

# ------------------------------------------------------------------ merge ----
hdr "Merge $DEVELOP into $STAGING"
git -C "$WT" switch --quiet -c "$TMP_STG" "$STG_REF" || die "could not branch $TMP_STG from $STG_REF"
git -C "$WT" merge --no-ff -m "Merge branch '$DEVELOP' into $STAGING" "$TMP_DEV" >/tmp/develop-staging-merge.log 2>&1
MERGE_RC=$?

if [ $MERGE_RC -ne 0 ]; then
  CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"
  say "conflicts:"; printf '%s\n' "$CONFLICTS" | sed 's/^/   /'

  # Take develop's side for paths the operator has already cleared.
  for p in "${RESOLVE_THEIRS[@]:-}"; do
    [ -z "$p" ] && continue
    if printf '%s\n' "$CONFLICTS" | grep -qx -- "$p"; then
      # NOTE: --theirs is a silent no-op once a path has been `git add`ed, so
      # this must run before anything stages it.
      git -C "$WT" checkout --theirs -- "$p" && git -C "$WT" add -- "$p" && say "resolved (develop's side, operator-cleared): $p"
    else
      warn "--resolve-theirs $p: not conflicted, ignored"
    fi
  done

  REMAINING="$(git -C "$WT" diff --name-only --diff-filter=U | grep -v '^CHANGELOG\.md$')"
  if [ -n "$REMAINING" ]; then
    hdr "STOP: conflicts outside CHANGELOG.md"
    echo "These need a human decision. For each file, the classification says whether"
    echo "develop already contains everything staging has (the usual hotfix-cherry-pick"
    echo "shape, safe to take develop) or whether staging carries content develop lacks."
    echo
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      verdict="$(node - "$WT/$f" <<'NODE'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
let i = 0, superset = true, hunks = 0;
while (i < lines.length) {
  if (!lines[i].startsWith("<<<<<<< ")) { i++; continue; }
  i++; const ours = [];
  while (i < lines.length && !lines[i].startsWith("=======")) ours.push(lines[i++]);
  i++; const theirs = [];
  while (i < lines.length && !lines[i].startsWith(">>>>>>> ")) theirs.push(lines[i++]);
  i++; hunks++;
  const t = new Set(theirs.map((l) => l.trim()).filter(Boolean));
  if (ours.map((l) => l.trim()).filter(Boolean).some((l) => !t.has(l))) superset = false;
}
console.log(superset ? `${hunks} hunk(s): develop is a superset of staging (safe to take develop's side)`
                     : `${hunks} hunk(s): STAGING CARRIES CONTENT DEVELOP LACKS — back-port it to develop first`);
NODE
)"
      printf '  %s\n      %s\n' "$f" "$verdict"
      git -C "$WT" --no-pager diff -- "$f" | sed -n '1,60p' | sed 's/^/      /'
      echo
    done <<< "$REMAINING"
    echo "Continue by re-running with --resolve-theirs <path> for each file whose"
    echo "classification you accept, or fix the source branches and re-run."
    exit 10
  fi

  if git -C "$WT" diff --name-only --diff-filter=U | grep -qx 'CHANGELOG.md'; then
    say "resolving CHANGELOG.md with the release-merge union"
    "$CUM" "$WT" --release-merge || die "CHANGELOG conflict is not mechanically resolvable, resolve it by hand in $WT" 10
    git -C "$WT" add CHANGELOG.md
  fi
  GIT_EDITOR=true git -C "$WT" merge --continue >>/tmp/develop-staging-merge.log 2>&1 \
    || { tail -30 /tmp/develop-staging-merge.log >&2; die "merge --continue failed (log: /tmp/develop-staging-merge.log)"; }
fi
say "merge commit $(git -C "$WT" rev-parse --short HEAD)"

# ----------------------------------------------------------------- parity ----
hdr "Parity gate: $STAGING vs $DEVELOP"
DIFF_PATHS="$(git -C "$WT" diff --name-only "$TMP_DEV")"
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
  for g in "${ALLOW[@]:-}"; do
    [ -z "$g" ] && continue
    case "$p" in $g) cleared=1 ;; esac
  done
  [ -n "$cleared" ] && { say "allowed by operator: $p"; continue; }
  BLOCKING="$BLOCKING$p"$'\n'
done <<< "$DIFF_PATHS"

if [ -n "$BLOCKING" ]; then
  hdr "STOP: non-CHANGELOG differences between $STAGING and $DEVELOP"
  echo "The push is aborted. Every path below means the two branches would not be"
  echo "equivalent after this release merge. Either back-port the change to the other"
  echo "branch, or clear it with --allow <glob> once you have reviewed it."
  echo
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    printf '  %s\n' "$p"
    git -C "$WT" --no-pager diff "$TMP_DEV" -- "$p" | sed -n '1,40p' | sed 's/^/      /'
    echo
  done <<< "$BLOCKING"
  echo "Note: the repo's precommit chain regenerates eslint.config.mjs and"
  echo "src/locales/strings on every commit, so those two can show up here purely as"
  echo "an artifact of the merge commit. Review, then --allow them if that is all it is."
  exit 11
fi
say "parity clean (CHANGELOG.md is the only expected difference)"

# ------------------------------------------------------------------- push ----
hdr "Push"
echo "  $TMP_DEV -> $REMOTE/$DEVELOP   ($(git -C "$WT" rev-parse --short "$TMP_DEV"))"
echo "  $TMP_STG -> $REMOTE/$STAGING   ($(git -C "$WT" rev-parse --short "$TMP_STG"))"
if [ -n "$DRY_RUN" ]; then
  hdr "DRY RUN — nothing was pushed"
  say "release $VERSION is ready; re-run without --dry-run to push"
  exit 0
fi
if [ -z "$ASSUME_YES" ]; then
  printf 'Push both branches? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) say "aborted by operator, nothing pushed"; exit 0 ;; esac
fi
git -C "$WT" push "$REMOTE" "$TMP_DEV:$DEVELOP" || die "push to $DEVELOP failed"
git -C "$WT" push "$REMOTE" "$TMP_STG:$STAGING" || die "push to $STAGING failed"
say "pushed $DEVELOP and $STAGING"
hdr "Done"
say "release $VERSION is on $STAGING"
