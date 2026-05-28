#!/usr/bin/env bash
# setup.sh — One-time setup for agent-watcher.
#
# Idempotent. Safe to re-run.
#
# Steps:
#   1. Install tmux if missing.
#   2. Verify jq is available.
#   3. Ensure ~/.config/agent-watcher/ exists with mode 700.
#   4. Prompt for Asana PAT (hidden input), write credentials.json mode 600.
#   5. Append a zshrc loader that exports ASANA_TOKEN from credentials.json.
#   6. Verify the PAT against Asana /users/me.

set -euo pipefail

CONFIG_DIR="$HOME/.config/agent-watcher"
CRED_FILE="$CONFIG_DIR/credentials.json"
ZSHRC="$HOME/.zshrc"
LOADER_MARKER="# agent-watcher: load ASANA_TOKEN from credentials.json"

step() { printf "\n\033[1;34m=> %s\033[0m\n" "$1"; }
ok()   { printf "   \033[32mOK\033[0m  %s\n" "$1"; }
warn() { printf "   \033[33m!!\033[0m  %s\n" "$1"; }
fail() { printf "   \033[31mERR\033[0m %s\n" "$1"; exit 1; }

# 1. tmux
step "tmux"
if command -v tmux >/dev/null 2>&1; then
  ok "already installed ($(tmux -V))"
else
  command -v brew >/dev/null 2>&1 || fail "Homebrew not found; install brew first"
  brew install tmux
  ok "installed"
fi

# 2. jq
step "jq"
command -v jq >/dev/null 2>&1 || fail "jq not found; run: brew install jq"
ok "available"

# 3. config dir
step "config dir"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
ok "$CONFIG_DIR (mode 700)"

# 4. credentials.json
step "credentials"
SKIP_PAT=false
if [[ -f "$CRED_FILE" ]]; then
  printf "   credentials.json already exists. Overwrite? [y/N] "
  read -r yn
  [[ "$yn" =~ ^[Yy]$ ]] || { warn "keeping existing credentials.json"; SKIP_PAT=true; }
fi

if [[ "$SKIP_PAT" == false ]]; then
  printf "   Paste your Asana PAT (input hidden, press Enter when done): "
  stty -echo
  IFS= read -r ASANA_PAT || true
  stty echo
  printf "\n"
  [[ -n "${ASANA_PAT:-}" ]] || fail "empty PAT"
  umask 077
  jq -n --arg token "$ASANA_PAT" '{asana_token: $token}' > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  unset ASANA_PAT
  ok "wrote $CRED_FILE (mode 600)"
fi

# 5. zshrc loader
step "zshrc loader"
if grep -qF "$LOADER_MARKER" "$ZSHRC" 2>/dev/null; then
  ok "already present in $ZSHRC"
else
  cat >> "$ZSHRC" <<'EOF'

# agent-watcher: load ASANA_TOKEN from credentials.json
if [ -f ~/.config/agent-watcher/credentials.json ]; then
  export ASANA_TOKEN=$(jq -r .asana_token ~/.config/agent-watcher/credentials.json 2>/dev/null)
fi
EOF
  ok "appended to $ZSHRC"
fi

# 6. verify against Asana API
step "verify PAT against Asana /users/me"
TOKEN=$(jq -r .asana_token "$CRED_FILE")
RESPONSE=$(curl -sS -H "Authorization: Bearer $TOKEN" https://app.asana.com/api/1.0/users/me) || fail "curl failed"
NAME=$(echo "$RESPONSE" | jq -r '.data.name // empty')
EMAIL=$(echo "$RESPONSE" | jq -r '.data.email // empty')
if [[ -n "$NAME" ]]; then
  ok "authenticated as: $NAME <$EMAIL>"
else
  echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
  fail "PAT did not authenticate"
fi
unset TOKEN

printf "\n\033[1;32mSetup complete.\033[0m Open a new shell to pick up \$ASANA_TOKEN.\n"
