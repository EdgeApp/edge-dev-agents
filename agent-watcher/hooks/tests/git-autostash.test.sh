#!/usr/bin/env bash
# git-autostash.test.sh: the stash takes real work and leaves gitignored config.
#
#   git-autostash.sh    keeps an untracked file that the default branch or a named
#                       ref ignores, stashes everything else under the label, and
#                       reports NOTHING when only kept files are dirty.
#   podfile_lock_only_hermes_changed (native-deps-hash.sh) recognizes the one line
#                       pod install rewrites and no other lock change.
#
#   refresh-master-build.sh  its dirty-checkout block, lifted from the real script:
#                       discards a hermes-only lock, stashes real work and goes
#                       on, and skips the refresh when git refuses the stash.
#
# Runs against a throwaway repo with a bare origin.
set -uo pipefail

H="$HOME/.cursor/skills/git-autostash.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/git-autostash-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
stashes() { git -C "$R" stash list | wc -l | tr -d ' '; }
untracked_in_stash() { git -C "$R" ls-tree -r --name-only 'stash@{0}^3' 2>/dev/null | tr '\n' ' '; }

git init -q --bare "$TMP/o.git"
R="$TMP/w"
git clone -q "$TMP/o.git" "$R" 2>/dev/null
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" checkout -q -b develop
printf 'node_modules\n' > "$R/.gitignore"; printf 'a\n' > "$R/a.txt"
git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" branch old
printf 'node_modules\n/edgeKey.json\n/ks/cfg.json\n' > "$R/.gitignore"
git -C "$R" add -A; git -C "$R" commit -qm ignore
git -C "$R" push -q origin develop 2>/dev/null
git -C "$R" checkout -q old

# --- a checkout with only protected files dirty stashes nothing ---
printf 's\n' > "$R/edgeKey.json"
out=$("$H" --repo "$R" --message t1 2>/dev/null)
check "only kept files dirty reports NOTHING" "$out" "NOTHING"
check "only kept files dirty makes no stash" "$(stashes)" 0
[[ -f "$R/edgeKey.json" ]] && ok "the kept file stays" || fail "the kept file stays"

# --- real work goes, config stays ---
printf 'w\n' > "$R/work.txt"; printf 'b\n' >> "$R/a.txt"
mkdir -p "$R/ks"; printf 'c\n' > "$R/ks/cfg.json"; printf 'x\n' > "$R/sp ace.txt"
out=$("$H" --repo "$R" --message t2 2>/dev/null)
check "real work reports the label" "$out" "STASHED t2"
check "real work makes one stash" "$(stashes)" 1
check "the stash holds the untracked work and no config" "$(untracked_in_stash)" "sp ace.txt work.txt "
check "the stash holds the tracked edit" "$(git -C "$R" diff --name-only 'stash@{0}^1' 'stash@{0}' | tr -d '\n')" "a.txt"
[[ -f "$R/edgeKey.json" && -f "$R/ks/cfg.json" ]] && ok "config stays in the checkout" || fail "config stays in the checkout"
[[ ! -f "$R/work.txt" ]] && ok "untracked work left the checkout" || fail "untracked work left the checkout"
rm -rf "$R/edgeKey.json" "$R/ks"

# --- a clean checkout ---
check "a clean checkout reports NOTHING" "$("$H" --repo "$R" --message t3 2>/dev/null)" "NOTHING"

# --- --ignore-ref covers a branch the defaults do not ---
git -C "$R" checkout -q -b x develop
printf '/late.json\n' >> "$R/.gitignore"; git -C "$R" add -A; git -C "$R" commit -qm late
git -C "$R" checkout -q old
printf 'l\n' > "$R/late.json"
check "--ignore-ref keeps its ignored file" "$("$H" --repo "$R" --message t4 --ignore-ref x 2>/dev/null)" "NOTHING"
out=$("$H" --repo "$R" --message t5 2>/dev/null)
check "without --ignore-ref the file is stashed" "$out" "STASHED t5"
git -C "$R" stash clear

# --- a subdirectory resolves to the repo root ---
mkdir -p "$R/sub"; printf 'q\n' > "$R/sub/q.txt"
check "--repo may name a subdirectory" "$("$H" --repo "$R/sub" --message t6 2>/dev/null)" "STASHED t6"
git -C "$R" stash clear

