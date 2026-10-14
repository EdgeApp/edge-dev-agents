#!/usr/bin/env bash
# branch-ops-basics.test.sh: the three plain commands of the shared branch
# library, which the fixup and self-rewrite tests do not reach.
#
#   git-branch-ops.sh autosquash  squashes every fixup commit above the base,
#                                 with the base given outright, worked out
#                                 from a named ref, or defaulted
#   git-branch-ops.sh push        a plain push, or one that overwrites the
#                                 remote only when the remote still holds what
#                                 this checkout last saw
#   git-branch-ops.sh note-scope  prints what an operator's rewrite approval
#                                 note covers, and exits 1 when there is none
#
# The library's other commands are covered by fixup-discipline.test.py and
# self-rewrite-gate.test.py.
#
# Runs the real script against throwaway repos with a bare origin, in a
# private HOME, so the default base falls back to origin/master and nothing
# reaches the network.
set -uo pipefail

OPS="$HOME/.cursor/skills/git-branch-ops.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/branch-ops-basics-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
GID="branch-ops-basics-test-$$"
trap 'rm -rf "$TMP" "/tmp/agent-history-rewrite-approved-$GID.md"' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
has() { # has <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1: '$3' not in '$2'"; fi
}
# gap <name> <actual> <wanted>: a known shortfall. Printed, never a failure;
# it turns into an ok line once the script is fixed.
gap() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else echo "gap  $1: got '$2', want '$3'"; fi
}

FH="$TMP/home"
mkdir -p "$FH"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset AGENT_TASK_GID

commit() { # commit <repo> <file> <content> <message>
  printf '%s\n' "$3" >> "$1/$2"
  git -C "$1" add -A && git -C "$1" commit -q -m "$4"
}
# make_repo <name>: bare origin with master, cloned to $TMP/<name> with a
# pushed feature branch that carries two commits and a fixup for each.
make_repo() {
  local O="$TMP/$1.origin.git" R="$TMP/$1"
  git init -q --bare -b master "$O"
  git init -q -b master "$R"
  commit "$R" base.txt base "Base"
  git -C "$R" remote add origin "$O"
  git -C "$R" push -q origin master
  git -C "$R" checkout -q -b feature
  commit "$R" a.txt one "Add a"
  commit "$R" b.txt one "Add b"
  commit "$R" a.txt two "fixup! Add a"
  commit "$R" b.txt two "fixup! Add b"
  git -C "$R" push -q -u origin feature
}
# ops <repo> <args...>: sets OUT (stdout), ERR (stderr) and RC.
ops() {
  local R="$TMP/$1"; shift
  OUT=$(cd "$R" && HOME="$FH" "$OPS" "$@" 2>"$TMP/err")
  RC=$?
  ERR=$(cat "$TMP/err")
}
count() { git -C "$TMP/$1" rev-list --count "$2"; }
origin() { git --git-dir="$TMP/$1.origin.git" rev-parse "$2"; }
tip() { git -C "$TMP/$1" rev-parse "$2"; }
in_rebase() { [[ -d "$TMP/$1/.git/rebase-merge" || -d "$TMP/$1/.git/rebase-apply" ]] && echo yes || echo no; }
# other_push <name> <file> <message>: a second clone adds a commit to feature.
other_push() {
  local C="$TMP/$1.other.$RANDOM"
  git clone -q -b feature "$TMP/$1.origin.git" "$C"
  commit "$C" "$2" theirs "$3"
  git -C "$C" push -q origin feature
}

# --- autosquash ---
make_repo defbase
ops defbase autosquash
check "autosquash with no base given: exit code" "$RC" 0
check "every fixup is squashed" "$(count defbase origin/master..feature)" 2
check "the squashed commits keep the fixups' changes" \
  "$(cat "$TMP/defbase/a.txt" "$TMP/defbase/b.txt" | tr '\n' ' ')" "one two one two "
