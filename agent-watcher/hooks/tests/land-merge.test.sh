#!/usr/bin/env bash
# land-merge.test.sh: the local merge path rebases, verifies, then merges.
#
#   pr-land-merge.sh  rebases the branch onto the moved base and pushes it,
#                     asks GitHub to merge only after verification passed,
#                     skips a PR that is already merged, stops with the rebase
#                     left in progress on a conflict, and takes the repo land
#                     lock for the whole run.
#
# Runs the real script against throwaway repos with a bare origin. The GitHub
# command, the dependency installer, the verifier and the load wait are
# stand-ins in a private HOME, so nothing is installed and nothing reaches the
# network.
#
# A line that starts with "gap" marks behavior this test found and did not
# change: the check prints what the script does and what would be safer, and
# does not fail the file. It turns into an "ok" line once the script is fixed.
set -uo pipefail

REAL="$HOME/.cursor/skills"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/land-merge-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
FAILS=0; GAPS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
gap() { # gap <name> <actual> <safer value>
  if [[ "$2" == "$3" ]]; then ok "$1"; else echo "gap  $1: the script gives '$2', safer is '$3'"; GAPS=$((GAPS + 1)); fi
}

FH="$TMP/home"
SK="$FH/.cursor/skills"
FAKE="$TMP/fake"
mkdir -p "$SK/pr-land/scripts" "$FH/git" "$TMP/state" "$TMP/bin" "$FAKE"
cp "$REAL/pr-land/scripts/pr-land-merge.sh" "$REAL/pr-land/scripts/edge-repo.js" \
   "$REAL/pr-land/scripts/repo-land-lock.sh" "$SK/pr-land/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SK/pr-land/scripts/wait-for-quiet-load.sh"
printf '#!/usr/bin/env bash\nexit "${FAKE_INSTALL_RC:-0}"\n' > "$SK/install-deps.sh"
# The verifier stand-in records the branch tip it was asked to verify.
cat > "$SK/verify-repo.sh" <<'JS'
const { execSync } = require("child_process");
const fs = require("fs");
const tip = execSync("git rev-parse HEAD", { cwd: process.argv[2], encoding: "utf8" }).trim();
fs.appendFileSync(process.env.FAKE + "/verify.log", tip + " " + process.argv.slice(3).join(" ") + "\n");
process.exit(Number(process.env.FAKE_VERIFY_RC || 0));
JS

# Stand-in for the GitHub command. Every call is logged.
#   auth status                      exits FAKE_AUTH_RC
#   api repos/EdgeApp/<r>/pulls/<n>  prints FAKE/pr-<n>.json, or an open PR
#   api .../pulls/<n>/merge -X PUT   saves the request body to
#                                    FAKE/merge-<n>.body and the origin branch
#                                    tips to FAKE/merge-<n>.tips, then prints
#                                    FAKE/mergeresp-<n>.json, or a merged answer
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/gh.log"
if [[ "$1" == auth ]]; then exit "${FAKE_AUTH_RC:-0}"; fi
[[ "$1" == api ]] || exit 1
N=$(echo "$2" | sed -E 's|.*/pulls/([0-9]+).*|\1|')
R=$(echo "$2" | sed -E 's|repos/EdgeApp/([^/]+)/.*|\1|')
case "$2" in
  */merge)
    cat > "$FAKE/merge-$N.body"
    git --git-dir="$ORIGINS/$R.origin.git" for-each-ref --format='%(refname:short) %(objectname)' refs/heads > "$FAKE/merge-$N.tips"
    cat "$FAKE/mergeresp-$N.json" 2>/dev/null || echo '{"merged":true,"sha":"0123456789abcdef"}' ;;
  *) cat "$FAKE/pr-$N.json" 2>/dev/null || echo '{"state":"open","merged":false}' ;;
