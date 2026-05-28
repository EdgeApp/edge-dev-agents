#!/usr/bin/env bash
# set-github-secret.sh — Add or update ASANA_GITHUB_SECRET in credentials.json
# and ensure the ~/.zshrc loader exports it.
#
# Idempotent. Safe to re-run.

set -euo pipefail

CRED="$HOME/.config/agent-watcher/credentials.json"
ZSHRC="$HOME/.zshrc"
LOADER_LINE='export ASANA_GITHUB_SECRET=$(jq -r '"'"'.asana_github_secret // empty'"'"' ~/.config/agent-watcher/credentials.json 2>/dev/null)'
LOADER_MARKER='# agent-watcher: load ASANA_GITHUB_SECRET from credentials.json'

ok()   { printf "   \033[32mOK\033[0m  %s\n" "$1"; }
warn() { printf "   \033[33m!!\033[0m  %s\n" "$1"; }
fail() { printf "   \033[31mERR\033[0m %s\n" "$1"; exit 1; }

[[ -f "$CRED" ]] || fail "Missing $CRED — run setup.sh first to set ASANA_TOKEN."
command -v jq >/dev/null 2>&1 || fail "jq not found."

if [[ -n $(jq -r '.asana_github_secret // empty' "$CRED") ]]; then
  printf "   asana_github_secret already set in credentials.json. Overwrite? [y/N] "
  read -r yn
  [[ "$yn" =~ ^[Yy]$ ]] || { warn "keeping existing secret"; exit 0; }
fi

printf "   Paste ASANA_GITHUB_SECRET (input hidden, Enter when done): "
stty -echo
IFS= read -r SECRET || true
stty echo
printf "\n"
[[ -n "${SECRET:-}" ]] || fail "empty input"

# Merge into existing JSON (preserve asana_token + any other fields)
tmpfile=$(mktemp)
jq --arg s "$SECRET" '. + {asana_github_secret: $s}' "$CRED" > "$tmpfile"
mv "$tmpfile" "$CRED"
chmod 600 "$CRED"
unset SECRET
ok "merged into $CRED (mode 600)"

# Add zshrc loader if missing
if grep -qF "$LOADER_MARKER" "$ZSHRC" 2>/dev/null; then
  ok "zshrc loader already present"
else
  {
    echo ""
    echo "$LOADER_MARKER"
    echo "if [ -f ~/.config/agent-watcher/credentials.json ]; then"
    echo "  $LOADER_LINE"
    echo "fi"
  } >> "$ZSHRC"
  ok "appended loader to $ZSHRC"
fi

printf "\n\033[1;32mDone.\033[0m Open a new shell to pick up \$ASANA_GITHUB_SECRET, or run:\n"
printf "   export ASANA_GITHUB_SECRET=\$(jq -r .asana_github_secret %s)\n" "$CRED"
