#!/usr/bin/env bash
set -euo pipefail

# master-release-merge.sh — ship an X.Y.0 release by merging staging into
# master: merge with git's default message, date the release's CHANGELOG
# heading, prove master ends up with staging's tree, verify, push master, then
# push the lightweight vX.Y.0 tag on the merge commit.
#
# Point releases (X.Y.Z with Z > 0, shipped by /point-release) are out of
# scope; the preflight refuses them.
#
# Everything happens in a THROWAWAY git worktree on a temp branch cut from
# <remote>/master. The caller's checkout, HEAD, index and working tree are never
# touched, so --dry-run leaves no residue beyond the optional inspection tag.
#
# Usage: master-release-merge.sh [options]
#   --repo <path>        repo to release (default: $EDGE_GUI_DIR or ~/git/edge-react-gui)
#   --ref <commit>       staging commit to ship (default: <remote>/staging tip);
#                        must be reachable from <remote>/staging
#   --date YYYY-MM-DD    release date for the CHANGELOG heading (default: today)
#   --dry-run            do everything except the master push and the vX.Y.0 tag
#   --yes                skip the interactive push confirmation
#   --resolve-theirs <p> take staging's side for this conflicted path (repeatable)
#   --allow <glob>       parity path the operator has cleared (repeatable)
#   --build-config-ready the master build server already carries the config the
#                        release's schema change needs
#   --master <branch>    default: master
#   --staging <branch>   default: staging
#   --remote <name>      default: origin
#   --keep-workspace     leave the temp worktree in place for inspection
#   --no-publish         skip publishing the dry-run inspection tag
#   --tag-prefix <ns>    namespace for that tag (default: dryrun)
#
# Under pipefail, `cmd | grep -q` fails when grep exits early and cmd takes
# SIGPIPE, so every membership test reads a here-string instead.
#
# Exit: 0 done, 1 error, 2 needs operator input.
# The last line is always `RESULT: <verdict>`:
#   ok                done (pushed and tagged, or a clean dry run)
#   conflicts         merge conflicts outside CHANGELOG.md
#   parity-mismatch   the merge result differs from staging beyond the dated heading
#   build-config      the release changes the build config schema
#   aborted           operator declined the push
#   error             anything else

REPO="${EDGE_GUI_DIR:-$HOME/git/edge-react-gui}"
SHIP_REF=""
REL_DATE=""
DRY_RUN=""
ASSUME_YES=""
MASTER="master"
STAGING="staging"
REMOTE="origin"
KEEP_WS=""
PUBLISH=1
TAG_PREFIX="dryrun"
BUILD_CONFIG_READY=""
ALLOW=()
RESOLVE_THEIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --ref) SHIP_REF="$2"; shift 2 ;;
    --date) REL_DATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --resolve-theirs) RESOLVE_THEIRS+=("$2"); shift 2 ;;
    --allow) ALLOW+=("$2"); shift 2 ;;
    --build-config-ready) BUILD_CONFIG_READY=1; shift ;;
    --master) MASTER="$2"; shift 2 ;;
    --staging) STAGING="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --keep-workspace) KEEP_WS=1; shift ;;
    --no-publish) PUBLISH=""; shift ;;
    --tag-prefix) TAG_PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '4,35p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo "RESULT: error"; exit 1 ;;
  esac
done

PHASES="Preflight Master-only Workspace Merge Release-date Parity Build-config Commit Verify Push Tag"
# shellcheck source=../../release-merge-lib.sh
. "$HOME/.cursor/skills/release-merge-lib.sh"

TMPROOT="${TMPDIR:-/tmp}"; TMPROOT="${TMPROOT%/}"
MERGE_LOG="$TMPROOT/master-release-merge.$$.merge.log"
# Files whose change between master and the release means the master build
# server needs new config before a master build can succeed.
BUILD_CONFIG_FILES="src/envConfig.ts src/configKeysSchema.ts"

is_allowed() {
  local p="$1" g
  for g in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    case "$p" in $g) return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------- preflight --
hdr "Preflight"
[ -e "$REPO/.git" ] || die "not a git repo: $REPO"
REPO="$(cd "$REPO" && pwd)"
say "repo $REPO"

