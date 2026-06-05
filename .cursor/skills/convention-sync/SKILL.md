---
name: convention-sync
description: Sync cursor files between ~/.cursor/ and the edge-dev-agents repo, commit, push, and update PR description. Use when the user wants to sync conventions.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Sync the canonical home setup (`~/.cursor/` skills/rules/scripts + the agent orchestration system + shared Claude memories) into the `edge-dev-agents` repo, commit, push, and update the PR description from the synced repo root README. Also maintains cross-tool compatibility: symlinks `~/.claude/skills` → `~/.cursor/skills` and generates `~/.claude/CLAUDE.md` from always-apply rules. The repo is the distribution copy a second machine bootstraps from.</goal>

<rules>
<rule id="local-is-canonical">`~/.cursor/` is the canonical source. Edits happen locally; the repo is the distribution copy. Default direction is `user-to-repo`. Use `--repo-to-user` only for onboarding or pulling changes authored by others.</rule>
<rule id="extra-trees">Beyond `~/.cursor`, the script also mirrors portable "extra trees" into the repo so a second Mac can be reproduced: the orchestration system (`~/.config/agent-watcher` → repo `agent-watcher/`), shared Claude memories (`~/.claude/memory-shared` → repo `memory-shared/`), and the memory link helper (`~/.claude/link-shared-memory.sh` → repo `bin/`). Secrets and machine-local state are EXCLUDED by hardcoded rsync excludes in the script (`credentials.json`, `*.log`, `*.state`, `pool.json`, `slots.json`, `watchdog-state.json`, `oom-repro/forensics`, `oom-repro/logs`); `credentials.example.json` is committed as a fill-in template. These appear in the JSON under `extra`/`extraTotal`. NEVER hand-add secret/state files to the repo. A fresh machine reproduces everything by cloning the repo and running `./bootstrap.sh` (installs the trees into home, seeds credentials from the example, links skills + shared memory). Auto-memory (`~/.claude/projects/<project>/memory/`) is machine-local per Anthropic docs and is intentionally NOT synced.</rule>
<rule id="cross-machine-safety">The script auto-fetches origin and HARD-BLOCKS (exit non-zero) a `--stage`/`--commit` (user-to-repo) on any of: (a) `originAhead > 0` — remote has commits you lack; pull first. (b) Wrong branch — HEAD is the repo default branch, or doesn't match the open sync PR's head branch; this prevents pushing the sync onto `main` and bypassing the PR (override: `--force-branch`). (c) Blocking `warnings` of kind `deletion`, `stale-local`, or `re-adding-deleted` — the sync would delete or revert canonical files, in `~/.cursor` OR the portable extra trees (override: `--force`). Warnings are NO LONGER advisory. When blocked by (c), the right fix is almost always `--repo-to-user --stage` to de-stale this machine first, THEN re-run user-to-repo to push. The dry-run summary computes all of these by content hash (not mtime), so timestamp churn no longer inflates the diff. Always surface `warnings` in the summary.</rule>
<rule id="use-companion-script">Use `~/.cursor/skills/convention-sync/scripts/convention-sync.sh` for diffing and syncing. Do NOT manually diff or copy files.</rule>
<rule id="dry-run-first">Always run without `--stage` first to show the summary. Only stage/commit after user confirms.</rule>
<rule id="no-script-bypass">If the script fails, report the error and STOP.</rule>
<rule id="readme-is-source">`~/.cursor/README.md` is the canonical local documentation source. The sync script mirrors it to `<repo>/README.md`, and PR descriptions must be updated from that synced repo root README.</rule>
<rule id="claude-compat">Every run ensures `~/.claude/skills` symlinks to `~/.cursor/skills` and regenerates `~/.claude/CLAUDE.md` from `alwaysApply: true` rules. This enables OpenCode and Claude Code to discover skills and rules without separate config.</rule>
<rule id="target-repo-resolution">For user-to-repo sync, target the `edge-dev-agents` checkout. Do NOT assume the current repo is correct just because it contains a `.cursor/` folder. Let the companion script resolve and validate the repo path.</rule>
</rules>

<step id="1" name="Detect changes and PR status">
Use the companion script's default repo resolution first. It targets the `edge-dev-agents` checkout and fails if the resolved or provided repo is not actually `edge-dev-agents`.

Run the sync script in dry-run mode:

```bash
~/.cursor/skills/convention-sync/scripts/convention-sync.sh
```

Parse the JSON output and extract `repoDir`. Then check for an open PR:

```bash
cd <repo-dir> && gh pr view --json number,url --jq '{number: .number, url: .url}' 2>/dev/null || echo '{}'
```

Use the resolved repo path from the script for subsequent git and PR commands. If BOTH `total` and `extraTotal` are 0, report "Everything is in sync" and stop.
</step>

<step id="2" name="Present summary">
Show the user a concise summary including PR update status, origin lag, and any cross-machine warnings:

