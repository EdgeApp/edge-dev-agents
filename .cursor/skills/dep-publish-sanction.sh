#!/usr/bin/env bash
# dep-publish-sanction.sh — the sanction for a PR whose CI cannot pass until a
# dependency publishes (one-shot `dep-blocked-pr-vs-bump`). Such a PR opens ready
# for review like any other; this script records why its CI is red and lets the
# watch excuse exactly that failure and nothing else.
#
# The sanction is two things on the PR, and needs both:
#   - the GitHub label `awaiting-dep-publish`
#   - a body block naming what it waits on, one line per dependency:
#       <!-- agent-dep-publish:start -->
#       Awaiting publish: <pkg>@<version> (npm latest when applied: <x.y.z>)
#       <!-- agent-dep-publish:end -->
#     (an agent sentinel block, so pr-prose-edit.sh carries it across rewrites).
#     <version> is a prediction; the recorded latest is what makes expiry
#     certain: ANY publish of the package after the sanction was applied
#     expires it, whichever version number that publish took.
#
# It excuses CI checks only. Reviewer-bot checks and review threads gate as on
# any PR; a failing check this script cannot classify is never excused.
#
# Usage:
#   dep-publish-sanction.sh apply --repo <owner/name> --pr <n> --dep <pkg> --version <x.y.z>
#       Adds the label and the body line (replacing an earlier line for the same
#       package). Run once per dependency the PR waits on. <version> is the
#       version the dependency's next publish will carry: its package.json
#       version bumped by its Unreleased CHANGELOG, minor for added/changed,
#       patch for fixed (what pr-land-publish.sh stamps).
#   dep-publish-sanction.sh check --repo <owner/name> --pr <n> [--ignore-prefix <check-name-prefix>]...
#       First stdout line is the verdict:
#         SANCTION: valid awaiting="<pkg>@<ver>[, ...]" excused="<check>[, ...]" kind=<install|types|none>
#         SANCTION: expired published="<pkg>@<ver>[, ...]"
#         SANCTION: unconfirmed check="<name>" reason="<why>"
#         SANCTION: none reason="<label or body line missing>"
#       valid       every awaited version is still unpublished AND every failing
#                   check is a missing-package failure (below). No failing check
#                   at all is also valid, with excused="".
#       expired     every awaited package has published since the sanction was
#                   applied (the awaited version is on npm, or the registry's
#                   latest moved past the awaited version or past the latest
#                   recorded at apply). The failure is excused by nothing: land
#                   the bump, rebase, get CI green, then `clear`. A label that
#                   outlives the publish is a defect. If the publish that
#                   expired it did not carry this PR's dependency change,
#                   `apply` again with the next version.
#       unconfirmed a failing check is not the missing-package kind, or has no
#                   log this script can read. Treat it as an ordinary failure.
#   dep-publish-sanction.sh clear --repo <owner/name> --pr <n>
#       Removes the label and the body block. pr-land runs it once the bump is
#       on the base branch and the PR is rebased onto it.
#
# MISSING-PACKAGE FAILURE, per failing check:
#   Travis (log read without auth: api.travis-ci.com /build/<id>/jobs, then
#   /job/<id>/log.txt, build id from the check's details URL): every command
#   the job reports as failed (`The command "<cmd>" exited with <n>`) must be
#     - an install step (npm ci / npm install / yarn) with a registry error
#       naming an awaited package (ETARGET, "No matching version found for",
#       "Couldn't find any versions for"), or
#     - a `tsc` step with at least one `error TS<n>` diagnostic.
#   A failed test, lint or build command is never excused.
#   GitHub Actions (`gh run view --log-failed`): no failed-test or lint-error
#   marker, and either that registry error or a TypeScript diagnostic.
#   A type-check failure is accepted on the tsc step alone: a diagnostic against
#   a missing API ("Property 'x' does not exist on type 'Y'") does not name the
#   package the type comes from. What ties it to the dependency is the required
#   local pass against the linked package (build-and-test
#   `gui-dependency-integration`), which this script cannot see.
#
# Exit: 0 valid / applied / cleared; 1 error (gh, npm or Travis unreachable,
#       PR not open, not your PR); 2 usage, or apply needs the operator (the
#       label does not exist in the repo: creating one is the operator's call);
#       3 expired (check), or apply refused because the version is already on
#       npm; 4 unconfirmed; 5 none.
# Env (tests): DPS_NPM (npm binary), DPS_TRAVIS_API (API root).
set -euo pipefail