git -C "$REPO" fetch --quiet --tags "$REMOTE" "$MASTER" "$STAGING" || die "fetch failed"
MASTER_REF="$REMOTE/$MASTER"
STG_TIP="$REMOTE/$STAGING"
git -C "$REPO" rev-parse --verify --quiet "$MASTER_REF" >/dev/null || die "no such ref: $MASTER_REF"
git -C "$REPO" rev-parse --verify --quiet "$STG_TIP" >/dev/null || die "no such ref: $STG_TIP"
SHIP="$(git -C "$REPO" rev-parse --verify --quiet "${SHIP_REF:-$STG_TIP}^{commit}")" || die "no such commit: $SHIP_REF"
git -C "$REPO" merge-base --is-ancestor "$SHIP" "$STG_TIP" || die "--ref $SHIP_REF is not on $STG_TIP"
SHIP_SHORT="$(git -C "$REPO" rev-parse --short "$SHIP")"
MASTER_SHORT="$(git -C "$REPO" rev-parse --short "$MASTER_REF")"
BEHIND="$(git -C "$REPO" rev-list --count "$SHIP..$STG_TIP")"
[ "$BEHIND" = "0" ] || warn "shipping $SHIP_SHORT, $BEHIND commit(s) behind the $STG_TIP tip"

VERSION="$(git -C "$REPO" show "$SHIP:package.json" | read_json_field version)"
MASTER_VERSION="$(git -C "$REPO" show "$MASTER_REF:package.json" | read_json_field version)"
case "$VERSION" in
  [0-9]*.[0-9]*.0) ;;
  *) die "staging is at $VERSION; this flow ships X.Y.0 releases only (point releases ship through /point-release)" ;;
esac
node -e 'const [a,b]=process.argv.slice(1).map(v=>v.split(".").map(Number));for(let i=0;i<3;i++){if(a[i]!==b[i])process.exit(a[i]>b[i]?0:1)}process.exit(1)' "$VERSION" "$MASTER_VERSION" \
  || die "staging's $VERSION is not newer than $MASTER's $MASTER_VERSION"
grep -qxF "## $VERSION (staging)" <<< "$(git -C "$REPO" show "$SHIP:CHANGELOG.md")" \
  || die "staging's CHANGELOG.md has no '## $VERSION (staging)' heading"
if [ -n "$(git -C "$REPO" ls-remote --tags "$REMOTE" "refs/tags/v$VERSION")" ]; then
  die "tag v$VERSION already exists on $REMOTE; $VERSION is already released"
fi
git -C "$REPO" rev-parse --verify --quiet "refs/tags/v$VERSION" >/dev/null \
  && die "a local tag v$VERSION exists that $REMOTE does not have; delete it (git tag -d v$VERSION) and re-run"
REL_DATE="${REL_DATE:-$(date +%Y-%m-%d)}"
case "$REL_DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "--date must be YYYY-MM-DD, got: $REL_DATE" ;;
esac
say "release $VERSION ($MASTER at $MASTER_VERSION), shipping $STAGING $SHIP_SHORT, dated $REL_DATE"
step Preflight ok "$MASTER_VERSION -> $VERSION; $MASTER_REF $MASTER_SHORT, $STAGING $SHIP_SHORT; date $REL_DATE"

# -------------------------------------------------------------- master-only --
# Commits made on master since the last staging merge (point releases), each
# matched to a staging counterpart by patch-id or exact subject. This is the
# proof the Merge phase uses for conflicts: a conflicted file that no unmatched
# commit touches takes staging's side with nothing lost, however differently
# the two sides now word it (a point-release fix reaches staging through
# develop, often rewritten). An unmatched commit is either superseded on
# staging (a newer dependency pin) or missing from it, and only the operator
# can tell which.
hdr "Master-only commits since the last release merge"
LAST_MERGE="$(git -C "$REPO" log --first-parent --merges --format=%H -1 --grep="$STAGING" "$MASTER_REF")"
if [ -z "$LAST_MERGE" ]; then
  step Master-only skipped "no earlier $STAGING merge on $MASTER to measure from"