has "the default base is the fork point from origin/master" "$OUT" "base: $(tip defbase origin/master)"
check "autosquash pushes nothing" "$(git --git-dir="$TMP/defbase.origin.git" rev-list --count master..feature)" 4

make_repo named
git -C "$TMP/named" branch -q mark origin/master
ops named autosquash --merge-base-with mark
check "autosquash from a named ref: exit code" "$RC" 0
check "autosquash from a named ref squashes every fixup" "$(count named mark..feature)" 2

make_repo outright
ops outright autosquash --base "$(tip outright 'feature~3')"
check "autosquash with the base given outright: exit code" "$RC" 0
check "a fixup whose target sits below the base stays a commit" \
  "$(git -C "$TMP/outright" log --format=%s origin/master..feature | /usr/bin/grep -c '^fixup! Add a$')" 1
check "a fixup whose target sits above the base is squashed" \
  "$(git -C "$TMP/outright" log --format=%s origin/master..feature | /usr/bin/grep -c '^fixup! Add b$')" 0

make_repo both
TIP=$(tip both feature)
ops both autosquash --base origin/master --merge-base-with origin/master
check "both base flags together: exit code" "$RC" 1
has "both base flags together: the message says so" "$ERR" "not both"
check "both base flags together leave the branch alone" "$(tip both feature)" "$TIP"

ops both autosquash --merge-base-with no-such-ref
check "a ref that does not exist: exit code" "$RC" 1
has "a ref that does not exist: the message names it" "$ERR" "no-such-ref"

# a fixup that cannot be moved next to its target
make_repo clash
R="$TMP/clash"
printf 'rewritten\n' > "$R/a.txt"; git -C "$R" commit -q -am "Rewrite a"
printf 'rewritten again\n' > "$R/a.txt"; git -C "$R" commit -q -am "fixup! Add a"
TIP=$(tip clash feature)
ops clash autosquash
[[ "$RC" -ne 0 ]] && ok "a fixup that cannot be squashed exits non-zero" \
  || fail "a fixup that cannot be squashed exits non-zero: got 0"
gap "a fixup that cannot be squashed leaves no rebase in progress" "$(in_rebase clash)" no
git -C "$R" rebase --abort >/dev/null 2>&1
check "aborting the rebase puts the branch back" "$(tip clash feature)" "$TIP"

# --- push ---
make_repo plain
commit "$TMP/plain" c.txt one "Add c"
ops plain push
check "a plain push: exit code" "$RC" 0
check "a plain push defaults to the checked-out branch" "$(origin plain feature)" "$(tip plain feature)"
has "a plain push says which mode it used" "$OUT" "origin/feature, mode: plain"

git -C "$TMP/plain" branch -q side feature
commit "$TMP/plain" c.txt two "More c"
git -C "$TMP/plain" branch -q -f side feature
git -C "$TMP/plain" reset -q --hard HEAD~1
ops plain push --branch side
check "a named branch is pushed in place of the checked-out one" "$(origin plain side)" "$(tip plain side)"
[[ "$(origin plain feature)" != "$(tip plain side)" ]] \
  && ok "pushing a named branch leaves the checked-out branch's remote alone" \
  || fail "pushing a named branch leaves the checked-out branch's remote alone"

git init -q --bare -b master "$TMP/second.git"
git -C "$TMP/plain" remote add second "$TMP/second.git"
ops plain push --remote second
check "a named remote receives the push" \
  "$(git --git-dir="$TMP/second.git" rev-parse feature)" "$(tip plain feature)"

make_repo rewritten
ops rewritten autosquash
BEFORE=$(origin rewritten feature)
ops rewritten push
[[ "$RC" -ne 0 ]] && ok "a plain push of a rewritten branch is refused" \
  || fail "a plain push of a rewritten branch is refused: got 0"
