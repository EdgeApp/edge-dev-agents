---
name: convention-sync
description: Sync cursor files between ~/.cursor/ and the edge-dev-agents repo, commit, and push to main. Use when the user wants to sync conventions.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Sync the canonical home setup (`~/.cursor/` skills/rules/scripts + the agent orchestration system + shared Claude memories) into the `edge-dev-agents` repo, commit, and push directly to `main` (the perpetual sync PR is retired; PR #1 merged 2026-08-26). Also maintains cross-tool compatibility: symlinks `~/.claude/skills` → `~/.cursor/skills` and generates `~/.claude/CLAUDE.md` from always-apply rules. The repo is the distribution copy a second machine bootstraps from.</goal>

<rules>
<rule id="default-branch-only">Every run works on the repo default branch (`main`) unless `--branch <name>` names another for THAT run. The script checks the branch out itself before any diff, restore or commit (creating a `--branch` that does not exist from `origin/main`), refuses to switch away from uncommitted work, and measures `originAhead` against `origin/<branch>`. `--branch` never persists: the next run without it is back on main, so no machine can get parked on a side branch again. Pass it only when the operator says the work stays on a branch for a while; announce and notify as usual, naming the branch.</rule>
<rule id="local-is-canonical">`~/.cursor/` is the canonical source. Edits happen locally; the repo is the distribution copy. Default direction is `user-to-repo`. Use `--repo-to-user` only for onboarding or pulling changes authored by others.</rule>
<rule id="extra-trees">Beyond `~/.cursor`, the script also mirrors portable "extra trees" into the repo so a second Mac can be reproduced: the orchestration system (`~/.config/agent-watcher` → repo `agent-watcher/`), shared Claude memories (`~/.claude/memory-shared` → repo `memory-shared/`), Workflow-tool scripts (`~/.claude/workflows` → repo `claude-workflows/`, e.g. code-review-sonnet.js), and the memory link helper (`~/.claude/link-shared-memory.sh` → repo `bin/`), plus a PROJECTION of Claude hook registrations: the `.hooks` key of `~/.claude/settings.json` → repo `claude-settings/hooks.json` (user→repo exports the key; repo→user and `bootstrap.sh` merge it back replacing ONLY `.hooks` — model/theme/etc stay machine-local; an empty/missing local hooks block is never exported, so an unconfigured machine cannot blank the canonical registrations; a PARTIAL block still can, which is what `hooks-projection-loss` guards). Hook SCRIPTS ship in the agent-watcher tree; without this projection they would be installed but never fire. Secrets and machine-local state are EXCLUDED by hardcoded rsync excludes in the script (`credentials.json`, `*.log`, `*.state`, `pool.json`, `slots.json`, `watchdog-state.json`, `oom-repro/forensics`, `oom-repro/logs`); `credentials.example.json` is committed as a fill-in template. These appear in the JSON under `extra`/`extraTotal`. NEVER hand-add secret/state files to the repo. A fresh machine reproduces everything by cloning the repo and running `./bootstrap.sh` (installs the trees into home, seeds credentials from the example, links skills + shared memory). Auto-memory (`~/.claude/projects/<project>/memory/`) is machine-local per Anthropic docs and is intentionally NOT synced.</rule>
<rule id="authored-only-skills">`skills/` is authored-only: the script pushes a skill only when the repo already carries it or its SKILL.md claims an author the repo distributes, and it lists everything else in `excludedSkills` with a reason and a file count. Surface that list in the summary every run and judge each entry. A third-party or unknown skill belongs there: leave it, and do NOT add it to `.syncignore` (that only hides it from the report). One of the operator's OWN skills in the list means its SKILL.md is missing `metadata.author`: add the marker to the skill, never a flag or an ignore pattern. An operator skill MISSING from the repo and from the list is the state to escalate: it means the gate let something through unexamined.</rule>
<rule id="no-secret-bypass">`secretFindings` names a file the sync refuses to copy. Treat it as a live credential: report the path to the user and have the value removed or moved out of the synced trees. Add the path to `.syncignore` ONLY after the user confirms it is a false positive, and never hand-copy a refused file into the repo.</rule>
<rule id="cross-machine-safety">The script auto-fetches origin and HARD-BLOCKS (exit non-zero) a `--stage`/`--commit` (user-to-repo) on any of: (a) `originAhead > 0` — remote has commits you lack; pull first. (b) Uncommitted changes on a non-default branch — the script switches a clean checkout to the default branch itself (`default-branch-only`) and refuses to switch away from dirty work. (c) Blocking `warnings` of kind `deletion`, `stale-local`, or `re-adding-deleted` — the sync would delete or revert canonical files, in `~/.cursor` OR the portable extra trees (override: `--force`). (d) Non-empty `droppedHooks` — the export would blank canonical hook registrations for every machine (override: `--force`); see `hooks-projection-loss`. Warnings are NO LONGER advisory. When blocked by (c), the right fix is almost always `--repo-to-user --stage` to de-stale this machine first, THEN re-run user-to-repo to push. The dry-run summary computes all of these by content hash (not mtime), so timestamp churn no longer inflates the diff. Always surface `warnings` in the summary.</rule>
<rule id="hooks-projection-loss">The hooks projection replaces the WHOLE `.hooks` block in whichever direction it runs, so registrations present only on the receiving side are destroyed and their `matcher` values are unrecoverable. The script reports these in `droppedHooks` (event + matcher + command) in BOTH directions and on dry runs, so the loss is visible BEFORE it happens. Never wave this away: surface every entry to the user. A dropped hook is machine-specific (hardcoded device ids, absolute paths outside the synced trees) → it belongs in `~/.claude/settings.local.json`, which is never projected. Otherwise it is real work → re-add it to `~/.claude/settings.json` and push it up. On `--repo-to-user --stage` the script also writes `settingsBackup` (a timestamped copy of the pre-overwrite settings.json); cite that path when registrations were dropped.</rule>
<rule id="use-companion-script">Use `~/.cursor/skills/convention-sync/scripts/convention-sync.sh` for diffing and syncing. Do NOT manually diff or copy files.</rule>
<rule id="no-silent-ride-along">A sync carries whatever is newer, which routinely includes files OTHER sessions wrote. The syncing session OWNS the whole commit: every change is read, understood and described by what it does, exactly as if this session had written it. Attribution (`scripts/sync-attribution.sh --from-sync <repo> --self <your-transcript-uuid>`; your uuid is the directory name of your scratchpad path) is the INTERNAL worklist for that: it says whose diffs you have not seen yet. Read each of those diffs. When a diff does not explain itself, SendMessage the `live:` session and ask what the change does and whether it is finished, BEFORE committing; an unfinished file is held out, not shipped. After the push, SendMessage each `live:` session that its work shipped, with the sha, so it can close the thread. A file that comes back `unattributed` still gets read and described; ask the operator only when its purpose cannot be worked out from the diff.</rule>
<rule id="one-author-outward">Everything outward reads as one author describing one body of work: the commit message, the Slack announcement and the README. Group the commit body by SUBJECT (what changed and why), never by who wrote it. No session ids, tmux names, "carries work from other sessions" block, or "another session's" phrasing on any outward surface. Session coordination stays in SendMessage and in the chat summary to the operator.</rule>
<rule id="readme-current">The README ships with the change it documents, in the SAME commit, for every change in the sync regardless of which session made it. Before committing, walk the dry run's file list and bring `~/.cursor/README.md` (the repo front page) and `~/.config/agent-watcher/hooks/README.md` (the hook registry) current: a new, removed, renamed or re-scoped hook, script, skill, flag, config key, eval dimension or synced tree gets its row or paragraph added or corrected, and a count or range the change moved (dimension ranges, hook totals) is updated. `scripts/readme-gaps.sh <repo-dir>` lists the mechanical misses (a file the sync adds or deletes whose name the READMEs do not carry, or still carry); its exit 1 blocks the commit until each line is fixed or is a file that genuinely needs no mention (a test, a fixture, a library documented under its caller). Behavior changes inside an already-listed file are the judgment half: re-read its row against the diff.</rule>
<rule id="announce-every-sync">Every pushed sync is announced in Slack, in `#edge-dev-agents`. Compose with `scripts/sync-slack-message.sh <sha>` and post the output with `slack_send_message` (the operator has standing approval for this one message, so it is a direct send, not a draft, per the slack skill's `draft-first-for-unreviewed` carve-out). The script passes the commit title and body through verbatim with the title bolded and linked to the commit; do NOT re-summarize, re-order, or add commentary. Announce AFTER the push: the script refuses a commit that is not yet on a remote branch, because the link would 404. Relay the returned `message_link` per the slack skill's `relay-message-link`.</rule>
<rule id="announcer-stays-local">`scripts/sync-attribution.sh` and `scripts/sync-slack-message.sh` are machine-local by decision and are excluded in `.syncignore`. They will be ABSENT on any other machine, so each step that calls them checks first and skips cleanly when missing. Never "fix" their absence by copying them into the repo.</rule>
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

Then attribute the changes per `no-silent-ride-along` (skip when the script is absent, per `announcer-stays-local`):

```bash
[ -x ~/.cursor/skills/convention-sync/scripts/sync-attribution.sh ] && \
  ~/.cursor/skills/convention-sync/scripts/sync-attribution.sh --from-sync <repo-dir> --self <your-transcript-uuid>
```

It walks the transcript tree when the write ledger does not cover a file, so allow it 1-2 minutes on a large sync. Its output is a worklist per `no-silent-ride-along` (diffs to read, sessions to ask, sessions to notify after the push), never text for the commit.

Then read every diff the sync carries (`diff <(git -C <repo-dir> show HEAD:<repo-path>) <home-file>`), ask the live authors where a diff does not explain itself, and bring the READMEs current per `readme-current`:

```bash
~/.cursor/skills/convention-sync/scripts/readme-gaps.sh <repo-dir>
```
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
  Not the operator's, excluded: skills/foo (N files): <reason>          (from `excludedSkills`; only if non-empty)

⛔ Refusing to stage, these look like credentials:                  (only if secretFindings non-empty)
    - skills/foo/scripts/key.txt (key-shaped blob in a key-named file)

⚠️  origin/<branch> is N commit(s) ahead — pull before staging.   (only if originAhead > 0)
⚠️  Possible overwrites of upstream work:                         (only if warnings array non-empty)
    - file3 (stale-local) — last upstream commit: <hash> <subject>
    - file8 (deletion) — last upstream commit: <hash> <subject>
⚠️  Hook registrations this sync would destroy:                   (only if droppedHooks non-empty)
    - [PreToolUse] <matcher> -> <command>

Commit and push to main? [y/N]
```

If `ignored` is empty, omit the Ignored line. If `excludedSkills` is empty, omit that line; otherwise judge every entry per `authored-only-skills` before staging. If `secretFindings` is non-empty, stop at the summary and resolve it per `no-secret-bypass` (the stage exits non-zero anyway, with no override flag). If `originAhead` is 0, omit that warning. If `warnings` is empty, omit that block. If `droppedHooks` is empty, omit that block; if non-empty, resolve every entry per `hooks-projection-loss` BEFORE staging (it blocks a user-to-repo stage anyway).

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

Write the message per `one-author-outward`: a subject under 50 characters, then a body grouped by subject that says what each change does and why, covering EVERY file in the sync. Pass it from a file (`-m "$(cat <file>)"`), since a long message inline trips command-text hooks.

Do NOT run `gh pr edit`: there is no sync PR anymore, and a bare `gh pr edit` targets whatever PR the current branch happens to have (this overwrote the merged PR #3's body on 2026-08-26).

</step>

<step id="4" name="Announce and close the loop">
Both actions here are OUTWARD and happen only after the push succeeded. Skip either one whose script is absent, per `announcer-stays-local`.

1. **Slack**, per `announce-every-sync`:

```bash
~/.cursor/skills/convention-sync/scripts/sync-slack-message.sh <sha>
```

Post that output verbatim to `#edge-dev-agents` with `slack_send_message`, then relay the returned `message_link` to the operator.

2. **The other sessions**, per `no-silent-ride-along`. For each attribution row showing `live: <tmux>`, resolve its addressable name with `ListAgents` (match the tmux name) and SendMessage it: what shipped, the commit sha, and that its thread can close. One message per session, not per file. Rows showing `(ended)` get nothing. This is the only place other sessions are named.

If the Slack send is denied by slack-prose-gate, the lint findings describe text that came from the COMMIT MESSAGE, so the commit prose is what violated the standard. Report it to the operator rather than rewording only the Slack copy: the two should not diverge.
</step>

<edge-cases>
<case name="Reverse sync (repo → user)">If the user says "pull from repo" or "update my local", run with `--repo-to-user --stage`. This restores BOTH `~/.cursor` AND the portable extra trees (agent-watcher, memory-shared, claude-workflows, bin) from the repo, and never deletes home-local state/secret files. No git operations needed. SELF-UPDATE: the restore first compares the repo's `convention-sync.sh` against the installed one; if they differ it installs the repo copy and re-execs, so a tree-list change added upstream applies in the SAME run — never advise running the restore twice for script-version skew. This is also the de-stale step to run before a user-to-repo sync that was blocked by `deletion`/`stale-local` warnings. Newer-local protection: files whose LOCAL copy was modified after the repo file's last commit are NOT copied or deleted — they're reported in the JSON `skippedNewer` array (this protects unpushed local work; the comparison is local mtime vs repo commit time, so a fresh `git pull` can't defeat it). Surface `skippedNewer` to the user; `--force` disables the protection. `extra`/`extraTotal` report what the restore actually transferred, so a run that rewrites the whole agent-watcher tree says so. Hook registrations only this machine had are destroyed by the restore and listed in `droppedHooks` — handle them per `hooks-projection-loss`.</case>
<case name="Current repo has a .cursor folder but is not edge-dev-agents">Do not sync into that repo. Fall back to `~/git/edge-dev-agents` or ask for the correct repo path.</case>
<case name="Dry-run resolved a repo path">Reuse the `repoDir` value from the script's JSON output for the commit run and push steps.</case>
<case name="Selective sync">To permanently exclude files, add glob patterns to `.syncignore` (one per line, `#` comments). The script reads `.syncignore` from the REPO (`<repo>/.cursor/.syncignore`) as the canonical source so every machine honors the same excludes, falling back to `~/.cursor/.syncignore` only if the repo lacks one. The script skips matching entries and reports them in the `ignored` array. To exclude ad-hoc, remove files from staging with `git reset HEAD .cursor/<file>` before committing. `.syncignore` is for paths that ARE the operator's but should stay local; third-party skills need no entry (see `authored-only-skills`).</case>
<case name="A skill of the operator's shows up in excludedSkills">Its SKILL.md has no `metadata.author`, or an author the repo has never distributed. Add
```yaml
metadata:
  author: <the operator's id, as used by the repo's tracked skills>
```
to that skill's frontmatter and re-run the dry run: the entry should move out of `excludedSkills` and into `new`. Do not reach for `--force` or `.syncignore`; neither affects this gate.</case>
<case name="README migration">During migration, the dry-run may report deletion of `.cursor/README.md` in the repo copy. That is expected: the repo should keep only the root `README.md`.</case>
<case name="No README">If `~/.cursor/README.md` doesn't exist, warn the user — the repo front page would go stale.</case>
<case name="origin is ahead (originAhead > 0)">The script auto-fetches and detects this. Surface the count to the user, instruct them to `cd <repo-dir> && git pull --rebase`, then re-run convention-sync. Do not attempt --stage/--commit before pulling — the script will exit non-zero.</case>
<case name="Checkout on another branch">The script puts the checkout on the repo default branch itself (both directions, dry runs included) when the tree is clean, and prints `switched … to main`. A dirty tree on another branch is an error naming the branch: commit or stash there, then re-run. There is no override; per-machine work branches are gone (the `jon` branch is archived as tag `archive/jon-2026-09-04`).</case>
<case name="Blocking warnings (deletion / stale-local / re-adding-deleted)">The script HARD-BLOCKS staging on these — the sync would delete or revert canonical files because this machine is stale/incomplete (covers `~/.cursor` AND the extra trees). Default action: run `--repo-to-user --stage` to pull the canonical state down first, then re-run user-to-repo to push your genuine additions. Only after the user reviews the specific files and explicitly intends to overwrite upstream should you re-run with `--force`. Never pass `--force` reflexively.</case>
<case name="Fetch fails (offline)">If `git fetch origin` fails the script proceeds with `originAhead=0`. The cross-machine safety check is best-effort; on a flaky network the user should re-run when connectivity is back if cross-machine sync matters.</case>
</edge-cases>