else
  BASE="$(git -C "$REPO" merge-base "$MASTER_REF" "$SHIP")"
  STG_SUBJECTS="$(git -C "$REPO" log --no-merges --format=%s "$BASE..$SHIP")"
  EQUIV="$(git -C "$REPO" cherry "$SHIP" "$MASTER_REF" "$LAST_MERGE" | awk '$1=="-"{print $2}')"
  TOTAL=0; UNMATCHED=""; UNMATCHED_SHAS=""
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    TOTAL=$((TOTAL + 1))
    grep -qxF -- "$c" <<< "$EQUIV" && continue
    s="$(git -C "$REPO" log -1 --format=%s "$c")"
    grep -qxF -- "$s" <<< "$STG_SUBJECTS" && continue
    UNMATCHED="$UNMATCHED$(git -C "$REPO" log -1 --format='%h %s' "$c")"$'\n'
    UNMATCHED_SHAS="$UNMATCHED_SHAS$c"$'\n'
  done <<< "$(git -C "$REPO" rev-list --no-merges --first-parent "$LAST_MERGE..$MASTER_REF")"
  if [ -n "$UNMATCHED" ]; then
    say "master-only commits with no counterpart on $STAGING:"
    printf '%s' "$UNMATCHED" | sed 's/^/   /'
    step Master-only warn "$(printf '%s' "$UNMATCHED" | grep -c .) of $TOTAL commit(s) since $(git -C "$REPO" rev-parse --short "$LAST_MERGE") have no counterpart on $STAGING; confirm each is superseded"
  else
    step Master-only ok "all $TOTAL commit(s) since $(git -C "$REPO" rev-parse --short "$LAST_MERGE") have a counterpart on $STAGING"
  fi
fi

# --------------------------------------------------------------- workspace ---
WT="$TMPROOT/master-release-merge-$SHIP_SHORT-$$"
TMP_BR="master-release/$VERSION"