```
Sync summary (user → repo):
  New: file1, file2
  Modified: file3, file4
  Deleted: file5
  Ignored: file6, file7 (via .syncignore)
  Extra (orch + memories): agent-watcher/…, memory-shared/…, bin/…  (from `extra`; only if extraTotal > 0)

⚠️  origin/<branch> is N commit(s) ahead — pull before staging.   (only if originAhead > 0)
⚠️  Possible overwrites of upstream work:                         (only if warnings array non-empty)
    - file3 (stale-local) — last upstream commit: <hash> <subject>
    - file8 (deletion) — last upstream commit: <hash> <subject>

PR #N: Will update description from repo `README.md` (or "No open PR")

Commit and push? [y/N]
```

If `ignored` is empty, omit the Ignored line. If `originAhead` is 0, omit that warning. If `warnings` is empty, omit that block.

**Warning kinds:**
- `stale-local`: a modified file's most-recent upstream commit timestamp is newer than the local file's mtime — your local was likely written from an older copy.
- `deletion`: you'd be deleting a path that exists in the repo. Always confirm.
- `re-adding-deleted`: a "new" file locally that was deleted upstream after your local was last written.

If `originAhead > 0`, advise the user to `cd <repo-dir> && git pull --rebase` before re-running. Do NOT proceed to step 3 — the script will refuse to stage anyway.

If the user provided a commit message in their prompt, still surface warnings; only skip the y/N confirmation when there are no warnings.
</step>

<step id="3" name="Stage, commit, push, update PR">
Run the script with `--commit`:

```bash
~/.cursor/skills/convention-sync/scripts/convention-sync.sh <repo-dir> --commit -m "<message>"
```

Then push:

```bash
cd <repo-dir> && git push origin HEAD
```

If an open PR exists, update the PR description from the synced repo root README:

```bash
cd <repo-dir> && gh pr edit --body-file README.md
```
</step>

<edge-cases>
<case name="Reverse sync (repo → user)">If the user says "pull from repo" or "update my local", run with `--repo-to-user --stage`. This restores BOTH `~/.cursor` AND the portable extra trees (agent-watcher, memory-shared, bin) from the repo, and never deletes home-local state/secret files. No git operations needed. This is also the de-stale step to run before a user-to-repo sync that was blocked by `deletion`/`stale-local` warnings.</case>
<case name="Current repo has a .cursor folder but is not edge-dev-agents">Do not sync into that repo. Fall back to `~/git/edge-dev-agents` or ask for the correct repo path.</case>
<case name="Dry-run resolved a repo path">Reuse the `repoDir` value from the script's JSON output for the PR query, commit run, push, and PR edit steps.</case>
<case name="Selective sync">To permanently exclude files, add glob patterns to `.syncignore` (one per line, `#` comments). The script reads `.syncignore` from the REPO (`<repo>/.cursor/.syncignore`) as the canonical source so every machine honors the same excludes, falling back to `~/.cursor/.syncignore` only if the repo lacks one. The script skips matching entries and reports them in the `ignored` array. To exclude ad-hoc, remove files from staging with `git reset HEAD .cursor/<file>` before committing.</case>
<case name="README migration">During migration, the dry-run may report deletion of `.cursor/README.md` in the repo copy. That is expected: the repo should keep only the root `README.md`.</case>
<case name="No README">If `~/.cursor/README.md` doesn't exist, skip PR description update and warn the user.</case>
<case name="origin is ahead (originAhead > 0)">The script auto-fetches and detects this. Surface the count to the user, instruct them to `cd <repo-dir> && git pull --rebase`, then re-run convention-sync. Do not attempt --stage/--commit before pulling — the script will exit non-zero.</case>
<case name="Wrong branch (default or non-PR branch)">The script refuses `--stage`/`--commit` when HEAD is the repo default branch or doesn't match the open sync PR's head branch — this stops a fresh clone (which sits on `main`) from pushing the sync onto `main` and bypassing the PR. Checkout the sync branch (`cd <repo-dir> && git checkout <pr-head>`) and re-run. Override with `--force-branch` ONLY if intentionally committing to a different branch.</case>
<case name="Blocking warnings (deletion / stale-local / re-adding-deleted)">The script HARD-BLOCKS staging on these — the sync would delete or revert canonical files because this machine is stale/incomplete (covers `~/.cursor` AND the extra trees). Default action: run `--repo-to-user --stage` to pull the canonical state down first, then re-run user-to-repo to push your genuine additions. Only after the user reviews the specific files and explicitly intends to overwrite upstream should you re-run with `--force`. Never pass `--force` reflexively.</case>
<case name="Fetch fails (offline)">If `git fetch origin` fails the script proceeds with `originAhead=0`. The cross-machine safety check is best-effort; on a flaky network the user should re-run when connectivity is back if cross-machine sync matters.</case>
</edge-cases>
