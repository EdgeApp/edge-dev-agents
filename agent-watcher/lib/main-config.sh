# main-config.sh: is the gui main checkout's gitignored config fit to copy into
# worktrees, and a last-known-good copy of it. Sourced by setup-task-workspace.sh,
# which copies whatever the checkout holds, so damage here reaches every new run:
# a missing edgeKey.json fails the native build and hollow keys.json builds an app
# with no plugin credentials.
#
# The list comes from the base ref, never from names kept here: any tracked root
# X.example.json requires a real X.json that differs from the example, and a
# configure.ts that reads keys.json requires one with plugin maps. A branch without
# them (staging, master) requires nothing.

MAIN_CONFIG_FILES=(env.json config.json keys.json edgeKey.json)
MAIN_CONFIG_GOOD="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/main-config-good"

# Prints one problem per line; no output means fit.
main_config_problems() {
  local main="$1" base="$2" f real
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    real="${f%.example.json}.json"
    if [[ ! -f "$main/$real" ]]; then
      echo "$real is missing"
    elif git -C "$main" show "$base:$f" 2>/dev/null | cmp -s - "$main/$real"; then
      echo "$real is still the unfilled $f"
    fi
  done < <(git -C "$main" ls-tree --name-only "$base" 2>/dev/null | grep -E '\.example\.json$' || true)

  if git -C "$main" show "$base:scripts/configure.ts" 2>/dev/null | grep -q 'keys\.json'; then
    if [[ ! -f "$main/keys.json" ]]; then
      echo "keys.json is missing"
    elif ! jq -e '[.corePlugins, .swapPlugins, .rampPlugins] | map(length) | add > 0' "$main/keys.json" >/dev/null 2>&1; then
      echo "keys.json has empty plugin maps or is not valid JSON"
    fi
  fi
}

# Call only after main_config_problems came back empty. Each file is replaced
# atomically and the directory stays private: these are secrets.
snapshot_main_config() {
  local main="$1" f tmp
  (umask 077; mkdir -p "$MAIN_CONFIG_GOOD")
  for f in "${MAIN_CONFIG_FILES[@]}"; do
    [[ -f "$main/$f" ]] || continue
    cmp -s "$main/$f" "$MAIN_CONFIG_GOOD/$f" && continue
    tmp="$(mktemp "$MAIN_CONFIG_GOOD/.$f.XXXXXX")"
    cp "$main/$f" "$tmp" && mv "$tmp" "$MAIN_CONFIG_GOOD/$f"
  done
}