cleanup() {
  if [ -n "$KEEP_WS" ]; then
    [ -z "$RESULT_PRINTED" ] && say "workspace kept at $WT"
    return 0
  fi
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO" branch -D "$TMP_BR" >/dev/null 2>&1 || true
  rm -rf "$WT" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

hdr "Workspace"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$REPO" branch -D "$TMP_BR" >/dev/null 2>&1 || true
git -C "$REPO" worktree add --quiet -b "$TMP_BR" "$WT" "$MASTER_REF" || die "worktree add failed"
say "worktree $WT on $TMP_BR"
# The Verify phase runs the repo's checks, which need the gitignored artifacts.
release_ws_prep "$REPO" "$WT"
step Workspace ok "$WT on $TMP_BR"

# ------------------------------------------------------------------- merge ---
hdr "Merge $STAGING into $MASTER"
rc=0
git -C "$WT" merge --no-ff --no-commit "$SHIP" >"$MERGE_LOG" 2>&1 || rc=$?
CONFLICTS=""
if [ $rc -ne 0 ]; then
  CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"
  [ -n "$CONFLICTS" ] || { tail -30 "$MERGE_LOG" >&2; die "merge failed without conflicts (full log: $MERGE_LOG)"; }
  say "conflicts:"; printf '%s\n' "$CONFLICTS" | sed 's/^/   /'
fi

# Take staging's side for every path the operator cleared. --theirs is a silent
# no-op once a path has been `git add`ed, so this runs before anything stages a
# conflicted file. A path staging deleted has no stage-3 entry, and staging's
# side of it is the deletion. A cleared path that auto-merged to something other
# than staging's file gets staging's file (or its deletion) too.
for p in "${RESOLVE_THEIRS[@]+"${RESOLVE_THEIRS[@]}"}"; do
  if grep -qxF -- "$p" <<< "$CONFLICTS"; then
    if git -C "$WT" ls-files -u -- "$p" | awk '$3 == 3 { found = 1 } END { exit !found }'; then
      git -C "$WT" checkout --theirs -- "$p"
      git -C "$WT" add -- "$p"
      say "resolved (staging's side, operator-cleared): $p"
    else
      git -C "$WT" rm --quiet -- "$p"
      say "resolved (staging's side is a deletion, operator-cleared): $p"
    fi
  elif ! git -C "$WT" diff --cached --quiet "$SHIP" -- "$p"; then
    if git -C "$WT" cat-file -e "$SHIP:$p" 2>/dev/null; then
      git -C "$WT" checkout "$SHIP" -- "$p"
    else
      git -C "$WT" rm --quiet -f -- "$p"
    fi
    say "resolved (auto-merged result replaced with staging's side, operator-cleared): $p"
  else
    warn "--resolve-theirs $p: not conflicted and already equal to $STAGING, ignored"
  fi
done

REMAINING="$(git -C "$WT" diff --name-only --diff-filter=U | grep -v '^CHANGELOG\.md$' || true)"
if [ -n "$REMAINING" ]; then
  hdr "STOP: conflicts outside CHANGELOG.md"
  SAFE=""; REVIEW=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    stages="$(git -C "$WT" ls-files -u -- "$f" | awk '{print $3}' | sort -u | tr -d '\n')"
    case "$stages" in
      *2*3*) shape="" ;;
      *2*) shape="; $STAGING deleted it, so its side is the deletion" ;;
      *) shape="; $MASTER deleted it, so $STAGING's side keeps it" ;;
    esac
    printf '  %s\n' "$f"
    if [ -n "$LAST_MERGE" ]; then
      touching=""
      while IFS= read -r c; do
        [ -n "$c" ] && grep -qxF -- "$c" <<< "$UNMATCHED_SHAS" && touching="$touching$(git -C "$REPO" log -1 --format='%h %s' "$c")"$'\n'
      done <<< "$(git -C "$REPO" rev-list --no-merges --first-parent "$LAST_MERGE..$MASTER_REF" -- "$f")"
      if [ -z "$touching" ]; then
        echo "      every $MASTER commit touching it has a counterpart on $STAGING$shape; taking $STAGING's side loses nothing"
        SAFE="$SAFE --resolve-theirs $f"
        continue
      fi
      echo "      touched by $MASTER commit(s) with no counterpart on $STAGING$shape:"
      printf '%s' "$touching" | sed 's/^/        /'
    else
      echo "      no earlier $STAGING merge to match commits against$shape"
    fi
    REVIEW="$REVIEW --resolve-theirs $f"
    if [ -z "$shape" ]; then
      release_classify_conflict "$WT/$f" "$MASTER" "$STAGING" | sed 's/^/      /'
      git -C "$WT" --no-pager diff -- "$f" | sed -n '1,40p' | sed 's/^/      /'
    fi
    echo
  done <<< "$REMAINING"
  echo
  if [ -n "$SAFE" ]; then
    echo "Cleared by the commit match (HEAD is $MASTER in any diff above):"
    echo "  $SAFE"
    echo
  fi
  if [ -n "$REVIEW" ]; then
    echo "Need an operator decision. For each listed commit, confirm $STAGING carries"
    echo "it or something newer, then clear the file with --resolve-theirs. A commit"
    echo "$STAGING genuinely lacks goes to develop first, then /staging-cherry-pick:"
    echo "  $REVIEW"
    echo
  fi
  step Merge stopped "$(grep -c . <<< "$REMAINING") conflict(s) outside CHANGELOG.md: $(grep -o -- '--resolve-theirs' <<< "$SAFE" | grep -c . || true) cleared by commit match, $(grep -o -- '--resolve-theirs' <<< "$REVIEW" | grep -c . || true) need review"
  finish conflicts 2
fi

# CHANGELOG.md is staging's file. Point-release sections reach staging through
# develop, so staging's file is a superset of master's; a union merge would
# rewrite staging's text (it deduplicates entries) instead of shipping it. The
# one thing that can be lost is a released section master has and staging
# does not, so that stops the run.
MISSING_HEADINGS="$(comm -23 \
  <(git -C "$WT" show "$MASTER_REF:CHANGELOG.md" | grep -E '^## [0-9]+\.[0-9]+\.[0-9]+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' | sort -u) \
  <(git -C "$WT" show "$SHIP:CHANGELOG.md" | grep -E '^## [0-9]+\.[0-9]+\.[0-9]+ ' | sort -u))"
if [ -n "$MISSING_HEADINGS" ]; then
  hdr "STOP: $MASTER's CHANGELOG has released sections $STAGING lacks"
  printf '%s\n' "$MISSING_HEADINGS" | sed 's/^/  /'
  echo
  echo "Land each section on develop, then /staging-cherry-pick it, and re-run."
  step Merge stopped "$(grep -c . <<< "$MISSING_HEADINGS") released CHANGELOG section(s) on $MASTER missing from $STAGING"
  finish parity-mismatch 2