esac
SH
chmod +x "$SK"/*.sh "$SK"/pr-land/scripts/*.sh "$TMP/bin/gh"

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
  printf '# Changelog\n\n## Unreleased\n\n- added: Base\n' > "$R/CHANGELOG.md"
  commit "$R" base.txt base -m "Base"
  git -C "$R" remote add origin "$O"
  git -C "$R" push -q origin master
  git -C "$R" checkout -q -b feature
  commit "$R" feature.txt one -m "Add feature"
  git -C "$R" push -q -u origin feature
  git -C "$R" remote set-head origin master
}
# base_push <name> <file> <content> <message>: a second clone moves master.
base_push() {
  local C="$TMP/$1.base.$RANDOM"
  git clone -q -b master "$TMP/$1.origin.git" "$C"
  commit "$C" "$2" "$3" -m "$4"
  git -C "$C" push -q origin master
}
# other_push <name> <file> <message>: a second clone pushes a commit to feature.
other_push() {
  local C="$TMP/$1.other.$RANDOM"
  git clone -q -b feature "$TMP/$1.origin.git" "$C"
  commit "$C" "$2" other -m "$3"
  git -C "$C" push -q origin feature
}
origin() { git --git-dir="$TMP/$1.origin.git" rev-parse "$2"; }
# merge <json> [method]: sets OUT (the JSON result) and RC.
merge() {
  local IN="$1"; shift
  : > "$FAKE/gh.log"; : > "$FAKE/verify.log"
  OUT=$(printf '%s' "$IN" | HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" ORIGINS="$TMP" \
    PATH="$TMP/bin:$PATH" "$SK/pr-land/scripts/pr-land-merge.sh" "$@" 2>"$TMP/merge.err")
  RC=$?
}
j() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
one() { echo "[{\"repo\":\"$1\",\"prNumber\":$2,\"branch\":\"feature\"}]"; }
put_calls() { /usr/bin/grep -c -- '-X PUT' "$FAKE/gh.log"; }
locks() { ls "$TMP/state/agent-watcher/land-locks" 2>/dev/null | wc -l | tr -d ' '; }

# --- the base moved: rebase, push, verify, merge ---
make_repo happy
base_push happy other.txt moved "Move the base"
merge "$(one happy 1)"
check "a clean PR: exit code" "$RC" 0
check "a clean PR: status" "$(j .status)" complete
check "a clean PR is reported merged" "$(j '.merged[0].merged')" true
check "one merge request is sent" "$(put_calls)" 1
check "the merge request uses the merge method" "$(jq -r .merge_method "$FAKE/merge-1.body")" merge
check "the merge commit title names the PR and branch" "$(jq -r .commit_title "$FAKE/merge-1.body")" \
  "Merge pull request #1 from EdgeApp/feature"
TIP=$(git -C "$FH/git/happy" rev-parse feature)
check "the pushed branch is the rebased local branch" "$(origin happy feature)" "$TIP"
git --git-dir="$TMP/happy.origin.git" merge-base --is-ancestor master feature \
  && ok "the pushed branch sits on the moved base" || fail "the pushed branch sits on the moved base"
check "verification ran on the rebased tip" "$(cut -d' ' -f1 "$FAKE/verify.log")" "$TIP"
check "the branch was pushed before the merge request" \
  "$(/usr/bin/grep '^feature ' "$FAKE/merge-1.tips" | cut -d' ' -f2)" "$TIP"
check "the land lock is released after the run" "$(locks)" 0

merge "$(one happy 1)" squash
check "the squash method is passed on" "$(jq -r .merge_method "$FAKE/merge-1.body")" squash
check "a squash sends no merge commit title" "$(jq -r '.commit_title // "none"' "$FAKE/merge-1.body")" none

# --- already merged ---
make_repo done
base_push done other.txt moved "Move the base"
echo '{"state":"closed","merged":true}' > "$FAKE/pr-2.json"
BEFORE=$(origin done feature)
merge "$(one done 2)"
check "an already merged PR: exit code" "$RC" 0
check "an already merged PR is listed as merged" "$(j '.merged[0].sha')" already-merged
check "an already merged PR sends no merge request" "$(put_calls)" 0
check "an already merged PR is not pushed" "$(origin done feature)" "$BEFORE"
check "an already merged PR is not verified" "$(wc -l < "$FAKE/verify.log" | tr -d ' ')" 0

# --- verification fails ---
make_repo red
FAKE_VERIFY_RC=1 merge "[{\"repo\":\"red\",\"prNumber\":3,\"branch\":\"feature\"},{\"repo\":\"happy\",\"prNumber\":1,\"branch\":\"feature\"}]"
check "failed verification: exit code" "$RC" 1
check "failed verification: status" "$(j .status)" verification_failed
check "failed verification names the PR" "$(j .verificationFailed.prNumber)" 3
check "failed verification sends no merge request" "$(put_calls)" 0
check "the PRs after a failed one are listed as pending" "$(j '.pending[0].prNumber')" 1
check "the land lock is released after a failed run" "$(locks)" 0

# --- conflicts stop with the rebase left in progress ---
make_repo chlog
commit "$FH/git/chlog" CHANGELOG.md "- added: Ours" -m "Changelog entry"
git -C "$FH/git/chlog" push -q origin feature
base_push chlog CHANGELOG.md "- added: Theirs" "Their entry"
BEFORE=$(origin chlog feature)
merge "[{\"repo\":\"chlog\",\"prNumber\":4,\"branch\":\"feature\"},{\"repo\":\"happy\",\"prNumber\":1,\"branch\":\"feature\"}]"
check "a changelog conflict: exit code" "$RC" 4
check "a changelog conflict: status" "$(j .status)" changelog_conflict_needs_resolution
check "a changelog conflict names the file" "$(j '.changelogConflict.conflictFiles[0]')" CHANGELOG.md
[[ -d "$FH/git/chlog/.git/rebase-merge" ]] && ok "a changelog conflict leaves the rebase in progress" \
  || fail "a changelog conflict leaves the rebase in progress"
check "a changelog conflict pushes nothing" "$(origin chlog feature)" "$BEFORE"
check "a changelog conflict sends no merge request" "$(put_calls)" 0
check "the PRs after a conflict are listed as pending" "$(j '.pending[0].prNumber')" 1

make_repo code
base_push code feature.txt theirs "Their feature"
BEFORE=$(origin code feature)
merge "$(one code 5)"
check "a code conflict: exit code" "$RC" 4
check "a code conflict: status" "$(j .status)" code_conflict_needs_resolution
check "a code conflict names the file" "$(j '.codeConflict.conflictFiles[0]')" feature.txt
[[ -d "$FH/git/code/.git/rebase-merge" ]] && ok "a code conflict leaves the rebase in progress" \
  || fail "a code conflict leaves the rebase in progress"
check "a code conflict pushes nothing" "$(origin code feature)" "$BEFORE"
check "a code conflict sends no merge request" "$(put_calls)" 0

# --- failures that the script lists under "failed" ---
make_repo refused
echo '{"merged":false,"message":"Base branch was modified"}' > "$FAKE/mergeresp-6.json"
merge "$(one refused 6)"
check "a merge GitHub refuses is listed as failed" "$(j '.failed[0].message')" "Base branch was modified"
check "a merge GitHub refuses is not listed as merged" "$(j '.merged | length')" 0
gap "a merge GitHub refuses: exit code" "$RC" 1

make_repo noinstall
BEFORE=$(origin noinstall feature)
base_push noinstall other.txt moved "Move the base"
FAKE_INSTALL_RC=1 merge "$(one noinstall 7)"
check "a failed install is listed as failed" "$(j '.failed | length')" 1
check "a failed install pushes nothing" "$(origin noinstall feature)" "$BEFORE"
check "a failed install sends no merge request" "$(put_calls)" 0
gap "a failed install: exit code" "$RC" 1

# --- a commit someone else pushed to the branch ---
make_repo theirs
other_push theirs theirs.txt "Their pushed commit"
THEIRS=$(origin theirs feature)
base_push theirs other.txt moved "Move the base"
merge "$(one theirs 8)"
if git --git-dir="$TMP/theirs.origin.git" merge-base --is-ancestor "$THEIRS" feature; then KEPT=kept; else KEPT=overwritten; fi
gap "a commit pushed by someone else, missing locally" "$KEPT" kept
gap "a branch that lost a pushed commit is not merged" "$(put_calls)" 0

# --- the land lock, sign-in and usage ---
make_repo busy
XDG_STATE_HOME="$TMP/state" "$SK/pr-land/scripts/repo-land-lock.sh" acquire --repo busy --owner someone-else >/dev/null 2>&1
BEFORE=$(origin busy feature)
base_push busy other.txt moved "Move the base"
merge "$(one busy 9)"
check "a busy land lock: exit code" "$RC" 75
check "a busy land lock pushes nothing" "$(origin busy feature)" "$BEFORE"
check "a busy land lock sends no merge request" "$(put_calls)" 0
check "a busy land lock keeps the other owner's lease" \
  "$(jq -r .owner "$TMP/state/agent-watcher/land-locks/busy.json" 2>/dev/null)" someone-else

OUT=$(one happy 1 | HOME="$FH" FAKE="$FAKE" FAKE_AUTH_RC=1 PATH="$TMP/bin:$PATH" \
  "$SK/pr-land/scripts/pr-land-merge.sh" 2>&1); RC=$?
check "no GitHub sign-in: exit code" "$RC" 2
check "no GitHub sign-in: message" "$OUT" PROMPT_GH_AUTH
merge "$(one happy 1)" fast-forward
check "an unknown merge method: exit code" "$RC" 1

if [[ "$GAPS" -gt 0 ]]; then echo "$GAPS gaps found and left as they are"; fi
if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
