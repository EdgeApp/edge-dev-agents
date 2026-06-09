#!/usr/bin/env bash
# bootstrap.sh — Reproduce this agent setup on a fresh Mac from the cloned repo.
#
# Installs (repo -> home), idempotent, never clobbers secrets/state:
#   .cursor/            -> ~/.cursor/                 (skills, rules, scripts, README)
#   agent-watcher/      -> ~/.config/agent-watcher/   (orchestration code + config)
#   memory-shared/      -> ~/.claude/memory-shared/   (shared memory notes)
#   bin/link-shared-memory.sh -> ~/.claude/link-shared-memory.sh
# Then: links ~/.claude/skills -> ~/.cursor/skills, regenerates ~/.claude/CLAUDE.md,
# and links shared memory into the standard entry points (~ and ~/git).
#
# Secrets are NOT in the repo. agent-watcher/credentials.json is seeded from
# credentials.example.json (fill it in afterward). Machine-local state (pools,
# logs, worktrees, watchdog state) is never copied.
#
# Usage:  ./bootstrap.sh        (run from the repo root after cloning)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\033[1;32m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

have_rsync() { command -v rsync >/dev/null 2>&1; }
copy_tree() { # src dest  (update files, preserve anything extra in dest)
  local src="$1" dest="$2"
  mkdir -p "$dest"
  if have_rsync; then rsync -rlpt --exclude='.DS_Store' --exclude='.git' "$src/" "$dest/"
  else cp -R "$src/." "$dest/"; fi
}

# 1. Cursor skills/rules/scripts (still used; mirrors into ~/.cursor)
if [[ -d "$REPO/.cursor" ]]; then
  say "Installing ~/.cursor from repo/.cursor"
  copy_tree "$REPO/.cursor" "$HOME/.cursor"
  [[ -f "$REPO/README.md" ]] && cp "$REPO/README.md" "$HOME/.cursor/README.md"
fi

# 2. Orchestration code/config (preserve existing credentials.json + state)
if [[ -d "$REPO/agent-watcher" ]]; then
  say "Installing ~/.config/agent-watcher from repo/agent-watcher (code/config only)"
  copy_tree "$REPO/agent-watcher" "$HOME/.config/agent-watcher"
  CRED="$HOME/.config/agent-watcher/credentials.json"
  if [[ ! -f "$CRED" && -f "$HOME/.config/agent-watcher/credentials.example.json" ]]; then
    cp "$HOME/.config/agent-watcher/credentials.example.json" "$CRED"
    chmod 600 "$CRED"
    warn "Seeded $CRED from example — EDIT IT and add your real asana_token."
  fi
fi

# 3. Shared memory store
if [[ -d "$REPO/memory-shared" ]]; then
  say "Installing ~/.claude/memory-shared from repo/memory-shared"
  copy_tree "$REPO/memory-shared" "$HOME/.claude/memory-shared"
fi

# 4. Shared-memory link helper
if [[ -f "$REPO/bin/link-shared-memory.sh" ]]; then
  say "Installing ~/.claude/link-shared-memory.sh"
  cp "$REPO/bin/link-shared-memory.sh" "$HOME/.claude/link-shared-memory.sh"
  chmod +x "$HOME/.claude/link-shared-memory.sh"
fi

# 5. Claude compat: ~/.claude/skills -> ~/.cursor/skills + regenerate CLAUDE.md
if [[ -d "$HOME/.cursor/skills" ]]; then
  if [[ -L "$HOME/.claude/skills" || ! -e "$HOME/.claude/skills" ]]; then
    mkdir -p "$HOME/.claude"
    ln -sfn "$HOME/.cursor/skills" "$HOME/.claude/skills"
    say "Linked ~/.claude/skills -> ~/.cursor/skills"
  else
    warn "~/.claude/skills exists and is not a symlink — left as-is."
  fi
fi
GEN="$HOME/.cursor/skills/convention-sync/scripts/generate-claude-md.sh"
[[ -x "$GEN" ]] && { say "Regenerating ~/.claude/CLAUDE.md"; "$GEN" >/dev/null || warn "generate-claude-md.sh failed (non-fatal)"; }

# 5b. Portable `timeout` on PATH: macOS has no timeout/gtimeout, but the skills
# prescribe `timeout <s> <cmd>` to bound waits. Symlink the committed shim.
if [[ -f "$HOME/.cursor/skills/timeout.sh" ]] && ! command -v timeout >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  chmod +x "$HOME/.cursor/skills/timeout.sh"
  ln -sf "$HOME/.cursor/skills/timeout.sh" "$HOME/.local/bin/timeout"
  say "Linked ~/.local/bin/timeout -> ~/.cursor/skills/timeout.sh (portable timeout shim)"
fi

# 6. Link shared memory into the standard entry points
if [[ -x "$HOME/.claude/link-shared-memory.sh" ]]; then
  for d in "$HOME" "$HOME/git"; do
    [[ -d "$d" ]] && "$HOME/.claude/link-shared-memory.sh" "$d" || true
  done
  say "Linked shared memory into ~ and ~/git (run link-shared-memory.sh <repo> for others)"
fi

say "Bootstrap complete."
echo
echo "Next steps:"
echo "  1. Fill ~/.config/agent-watcher/credentials.json with your real asana_token (and asana_github_secret if used)."
echo "  2. Install Node deps used by the orchestration if needed (jq, node)."
echo "  3. Per repo where you want shared memory: ~/.claude/link-shared-memory.sh /path/to/repo"