fi
git -C "$WT" checkout "$SHIP" -- CHANGELOG.md
say "CHANGELOG.md taken from $STAGING (it carries every released section on $MASTER)"
if [ -n "$CONFLICTS" ]; then
  step Merge ok "$(printf '%s\n' "$CONFLICTS" | grep -c .) conflict(s) resolved, ${#RESOLVE_THEIRS[@]} path(s) cleared to $STAGING"
else
  step Merge ok "no conflicts"
fi

# ------------------------------------------------------------ release date ---
hdr "Release date"
node - "$WT/CHANGELOG.md" "$VERSION" "$REL_DATE" <<'NODE' || die "could not date the $VERSION heading in the merged CHANGELOG.md"
const fs = require("fs");
const [file, version, date] = process.argv.slice(2);
const lines = fs.readFileSync(file, "utf8").split("\n");
const at = lines.indexOf(`## ${version} (staging)`);
if (at === -1) { console.error(`no '## ${version} (staging)' heading after the merge`); process.exit(1); }
lines[at] = `## ${version} (${date})`;
fs.writeFileSync(file, lines.join("\n"));
NODE
git -C "$WT" add CHANGELOG.md
say "dated ## $VERSION ($REL_DATE)"
step Release-date ok "## $VERSION (staging) -> ## $VERSION ($REL_DATE)"

# ------------------------------------------------------------------ parity ---
# The merge result must be staging's tree. The one expected difference is the
# heading just dated; anything else in CHANGELOG.md (a master-only point-release
# section the union kept) or any other path needs an operator clearance.
hdr "Parity gate: merge result vs $STAGING $SHIP_SHORT"
EXPECTED_CL="$TMPROOT/master-release-merge.$$.CHANGELOG.expected"
git -C "$WT" show "$SHIP:CHANGELOG.md" | sed "s/^## $VERSION (staging)\$/## $VERSION ($REL_DATE)/" >"$EXPECTED_CL"
DIFF_PATHS="$(git -C "$WT" diff --cached --name-only "$SHIP" || true)"
BLOCKING=""
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ "$p" = "CHANGELOG.md" ] && git -C "$WT" show ":CHANGELOG.md" | cmp -s - "$EXPECTED_CL"; then
    continue
  fi
  if is_allowed "$p"; then say "allowed by operator: $p"; continue; fi
  BLOCKING="$BLOCKING$p"$'\n'
done <<< "$DIFF_PATHS"
if [ -n "$BLOCKING" ]; then
  hdr "STOP: the merge result differs from $STAGING"
  echo "Each diff reads from $STAGING to the merge result, so a + line is $MASTER"
  echo "content the merge kept. Git keeps it when $STAGING took the same change and"
  echo "later changed it again (a revert or rework); the commits below say which."
  echo
  FIXABLE=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    printf '  %s\n' "$p"
    if [ -n "$LAST_MERGE" ] && [ "$p" != "CHANGELOG.md" ]; then
      touching=""; unmatched=""
      while IFS= read -r c; do
        [ -z "$c" ] && continue
        touching="$touching$(git -C "$REPO" log -1 --format='%h %s' "$c")"$'\n'
        grep -qxF -- "$c" <<< "$UNMATCHED_SHAS" && unmatched=1
      done <<< "$(git -C "$REPO" rev-list --no-merges --first-parent "$LAST_MERGE..$MASTER_REF" -- "$p")"
      if [ -n "$touching" ] && [ -z "$unmatched" ]; then
        echo "      every $MASTER commit touching it has a counterpart on $STAGING; $STAGING changed it since:"
        git -C "$REPO" log --format='%h %s' -3 "$(git -C "$REPO" merge-base "$MASTER_REF" "$SHIP")..$SHIP" -- "$p" | sed 's/^/        /'
        FIXABLE="$FIXABLE --resolve-theirs $p"
      elif [ -n "$touching" ]; then
        echo "      touched by $MASTER commit(s), at least one with no counterpart on $STAGING:"
        printf '%s' "$touching" | sed 's/^/        /'
      fi
    fi
    if [ "$p" = "CHANGELOG.md" ]; then
      git -C "$WT" show ":CHANGELOG.md" | diff -u "$EXPECTED_CL" - | sed -n '3,60p' | sed 's/^/      /' || true
    else
      git -C "$WT" --no-pager diff --cached "$SHIP" -- "$p" | sed -n '1,40p' | sed 's/^/      /'
    fi
    echo
  done <<< "$BLOCKING"
  if [ -n "$FIXABLE" ]; then
    echo "$STAGING superseded these; re-run adding:"
    echo " $FIXABLE"
    echo
  fi
  echo "Anything else is $MASTER content $STAGING never received: land it on develop,"
  echo "then /staging-cherry-pick, or clear the path with --allow <glob> to keep it."
  echo
  step Parity stopped "$(printf '%s' "$BLOCKING" | grep -c .) path(s) differ from $STAGING beyond the dated heading"
  finish parity-mismatch 2