check "the refused push leaves the remote alone" "$(origin rewritten feature)" "$BEFORE"
ops rewritten push --force-with-lease
check "the overwriting push of a rewritten branch: exit code" "$RC" 0
check "the overwriting push lands the rewritten branch" "$(origin rewritten feature)" "$(tip rewritten feature)"
has "the overwriting push says which mode it used" "$OUT" "mode: force-with-lease"

make_repo moved
ops moved autosquash
other_push moved theirs.txt "Their commit"
THEIRS=$(origin moved feature)
ops moved push --force-with-lease
[[ "$RC" -ne 0 ]] && ok "the overwriting push is refused when someone else pushed" \
  || fail "the overwriting push is refused when someone else pushed: got 0"
check "the refused overwrite keeps the other person's commit" "$(origin moved feature)" "$THEIRS"
# Once the checkout has fetched, the lease compares against the fresh ref and
# no longer protects the other commit. The scripts that fetch before this push
# need their own check; pr-land-prepare.sh has one (land-overwrite.test.sh).
git -C "$TMP/moved" fetch -q origin
ops moved push --force-with-lease
check "after a fetch the same push overwrites the other person's commit" \
  "$(git --git-dir="$TMP/moved.origin.git" merge-base --is-ancestor "$THEIRS" feature && echo kept || echo overwritten)" overwritten

make_repo detached
git -C "$TMP/detached" checkout -q --detach
ops detached push
check "a push with no branch checked out and none named: exit code" "$RC" 1
has "a push with no branch: the message says so" "$ERR" "Could not determine current branch"

# --- note-scope ---
NOTE="$TMP/note.md"
ops plain note-scope --note "$TMP/absent.md"
check "no note: exit code" "$RC" 1
check "no note: prints nothing" "$OUT" ""
: > "$NOTE"
ops plain note-scope --note "$NOTE"
check "an empty note: exit code" "$RC" 1
printf 'Approved by the operator in a task comment.\n' > "$NOTE"
ops plain note-scope --note "$NOTE"
check "a note with no scope line: exit code" "$RC" 0
check "a note with no scope line: prints nothing" "$OUT" ""
printf 'Approved.\nTargets: ABC1234, def5678\n' > "$NOTE"
ops plain note-scope --note "$NOTE"
check "a note naming two commits: exit code" "$RC" 0
check "the commits come out one per line, lowercased" "$(printf '%s' "$OUT" | tr '\n' ' ')" "abc1234 def5678"
printf '  target : All\n' > "$NOTE"
ops plain note-scope --note "$NOTE"
check "the singular, indented, mixed-case form parses" "$OUT" all
printf 'Targets: aaa1111\nnotes\ntargets: bbb2222 ccc3333\n' > "$NOTE"
ops plain note-scope --note "$NOTE"
check "every scope line is read" "$(printf '%s' "$OUT" | tr '\n' ' ')" "aaa1111 bbb2222 ccc3333"
printf 'The Targets: line is described here, mid-sentence.\n' > "$NOTE"
ops plain note-scope --note "$NOTE"
check "a scope word in the middle of a line is not a scope line" "$OUT" ""

printf 'Targets: all\n' > "/tmp/agent-history-rewrite-approved-$GID.md"
OUT=$(cd "$TMP/plain" && HOME="$FH" AGENT_TASK_GID="$GID" "$OPS" note-scope 2>/dev/null); RC=$?
check "with no path given the note is found by the task id" "$OUT" all
OUT=$(cd "$TMP/plain" && HOME="$FH" AGENT_TASK_GID="$GID-other" "$OPS" note-scope 2>/dev/null); RC=$?
check "another task's note is not read" "$RC" 1

# --- usage ---
ops plain
check "no command: exit code" "$RC" 1
has "no command prints the usage line" "$ERR" "Usage: git-branch-ops.sh"
ops plain grab
check "an unknown command: exit code" "$RC" 1
ops plain push --bogus
check "an unknown flag: exit code" "$RC" 1
has "an unknown flag is named" "$ERR" "Unknown arg: --bogus"

if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
