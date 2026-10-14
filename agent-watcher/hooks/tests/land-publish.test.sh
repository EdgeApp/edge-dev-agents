#!/usr/bin/env bash
# land-publish.test.sh: the version bump before an npm publish.
#
#   pr-land-publish.sh  picks a patch or minor bump from the changelog entries
#                       (or the caller's override), verifies first, then writes
#                       the version, the changelog heading and the lockfile
#                       into one commit with a tag, and pushes nothing. A repo
#                       with no unreleased entries is skipped, a failed
#                       verification leaves the repo untouched, and the run
#                       holds the repo land lock.
#
# Runs the real script against throwaway repos with a bare origin. The npm
# command, the package manager wrapper, the dependency installer and the load
# wait are stand-ins, so nothing is installed and nothing reaches the network.
set -uo pipefail

REAL="$HOME/.cursor/skills"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/land-publish-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}

FH="$TMP/home"
SK="$FH/.cursor/skills"
FAKE="$TMP/fake"
mkdir -p "$SK/pr-land/scripts" "$FH/git" "$TMP/state" "$TMP/bin" "$FAKE"
cp "$REAL/pr-land/scripts/pr-land-publish.sh" "$REAL/pr-land/scripts/edge-repo.js" \
   "$REAL/pr-land/scripts/repo-land-lock.sh" "$SK/pr-land/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SK/pr-land/scripts/wait-for-quiet-load.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SK/install-deps.sh"
# The package manager wrapper stand-in logs the script it was asked to run.
cat > "$SK/pm.sh" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$PWD") $*" >> "$FAKE/pm.log"
exit "${FAKE_VERIFY_RC:-0}"
SH
# The npm stand-in: "npm view <name>@<version> version" answers from the list
# in FAKE/published, and "npm install --package-lock-only" copies the version
# from package.json into package-lock.json, as the real command does.
cat > "$TMP/bin/npm" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/npm.log"
case "$1" in
  view)
    /usr/bin/grep -qxF "$2" "$FAKE/published" 2>/dev/null || exit 1
    echo "${2##*@}" ;;
  install)
    V=$(jq -r .version package.json)
    jq --arg v "$V" '.version = $v | .packages[""].version = $v' package-lock.json > package-lock.json.tmp \
      && mv package-lock.json.tmp package-lock.json ;;
  *) exit 1 ;;
