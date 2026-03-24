#!/usr/bin/env bash
# setup.sh — Bootstrap edge-dev-agents on a new machine.
# Usage: ./scripts/setup.sh
#
# Creates symlinks from ~/.cursor/ and ~/.claude/ into this repo's
# .cursor/ content, then generates ~/.claude/CLAUDE.md from alwaysApply rules.
# Idempotent — safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURSOR_SRC="$REPO_DIR/.cursor"

if [[ ! -d "$CURSOR_SRC/skills" ]]; then
  echo "ERROR: $CURSOR_SRC/skills not found. Is this the edge-dev-agents repo?" >&2
  exit 1
fi

# 1. Symlink ~/.cursor/{skills,rules,scripts} → repo equivalents
echo "Setting up ~/.cursor/ symlinks..."
mkdir -p "$HOME/.cursor"
for dir in skills rules scripts; do
  target="$CURSOR_SRC/$dir"
  link="$HOME/.cursor/$dir"
  if [[ -L "$link" ]]; then
    current="$(readlink "$link")"
    if [[ "$current" == "$target" ]]; then
      echo "  $dir: already linked"
      continue
    fi
    rm "$link"
  elif [[ -d "$link" ]]; then
    echo "  WARNING: $link is a real directory, not a symlink. Skipping."
    echo "           Remove it manually if you want to link to the repo."
    continue
  fi
  ln -s "$target" "$link"
  echo "  $dir: linked → $target"
done

# 2. Symlink ~/.claude/skills → ~/.cursor/skills
echo "Setting up ~/.claude/skills symlink..."
mkdir -p "$HOME/.claude"
CLAUDE_SKILLS="$HOME/.claude/skills"
if [[ -L "$CLAUDE_SKILLS" ]]; then
  current="$(readlink "$CLAUDE_SKILLS")"
  if [[ "$current" != "$HOME/.cursor/skills" ]]; then
    rm "$CLAUDE_SKILLS"
    ln -s "$HOME/.cursor/skills" "$CLAUDE_SKILLS"
    echo "  skills: relinked → ~/.cursor/skills"
  else
    echo "  skills: already linked"
  fi
elif [[ ! -e "$CLAUDE_SKILLS" ]]; then
  ln -s "$HOME/.cursor/skills" "$CLAUDE_SKILLS"
  echo "  skills: linked → ~/.cursor/skills"
fi

# 3. Generate ~/.claude/CLAUDE.md from alwaysApply rules
GEN_SCRIPT="$CURSOR_SRC/skills/convention-sync/scripts/generate-claude-md.sh"
if [[ -x "$GEN_SCRIPT" ]]; then
  echo "Generating ~/.claude/CLAUDE.md..."
  "$GEN_SCRIPT" >/dev/null
  echo "  CLAUDE.md generated"
else
  echo "WARNING: generate-claude-md.sh not found or not executable"
fi

# 4. Make all .sh files executable
find "$REPO_DIR" -name "*.sh" -exec chmod +x {} +

# 5. Check prerequisites
echo ""
echo "Checking prerequisites..."
for cmd in gh jq node; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  $cmd: $(command -v "$cmd")"
  else
    echo "  WARNING: $cmd not found"
  fi
done

echo ""
echo "Setup complete."