# --- git refusing is exit 1 ---
git -C "$R" checkout -q develop
printf 'c1\n' > "$R/a.txt"; git -C "$R" commit -qam c1
git -C "$R" checkout -q old
printf 'c2\n' > "$R/a.txt"; git -C "$R" commit -qam c2
git -C "$R" merge develop >/dev/null 2>&1
"$H" --repo "$R" --message t7 >/dev/null 2>&1
check "a checkout mid-conflict exits 1" "$?" 1
git -C "$R" merge --abort

# --- usage ---
"$H" --repo "$R" >/dev/null 2>&1
check "a missing label exits 2" "$?" 2

# --- the hermes-engine lock line ---
source "$HOME/.cursor/skills/build-and-test/scripts/lib/native-deps-hash.sh"
L="$TMP/l"
git init -q "$L"; git -C "$L" config user.email t@t; git -C "$L" config user.name t
mkdir -p "$L/ios"
printf 'A: 1\n  hermes-engine: 1111111111111111111111111111111111111111\n  other: 2222222222222222222222222222222222222222\n' > "$L/ios/Podfile.lock"
git -C "$L" add -A; git -C "$L" commit -qm lock
hermes() { (cd "$L" && podfile_lock_only_hermes_changed && echo yes || echo no); }
check "an unchanged lock is not a hermes change" "$(hermes)" no
sed -i '' 's/hermes-engine: 1111/hermes-engine: 9999/' "$L/ios/Podfile.lock"
check "the hermes line alone is recognized" "$(hermes)" yes
sed -i '' 's/other: 2222/other: 8888/' "$L/ios/Podfile.lock"
check "another changed line is not" "$(hermes)" no
git -C "$L" checkout -q -- ios/Podfile.lock
printf 'new pod\n' >> "$L/ios/Podfile.lock"
check "an added line is not" "$(hermes)" no

# --- the refresh's own dirty-checkout block, lifted from the real script ---
BLOCK=$(sed -n '/^# 1\. Put the main checkout exactly on develop/,/^log "checking out/p' "$HOME/.config/agent-watcher/refresh-master-build.sh" | sed '$d')
refresh_block() { # prints log lines, then CONTINUED if the block fell through
  ( set -euo pipefail; REPO_DIR="$1"; DEVELOP_REF="$2"; log() { echo "LOG $*"; }
    eval "$BLOCK"$'\n:'
    echo CONTINUED )
}
D="$TMP/d"
git init -q "$D"; git -C "$D" config user.email t@t; git -C "$D" config user.name t
mkdir -p "$D/ios"
printf '  hermes-engine: 1111111111111111111111111111111111111111\n  other: 1\n' > "$D/ios/Podfile.lock"
printf 'node_modules\n/keys.json\n' > "$D/.gitignore"; git -C "$D" add -A; git -C "$D" commit -qm base
sed -i '' 's/hermes-engine: 1111/hermes-engine: 9999/' "$D/ios/Podfile.lock"
out=$(refresh_block "$D" HEAD)
[[ "$out" == *"discarded"* && "$out" == *CONTINUED* ]] && ok "refresh: a hermes-only lock is discarded and the refresh goes on" || fail "refresh: hermes-only: $out"
check "refresh: the hermes-only lock is clean afterwards" "$(git -C "$D" status --porcelain | wc -l | tr -d ' ')" 0
check "refresh: the hermes-only lock makes no stash" "$(git -C "$D" stash list | wc -l | tr -d ' ')" 0
printf 'real\n' > "$D/one-off.txt"; printf 'k\n' > "$D/keys.json"
out=$(refresh_block "$D" HEAD)
[[ "$out" == *"master-refresh-autostash"* && "$out" == *CONTINUED* ]] && ok "refresh: real work is stashed, named, and the refresh goes on" || fail "refresh: real work: $out"
[[ -f "$D/keys.json" && ! -f "$D/one-off.txt" ]] && ok "refresh: config stays, the one-off moves to the stash" || fail "refresh: config stays"
git -C "$D" stash clear
git -C "$D" checkout -q -b side; printf 'side\n' > "$D/a.txt"; git -C "$D" add -A; git -C "$D" commit -qm side
git -C "$D" checkout -q -; printf 'main\n' > "$D/a.txt"; git -C "$D" add -A; git -C "$D" commit -qm main
git -C "$D" merge side >/dev/null 2>&1
out=$(refresh_block "$D" HEAD)
[[ "$out" == *"could not stash"* && "$out" != *CONTINUED* ]] && ok "refresh: a stash git refuses skips the refresh" || fail "refresh: refused stash: $out"

[[ "$FAILS" -eq 0 ]] && echo "all passed" || echo "$FAILS FAILED"
exit "$((FAILS > 0))"