esac
SH
chmod +x "$SK"/*.sh "$SK"/pr-land/scripts/*.sh "$TMP/bin/npm"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset AGENT_TASK_GID AGENT_SESSION_UUID

# make_repo <name> <scripts json> <changelog entry line...>: a package at
# version 1.2.3, already published, with the given unreleased entries.
make_repo() {
  local N="$1" SCRIPTS="$2" O="$TMP/$1.origin.git" R="$FH/git/$1"; shift 2
  git init -q --bare -b master "$O"
  git init -q -b master "$R"
  jq -n --arg n "$N" --argjson s "$SCRIPTS" '{name:$n, version:"1.2.3", scripts:$s}' > "$R/package.json"
  { printf '# Changelog\n\n## Unreleased\n\n'; for E in "$@"; do printf '%s\n' "$E"; done
    printf '\n## 1.2.3 (2026-01-01)\n\n- fixed: Older\n'; } > "$R/CHANGELOG.md"
  git -C "$R" add -A && git -C "$R" commit -q -m "Base"
  git -C "$R" remote add origin "$O"
  git -C "$R" push -q -u origin master
  echo "$N@1.2.3" >> "$FAKE/published"
}
origin() { git --git-dir="$TMP/$1.origin.git" rev-parse --verify --quiet "$2" 2>/dev/null; }
# publish <json>: sets OUT (the JSON result) and RC.
publish() {
  : > "$FAKE/pm.log"
  OUT=$(printf '%s' "$1" | HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" PATH="$TMP/bin:$PATH" \
    "$SK/pr-land/scripts/pr-land-publish.sh" 2>"$TMP/publish.err")
  RC=$?
}
j() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
one() { echo "[{\"repo\":\"$1\",\"branch\":\"master\"${2:+,\"bump\":\"$2\"}}]"; }
version() { jq -r .version "$FH/git/$1/package.json"; }
subject() { git -C "$FH/git/$1" log -1 --format=%s; }
locks() { ls "$TMP/state/agent-watcher/land-locks" 2>/dev/null | wc -l | tr -d ' '; }
VERIFY='{"verify":"true"}'

# --- a fix is a patch bump ---
make_repo patch "$VERIFY" "- fixed: A bug"
BEFORE=$(origin patch master)
publish "$(one patch)"
check "a fix: exit code" "$RC" 0
check "a fix is a patch bump" "$(j '.published[0].newVersion')" 1.2.4
check "a fix: the result asks for a push" "$(j '.published[0].needsPush')" true
check "the package version is written" "$(version patch)" 1.2.4
check "the version commit is named for the version" "$(subject patch)" v1.2.4
check "the version commit is tagged" "$(git -C "$FH/git/patch" rev-parse v1.2.4^{commit})" "$(git -C "$FH/git/patch" rev-parse HEAD)"
check "the changelog gets a heading for the version" \
  "$(/usr/bin/grep -c "^## 1.2.4 ($(date -u +%Y-%m-%d))\$" "$FH/git/patch/CHANGELOG.md")" 1
check "the changelog keeps an empty Unreleased heading above it" \
  "$(/usr/bin/grep -n '^## ' "$FH/git/patch/CHANGELOG.md" | head -2 | cut -d: -f2 | tr '\n' '|')" "## Unreleased|## 1.2.4 ($(date -u +%Y-%m-%d))|"
check "the version commit holds the package file and the changelog" \
  "$(git -C "$FH/git/patch" show --name-only --format= HEAD | sort | tr '\n' ' ')" "CHANGELOG.md package.json "
check "nothing is pushed to the branch" "$(origin patch master)" "$BEFORE"
check "the tag is not pushed" "$(origin patch v1.2.4 || echo none)" none
check "verification ran through the verify script" "$(cat "$FAKE/pm.log")" "patch run verify"
check "the land lock is released after the run" "$(locks)" 0

# --- a feature is a minor bump, and the caller can override ---
make_repo minor "$VERIFY" "- fixed: A bug" "- added: A feature"
publish "$(one minor)"
check "a feature is a minor bump" "$(j '.published[0].newVersion')" 1.3.0
make_repo changed "$VERIFY" "- changed: A behavior"
publish "$(one changed)"
check "a behavior change is a minor bump" "$(j '.published[0].newVersion')" 1.3.0
make_repo forcepatch "$VERIFY" "- added: A feature"
publish "$(one forcepatch patch)"
check "the patch override wins over a feature entry" "$(j '.published[0].newVersion')" 1.2.4
make_repo forceminor "$VERIFY" "- fixed: A bug"
publish "$(one forceminor minor)"
check "the minor override wins over a fix entry" "$(j '.published[0].newVersion')" 1.3.0

# --- which verification scripts run ---
make_repo twoscripts '{"tsc":"true","lint":"true"}' "- fixed: A bug"
publish "$(one twoscripts)"
check "without a verify script, the type check and the lint run" \
  "$(tr '\n' '|' < "$FAKE/pm.log")" "twoscripts run tsc|twoscripts run lint|"
make_repo noscripts '{}' "- fixed: A bug"
publish "$(one noscripts)"
check "a repo with no check scripts still bumps" "$(j '.published[0].newVersion')" 1.2.4
check "a repo with no check scripts runs none" "$(wc -l < "$FAKE/pm.log" | tr -d ' ')" 0

# --- the npm lockfile follows the version ---
make_repo locked "$VERIFY" "- fixed: A bug"
jq -n '{name:"locked", version:"1.2.3", packages:{"":{version:"1.2.3"}}}' > "$FH/git/locked/package-lock.json"
git -C "$FH/git/locked" add -A && git -C "$FH/git/locked" commit -q -m "Lockfile" && git -C "$FH/git/locked" push -q origin master
publish "$(one locked)"
check "the lockfile's version is updated" "$(jq -r '.packages[""].version' "$FH/git/locked/package-lock.json")" 1.2.4
check "the lockfile is in the version commit" \
  "$(git -C "$FH/git/locked" show --name-only --format= HEAD | sort | tr '\n' ' ')" "CHANGELOG.md package-lock.json package.json "
check "the checkout is clean after the bump" "$(git -C "$FH/git/locked" status --porcelain | wc -l | tr -d ' ')" 0

# --- nothing to release ---
make_repo empty "$VERIFY"
BEFORE=$(git -C "$FH/git/empty" rev-parse HEAD)
publish "$(one empty)"
check "no unreleased entries: exit code" "$RC" 0
check "no unreleased entries: the repo is skipped" "$(j '.skipped[0].repo')" empty
check "no unreleased entries: nothing is committed" "$(git -C "$FH/git/empty" rev-parse HEAD)" "$BEFORE"
check "no unreleased entries: nothing is verified" "$(wc -l < "$FAKE/pm.log" | tr -d ' ')" 0

make_repo badentry "$VERIFY" "- Fixed a bug with no tag"
BEFORE=$(git -C "$FH/git/badentry" rev-parse HEAD)
publish "$(one badentry)"
check "an entry with no type tag: nothing is committed" "$(git -C "$FH/git/badentry" rev-parse HEAD)" "$BEFORE"
check "an entry with no type tag: the result quotes the entry" "$(j '.failed[0].error')" \
  "Changelog entry has no type tag (added, changed, deprecated, removed, fixed or security): - Fixed a bug with no tag"
check "an entry with no type tag: exit code" "$RC" 1
check "an entry with no type tag: nothing is verified" "$(wc -l < "$FAKE/pm.log" | tr -d ' ')" 0

# --- verification fails ---
make_repo red "$VERIFY" "- fixed: A bug"
BEFORE=$(git -C "$FH/git/red" rev-parse HEAD)
FAKE_VERIFY_RC=1 publish "[{\"repo\":\"red\",\"branch\":\"master\"},{\"repo\":\"patch\",\"branch\":\"master\"}]"
check "failed verification: exit code" "$RC" 1
check "failed verification: the repo is listed as failed" "$(j '.failed[0].error')" "Verification failed"
check "failed verification: the version is not written" "$(version red)" 1.2.3
check "failed verification: nothing is committed" "$(git -C "$FH/git/red" rev-parse HEAD)" "$BEFORE"
check "failed verification: no tag is made" "$(git -C "$FH/git/red" tag | wc -l | tr -d ' ')" 0
check "failed verification: the checkout is clean" "$(git -C "$FH/git/red" status --porcelain | wc -l | tr -d ' ')" 0

# --- a second run after the first ---
# The first run left the bump as a local commit and tag, not pushed.
make_repo again "$VERIFY" "- fixed: A bug"
publish "$(one again)"
FIRST=$(git -C "$FH/git/again" rev-parse HEAD)
publish "$(one again)"
check "a second run before the push: exit code" "$RC" 0
check "a second run before the push reports the same version" "$(j '.published[0].newVersion // "none"')" 1.2.4
check "a second run before the push keeps the first bump" "$(git -C "$FH/git/again" rev-parse HEAD)" "$FIRST"
check "a second run before the push asks for a push" "$(j '.published[0].needsPush')" true
check "a second run before the push says it resumed" "$(j '.published[0].resumed')" true
check "a second run before the push verifies nothing" "$(wc -l < "$FAKE/pm.log" | tr -d ' ')" 0
# The same, with the tag gone (develop-staging deletes unpushed tags first).
git -C "$FH/git/again" tag -d v1.2.4 >/dev/null
publish "$(one again)"
check "a second run with the tag gone: the tag is made again" "$(git -C "$FH/git/again" rev-parse v1.2.4 2>/dev/null)" "$FIRST"
# A local commit that is not a version commit is still reset away.
make_repo stray "$VERIFY" "- fixed: A bug"
commit_stray() { printf 'x\n' >> "$FH/git/stray/stray.txt"; git -C "$FH/git/stray" add -A; git -C "$FH/git/stray" commit -q -m "Stray"; }
commit_stray
publish "$(one stray)"
check "a stray local commit is reset away and the bump made" "$(git -C "$FH/git/stray" log -1 --format=%s HEAD~1)" Base

# The bump is pushed and the package is not on npm yet.
make_repo pushed "$VERIFY" "- fixed: A bug"
publish "$(one pushed)"
git -C "$FH/git/pushed" push -q origin master
HEAD_BEFORE=$(git -C "$FH/git/pushed" rev-parse HEAD)
publish "$(one pushed)"
check "pushed without its tag: no second bump" "$(git -C "$FH/git/pushed" rev-parse HEAD)" "$HEAD_BEFORE"
check "pushed without its tag: the version is reported" "$(j '.published[0].newVersion')" 1.2.4
check "pushed without its tag: the result asks for a push" "$(j '.published[0].needsPush')" true
git -C "$FH/git/pushed" push -q origin v1.2.4
publish "$(one pushed)"
check "pushed with its tag: the result asks for no push" "$(j '.published[0].needsPush')" false
check "pushed with its tag: nothing is verified again" "$(wc -l < "$FAKE/pm.log" | tr -d ' ')" 0

# --- the land lock ---
make_repo busy "$VERIFY" "- fixed: A bug"
XDG_STATE_HOME="$TMP/state" "$SK/pr-land/scripts/repo-land-lock.sh" acquire --repo busy --owner someone-else >/dev/null 2>&1
publish "$(one busy)"
check "a busy land lock: exit code" "$RC" 75
check "a busy land lock: the version is not written" "$(version busy)" 1.2.3
check "a busy land lock keeps the other owner's lease" \
  "$(jq -r .owner "$TMP/state/agent-watcher/land-locks/busy.json" 2>/dev/null)" someone-else

if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
