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
#   --crowdin-merge-existing  the open Crowdin PR is already fresh: merge it
#                        directly instead of the close-delete-resync flow
#   --no-gui-push        do everything (Crowdin merges, dep publishes, bump,
#                        merge, verify) but hold the develop/staging push;
#                        publishes the inspection tags like a dry run
#   --no-publish         skip publishing the dry-run inspection tags
#   --tag-prefix <ns>    namespace for those tags (default: dryrun)
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
PUBLISH=1
TAG_PREFIX="dryrun"
CROWDIN_MERGE_EXISTING=""
NO_GUI_PUSH=""
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
    --no-publish) PUBLISH=""; shift ;;
    --crowdin-merge-existing) CROWDIN_MERGE_EXISTING=1; shift ;;
    --no-gui-push) NO_GUI_PUSH=1; shift ;;
    --tag-prefix) TAG_PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '4,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo "RESULT: error"; exit 1 ;;
  esac
done

say()  { printf '>> %s\n' "$*"; }
WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '!! %s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

# Step ledger. Every phase records its outcome here, and finish() renders it on
# EVERY exit path, so a run that stopped at a gate still reports what the phases
# before it did. Kept as a newline-delimited string rather than an associative
# array, which bash 3.2 (the macOS system bash) does not have.
PHASES="Preflight Crowdin-gui Crowdin-login-ui Workspace zcash piratechain chain-registry Release-dates Version-bump Merge Parity Verify Push"
STEP_LOG=""
step() { STEP_LOG="$STEP_LOG$1|$2|$3
"; }
render_steps() {
  printf '\n=== Step report ===\n'
  for ph in $PHASES; do
    line="$(printf '%s' "$STEP_LOG" | grep "^$ph|" || true)"
    if [ -z "$line" ]; then
      printf '  %-16s %-11s %s\n' "$ph" "not-reached" "-"
      continue
    fi
    st="$(printf '%s' "$line" | cut -d'|' -f2)"
    detail="$(printf '%s' "$line" | cut -d'|' -f3-)"
    printf '  %-16s %-11s %s\n' "$ph" "$st" "$detail"
  done
}
RESULT_PRINTED=""
finish() {
  # The kept-workspace note prints HERE, not from the EXIT trap, so that
  # `RESULT:` is always the last line a caller reads.
  [ -n "${KEEP_WS:-}" ] && [ -n "${WT:-}" ] && [ -d "$WT" ] && say "workspace kept at $WT"
  render_steps
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
step Preflight ok "$CUR_VERSION -> $VERSION; $DEV_REF $(git -C "$REPO" rev-parse --short "$DEV_REF"), $STG_REF $(git -C "$REPO" rev-parse --short "$STG_REF")"

# ------------------------------------------------------------- translations --
# Checklist subtasks 1 and 2. The Crowdin PR merges into develop BEFORE the
# version bump (verified in history: the 4.46.0 cut merged l10n_develop, then
# the dep upgrades, then the bump). Merging it moves origin/develop, so this
# runs before the worktree is cut.
UPGRADE_DEP="$HOME/.cursor/skills/pr-land/scripts/upgrade-dep.sh"
PUBLISH_SH="$HOME/.cursor/skills/pr-land/scripts/pr-land-publish.sh"
NPM_PUBLISH="$HOME/.cursor/skills/pr-land/scripts/npm-publish-web.sh"

crowdin_merge_pr() {
  local repo="$1" pr="$2"
  if gh pr merge "$pr" --repo "$repo" --merge >/dev/null 2>&1; then
    return 0
  fi
  local nonl10n
  nonl10n="$(gh pr view "$pr" --repo "$repo" --json files \
    --jq '[.files[].path | select((startswith("src/locales/") or startswith("localization/")) | not)] | length' 2>/dev/null || echo "?")"
  if [ "$nonl10n" != "0" ]; then
    warn "PR #$pr touches $nonl10n non-translation file(s); refusing the admin-merge fallback"
    return 1
  fi
  gh pr merge "$pr" --repo "$repo" --merge --admin >/dev/null 2>&1 || return 1
  MERGE_MODE="admin"
  return 0
}

crowdin_step() {
  local repo="$1" phase="$2"
  local pr
  # Detect by the integration's own head branch, not the PR title: the title is
  # Crowdin's to change, l10n_develop is the configured branch.
  pr="$(gh pr list --repo "$repo" --state open --head l10n_develop --json number --jq '.[0].number // empty' 2>/dev/null || echo "")"
  if [ -z "$pr" ]; then
    # No PR, and none can be conjured from here: the sync trigger is the Sync
    # Now button in Crowdin's GitHub app (crowdin.com/project/edge/apps), with
    # no API surface, and the scheduled sync has been dormant since 2026-06.
    # This is a REPORTED gap, not a blocker: the 4.50.0 cut shipped without an
    # l10n merge too. The release proceeds with translations unmerged.
    step "$phase" ok "no open Crowdin PR; nothing to merge. If a sync was expected, trigger Sync Now in the Crowdin GitHub app (the scheduled sync has been dormant) and re-run."
    say "$repo: no Crowdin PR; nothing to merge"
    return 0
  fi
  if [ -n "$CROWDIN_MERGE_EXISTING" ]; then
    if [ -n "$DRY_RUN" ]; then
      step "$phase" dry-run "open Crowdin PR #$pr would be merged as-is (operator vouched it is fresh)"
      return 0
    fi
    MERGE_MODE="merge"
    crowdin_merge_pr "$repo" "$pr" \
      || { step "$phase" failed "merge of existing PR #$pr failed"; die "crowdin: merging $repo PR #$pr failed"; }
    step "$phase" ok "merged existing PR #$pr as-is${MERGE_MODE:+ ($MERGE_MODE)} (operator vouched it is fresh)"
    say "merged $repo Crowdin PR #$pr"
    return 0
  fi
  if [ -n "$DRY_RUN" ]; then
    step "$phase" dry-run "open Crowdin PR #$pr would be closed and deleted, re-synced via the Crowdin app, and the fresh PR merged"
    return 0
  fi
  # Close and DELETE so the fresh sync produces one compressed PR instead of
  # stacking onto a stale branch, then hand the Sync Now click to the operator.
  local head
  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
  gh pr close "$pr" --repo "$repo" --delete-branch >/dev/null 2>&1 \
    || { step "$phase" failed "could not close PR #$pr"; die "crowdin: closing $repo PR #$pr failed"; }
  say "closed and deleted $repo PR #$pr ($head)"
  hdr "Operator step: Crowdin sync for $repo"
  echo "  1. Open https://crowdin.com/project/edge/apps/system/github"
  echo "  2. Click $repo, then Sync Now"
  echo "  3. Wait for the fresh Crowdin PR to appear"
  printf 'Press return once the new PR exists (or s to proceed without translations): '
  read -r reply
  if [ "$reply" = "s" ]; then
    step "$phase" warn "operator proceeded without translations (sync unavailable)"
    return 0
  fi
  pr="$(gh pr list --repo "$repo" --state open --head l10n_develop --json number --jq '.[0].number // empty' 2>/dev/null || echo "")"
  if [ -z "$pr" ]; then
    step "$phase" failed "no Crowdin PR appeared after the sync"
    die "crowdin: no PR to merge in $repo"
  fi
  MERGE_MODE="merge"
  crowdin_merge_pr "$repo" "$pr" \
    || { step "$phase" failed "merge of PR #$pr failed"; die "crowdin: merging $repo PR #$pr failed"; }
  step "$phase" ok "merged PR #$pr${MERGE_MODE:+ ($MERGE_MODE)}"
  say "merged $repo Crowdin PR #$pr"
}

hdr "Translations"
crowdin_step EdgeApp/edge-react-gui Crowdin-gui
crowdin_step EdgeApp/edge-login-ui-rn Crowdin-login-ui
# The Crowdin merges moved develop; re-resolve before cutting the worktree.
git -C "$REPO" fetch --quiet --tags "$REMOTE" "$DEVELOP" || die "re-fetch after crowdin failed"

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
# COPIED, never symlinked: a symlink named `_` is a file, so husky's own
# `_/.gitignore` (which lives INSIDE the real dir) cannot ignore it, and a
# scoped commit can sweep the link into the repo as a dangling absolute path
# that breaks husky on every other machine (shipped to develop+staging in the
# 4.51.0 cut's zcash pin-bump, 2026-08-27; removed in 99297e718).
if [ ! -e "$WT/.husky/_" ] && [ -d "$REPO/.husky/_" ]; then
  mkdir -p "$WT/.husky"
  cp -R "$REPO/.husky/_" "$WT/.husky/_"
  say "copied .husky/_"
fi
# Copied, not symlinked: the prepare step regenerates this dir (typechain
# mkdir), which fails with EEXIST when the path is a symlink into the caller's
# checkout — and a symlink would let the regen write into that checkout.
if [ ! -e "$WT/src/plugins/contracts" ] && [ -d "$REPO/src/plugins/contracts" ]; then
  cp -R "$REPO/src/plugins/contracts" "$WT/src/plugins/contracts"
  say "copied src/plugins/contracts"
fi
# Copied rather than linked so nothing the hooks do can write into the caller's
# checkout. Without these, the precommit tsc fails on unresolvable modules.
for p in env.json src/controllers/edgeProvider/client/rolledUp.js src/controllers/edgeProvider/injectThisInWebView.js; do
  [ -e "$WT/$p" ] && continue
  [ -e "$REPO/$p" ] || { warn "missing $p in $REPO, the precommit hooks may fail"; continue; }
  mkdir -p "$(dirname "$WT/$p")"
  cp "$REPO/$p" "$WT/$p"
  say "copied $p"
done

step Workspace ok "$WT on $TMP_DEV"

# -------------------------------------------------------- dependency bumps ---
# Checklist subtasks 3-5. History places these upgrade commits on develop
# immediately before the version bump (the 4.46.0 and 4.50.0 cuts both show
# upgrade-then-bump), so they are made HERE on the temp develop branch. The
# publish chain is pr-land's existing machinery: pr-land-publish.sh (bump +
# changelog + tag in the dep repo), npm-publish-web.sh (web-auth publish,
# operator taps the link), upgrade-dep.sh (bump the pin in the gui + lockfiles).
registry_version() {
  curl -fsS --max-time 10 "https://registry.npmjs.org/$1/latest" 2>/dev/null | read_json_field version || echo ""
}
pinned_version() {
  git -C "$WT" show "HEAD:package.json" | read_json_field "dependencies.$1" | sed 's/^[\^~]//'
}

dep_step() {
  local phase="$1" pkg="$2" prep_cmd="$3" cl_entry="$4" bump="${5:-}"
  local repo_dir="$HOME/git/$pkg" pin latest
  pin="$(pinned_version "$pkg")"
  latest="$(registry_version "$pkg")"
  if [ -n "$DRY_RUN" ]; then
    step "$phase" dry-run "would refresh in $repo_dir, publish via pr-land machinery, upgrade gui (pin $pin, registry ${latest:-unknown})"
    return 0
  fi
  [ -d "$repo_dir" ] || { step "$phase" failed "$repo_dir not cloned"; die "dep: missing checkout $repo_dir"; }
  local branch dirty
  branch="$(git -C "$repo_dir" branch --show-current)"
  dirty="$(git -C "$repo_dir" status --porcelain | head -1)"
  [ "$branch" = "master" ] || { step "$phase" failed "$pkg checkout is on '$branch', not master"; die "dep: $pkg not on master"; }
  [ -z "$dirty" ] || { step "$phase" failed "$pkg checkout is dirty"; die "dep: $pkg has uncommitted changes"; }
  git -C "$repo_dir" pull --ff-only --quiet || { step "$phase" failed "pull failed"; die "dep: $pkg pull failed"; }

  # The refresh scripts run under `node -r sucrase/register`, so the repo's own
  # dev dependencies must be installed first (a fresh or long-idle checkout has
  # no node_modules).
  ( cd "$repo_dir" && "$HOME/.cursor/skills/pm.sh" install ) >"$TMPROOT/staging-release-merge.$$.$pkg.install.log" 2>&1 \
    || { step "$phase" failed "dependency install failed, log $TMPROOT/staging-release-merge.$$.$pkg.install.log"; die "dep: $pkg install failed"; }
  ( cd "$repo_dir" && eval "$prep_cmd" ) >"$TMPROOT/staging-release-merge.$$.$pkg.log" 2>&1 \
    || { step "$phase" failed "'$prep_cmd' failed, log $TMPROOT/staging-release-merge.$$.$pkg.log"; die "dep: $pkg prep failed"; }
  if [ -n "$(git -C "$repo_dir" status --porcelain)" ]; then
    # pr-land-publish.sh refuses an empty ## Unreleased section (exit 2), so the
    # refresh commit carries its own changelog entry, per the checklist's "bump
    # version and update changelog".
    node - "$repo_dir/CHANGELOG.md" "$cl_entry" <<'CLNODE' \
      || { step "$phase" failed "could not add CHANGELOG entry"; die "dep: $pkg changelog edit failed"; }
const fs = require("fs");
const [file, entry] = process.argv.slice(2);
const lines = fs.readFileSync(file, "utf8").split("\n");
const at = lines.findIndex((l) => /^##\s+Unreleased\b/.test(l));
if (at === -1) { console.error("no ## Unreleased heading"); process.exit(1); }
if (!lines.slice(at + 1, at + 12).some((l) => l === entry)) lines.splice(at + 1, 0, "", entry);
fs.writeFileSync(file, lines.join("\n"));
CLNODE
    ( cd "$repo_dir" && "$LINT_COMMIT" -m "${cl_entry#- changed: }" ) >>"$TMPROOT/staging-release-merge.$$.$pkg.log" 2>&1 \
      || { step "$phase" failed "commit failed"; die "dep: $pkg commit failed"; }
    # The refresh commit must reach origin BEFORE pr-land-publish.sh runs: that
    # script hard-resets the branch to origin/<branch> (it assumes pr-land's
    # already-merged state), so an unpushed local commit would be destroyed.
    git -C "$repo_dir" push "$REMOTE" master \
      || { step "$phase" failed "push of refresh commit failed"; die "dep: $pkg push failed"; }
  else
    say "$pkg: no refresh changes; continuing to the publish check (resumes an interrupted release, no-ops a current one)"
  fi
  # Clear tag debris from an interrupted run: pr-land-publish.sh hard-resets to
  # origin/<branch>, orphaning any unpushed local bump commit, and its re-bump
  # then dies on `tag already exists`. A local tag that is neither reachable
  # from origin/master nor present on the remote is that debris; delete it.
  local t
  for t in $(git -C "$repo_dir" tag --no-merged "$REMOTE/master" 2>/dev/null); do
    if ! git -C "$repo_dir" ls-remote --tags "$REMOTE" "refs/tags/$t" 2>/dev/null | grep -q .; then
      git -C "$repo_dir" tag -d "$t" >/dev/null
      say "$pkg: deleted orphaned local tag $t (debris from an interrupted run)"
    fi
  done
  local pub_json pub_rc new_version skipped_err
  pub_rc=0
  pub_json="$(printf '[{"repo":"%s","branch":"master"%s}]' "$pkg" "${bump:+,\"bump\":\"$bump\"}" | "$PUBLISH_SH" | sed -n '/^{/,$p')" || pub_rc=$?
  if [ "$pub_rc" -eq 2 ]; then
    # Exit 2 is "nothing to release" ONLY for an empty-but-present Unreleased
    # section with the current version already served by the registry. Any
    # other exit-2 shape (missing CHANGELOG, missing Unreleased heading) is
    # repo damage and stops the run. Failures are stops, never skips.
    local err2 mver
    err2="$(printf '%s' "$pub_json" | read_json_field "skipped.0.error" 2>/dev/null || echo "")"
    mver="$(git -C "$repo_dir" show "$REMOTE/master:package.json" | read_json_field version)"
    if [ "$err2" = "No entries in Unreleased section" ] && [ -n "$latest" ] && [ "$mver" = "$latest" ]; then
      if [ "$pin" != "$latest" ]; then
        ( cd "$WT" && "$UPGRADE_DEP" "$pkg" "$latest" ) \
          || { step "$phase" failed "nothing to publish, but upgrade-dep.sh failed for the gui pin"; die "dep: gui upgrade of $pkg failed"; }
        step "$phase" ok "nothing to publish; gui pin upgraded $pin -> $latest"
        return 0
      fi
      step "$phase" ok "nothing to publish (Unreleased empty, $latest current on registry and master)"
      return 0
    fi
    step "$phase" failed "pr-land-publish.sh exit 2: ${err2:-unreadable reason} (master $mver, registry ${latest:-unknown})"
    die "dep: $pkg publish preflight refused; failures are stops"
  fi
  [ "$pub_rc" -eq 0 ] || { step "$phase" failed "pr-land-publish.sh exit $pub_rc"; die "dep: $pkg version bump failed"; }
  # A skipped repo also comes back with exit 0: the JSON's published array is
  # empty and skipped[] carries the reason.
  skipped_err="$(printf '%s' "$pub_json" | read_json_field "skipped.0.error" 2>/dev/null || echo "")"
  new_version="$(printf '%s' "$pub_json" | read_json_field "published.0.newVersion" 2>/dev/null || echo "")"
  if [ -z "$new_version" ] && [ -n "$skipped_err" ]; then
    local master_ver
    master_ver="$(git -C "$repo_dir" show "$REMOTE/master:package.json" | read_json_field version)"
    if [ "$skipped_err" != "No entries in Unreleased section" ]; then
      step "$phase" failed "pr-land-publish.sh skipped: $skipped_err. Failures are stops, never skips."
      die "dep: $pkg publish skipped for a non-benign reason"
    fi
    if [ -n "$latest" ] && [ "$master_ver" != "$latest" ]; then
      step "$phase" failed "registry serves $latest but $REMOTE/master's package.json says $master_ver; a prior run published without pushing the bump. Reconcile by hand (recreate the bump commit on master or unpublish), then re-run."
      die "dep: $pkg registry/master version mismatch"
    fi
    if [ -n "$latest" ] && [ "$pin" != "$latest" ]; then
      ( cd "$WT" && "$UPGRADE_DEP" "$pkg" "$latest" ) \
        || { step "$phase" failed "already published, but upgrade-dep.sh failed for the gui pin"; die "dep: gui upgrade of $pkg failed"; }
      step "$phase" ok "already published; gui pin upgraded $pin -> $latest"
      return 0
    fi
    step "$phase" ok "nothing to publish (Unreleased empty; pin $pin == registry $latest)"
    return 0
  fi
  [ -n "$new_version" ] || { step "$phase" failed "no newVersion in pr-land-publish.sh output"; die "dep: $pkg publish output unreadable"; }
  # A resumed release can arrive here with the bump commit on master but the
  # tag gone (pr-land-publish's resume path never re-tags). Recreate it so the
  # post-publish --follow-tags push has a tag to carry.
  if ! git -C "$repo_dir" tag -l "v$new_version" | grep -q .; then
    git -C "$repo_dir" tag "v$new_version" \
      || { step "$phase" failed "could not tag v$new_version"; die "dep: $pkg tag failed"; }
    say "$pkg: recreated missing tag v$new_version at $(git -C "$repo_dir" rev-parse --short HEAD)"
  fi
  git -C "$repo_dir" push "$REMOTE" master --follow-tags \
    || { step "$phase" failed "push of master + tag failed"; die "dep: $pkg push failed"; }
  # Publish is the auth-gated, RESUMABLE tail (pr-land npm-publish-auth): a
  # pushed version commit npm lacks is benign — a re-run's resume path
  # completes it whenever the operator taps the link.
  "$NPM_PUBLISH" "$repo_dir" \
    || { step "$phase" failed "npm publish did not complete (auth pending or registry error); master+tag are pushed, re-run resumes the publish"; die "dep: $pkg publish pending"; }
  ( cd "$WT" && "$UPGRADE_DEP" "$pkg" "$new_version" ) \
    || { step "$phase" failed "upgrade-dep.sh failed in the gui worktree"; die "dep: gui upgrade of $pkg failed"; }
  step "$phase" ok "published $new_version, gui upgraded from $pin"
}

hdr "Dependency updates"
dep_step zcash react-native-zcash "\"$HOME/.cursor/skills/pm.sh\" run update-checkpoints" "- changed: Update checkpoints" patch
dep_step piratechain react-native-piratechain "\"$HOME/.cursor/skills/pm.sh\" run update-checkpoints" "- changed: Update checkpoints" patch
# pm.sh has no `add` subcommand; resolve the PM once and call it directly.
dep_step chain-registry edge-currency-accountbased 'PM=$("$HOME/.cursor/skills/pm.sh" detect); "$PM" add chain-registry && "$HOME/.cursor/skills/pm.sh" run prepare' "- changed: Update chain-registry"

# ------------------------------------------------------------------- bump ----
hdr "Version bump on $DEVELOP"
BUMP_OUT="$TMPROOT/staging-release-merge.$$.bumpedit.out"
node - "$WT" "$VERSION" "$PREV_DATE" <<'NODE' > "$BUMP_OUT" || { cat "$BUMP_OUT"; exit 1; }
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
// The checklist also asks for dates on ANY published version missing one, not
// just the release being retired. Date those from their tags; a version with
// no tag is left alone and counted, never guessed.
let backfilled = 0, untaggable = 0;
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^##\s+(\d+\.\d+\.\d+)\s*$/);
  if (!m) continue;
  const d = tagDate(m[1]);
  if (!d) { untaggable++; continue; }
  lines[i] = `## ${m[1]} (${d})`;
  backfilled++;
}
if (backfilled) console.log(`>> backfilled dates on ${backfilled} undated release heading(s) from their tags`);
if (untaggable) console.log(`!! ${untaggable} undated heading(s) have no matching tag and were left as-is`);

// Open the new release section: everything accumulated under the unreleased
// heading becomes this release's entries.
const at = lines.findIndex((l) => /^##\s+Unreleased\b/.test(l));
if (at === -1) { console.error("!! no `## Unreleased` heading in CHANGELOG.md"); process.exit(1); }
lines.splice(at + 1, 0, "", `## ${version} (staging)`);
fs.writeFileSync(cl, lines.join("\n"));
console.log(`>> opened release section ${version} (staging)`);
NODE

cat "$BUMP_OUT"
# Checklist subtask 6 gets its own ledger row: re-dating a shipped release is
# distinct work from opening the new section, and "nothing needed re-dating"
# must read differently from "re-dated".
DATED="$(grep '^>> dated previous release' "$BUMP_OUT" | sed 's/^>> dated previous release //' | paste -sd, - || true)"
BACKFILL="$(grep '^>> backfilled dates' "$BUMP_OUT" | sed 's/^>> //' || true)"
UNTAGGED="$(grep 'no matching tag' "$BUMP_OUT" | sed 's/^!! //' || true)"
if grep -q '^!! no tag' "$BUMP_OUT"; then
  step Release-dates warn "$(grep '^!! no tag' "$BUMP_OUT" | head -1 | sed 's/^!! //')"
elif [ -n "$DATED" ] || [ -n "$BACKFILL" ]; then
  step Release-dates ok "${DATED:-no (staging) heading}${BACKFILL:+; $BACKFILL}${UNTAGGED:+; $UNTAGGED}"
else
  step Release-dates skipped "every published heading already dated"
fi

rc=0
( cd "$WT" && "$LINT_COMMIT" -m "Bump version to v$VERSION" package.json package-lock.json CHANGELOG.md ) >"$BUMP_LOG" 2>&1 || rc=$?
if [ $rc -ne 0 ]; then
  tail -30 "$BUMP_LOG" >&2
  die "bump commit failed (full log: $BUMP_LOG)"
fi
step Version-bump ok "$(git -C "$WT" rev-parse --short HEAD) sets $VERSION in package.json, package-lock.json, CHANGELOG.md"
say "bump commit $(git -C "$WT" rev-parse --short HEAD)"
git -C "$WT" --no-pager show --stat --oneline HEAD | sed 's/^/   /'

# ------------------------------------------------------------------ merge ----
hdr "Merge $DEVELOP into $STAGING"
git -C "$WT" switch --quiet -c "$TMP_STG" "$STG_REF" || die "could not branch $TMP_STG from $STG_REF"
rc=0
git -C "$WT" merge --no-ff -m "Merge branch '$DEVELOP' into $STAGING" "$TMP_DEV" >"$MERGE_LOG" 2>&1 || rc=$?

HAD_CONFLICTS=""
if [ $rc -ne 0 ]; then
  HAD_CONFLICTS=1
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
    step Merge stopped "$(printf '%s' "$REMAINING" | grep -c . ) conflict(s) outside CHANGELOG.md need an operator decision"
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
if [ -n "$HAD_CONFLICTS" ]; then
  step Merge ok "$(git -C "$WT" rev-parse --short HEAD); CHANGELOG union-resolved, ${#RESOLVE_THEIRS[@]} file(s) cleared to develop"
else
  step Merge ok "$(git -C "$WT" rev-parse --short HEAD); no conflicts"
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
  step Parity stopped "$(printf '%s' "$BLOCKING" | grep -c . ) non-CHANGELOG path(s) differ between $STAGING and $DEVELOP"
  finish parity-mismatch 2
fi
step Parity ok "clean; CHANGELOG.md is the only difference${ALLOW[0]+, allowed: ${ALLOW[*]}}"
say "parity clean (CHANGELOG.md is the only expected difference)"

# ----------------------------------------------------------------- verify ----
# The checklist runs the repo verify before pushing. The precommit chain has
# already run lint-staged + tsc + jest on both commits, so a dry run (which
# pushes nothing) records that and moves on; a real push earns the full pass
# (whole-repo lint + typechain + tsc + tests).
if [ -n "$DRY_RUN" ]; then
  step Verify dry-run "precommit ran tsc + jest on both commits; the full repo verify runs before a real push"
else
  hdr "Verify"
  VERIFY_LOG="$TMPROOT/staging-release-merge.$$.verify.log"
  verify_once() { ( cd "$WT" && "$HOME/.cursor/skills/pm.sh" run verify ) >"$VERIFY_LOG" 2>&1; }
  verify_ok=""
  if verify_once; then
    verify_ok=1
  elif grep -qa "was terminated by another process: signal=SIGSEGV" "$VERIFY_LOG"; then
    # A jest worker segfault is an infra flake, not a merge defect (the same
    # suite passes in the commit chains). One retry before failing.
    say "verify hit a jest-worker SIGSEGV; retrying once"
    verify_once && verify_ok=2
  fi
  if [ "$verify_ok" = "2" ]; then
    step Verify ok "repo verify passed on the merge result (after one jest-worker SIGSEGV retry)"
  elif [ -n "$verify_ok" ]; then
    step Verify ok "repo verify passed on the merge result"
  else
    tail -30 "$TMPROOT/staging-release-merge.$$.verify.log" >&2
    step Verify failed "repo verify failed, log $TMPROOT/staging-release-merge.$$.verify.log"
    die "verify failed on the merge result; nothing pushed"
  fi
fi

# ------------------------------------------------------------------- push ----
hdr "Push"
echo "  $TMP_DEV -> $REMOTE/$DEVELOP   ($(git -C "$WT" rev-parse --short "$TMP_DEV"))"
echo "  $TMP_STG -> $REMOTE/$STAGING   ($(git -C "$WT" rev-parse --short "$TMP_STG"))"
if [ -n "$DRY_RUN" ] || [ -n "$NO_GUI_PUSH" ]; then
  if [ -n "$DRY_RUN" ]; then
    hdr "DRY RUN, neither $DEVELOP nor $STAGING was pushed"
  else
    hdr "GUI push held (--no-gui-push); neither $DEVELOP nor $STAGING was pushed"
  fi
  if [ -n "$PUBLISH" ]; then
    # Publish the two commits as TAGS so other machines can fetch and inspect
    # the merge result. Tags, not branches, and never in the `v*` namespace:
    # `vX.Y.Z` means a shipped release here, and this script reads those tags
    # to date CHANGELOG headings. A dry-run commit landing there would corrupt
    # the release record.
    case "$TAG_PREFIX" in
      v[0-9]*|"") die "refusing tag prefix '$TAG_PREFIX': it collides with the vX.Y.Z release namespace" ;;
    esac
    DEV_TAG="$TAG_PREFIX/$VERSION-develop"
    STG_TAG="$TAG_PREFIX/$VERSION-staging"
    CLEARED="${RESOLVE_THEIRS[*]+${RESOLVE_THEIRS[*]}}"
    ALLOWED="${ALLOW[*]+${ALLOW[*]}}"
    NOTE="dry run of $DEVELOP -> $STAGING for $VERSION
source: $DEV_REF $(git -C "$REPO" rev-parse --short "$DEV_REF"), $STG_REF $(git -C "$REPO" rev-parse --short "$STG_REF")
conflicts cleared to develop: ${CLEARED:-none}
parity paths allowed: ${ALLOWED:-none}
parity diff after merge: $(printf '%s' "${DIFF_PATHS:-none}" | tr '\n' ' ')
generated by staging-release-merge.sh on $(hostname -s) at $(date -u +%Y-%m-%dT%H:%M:%SZ)
NOT A RELEASE. Nothing was pushed to $DEVELOP or $STAGING."
    git -C "$WT" tag -f -a "$DEV_TAG" -m "$NOTE" "$TMP_DEV" >/dev/null
    git -C "$WT" tag -f -a "$STG_TAG" -m "$NOTE" "$TMP_STG" >/dev/null
    # Force is scoped to this prefix, which only this script writes, so a re-run
    # moves the tag to the new attempt instead of accumulating stale ones.
    if git -C "$WT" push -f "$REMOTE" "refs/tags/$DEV_TAG" "refs/tags/$STG_TAG" >/dev/null 2>&1; then
      say "published inspection tags:"
      echo "    $DEV_TAG   $(git -C "$WT" rev-parse --short "$TMP_DEV")   (bump on $DEVELOP)"
      echo "    $STG_TAG   $(git -C "$WT" rev-parse --short "$TMP_STG")   (merge result)"
      echo
      echo "  Inspect from any machine:"
      echo "    git fetch $REMOTE --tags --force"
      echo "    git diff $DEV_TAG $STG_TAG          # the parity check"
      echo "    git show $STG_TAG                    # the merge commit"
      echo "    git log --oneline $DEV_TAG -1        # the bump"
    else
      warn "could not push the inspection tags to $REMOTE (no write access, or the remote rejected them)"
      say "they exist locally as $DEV_TAG and $STG_TAG"
    fi
  fi
  if [ -n "$DRY_RUN" ]; then
    say "release $VERSION is ready; re-run without --dry-run to push"
    step Push dry-run "nothing pushed to $DEVELOP or $STAGING${DEV_TAG:+; inspection tags $DEV_TAG, $STG_TAG}"
  else
    say "release $VERSION is ready and held; push later from the kept workspace or a re-run"
    step Push held "--no-gui-push: $DEVELOP and $STAGING untouched${DEV_TAG:+; inspection tags $DEV_TAG, $STG_TAG}"
  fi
  finish ok 0
fi
if [ -z "$ASSUME_YES" ]; then
  printf 'Push both branches? [y/N] '
  read -r reply
  case "$reply" in
    [yY]*) ;;
    *) say "declined by operator, nothing pushed"; step Push declined "operator answered no at the confirmation"; finish aborted 2 ;;
  esac
fi
git -C "$WT" push "$REMOTE" "$TMP_DEV:$DEVELOP" || die "push to $DEVELOP failed"
git -C "$WT" push "$REMOTE" "$TMP_STG:$STAGING" || die "push to $STAGING failed"
say "pushed $DEVELOP and $STAGING"
say "release $VERSION is on $STAGING"
step Push ok "$DEVELOP <- $(git -C "$WT" rev-parse --short "$TMP_DEV"), $STAGING <- $(git -C "$WT" rev-parse --short "$TMP_STG")"
finish ok 0