fi
step Parity ok "tree equals $STAGING $SHIP_SHORT except the dated heading${ALLOW[0]+; allowed: ${ALLOW[*]}}"

# ------------------------------------------------------------ build config ---
hdr "Build config"
# shellcheck disable=SC2086
CFG_CHANGES="$(git -C "$WT" diff --cached --name-status "$MASTER_REF" -- $BUILD_CONFIG_FILES || true)"
if [ -z "$CFG_CHANGES" ]; then
  step Build-config ok "no change to $BUILD_CONFIG_FILES since $MASTER $MASTER_SHORT"
elif [ -n "$BUILD_CONFIG_READY" ]; then
  step Build-config ok "schema changed ($(printf '%s' "$CFG_CHANGES" | tr '\t\n' ' ')); operator confirmed the $MASTER build config is ready"
elif [ -n "$DRY_RUN" ]; then
  # A dry run ships nothing, so it continues to the inspection tag; the real
  # run stops here until the operator confirms.
  say "build config schema changed; a real run stops here until --build-config-ready"
  printf '%s\n' "$CFG_CHANGES" | sed 's/^/   /'
  step Build-config warn "schema changed: $(printf '%s' "$CFG_CHANGES" | tr '\t\n' ' '); a real run needs --build-config-ready"
else
  hdr "STOP: this release changes the build config schema"
  echo "$MASTER builds read their config from the build server. These files change"
  echo "between $MASTER and the release, so the $MASTER job needs matching config"
  echo "before its first build of $VERSION:"
  echo
  printf '%s\n' "$CFG_CHANGES" | sed 's/^/  /'
  echo
  # shellcheck disable=SC2086
  git -C "$WT" --no-pager diff --cached --stat "$MASTER_REF" -- $BUILD_CONFIG_FILES | sed 's/^/  /'
  echo
  echo "Once the $MASTER build config is updated, re-run with --build-config-ready."
  step Build-config stopped "schema changed: $(printf '%s' "$CFG_CHANGES" | tr '\t\n' ' ')"
  finish build-config 2
fi

# ------------------------------------------------------------------ commit ---
# --no-verify: parity just proved the tree is staging's (plus one dated
# heading), which already passed its own checks. The pre-commit hook could only
# rewrite files away from that tree (lint-staged fixes, the eslint warning
# list). The Verify phase runs the full repo check on a real run.
hdr "Commit"
git -C "$WT" commit --quiet --no-verify -m "Merge branch '$STAGING'" >>"$MERGE_LOG" 2>&1 \
  || { tail -30 "$MERGE_LOG" >&2; die "merge commit failed (full log: $MERGE_LOG)"; }
MERGE_SHA="$(git -C "$WT" rev-parse HEAD)"
MERGE_SHORT="$(git -C "$WT" rev-parse --short HEAD)"
say "merge commit $MERGE_SHORT"
step Commit ok "$MERGE_SHORT \"Merge branch '$STAGING'\", parents $MASTER_SHORT $SHIP_SHORT"

# ------------------------------------------------------------------ verify ---
if [ -n "$DRY_RUN" ]; then
  step Verify dry-run "the full repo verify runs before a real push"
else
  hdr "Verify"
  VERIFY_LOG="$TMPROOT/master-release-merge.$$.verify.log"
  rc=0; release_verify "$WT" "$VERIFY_LOG" || rc=$?
  if [ $rc -eq 3 ]; then
    step Verify ok "repo verify passed on the merge result (after one jest-worker SIGSEGV retry)"
  elif [ $rc -eq 0 ]; then
    step Verify ok "repo verify passed on the merge result"
  else
    tail -30 "$VERIFY_LOG" >&2
    step Verify failed "repo verify failed, log $VERIFY_LOG"
    die "verify failed on the merge result; nothing pushed"
  fi