LABEL="awaiting-dep-publish"
NPM="${DPS_NPM:-npm}"
TRAVIS_API="${DPS_TRAVIS_API:-https://api.travis-ci.com}"
S_START="<!-- agent-dep-publish:start -->"
S_END="<!-- agent-dep-publish:end -->"

usage() { sed -n '18,48p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SUB="${1:-}"; [ $# -gt 0 ] && shift
REPO="" PR="" DEP="" VERSION="" LOG_FILE="" KIND=""
IGNORE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --dep) DEP="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --ignore-prefix) IGNORE+=("${2:-}"); shift 2 ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

# ---- log classification -----------------------------------------------------
# classify_log <travis|actions> <pkg>[,<pkg>...] < log
# Prints "missing-package <install|types> <detail>" or "other <reason>".
classify_log() {
  perl -e '
my ($kind, $pkgs) = @ARGV; local $/; my $t = <STDIN>; $t = "" unless defined $t;
$t =~ s/\e\[[0-9;]*[A-Za-z]//g; $t =~ s/\r/\n/g;
my $install = "";
for my $pkg (split /,/, $pkgs) {
  my $q = quotemeta($pkg);
  my $err = qr/ETARGET|notarget|No matching version found for|Couldn.t find any versions for/;
  if ($t =~ /^[^\n]*(?:$err)[^\n]*(?<![\w\/@-])$q(?![\w\/-])[^\n]*$/m || $t =~ /^[^\n]*(?<![\w\/@-])$q(?![\w\/-])[^\n]*(?:$err)[^\n]*$/m) { $install = $pkg; last }
}
my @ts = ($t =~ /^[^\n]*error TS[0-9]+:[^\n]*$/mg);
my $ts_detail = scalar(@ts) . " TypeScript diagnostic(s)";
if (@ts) { my $first = $ts[0]; $first =~ s/^\s+//; $first = substr($first, 0, 160); $ts_detail .= ", first: $first" }
if ($kind eq "travis") {
  my (@failed, %seen);
  while ($t =~ /The command "([^"\n]+)" (?:failed and )?exited with ([0-9]+)/g) { push @failed, $1 if $2 != 0 && !$seen{$1}++ }
  unless (@failed) { print "other the job log reports no failed command\n"; exit }
  my $any_install = 0;
  for my $c (@failed) {
    if ($c =~ /\btsc\b/) {
      unless (@ts) { print "other `$c` failed with no TypeScript diagnostic\n"; exit }
      next;
    }
    if ($c =~ /^(?:eval\s+)?(?:npm\s+(?:ci|install|i)\b|yarn(?:\s+install\b|\s+--|\s*$))/) {
      unless ($install) { print "other `$c` failed with no registry error naming $pkgs\n"; exit }
      $any_install = 1; next;
    }
    print "other `$c` failed, which is not an install or type-check step\n"; exit;
  }
  if ($any_install) { print "missing-package install registry has no $install at the awaited version\n" }
  else { print "missing-package types $ts_detail\n" }
  exit;
}
my $testfail = ($t =~ /^[^\n]*Tests:\s+[0-9]+ failed/m) || ($t =~ /^[^\n]*Test Suites:\s+[0-9]+ failed/m) || ($t =~ /^(?:[^\n\t]*\t){0,3}[^\n]*\bFAIL\s+\S+\.(?:[jt]sx?)\b/m);
my $linterr = ($t =~ /✖ [0-9]+ problems? \(([0-9]+) errors?/ && $1 > 0);
if ($testfail) { print "other the failed step reports failing tests\n"; exit }
if ($linterr) { print "other the failed step reports lint errors\n"; exit }
if ($install) { print "missing-package install registry has no $install at the awaited version\n"; exit }
if (@ts) { print "missing-package types $ts_detail\n"; exit }
print "other no registry error naming $pkgs and no TypeScript diagnostic in the failed step\n";
' "$1" "$2"
}

# Test entry: classify a saved log without touching gh or Travis.
if [ "$SUB" = "classify" ]; then
  [ -n "$LOG_FILE" ] && [ -n "$DEP" ] || usage
  classify_log "${KIND:-travis}" "$DEP" < "$LOG_FILE"
  exit 0
fi

case "$SUB" in apply|check|clear) ;; *) usage ;; esac
[ -n "$REPO" ] && [ -n "$PR" ] || usage
command -v gh >/dev/null || { echo "ERROR: gh not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }

# ---- helpers ----------------------------------------------------------------
semver_gt() { # exit 0 when $1 > $2 (numeric x.y.z; a prerelease suffix is ignored)
  local a="${1%%-*}" b="${2%%-*}" i x y
  for i in 1 2 3; do
    x=$(printf '%s' "$a" | cut -d. -f"$i"); y=$(printf '%s' "$b" | cut -d. -f"$i")
    x=${x:-0}; y=${y:-0}
    case "$x$y" in *[!0-9]*) return 1 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# npm_versions <pkg>: the package's published versions as a JSON array; exit 1 when npm cannot say.
npm_versions() {
  local versions
  versions=$("$NPM" view "$1" versions --json 2>/dev/null) || return 1
  [ -n "$versions" ] || return 1
  # A package with one version prints a bare string, not an array.
  jq -c 'if type == "array" then . else [.] end' <<<"$versions" 2>/dev/null || return 1
}
latest_release() { # versions JSON on stdin -> highest plain x.y.z ("" when none)
  jq -r 'map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) | sort_by(split(".") | map(tonumber)) | last // ""'
}
# npm_state <pkg> <ver> [latest-when-applied]: prints published | superseded | unpublished;
# exit 1 when npm cannot say. superseded = the registry's latest is past <ver>, or past the
# latest recorded when the sanction was applied (a publish under another version number).
npm_state() {
  local pkg="$1" ver="$2" base="${3:-}" versions latest
  versions=$(npm_versions "$pkg") || return 1
  if jq -e --arg v "$ver" 'index($v) != null' <<<"$versions" >/dev/null; then echo published; return 0; fi
  latest=$(latest_release <<<"$versions")
  if [ -n "$latest" ] && { semver_gt "$latest" "$ver" || { [ -n "$base" ] && semver_gt "$latest" "$base"; }; }; then
    echo superseded
  else
    echo unpublished
  fi
}

pr_json() { gh pr view "$PR" --repo "$REPO" --json state,body,labels,author 2>/dev/null; }
awaited_from_body() { # body on stdin -> one "<pkg>@<ver> <latest-when-applied or empty>" per line
  grep -oE '^Awaiting publish: [^[:space:]]+@[0-9][^[:space:]]*( \(npm latest when applied: [0-9][^)]*\))?' \
    | sed -E 's/^Awaiting publish: //; s/ \(npm latest when applied: ([^)]*)\)$/ \1/' | sort -u || true
}
write_body() { # $1 = new body file
  gh pr edit "$PR" --repo "$REPO" --body-file "$1" >/dev/null
}
strip_block() { # body on stdin -> body without the sanction block
  perl -0pe 's/\n*<!-- agent-dep-publish:start -->.*?<!-- agent-dep-publish:end -->\n?//s'
}

PRJ=$(pr_json) || { echo "ERROR: cannot read $REPO#$PR" >&2; exit 1; }
[ -n "$PRJ" ] || { echo "ERROR: cannot read $REPO#$PR" >&2; exit 1; }
STATE=$(jq -r '.state' <<<"$PRJ")
BODY=$(jq -r '.body // ""' <<<"$PRJ")
HAS_LABEL=$(jq -r --arg l "$LABEL" 'any(.labels[]?; .name == $l)' <<<"$PRJ")
AWAITED=$(printf '%s\n' "$BODY" | awaited_from_body)

case "$SUB" in
  apply)
    [ -n "$DEP" ] && [ -n "$VERSION" ] || usage
    [ "$STATE" = "OPEN" ] || { echo "ERROR: $REPO#$PR is $STATE, not open" >&2; exit 1; }
    ME=$(gh api user -q .login 2>/dev/null || true)
    AUTHOR=$(jq -r '.author.login // ""' <<<"$PRJ")
    [ -n "$ME" ] && [ "$ME" = "$AUTHOR" ] || { echo "ERROR: $REPO#$PR is authored by ${AUTHOR:-?}, not you; its body is the owner's to edit" >&2; exit 1; }
    if ! gh api "repos/$REPO/labels/$LABEL" >/dev/null 2>&1; then
      echo "NEEDS OPERATOR: label \`$LABEL\` does not exist in $REPO. Creating a label is the operator's call: ask for it, do not create it." >&2
      exit 2
    fi
    NS=$(npm_state "$DEP" "$VERSION") || { echo "ERROR: npm cannot report versions of $DEP" >&2; exit 1; }
    if [ "$NS" != "unpublished" ]; then
      echo "REFUSED: $DEP@$VERSION is $NS on npm, so there is nothing to wait on. Bump the dependency instead." >&2
      exit 3
    fi
    BASE=$(npm_versions "$DEP" | latest_release)
    TMP=$(mktemp /tmp/dep-sanction-body.XXXXXX)
    LINES=$( { printf '%s\n' "$AWAITED" | grep -v -E "^$(printf '%s' "$DEP" | sed 's/[][\\.*^$/]/\\&/g')@" || true; echo "$DEP@$VERSION${BASE:+ $BASE}"; } \
      | grep -v '^$' | sort -u | sed -E 's/^([^ ]+) (.+)$/\1 (npm latest when applied: \2)/; s/^/Awaiting publish: /')
    { printf '%s\n' "$BODY" | strip_block | perl -0pe 's/\s+\z//'; printf '\n\n%s\n%s\n%s\n' "$S_START" "$LINES" "$S_END"; } > "$TMP"
    write_body "$TMP"; rm -f "$TMP"
    gh pr edit "$PR" --repo "$REPO" --add-label "$LABEL" >/dev/null
    echo "APPLIED $REPO#$PR label=$LABEL awaiting=\"$(printf '%s' "$LINES" | sed -E 's/^Awaiting publish: //; s/ \(npm latest.*$//' | paste -sd, - | sed 's/,/, /g')\""
    ;;

  clear)
    TMP=$(mktemp /tmp/dep-sanction-body.XXXXXX)
    if printf '%s' "$BODY" | grep -qF "$S_START"; then
      { printf '%s\n' "$BODY" | strip_block | perl -0pe 's/\s+\z//'; printf '\n'; } > "$TMP"
      write_body "$TMP"
    fi
    rm -f "$TMP"
    [ "$HAS_LABEL" = "true" ] && gh pr edit "$PR" --repo "$REPO" --remove-label "$LABEL" >/dev/null
    echo "CLEARED $REPO#$PR label_was=$HAS_LABEL awaited_was=\"$(printf '%s' "$AWAITED" | sed 's/ .*$//' | paste -sd, - | sed 's/,/, /g')\""
    ;;

  check)
    if [ "$HAS_LABEL" != "true" ]; then echo "SANCTION: none reason=\"label $LABEL is not on the PR\""; exit 5; fi
    if [ -z "$AWAITED" ]; then echo "SANCTION: none reason=\"the PR body has no 'Awaiting publish: <pkg>@<version>' line\""; exit 5; fi
    WAITING="" DONE=""
    while read -r spec base; do
      [ -n "$spec" ] || continue
      NS=$(npm_state "${spec%@*}" "${spec##*@}" "${base:-}") || { echo "ERROR: npm cannot report versions of ${spec%@*}" >&2; exit 1; }
      if [ "$NS" = "unpublished" ]; then WAITING="${WAITING:+$WAITING, }$spec"; else DONE="${DONE:+$DONE, }$spec"; fi
    done <<< "$AWAITED"
    if [ -z "$WAITING" ]; then
      echo "SANCTION: expired published=\"$DONE\""
      echo ">> every awaited dependency is on npm: the CI failure is excused by nothing. Land the bump, rebase, get CI green, then run: dep-publish-sanction.sh clear --repo $REPO --pr $PR" >&2
      exit 3
    fi
    PKGS=$(printf '%s\n' "$AWAITED" | sed 's/ .*$//; s/@[^@]*$//' | paste -sd, -)
    CHECKS=$(gh pr checks "$PR" --repo "$REPO" --json name,bucket,link 2>/dev/null || true)
    [ -n "$CHECKS" ] || CHECKS="[]"
    EXCUSED="" KINDS=""
    while IFS=$'\t' read -r name link; do
      [ -n "$name" ] || continue
      skip=""
      for p in ${IGNORE[@]+"${IGNORE[@]}"}; do case "$name" in "$p"*) skip=1 ;; esac; done
      [ -n "$skip" ] && continue
      verdict=""
      case "$link" in
        *travis-ci.com/*/builds/*)
          build=$(printf '%s' "$link" | sed -E 's#.*/builds/([0-9]+).*#\1#')
          jobs=$(curl -sf --max-time 30 -H "Travis-API-Version: 3" "$TRAVIS_API/build/$build/jobs" 2>/dev/null \
            | jq -r '.jobs[]? | select(.state == "failed" or .state == "errored") | .id' 2>/dev/null || true)
          if [ -z "$jobs" ]; then verdict="other Travis build $build has no failed job this script can read"; fi
          for job in $jobs; do
            log=$(curl -sf --max-time 60 -H "Travis-API-Version: 3" "$TRAVIS_API/job/$job/log.txt" 2>/dev/null || true)
            if [ -z "$log" ]; then verdict="other Travis job $job log is unreadable"; break; fi
            verdict=$(printf '%s' "$log" | classify_log travis "$PKGS")
            case "$verdict" in missing-package*) ;; *) break ;; esac
          done
          ;;
        *github.com/*/actions/runs/*)
          run=$(printf '%s' "$link" | sed -E 's#.*/actions/runs/([0-9]+).*#\1#')
          log=$(gh run view "$run" --repo "$REPO" --log-failed 2>/dev/null || true)
          if [ -z "$log" ]; then verdict="other Actions run $run has no failed-step log"; else verdict=$(printf '%s' "$log" | classify_log actions "$PKGS"); fi
          ;;
        *) verdict="other no CI log to read for this check" ;;
      esac
      case "$verdict" in
        missing-package*)
          EXCUSED="${EXCUSED:+$EXCUSED, }$name"
          k=$(printf '%s' "$verdict" | awk '{print $2}'); case " $KINDS " in *" $k "*) ;; *) KINDS="${KINDS:+$KINDS }$k" ;; esac
          echo ">> $name: ${verdict#missing-package }" >&2
          ;;
        *)
          echo "SANCTION: unconfirmed check=\"$name\" reason=\"${verdict#other }\""
          echo ">> $name is not a missing-package failure, so the sanction does not cover it. Read its log and fix it like any failed check." >&2
          exit 4
          ;;
      esac
    done < <(jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | [.name, (.link // "")] | @tsv' <<<"$CHECKS")
    echo "SANCTION: valid awaiting=\"$WAITING\" excused=\"$EXCUSED\" kind=${KINDS:-none}"
    [ -n "$DONE" ] && echo ">> already on npm: $DONE (still waiting on: $WAITING)" >&2
    exit 0
    ;;
esac
