---
name: convention-sync
description: Sync cursor files between ~/.cursor/ and the edge-dev-agents repo, commit, and push to main. Use when the user wants to sync conventions.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Sync the canonical home setup (`~/.cursor/` skills/rules/scripts + the agent orchestration system + shared Claude memories) into the `edge-dev-agents` repo, commit, and push directly to `main` (the perpetual sync PR is retired; PR #1 merged 2026-08-26). Also maintains cross-tool compatibility: symlinks `~/.claude/skills` → `~/.cursor/skills` and generates `~/.claude/CLAUDE.md` from always-apply rules. The repo is the distribution copy a second machine bootstraps from.</goal>

<rules>
<rule id="local-is-canonical">`~/.cursor/` is the canonical source. Edits happen locally; the repo is the distribution copy. Default direction is `user-to-repo`. Use `--repo-to-user` only for onboarding or pulling changes authored by others.</rule>
<rule id="extra-trees">Beyond `~/.cursor`, the script also mirrors portable "extra trees" into the repo so a second Mac can be reproduced: the orchestration system (`~/.config/agent-watcher` → repo `agent-watcher/`), shared Claude memories (`~/.claude/memory-shared` → repo `memory-shared/`), Workflow-tool scripts (`~/.claude/workflows` → repo `claude-workflows/`, e.g. code-review-sonnet.js), and the memory link helper (`~/.claude/link-shared-memory.sh` → repo `bin/`), plus a PROJECTION of Claude hook registrations: the `.hooks` key of `~/.claude/settings.json` → repo `claude-settings/hooks.json` (user→repo exports the key; repo→user and `bootstrap.sh` merge it back replacing ONLY `.hooks` — model/theme/etc stay machine-local; an empty/missing local hooks block is never exported, so an unconfigured machine cannot blank the canonical registrations; a PARTIAL block still can, which is what `hooks-projection-loss` guards). Hook SCRIPTS ship in the agent-watcher tree; without this projection they would be installed but never fire. Secrets and machine-local state are EXCLUDED by hardcoded rsync excludes in the script (`credentials.json`, `*.log`, `*.state`, `pool.json`, `slots.json`, `watchdog-state.json`, `oom-repro/forensics`, `oom-repro/logs`); `credentials.example.json` is committed as a fill-in template. These appear in the JSON under `extra`/`extraTotal`. NEVER hand-add secret/state files to the repo. A fresh machine reproduces everything by cloning the repo and running `./bootstrap.sh` (installs the trees into home, seeds credentials from the example, links skills + shared memory). Auto-memory (`~/.claude/projects/<project>/memory/`) is machine-local per Anthropic docs and is intentionally NOT synced.</rule>
<rule id="cross-machine-safety">The script auto-fetches origin and HARD-BLOCKS (exit non-zero) a `--stage`/`--commit` (user-to-repo) on any of: (a) `originAhead > 0` — remote has commits you lack; pull first. (b) Wrong branch — HEAD is NOT the repo default branch; the sync commits directly to `main` since 2026-08-26, and committing on another session's feature branch rides the sync onto its PR (the PR #3 fast-forward-merge incident) (override: `--force-branch`). (c) Blocking `warnings` of kind `deletion`, `stale-local`, or `re-adding-deleted` — the sync would delete or revert canonical files, in `~/.cursor` OR the portable extra trees (override: `--force`). (d) Non-empty `droppedHooks` — the export would blank canonical hook registrations for every machine (override: `--force`); see `hooks-projection-loss`. Warnings are NO LONGER advisory. When blocked by (c), the right fix is almost always `--repo-to-user --stage` to de-stale this machine first, THEN re-run user-to-repo to push. The dry-run summary computes all of these by content hash (not mtime), so timestamp churn no longer inflates the diff. Always surface `warnings` in the summary.</rule>
<rule id="hooks-projection-loss">The hooks projection replaces the WHOLE `.hooks` block in whichever direction it runs, so registrations present only on the receiving side are destroyed and their `matcher` values are unrecoverable. The script reports these in `droppedHooks` (event + matcher + command) in BOTH directions and on dry runs, so the loss is visible BEFORE it happens. Never wave this away: surface every entry to the user. A dropped hook is machine-specific (hardcoded device ids, absolute paths outside the synced trees) → it belongs in `~/.claude/settings.local.json`, which is never projected. Otherwise it is real work → re-add it to `~/.claude/settings.json` and push it up. On `--repo-to-user --stage` the script also writes `settingsBackup` (a timestamped copy of the pre-overwrite settings.json); cite that path when registrations were dropped.</rule>
<rule id="use-companion-script">Use `~/.cursor/skills/convention-sync/scripts/convention-sync.sh` for diffing and syncing. Do NOT manually diff or copy files.</rule>
<rule id="dry-run-first">Always run without `--stage` first to show the summary. Only stage/commit after user confirms.</rule>
<rule id="no-script-bypass">If the script fails, report the error and STOP.</rule>
<rule id="readme-is-source">`~/.cursor/README.md` is the canonical local documentation source. The sync script mirrors it to the repo root README, which is the repo's front page.</rule>
<rule id="claude-compat">Every run ensures `~/.claude/skills` symlinks to `~/.cursor/skills` and regenerates `~/.claude/CLAUDE.md` from `alwaysApply: true` rules. This enables OpenCode and Claude Code to discover skills and rules without separate config.</rule>
<rule id="target-repo-resolution">For user-to-repo sync, target the `edge-dev-agents` checkout. Do NOT assume the current repo is correct just because it contains a `.cursor/` folder. Let the companion script resolve and validate the repo path.</rule>
</rules>

<step id="1" name="Detect changes">
Use the companion script's default repo resolution first. It targets the `edge-dev-agents` checkout and fails if the resolved or provided repo is not actually `edge-dev-agents`.

Run the sync script in dry-run mode:

```bash
~/.cursor/skills/convention-sync/scripts/convention-sync.sh
```

Parse the JSON output and extract `repoDir`; reuse it for subsequent git commands. If BOTH `total` and `extraTotal` are 0, report "Everything is in sync" and stop.
</step>

<step id="2" name="Present summary">
Show the user a concise summary including origin lag and any cross-machine warnings:

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
⚠️  Hook registrations this sync would destroy:                   (only if droppedHooks non-empty)
    - [PreToolUse] <matcher> -> <command>

Commit and push to main? [y/N]
```

If `ignored` is empty, omit the Ignored line. If `originAhead` is 0, omit that warning. If `warnings` is empty, omit that block. If `droppedHooks` is empty, omit that block; if non-empty, resolve every entry per `hooks-projection-loss` BEFORE staging (it blocks a user-to-repo stage anyway).

**Warning kinds:**
- `stale-local`: a modified file's most-recent upstream commit timestamp is newer than the local file's mtime — your local was likely written from an older copy.
- `deletion`: you'd be deleting a path that exists in the repo. Always confirm.
- `re-adding-deleted`: a "new" file locally that was deleted upstream after your local was last written.

If `originAhead > 0`, advise the user to `cd <repo-dir> && git pull --rebase` before re-running. Do NOT proceed to step 3 — the script will refuse to stage anyway.

If the user provided a commit message in their prompt, still surface warnings; only skip the y/N confirmation when there are no warnings.
</step>

<step id="3" name="Stage, commit, push">
Run the script with `--commit`:

```bash
~/.cursor/skills/convention-sync/scripts/convention-sync.sh <repo-dir> --commit -m "<message>"
```

Then push (HEAD is `main`, enforced by the branch guard):

```bash
cd <repo-dir> && git push origin HEAD
```

Do NOT run `gh pr edit`: there is no sync PR anymore, and a bare `gh pr edit` targets whatever PR the current branch happens to have (this overwrote the merged PR #3's body on 2026-08-26).
</step>

<edge-cases>
<case name="Reverse sync (repo → user)">If the user says "pull from repo" or "update my local", run with `--repo-to-user --stage`. This restores BOTH `~/.cursor` AND the portable extra trees (agent-watcher, memory-shared, claude-workflows, bin) from the repo, and never deletes home-local state/secret files. No git operations needed. SELF-UPDATE: the restore first compares the repo's `convention-sync.sh` against the installed one; if they differ it installs the repo copy and re-execs, so a tree-list change added upstream applies in the SAME run — never advise running the restore twice for script-version skew. This is also the de-stale step to run before a user-to-repo sync that was blocked by `deletion`/`stale-local` warnings. Newer-local protection: files whose LOCAL copy was modified after the repo file's last commit are NOT copied or deleted — they're reported in the JSON `skippedNewer` array (this protects unpushed local work; the comparison is local mtime vs repo commit time, so a fresh `git pull` can't defeat it). Surface `skippedNewer` to the user; `--force` disables the protection. `extra`/`extraTotal` report what the restore actually transferred, so a run that rewrites the whole agent-watcher tree says so. Hook registrations only this machine had are destroyed by the restore and listed in `droppedHooks` — handle them per `hooks-projection-loss`.</case>
<case name="Current repo has a .cursor folder but is not edge-dev-agents">Do not sync into that repo. Fall back to `~/git/edge-dev-agents` or ask for the correct repo path.</case>
<case name="Dry-run resolved a repo path">Reuse the `repoDir` value from the script's JSON output for the commit run and push steps.</case>
<case name="Selective sync">To permanently exclude files, add glob patterns to `.syncignore` (one per line, `#` comments). The script reads `.syncignore` from the REPO (`<repo>/.cursor/.syncignore`) as the canonical source so every machine honors the same excludes, falling back to `~/.cursor/.syncignore` only if the repo lacks one. The script skips matching entries and reports them in the `ignored` array. To exclude ad-hoc, remove files from staging with `git reset HEAD .cursor/<file>` before committing.</case>
<case name="README migration">During migration, the dry-run may report deletion of `.cursor/README.md` in the repo copy. That is expected: the repo should keep only the root `README.md`.</case>
<case name="No README">If `~/.cursor/README.md` doesn't exist, warn the user — the repo front page would go stale.</case>
<case name="origin is ahead (originAhead > 0)">The script auto-fetches and detects this. Surface the count to the user, instruct them to `cd <repo-dir> && git pull --rebase`, then re-run convention-sync. Do not attempt --stage/--commit before pulling — the script will exit non-zero.</case>
<case name="Wrong branch (non-default)">The script refuses `--stage`/`--commit` when HEAD is not the repo default branch — a shared checkout parked on another session's feature branch would ride the sync onto that branch and its PR. Checkout the default branch and re-run. Override with `--force-branch` ONLY if intentionally committing to a different branch.</case>
<case name="Blocking warnings (deletion / stale-local / re-adding-deleted)">The script HARD-BLOCKS staging on these — the sync would delete or revert canonical files because this machine is stale/incomplete (covers `~/.cursor` AND the extra trees). Default action: run `--repo-to-user --stage` to pull the canonical state down first, then re-run user-to-repo to push your genuine additions. Only after the user reviews the specific files and explicitly intends to overwrite upstream should you re-run with `--force`. Never pass `--force` reflexively.</case>
<case name="Fetch fails (offline)">If `git fetch origin` fails the script proceeds with `originAhead=0`. The cross-machine safety check is best-effort; on a flaky network the user should re-run when connectivity is back if cross-machine sync matters.</case>
</edge-cases>