fi

# -------------------------------------------------------------- push + tag ---
hdr "Push"
echo "  $TMP_BR -> $REMOTE/$MASTER   ($MERGE_SHORT)"
echo "  tag v$VERSION -> $MERGE_SHORT"
INSPECT_TAG="$TAG_PREFIX/$VERSION-master"
if [ -n "$DRY_RUN" ]; then
  hdr "DRY RUN, $MASTER was not pushed and v$VERSION was not tagged"
  if [ -n "$PUBLISH" ]; then
    # Never in the `v*` namespace: vX.Y.Z means a shipped release here, and
    # /develop-staging reads those tags to date CHANGELOG headings.
    case "$TAG_PREFIX" in
      v[0-9]*|"") die "refusing tag prefix '$TAG_PREFIX': it collides with the vX.Y.Z release namespace" ;;
    esac
    NOTE="dry run of $STAGING -> $MASTER for $VERSION
source: $MASTER_REF $MASTER_SHORT, $STAGING $SHIP_SHORT
conflicts cleared to staging: ${RESOLVE_THEIRS[*]+${RESOLVE_THEIRS[*]}}
parity paths allowed: ${ALLOW[*]+${ALLOW[*]}}
generated by master-release-merge.sh on $(hostname -s) at $(date -u +%Y-%m-%dT%H:%M:%SZ)
NOT A RELEASE. Nothing was pushed to $MASTER."
    git -C "$WT" tag -f -a "$INSPECT_TAG" -m "$NOTE" "$MERGE_SHA" >/dev/null
    # Force is scoped to this prefix, which only the release scripts write.
    if git -C "$WT" push -f "$REMOTE" "refs/tags/$INSPECT_TAG" >/dev/null 2>&1; then
      say "published inspection tag $INSPECT_TAG ($MERGE_SHORT)"
      echo "  Inspect from any machine:"
      echo "    git fetch $REMOTE --tags --force"
      echo "    git diff $SHIP_SHORT $INSPECT_TAG       # the parity check"
      echo "    git show --stat $INSPECT_TAG             # the merge commit"
    else
      warn "could not push $INSPECT_TAG to $REMOTE; it exists locally"
    fi
    git -C "$REPO" tag -d "$INSPECT_TAG" >/dev/null 2>&1 || true
  fi
  step Push dry-run "nothing pushed to $MASTER${PUBLISH:+; inspection tag $INSPECT_TAG}"
  step Tag dry-run "v$VERSION not created"
  finish ok 0
fi
if [ -z "$ASSUME_YES" ]; then
  printf 'Push %s to %s and tag v%s? [y/N] ' "$MERGE_SHORT" "$MASTER" "$VERSION"
  read -r reply
  case "$reply" in
    [yY]*) ;;
    *) say "declined by operator, nothing pushed"; step Push declined "operator answered no at the confirmation"; finish aborted 2 ;;
  esac
fi
git -C "$WT" push "$REMOTE" "$TMP_BR:$MASTER" \
  || { step Push failed "push rejected ($MASTER moved since the fetch?); nothing changed on $REMOTE"; die "push to $MASTER failed; re-run to merge onto the new tip"; }
step Push ok "$MASTER <- $MERGE_SHORT"
say "pushed $MASTER"

# Lightweight, on the merge commit: the shape of every earlier vX.Y.0 tag.
git -C "$REPO" tag "v$VERSION" "$MERGE_SHA" \
  || { step Tag failed "could not create v$VERSION locally"; die "tag failed; $MASTER is pushed. Finish with: git tag v$VERSION $MERGE_SHA && git push $REMOTE refs/tags/v$VERSION"; }
git -C "$REPO" push "$REMOTE" "refs/tags/v$VERSION" \
  || { step Tag failed "push of v$VERSION failed"; die "tag push failed; $MASTER is pushed. Finish with: git push $REMOTE refs/tags/v$VERSION"; }
step Tag ok "v$VERSION -> $MERGE_SHORT"
say "tagged v$VERSION"
git -C "$REPO" push "$REMOTE" ":refs/tags/$INSPECT_TAG" >/dev/null 2>&1 && say "deleted stale inspection tag $INSPECT_TAG" || true
finish ok 0
