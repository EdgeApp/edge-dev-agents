#!/usr/bin/env bash
# main-config.test.sh: lib/main-config.sh names broken main-checkout config and keeps
# a last-known-good copy of config that passes. Runs against a throwaway repo.
set -uo pipefail

TMP=$(mktemp -d "${TMPDIR:-/tmp}/main-config-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
source "$HOME/.config/agent-watcher/lib/main-config.sh"
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}

R="$TMP/r"
git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/scripts"
echo '{"apiKey":"","apiSecret":""}' > "$R/edgeKey.example.json"
echo "makeConfig(asKeysJson, 'keys.json')" > "$R/scripts/configure.ts"
git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" branch new
git -C "$R" checkout -q -b old
git -C "$R" rm -q edgeKey.example.json scripts/configure.ts; git -C "$R" commit -qm old
git -C "$R" checkout -q new

check "a missing file is named, keys.json too" "$(main_config_problems "$R" new | tr '\n' ';')" "edgeKey.json is missing;keys.json is missing;"
check "a branch without the requirement needs nothing" "$(main_config_problems "$R" old)" ""

cp "$R/edgeKey.example.json" "$R/edgeKey.json"
echo '{"corePlugins":{},"swapPlugins":{},"rampPlugins":{}}' > "$R/keys.json"
check "an unfilled example and hollow keys are named" "$(main_config_problems "$R" new | tr '\n' ';')" \
  "edgeKey.json is still the unfilled edgeKey.example.json;keys.json has empty plugin maps or is not valid JSON;"

echo 'not json' > "$R/keys.json"
check "invalid keys.json is named" "$(main_config_problems "$R" new)" \
  "edgeKey.json is still the unfilled edgeKey.example.json
keys.json has empty plugin maps or is not valid JSON"

echo '{"apiKey":"k","apiSecret":"s"}' > "$R/edgeKey.json"
echo '{"corePlugins":{"a":{"k":1}},"swapPlugins":{},"rampPlugins":{}}' > "$R/keys.json"
check "filled config passes" "$(main_config_problems "$R" new)" ""

snapshot_main_config "$R"
check "the snapshot holds the keys" "$(cat "$MAIN_CONFIG_GOOD/keys.json")" "$(cat "$R/keys.json")"
check "the snapshot directory is private" "$(stat -f '%Lp' "$MAIN_CONFIG_GOOD")" 700
before=$(stat -f '%m%i' "$MAIN_CONFIG_GOOD/keys.json")
snapshot_main_config "$R"
check "an unchanged file is not rewritten" "$(stat -f '%m%i' "$MAIN_CONFIG_GOOD/keys.json")" "$before"
check "no temp files stay behind" "$(ls -A "$MAIN_CONFIG_GOOD" | grep -c '^\.')" 0

# --- setup-task-workspace.sh stops before any worktree work ---
FH="$TMP/home"; mkdir -p "$FH/git" "$FH/.config" "$FH/.cursor"
ln -s "$HOME/.config/agent-watcher" "$FH/.config/agent-watcher"
ln -s "$HOME/.cursor/skills" "$FH/.cursor/skills"
G="$FH/git/edge-react-gui"
git init -q --bare "$TMP/gui.git"
git clone -q "$TMP/gui.git" "$G" 2>/dev/null
git -C "$G" config user.email t@t; git -C "$G" config user.name t
git -C "$G" checkout -q -b develop
mkdir -p "$G/scripts"; cp "$R/edgeKey.example.json" "$G/"; cp "$R/scripts/configure.ts" "$G/scripts/"
git -C "$G" add -A; git -C "$G" commit -qm base; git -C "$G" push -q origin develop 2>/dev/null
out=$(HOME="$FH" "$HOME/.config/agent-watcher/setup-task-workspace.sh" --task-gid 1 --repo edge-react-gui 2>&1); rc=$?
check "setup on broken config exits 1" "$rc" 1
case "$out" in *"edgeKey.json is missing"*) ok "setup names the missing file" ;; *) fail "setup names the missing file: $out" ;; esac
case "$out" in *"Restore: cp"*) ok "setup gives the restore command" ;; *) fail "setup gives the restore command: $out" ;; esac
[[ ! -e "$FH/git/.agent-worktrees/1" ]] && ok "setup made no worktree" || fail "setup made no worktree"

[[ "$FAILS" -eq 0 ]] && echo "all passed" || echo "$FAILS FAILED"
exit "$((FAILS > 0))"
