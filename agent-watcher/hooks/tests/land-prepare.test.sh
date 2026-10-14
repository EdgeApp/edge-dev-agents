#!/usr/bin/env bash
# land-prepare.test.sh: every result the prepare step can give, bar "diverged".
#
#   pr-land-prepare.sh  squashes fixup commits, rebases onto the moved base and
#                       verifies, without pushing. A conflict stops with the
#                       rebase left in progress. A failed install, a failed
#                       verification, a fixup that cannot be squashed, a branch
#                       held by a worktree with unsaved work and a base marked
#                       unbuildable each give their own status. Unsaved work in
#                       the checkout is stashed and named in the result. The
#                       land lock is kept for a branch that goes on to the push
#                       and released for one that does not.
#
# The "diverged" status has its own file, land-overwrite.test.sh.
#
# Runs the real script against throwaway repos with a bare origin. The
# dependency installer, the verifier, the load wait and the base-buildable
# check are stand-ins in a private HOME, so nothing is installed and nothing
# reaches the network. The one clone the script attempts is pointed at a
# transport that fails at once.
set -uo pipefail

REAL="$HOME/.cursor/skills"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/land-prepare-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
has() { # has <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1: '$3' not in '$2'"; fi
}

FH="$TMP/home"
SK="$FH/.cursor/skills"
CFG="$FH/.config/agent-watcher"
FAKE="$TMP/fake"
mkdir -p "$SK/pr-land/scripts" "$CFG" "$FH/git" "$TMP/state" "$FAKE"
cp "$REAL/pr-land/scripts/pr-land-prepare.sh" "$REAL/pr-land/scripts/edge-repo.js" \
   "$REAL/pr-land/scripts/repo-land-lock.sh" "$SK/pr-land/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SK/pr-land/scripts/wait-for-quiet-load.sh"
