#!/usr/bin/env bash
# land-overwrite.test.sh: landing and fixup finalizing never replace pushed work.
#
#   pr-land-prepare.sh     stops with status "diverged", before any rewrite,
#                          when the local branch lacks commits the remote
#                          branch has; its own earlier rewrite of the local
#                          branch does not trip the stop on a re-run.
#   pr-finalize-fixups.sh  on a PR someone else owns, pushes the fixups as
#                          committed (no condense); on an owned PR it condenses.
#
# Runs the real scripts against throwaway repos with a bare origin. The
# dependency installer, the verifier, the review-mode lookup and the branch-base
# lookup are stand-ins in a private HOME, so nothing is installed and nothing
# reaches the network.
set -uo pipefail

REAL="$HOME/.cursor/skills"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/land-overwrite-test.XXXXXX")
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
mkdir -p "$SK/pr-land/scripts" "$SK/pr-address/scripts" "$FH/git" "$TMP/state"
cp "$REAL/pr-land/scripts/pr-land-prepare.sh" "$REAL/pr-land/scripts/edge-repo.js" \
   "$REAL/pr-land/scripts/repo-land-lock.sh" "$SK/pr-land/scripts/"
cp "$REAL/pr-finalize-fixups.sh" "$REAL/git-branch-ops.sh" "$SK/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SK/install-deps.sh"
printf 'process.exit(0)\n' > "$SK/verify-repo.sh"
printf '#!/usr/bin/env bash\necho origin/master\n' > "$SK/git-branch-base.sh"
cat > "$SK/pr-address/scripts/pr-address.sh" <<'SH'
#!/usr/bin/env bash
echo "{\"mode\":\"preserve\",\"isOwner\":${FAKE_IS_OWNER:-false},\"latestHumanActivity\":null}"
SH
chmod +x "$SK"/*.sh "$SK"/pr-land/scripts/*.sh "$SK"/pr-address/scripts/*.sh

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset AGENT_TASK_GID AGENT_SESSION_UUID

commit() { # commit <repo> <file> <content> <message...>
  local R="$1" F="$2" C="$3"; shift 3
  printf '%s\n' "$C" >> "$R/$F"
  git -C "$R" add -A && git -C "$R" commit -q "$@"
}

# make_repo <name>: bare origin with master and a feature branch one commit
# ahead, cloned to $FH/git/<name> with feature checked out.
make_repo() {
  local O="$TMP/$1.origin.git" R="$FH/git/$1"
  git init -q --bare -b master "$O"
  git init -q -b master "$R"
  commit "$R" base.txt base -m "Base"
  git -C "$R" remote add origin "$O"
  git -C "$R" push -q origin master
  git -C "$R" checkout -q -b feature
  commit "$R" feature.txt one -m "Add feature"
  git -C "$R" push -q -u origin feature
  git -C "$R" remote set-head origin master
}

# other_push <name> <file> <message>: a second clone pushes a commit to feature.
other_push() {
  local C="$TMP/$1.other.$RANDOM"
  git clone -q -b feature "$TMP/$1.origin.git" "$C"
  commit "$C" "$2" other -m "$3"
  git -C "$C" push -q origin feature
}

# prepare <name>: prints "<exit code> <status of the one branch>".
prepare() {
  local OUT RC
  OUT=$(echo "[{\"repo\":\"$1\",\"branch\":\"feature\"}]" | HOME="$FH" XDG_STATE_HOME="$TMP/state" \
    "$SK/pr-land/scripts/pr-land-prepare.sh" 2>"$TMP/prepare.err")
  RC=$?
  echo "$RC $(printf '%s' "$OUT" | node -e '
    const d = JSON.parse(require("fs").readFileSync(0, "utf8"))
    const all = Object.values(d).filter(Array.isArray).flat()
    process.stdout.write(all.length === 1 ? all[0].status : "entries=" + all.length)' 2>/dev/null)"
}

# 1. Local feature lacks a commit the remote has: stop, nothing rewritten.
make_repo stale
R="$FH/git/stale"
other_push stale theirs.txt "Reviewer change"
commit "$R" local.txt mine -m "Local change"
BEFORE=$(git -C "$R" rev-parse HEAD)
REMOTE_BEFORE=$(git -C "$TMP/stale.origin.git" rev-parse feature)
check "diverged: exit and status" "$(prepare stale)" "1 diverged"
check "diverged: local branch untouched" "$(git -C "$R" rev-parse HEAD)" "$BEFORE"
check "diverged: remote branch untouched" "$(git -C "$TMP/stale.origin.git" rev-parse feature)" "$REMOTE_BEFORE"
check "diverged: message names the reset" \
  "$(grep -c 'git checkout -B feature origin/feature' "$TMP/prepare.err")" 2

# 2. The reset the message names clears it.
git -C "$R" checkout -q -B feature origin/feature
check "after the reset: ready" "$(prepare stale)" "0 ready"

# 3. In sync with a fixup and a moved base: prepare rewrites the local branch,
#    and a re-run (the conflict flow) is not stopped by that rewrite.
make_repo rerun
R="$FH/git/rerun"
commit "$R" feature.txt two -m "fixup! Add feature"
git -C "$R" push -q origin feature
git -C "$R" checkout -q master
commit "$R" base.txt more -m "Base moves"
git -C "$R" push -q origin master
git -C "$R" checkout -q feature
check "in sync: ready" "$(prepare rerun)" "0 ready"
check "in sync: fixup was squashed locally" "$(git -C "$R" rev-list --count origin/master..HEAD)" 1
check "in sync: local no longer contains the remote tip" \
  "$(git -C "$R" merge-base --is-ancestor origin/feature HEAD && echo yes || echo no)" no
check "re-run after prepare's own rewrite: ready" "$(prepare rerun)" "0 ready"

# 4. The remote moves after that prepare: the recorded tip no longer matches.
other_push rerun theirs.txt "Late push"
check "remote moved after prepare: diverged" "$(prepare rerun)" "1 diverged"

# 5. Local is only behind: fast-forwarded, ready.
make_repo behind
other_push behind theirs.txt "Reviewer change"
check "local behind: ready" "$(prepare behind)" "0 ready"
check "local behind: fast-forwarded" \
  "$(git -C "$FH/git/behind" rev-parse HEAD)" "$(git -C "$TMP/behind.origin.git" rev-parse feature)"

# finalize <name> <is-owner>: two same-target, same-kind fixups on top of the
# pushed branch, then pr-finalize-fixups.sh. Prints the JSON line.
finalize() {
  local R="$FH/git/$1"
  make_repo "$1"
  commit "$R" feature.txt two -m "fixup! Add feature" -m "First round" -m "Fixup-for: auto"
  commit "$R" feature.txt three -m "fixup! Add feature" -m "Second round" -m "Fixup-for: auto"
  (cd "$R" && HOME="$FH" FAKE_IS_OWNER="$2" "$SK/pr-finalize-fixups.sh" \
    --owner o --repo r --pr 1 2>"$TMP/finalize.err")
}

OUT=$(finalize unowned false); RC=$?
R="$FH/git/unowned"
check "not the owner: exit code" "$RC" 0
check "not the owner: both fixups reach the remote as committed" \
  "$(git -C "$TMP/unowned.origin.git" log --format=%s master..feature | grep -c '^fixup! ')" 2
check "not the owner: reports nothing condensed" \
  "$(printf '%s' "$OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(d.action+" "+d.condensed)')" "push 0"
check "not the owner: plain push" "$(grep -c 'mode: plain' "$TMP/finalize.err")" 1

OUT=$(finalize owned true); RC=$?
check "owner: exit code" "$RC" 0
check "owner: fixups condensed to one on the remote" \
  "$(git -C "$TMP/owned.origin.git" log --format=%s master..feature | grep -c '^fixup! ')" 1

echo "---"
if [[ $FAILS -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
