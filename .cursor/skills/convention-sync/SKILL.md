---
name: convention-sync
description: Sync cursor files between ~/.cursor/ and the edge-dev-agents repo, commit, push, and update PR description. Use when the user wants to sync conventions.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Sync cursor files between `~/.cursor/` and the `edge-dev-agents` repo, commit, push, and update PR description from the synced repo root README. Also maintains cross-tool compatibility: symlinks `~/.claude/skills` → `~/.cursor/skills` and generates `~/.claude/CLAUDE.md` from always-apply rules.</goal>

<rules>
<rule id="local-is-canonical">`~/.cursor/` is the canonical source. Edits happen locally; the repo is the distribution copy. Default direction is `user-to-repo`. Use `--repo-to-user` only for onboarding or pulling changes authored by others.</rule>
<rule id="cross-machine-safety">The script auto-fetches origin on every run and emits two safety signals: `originAhead` (commits remote has past local HEAD) and `warnings` (per-file conflicts where a local copy looks stale relative to upstream). On `--stage`/`--commit` the script aborts if `originAhead > 0`. Always present `warnings` to the user as part of the dry-run summary so they can decide whether to overwrite.</rule>
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

Use the resolved repo path from the script for subsequent git and PR commands. If the script reports `total` as 0, report "Everything is in sync" and stop.
</step>

<step id="2" name="Present summary">
Show the user a concise summary including PR update status, origin lag, and any cross-machine warnings:

```
Sync summary (user → repo):
  New: file1, file2
  Modified: file3, file4
  Deleted: file5
  Ignored: file6, file7 (via .syncignore)

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
<case name="Reverse sync (repo → user)">If the user says "pull from repo" or "update my local", run with `--repo-to-user --stage` instead. No git operations needed.</case>
<case name="Current repo has a .cursor folder but is not edge-dev-agents">Do not sync into that repo. Fall back to `~/git/edge-dev-agents` or ask for the correct repo path.</case>
<case name="Dry-run resolved a repo path">Reuse the `repoDir` value from the script's JSON output for the PR query, commit run, push, and PR edit steps.</case>
<case name="Selective sync">To permanently exclude files, add glob patterns to `~/.cursor/.syncignore` (one per line, `#` comments). The script skips matching entries and reports them in the `ignored` array. To exclude ad-hoc, remove files from staging with `git reset HEAD .cursor/<file>` before committing.</case>
<case name="README migration">During migration, the dry-run may report deletion of `.cursor/README.md` in the repo copy. That is expected: the repo should keep only the root `README.md`.</case>
<case name="No README">If `~/.cursor/README.md` doesn't exist, skip PR description update and warn the user.</case>
<case name="origin is ahead (originAhead > 0)">The script auto-fetches and detects this. Surface the count to the user, instruct them to `cd <repo-dir> && git pull --rebase`, then re-run convention-sync. Do not attempt --stage/--commit before pulling — the script will exit non-zero.</case>
<case name="Warnings on user-confirmed overwrite">If the user reviews the warnings and explicitly chooses to overwrite (e.g., they know the upstream change is something they're intentionally replacing), proceed normally. Warnings are advisory; the script does not block the commit on them.</case>
<case name="Fetch fails (offline)">If `git fetch origin` fails the script proceeds with `originAhead=0`. The cross-machine safety check is best-effort; on a flaky network the user should re-run when connectivity is back if cross-machine sync matters.</case>
</edge-cases>