printf '#!/usr/bin/env bash\nexit "${FAKE_INSTALL_RC:-0}"\n' > "$SK/install-deps.sh"
printf '#!/usr/bin/env bash\necho "base marked unbuildable" >&2\nexit "${FAKE_BASE_RC:-0}"\n' > "$CFG/develop-buildable.sh"
# The verifier stand-in records its arguments, and on a failure names a step
# in the result file the way the real verifier does.
cat > "$SK/verify-repo.sh" <<'JS'
const fs = require("fs");
const args = process.argv.slice(3);
fs.appendFileSync(process.env.FAKE + "/verify.log", args.filter((a) => !a.includes("verify-result-")).join(" ") + "\n");
const rc = Number(process.env.FAKE_VERIFY_RC || 0);
if (rc !== 0) fs.writeFileSync(args[args.indexOf("--result-json") + 1], JSON.stringify({ failedStep: "lint" }));
process.exit(rc);
JS
chmod +x "$SK"/*.sh "$SK"/pr-land/scripts/*.sh "$CFG"/*.sh

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset AGENT_TASK_GID AGENT_SESSION_UUID
OWNER="op-${USER:-shell}"

commit() { # commit <repo> <file> <content> <message...>
  local R="$1" F="$2" C="$3"; shift 3
  printf '%s\n' "$C" >> "$R/$F"
  git -C "$R" add -A && git -C "$R" commit -q "$@"
}
# entry <repo dir> <heading> <entry>: put a changelog entry under a heading.
entry() {
  awk -v h="$2" -v e="$3" '{print} $0==h{print ""; print e; skip=1; next} ' "$1/CHANGELOG.md" > "$1/CHANGELOG.md.new"
  mv "$1/CHANGELOG.md.new" "$1/CHANGELOG.md"
}
# make_repo <name>: bare origin with master and a feature branch one commit
# ahead (a code file and a changelog entry), cloned to $FH/git/<name> with
# feature checked out.
make_repo() {
  local O="$TMP/$1.origin.git" R="$FH/git/$1"
  git init -q --bare -b master "$O"
  git init -q -b master "$R"
  printf '# Changelog\n\n## Unreleased\n\n## 4.5.0 (staging)\n\n- fixed: Staged\n\n## 4.4.0 (2026-01-01)\n\n- fixed: Older\n' > "$R/CHANGELOG.md"
  commit "$R" base.txt base -m "Base"
  git -C "$R" remote add origin "$O"
  git -C "$R" push -q origin master
  git -C "$R" checkout -q -b feature
  entry "$R" "${2:-## Unreleased}" "- added: Feature"
  commit "$R" feature.txt one -m "Add feature"
  git -C "$R" push -q -u origin feature
  git -C "$R" remote set-head origin master
}
# base_push <name> <file> <content> <message>: a second clone moves master.
base_push() {
  local C="$TMP/$1.base.$RANDOM"
  git clone -q -b master "$TMP/$1.origin.git" "$C"
  if [[ "$2" == CHANGELOG.md ]]; then
    entry "$C" "## Unreleased" "$3"; git -C "$C" add -A; git -C "$C" commit -q -m "$4"
  else
    commit "$C" "$2" "$3" -m "$4"
  fi
  git -C "$C" push -q origin master
}
origin() { git --git-dir="$TMP/$1.origin.git" rev-parse "$2"; }
# prepare <json> [flags...]: sets OUT (the JSON result) and RC.
prepare() {
  local IN="$1"; shift
  : > "$FAKE/verify.log"
  OUT=$(printf '%s' "$IN" | HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" GIT_SSH_COMMAND=false \
    "$SK/pr-land/scripts/pr-land-prepare.sh" "$@" 2>"$TMP/prepare.err")
  RC=$?
}
j() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
one() { echo "[{\"repo\":\"$1\",\"branch\":\"feature\"${2:+,\"buildField\":\"$2\"}}]"; }
lease() { jq -r '.owner // "none"' "$TMP/state/agent-watcher/land-locks/$1.json" 2>/dev/null || echo none; }
in_rebase() { [[ -d "$FH/git/$1/.git/rebase-merge" || -d "$FH/git/$1/.git/rebase-apply" ]] && echo yes || echo no; }

# --- ready: fixups squashed, rebased onto the moved base, verified, not pushed ---
make_repo ready
commit "$FH/git/ready" feature.txt two -m "fixup! Add feature"
git -C "$FH/git/ready" push -q origin feature
PUSHED=$(origin ready feature)
base_push ready other.txt moved "Move the base"
prepare "$(one ready)"
R="$FH/git/ready"
check "a clean branch: exit code" "$RC" 0
check "a clean branch: status" "$(j '.prepared[0].status')" ready
check "the fixup commit is squashed" "$(git -C "$R" rev-list --count origin/master..feature)" 1
check "the squashed commit keeps the fixup's change" "$(tr '\n' ' ' < "$R/feature.txt")" "one two "
git -C "$R" merge-base --is-ancestor origin/master feature \
  && ok "the branch sits on the moved base" || fail "the branch sits on the moved base"
check "nothing is pushed" "$(origin ready feature)" "$PUSHED"
check "verification ran against the base, with the changelog required" "$(cat "$FAKE/verify.log")" \
  "--base origin/master --require-changelog --skip-install --result-json"
check "the new entry's section is reported" "$(j '.prepared[0].newEntrySections[0]')" Unreleased
check "a well placed entry gives no placement warning" "$(j '.prepared[0].placementWarnings // [] | length')" 0
check "a ready branch keeps the land lock for the push" "$(lease ready)" "$OWNER"

# --- changelog placement warnings ---
make_repo released "## 4.4.0 (2026-01-01)"
prepare "$(one released)"
check "an entry under a released version: status" "$(j '.prepared[0].status')" ready
check "an entry under a released version is warned about" "$(j '.prepared[0].placementWarnings[0].reason')" released-section
check "the warning names the section" "$(j '.prepared[0].placementWarnings[0].section')" "4.4.0 (2026-01-01)"
make_repo stagingtask
prepare "$(one stagingtask staging)"
check "a staging task's entry under Unreleased is warned about" \
  "$(j '.prepared[0].placementWarnings[0].reason')" staging-task-under-unreleased
make_repo stagingok "## 4.5.0 (staging)"
prepare "$(one stagingok staging)"
check "a staging task's entry under the staging section is not warned about" \
  "$(j '.prepared[0].placementWarnings // [] | length')" 0
check "the staging section is reported" "$(j '.prepared[0].newEntrySections[0]')" "4.5.0 (staging)"

# --- conflicts stop with the rebase left in progress ---
make_repo chlog
base_push chlog CHANGELOG.md "- fixed: Theirs" "Their entry"
prepare "$(one chlog)"
check "a changelog conflict: exit code" "$RC" 0
check "a changelog conflict: status" "$(j '.changelogConflicts[0].status')" changelog_conflict
check "a changelog conflict names the file" "$(j '.changelogConflicts[0].conflictFiles[0]')" CHANGELOG.md
check "a changelog conflict leaves the rebase in progress" "$(in_rebase chlog)" yes
check "a changelog conflict is not verified" "$(wc -l < "$FAKE/verify.log" | tr -d ' ')" 0
check "a changelog conflict keeps the land lock" "$(lease chlog)" "$OWNER"

make_repo code
base_push code feature.txt theirs "Their feature"
prepare "$(one code)"
check "a code conflict: exit code" "$RC" 0
check "a code conflict: status" "$(j '.codeConflicts[0].status')" code_conflict
check "a code conflict names the file" "$(j '.codeConflicts[0].conflictFiles | index("feature.txt") != null')" true
check "a code conflict leaves the rebase in progress" "$(in_rebase code)" yes
check "a code conflict keeps the land lock" "$(lease code)" "$OWNER"

# --- failures ---
make_repo red
FAKE_VERIFY_RC=1 prepare "$(one red)"
check "failed verification: exit code" "$RC" 1
check "failed verification: status" "$(j '.failed[0].status')" verification_failed
check "failed verification passes the failed step on" "$(j '.failed[0].failedStep')" lint
check "failed verification releases the land lock" "$(lease red)" none

make_repo noinstall
FAKE_INSTALL_RC=1 prepare "$(one noinstall)"
check "a failed install: exit code" "$RC" 1
check "a failed install: status" "$(j '.failed[0].status')" install_failed
check "a failed install is not verified" "$(wc -l < "$FAKE/verify.log" | tr -d ' ')" 0
check "a failed install releases the land lock" "$(lease noinstall)" none

# a fixup that cannot be moved next to its target
make_repo badfixup
R="$FH/git/badfixup"
printf 'changed\n' > "$R/feature.txt"; git -C "$R" commit -q -am "Change the feature"
printf 'changed again\n' > "$R/feature.txt"; git -C "$R" commit -q -am "fixup! Add feature"
TIP=$(git -C "$R" rev-parse feature)
prepare "$(one badfixup)"
check "a fixup that cannot be squashed: exit code" "$RC" 1
check "a fixup that cannot be squashed: status" "$(j '.failed[0].status')" autosquash_failed
check "a fixup that cannot be squashed leaves no rebase in progress" "$(in_rebase badfixup)" no
check "a fixup that cannot be squashed leaves the branch as it was" "$(git -C "$R" rev-parse feature)" "$TIP"

prepare '[{"repo":"no-such-repo","branch":"feature"}]'
check "a repo that cannot be cloned: exit code" "$RC" 1
check "a repo that cannot be cloned: status" "$(j '.failed[0].status')" clone_failed

# --- the base is marked unbuildable ---
make_repo broken
git -C "$FH/git/broken" checkout -q master
FAKE_BASE_RC=3 prepare "$(one broken)"
check "an unbuildable base: exit code" "$RC" 3
check "an unbuildable base: status" "$(j '.baseUnbuildable[0].status')" base_unbuildable
check "an unbuildable base leaves the checkout where it was" "$(git -C "$FH/git/broken" rev-parse --abbrev-ref HEAD)" master
check "an unbuildable base releases the land lock" "$(lease broken)" none
FAKE_BASE_RC=3 prepare "$(one broken)" --allow-broken-develop
check "the operator flag lands onto an unbuildable base" "$(j '.prepared[0].status')" ready
FAKE_BASE_RC=3 prepare "[{\"repo\":\"broken\",\"branch\":\"feature\"},{\"repo\":\"red\",\"branch\":\"feature\"}]"
check "a batch that is all refused or unbuildable exits 3" "$RC" 3

# --- a branch held by another worktree ---
make_repo held
git -C "$FH/git/held" checkout -q master
git -C "$FH/git/held" worktree add -q "$TMP/held.wt" feature
echo unsaved >> "$TMP/held.wt/feature.txt"
prepare "$(one held)"
check "a worktree with unsaved work: exit code" "$RC" 1
check "a worktree with unsaved work: status" "$(j '.failed[0].status')" checkout_failed
has "a worktree with unsaved work: the message names it" "$(j '.failed[0].message')" "DIRTY worktree"
check "a worktree with unsaved work keeps its branch" "$(git -C "$TMP/held.wt" rev-parse --abbrev-ref HEAD)" feature
check "a worktree with unsaved work keeps the work" "$(tail -1 "$TMP/held.wt/feature.txt")" unsaved
git -C "$TMP/held.wt" checkout -q -- feature.txt
prepare "$(one held)"
check "a clean worktree: status" "$(j '.prepared[0].status')" ready
check "a clean worktree is detached to free the branch" "$(git -C "$TMP/held.wt" rev-parse --abbrev-ref HEAD)" HEAD
check "a clean worktree: the checkout holds the branch" "$(git -C "$FH/git/held" rev-parse --abbrev-ref HEAD)" feature

# --- unsaved work in the checkout is stashed ---
make_repo dirty
git -C "$FH/git/dirty" checkout -q master
echo scratch >> "$FH/git/dirty/base.txt"; echo new > "$FH/git/dirty/untracked.txt"
prepare "$(one dirty)"
check "unsaved work in the checkout: status" "$(j '.prepared[0].status')" ready
has "unsaved work in the checkout is named in the result" "$(j '.prepared[0].autostash')" "pr-land-autostash"
has "the stash records the branch the checkout was on" "$(j '.prepared[0].autostash')" "(was on master)"
check "the stash exists" "$(git -C "$FH/git/dirty" stash list | /usr/bin/grep -c pr-land-autostash)" 1
check "the stash holds the untracked file" \
  "$(git -C "$FH/git/dirty" show --name-only --format= 'stash@{0}^3' 2>/dev/null | tr -d '\n')" untracked.txt
check "the checkout is clean after the run" "$(git -C "$FH/git/dirty" status --porcelain | wc -l | tr -d ' ')" 0

# --- a batch ---
make_repo batchok
prepare "[{\"repo\":\"batchok\",\"branch\":\"feature\"},{\"repo\":\"no-such-repo\",\"branch\":\"feature\"}]"
check "one ready and one failed: both are reported" "$(j '(.prepared | length) + (.failed | length)')" 2
check "one ready and one failed: exit code" "$RC" 1
check "the ready repo of a mixed batch keeps its land lock" "$(lease batchok)" "$OWNER"
check "the failed repo of a mixed batch releases its land lock" "$(lease no-such-repo)" none

# --- the land lock and the build refresher ---
make_repo busy
XDG_STATE_HOME="$TMP/state" "$SK/pr-land/scripts/repo-land-lock.sh" acquire --repo busy --owner someone-else >/dev/null 2>&1
TIP=$(git -C "$FH/git/busy" rev-parse feature)
prepare "[{\"repo\":\"batchok\",\"branch\":\"feature\"},{\"repo\":\"red\",\"branch\":\"feature\"},{\"repo\":\"busy\",\"branch\":\"feature\"}]"
check "a busy land lock: exit code" "$RC" 75
check "a busy land lock leaves the branch alone" "$(git -C "$FH/git/busy" rev-parse feature)" "$TIP"
check "a busy land lock keeps the other owner's lease" "$(lease busy)" someone-else
check "a busy exit releases the lease it took in this call" "$(lease red)" none
check "a busy exit keeps a lease held from an earlier call" "$(lease batchok)" "$OWNER"

make_repo building
echo "$$ $FH/git/building" > "$CFG/master-build.lock"
prepare "$(one building)"
check "a running build refresh in the checkout: exit code" "$RC" 75
check "a running build refresh releases the lease it took" "$(lease building)" none
echo "999999 $FH/git/building" > "$CFG/master-build.lock"
prepare "$(one building)"
check "a build lock left by a dead process does not block" "$(j '.prepared[0].status')" ready
echo "$$ $FH/git/some-other-repo" > "$CFG/master-build.lock"
make_repo elsewhere
prepare "$(one elsewhere)"
check "a build refresh in another checkout does not block" "$(j '.prepared[0].status')" ready
rm -f "$CFG/master-build.lock"

if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
