#!/usr/bin/env bash
# bootstrap.sh — Reproduce this agent setup on a fresh Mac from the cloned repo.
#
# Installs (repo -> home), idempotent, never clobbers secrets/state:
#   .cursor/            -> ~/.cursor/                 (skills, rules, scripts, README)
#   agent-watcher/      -> ~/.config/agent-watcher/   (orchestration code + config)
#   claude-workflows/   -> ~/.claude/workflows/       (Workflow-tool scripts)
#   bin/link-shared-memory.sh -> ~/.claude/link-shared-memory.sh
#   claude-settings/hooks.json -> the .hooks key of ~/.claude/settings.json and
#                         of ~/.claude/settings.canonical.json (created if absent)
#   agent-watcher/launchd/*.plist -> ~/Library/LaunchAgents/ (rendered + loaded)
# Then: links ~/.claude/skills -> ~/.cursor/skills, regenerates ~/.claude/CLAUDE.md,
# and links any shared memory notes already in ~/.claude/memory-shared (they are
# never in this repo; carry them over in the machine-migration bundle) into the
# standard entry points (~ and ~/git).
#
# Secrets and people data are NOT in the repo. agent-watcher/credentials.json
# and agent-watcher/team-roster.json are seeded from their *.example.json
# templates (fill them in afterward). Machine-local state (pools, logs,
# worktrees, watchdog state, the Fleet ledger and artifact URL, the rc-heal
# anchor list) is never copied.
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
  # The reviewer roster (names + Asana user gids) is people data: local-only,
  # with an empty template in the repo. asana-task-update reads it.
  ROSTER="$HOME/.config/agent-watcher/team-roster.json"
  if [[ ! -f "$ROSTER" && -f "$HOME/.config/agent-watcher/team-roster.example.json" ]]; then
    cp "$HOME/.config/agent-watcher/team-roster.example.json" "$ROSTER"
    chmod 600 "$ROSTER"
    warn "Seeded $ROSTER from example: fill in .members (see NEW-MACHINE-SETUP.md, Local-only files)."
  fi
fi

# 3b. Workflow-tool scripts (model-invocable workflows, e.g. code-review-sonnet)
if [[ -d "$REPO/claude-workflows" ]]; then
  say "Installing ~/.claude/workflows from repo/claude-workflows"
  copy_tree "$REPO/claude-workflows" "$HOME/.claude/workflows"
fi

# 4. Shared-memory link helper
if [[ -f "$REPO/bin/link-shared-memory.sh" ]]; then
  say "Installing ~/.claude/link-shared-memory.sh"
  cp "$REPO/bin/link-shared-memory.sh" "$HOME/.claude/link-shared-memory.sh"
  chmod +x "$HOME/.claude/link-shared-memory.sh"
fi

# 4b. Hook registrations: merge claude-settings/hooks.json into
# ~/.claude/settings.json, replacing ONLY the .hooks key (model/theme/etc stay
# machine-local). Without this the agent-watcher hook SCRIPTS installed in
# step 2 are present but never fire. Written via temp+mv (no partial writes).
#
# The same block goes into ~/.claude/settings.canonical.json, the file
# settings-guard.sh treats as the source of truth: it re-applies that file's
# top-level keys to settings.json whenever a claude process rewrites it, and
# does nothing while the file is absent. A fresh machine gets the file seeded
# with the hooks key, so the guard protects the registrations from its first
# run. A machine that already has one gets only its .hooks key replaced: left
# alone, the guard would put the older registrations back over this step.
# Every other key in the canonical file (env, attribution, permissions) is the
# machine's own and is never touched; add a key there to pin it.
if [[ -f "$REPO/claude-settings/hooks.json" ]]; then
  say "Merging hook registrations into ~/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  SJ="$HOME/.claude/settings.json"
  CJ="$HOME/.claude/settings.canonical.json"
  # Local-only registrations live in the canonical file when there is one.
  OLD_SRC="$SJ"; [[ -f "$CJ" ]] && OLD_SRC="$CJ"
  if [[ -f "$SJ" ]]; then
    # Whole-block replace: name any local-only registration it destroys (the
    # matcher is unrecoverable afterwards) and keep a timestamped backup.
    DROPPED=$(jq -n --slurpfile new "$REPO/claude-settings/hooks.json" --slurpfile old "$OLD_SRC" '
      def flat: [ to_entries[] as $e | ($e.value // [])[] as $g | ($g.hooks // [])[] as $h
                  | {event: $e.key, matcher: ($g.matcher // ""), command: ($h.command // "")} ];
      ($new[0] | flat) as $n
      | (($old[0].hooks // {}) | flat)
      | map(select( . as $x | ($n | any(.event == $x.event and .command == $x.command)) | not ))
    ' 2>/dev/null || echo '[]')
    if [[ "$(printf '%s' "$DROPPED" | jq 'length')" -gt 0 ]]; then
      say "WARNING: these local-only hook registrations are being replaced:"
      printf '%s' "$DROPPED" | jq -r '.[] | "    [\(.event)] \(.matcher)  ->  \(.command)"'
      say "Re-add them in ~/.claude/settings.local.json if they are machine-specific."
    fi
    cp "$SJ" "$SJ.bak.$(date +%Y%m%d-%H%M%S)"
    MERGED=$(jq -S --slurpfile h "$REPO/claude-settings/hooks.json" '.hooks = $h[0]' "$SJ")
  else
    MERGED=$(jq -nS --slurpfile h "$REPO/claude-settings/hooks.json" '{hooks: $h[0]}')
  fi
  [[ -n "$MERGED" ]] && printf '%s\n' "$MERGED" > "$SJ.tmp.$$" && mv "$SJ.tmp.$$" "$SJ"

  if [[ -f "$CJ" ]]; then
    cp "$CJ" "$CJ.bak.$(date +%Y%m%d-%H%M%S)"
    CMERGED=$(jq -S --slurpfile h "$REPO/claude-settings/hooks.json" '.hooks = $h[0]' "$CJ")
    CSAY="Replaced the hooks key of ~/.claude/settings.canonical.json (other pinned keys kept)"
  else
    CMERGED=$(jq -nS --slurpfile h "$REPO/claude-settings/hooks.json" '{hooks: $h[0]}')
    CSAY="Seeded ~/.claude/settings.canonical.json with the hook registrations (settings-guard.sh keeps settings.json equal to it)"
  fi
  if [[ -n "$CMERGED" ]]; then
    printf '%s\n' "$CMERGED" > "$CJ.tmp.$$" && mv "$CJ.tmp.$$" "$CJ" && say "$CSAY"
  else
    warn "could not write ~/.claude/settings.canonical.json; settings-guard.sh stays inert until it exists"
  fi
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
# 5. launchd jobs (watcher, watchdog, sweeps, guards). Templates live in
# agent-watcher/launchd; the installer renders __HOME__/__NODE_BIN__, loads
# each job, and skips any whose program is not on this machine.
if [[ -x "$HOME/.config/agent-watcher/launchd/install-launchd.sh" ]]; then
  say "Installing launchd jobs from agent-watcher/launchd"
  "$HOME/.config/agent-watcher/launchd/install-launchd.sh" || warn "some launchd jobs did not load; see output above"
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
echo "  4. To pin more Claude settings across sessions (env, attribution, permissions), add the key to ~/.claude/settings.canonical.json."
