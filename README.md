# edge-dev-agents

Development agent configurations: Cursor skills, Claude Code rules, and (soon) OpenClaw workspace files.

## Contents

- `.cursor/` — Skills, rules, and scripts synced from `~/.cursor/` via the `convention-sync` skill
- `.claude/` — Auto-generated `CLAUDE.md` and skills symlink for Claude Code compatibility
- `scripts/setup.sh` — Bootstrap script for deploying to new machines

## Setup (new machine)

```bash
git clone git@github.com:EdgeApp/edge-dev-agents.git ~/git/edge-dev-agents
cd ~/git/edge-dev-agents
./scripts/setup.sh
```

This creates symlinks from `~/.cursor/` and `~/.claude/` into the repo, so both Cursor and Claude Code discover the skills and rules.

## Syncing

After editing skills locally in `~/.cursor/`, sync to this repo:

```
/convention-sync
```

To pull changes from this repo into your local setup:

```bash
./scripts/setup.sh
```
