---
name: pr-land
description: Land approved PRs by autosquashing fixups, rebasing onto the default upstream branch, and merging. Use when the user wants to merge/land pull requests.
compatibility: Requires git, gh, node, jq. ASANA_TOKEN for Asana updates.
metadata:
  author: j0ntz
---

<goal>Land approved PRs by autosquashing fixups, rebasing onto the default upstream branch, and merging. Accepts repo names, explicit PR references, or Asana task URLs.</goal>

<usage>
```
/pr-land                                          # Asana "PR Pipeline" section, incomplete tasks assigned to me
/pr-land --branch-scan                            # All EdgeApp repos with $GIT_BRANCH_PREFIX/* PRs (legacy)
/pr-land edge-react-gui                           # Specific repo (branch-prefix scan)
/pr-land edge-react-gui edge-core-js              # Multiple repos
/pr-land edge-react-gui#123                       # Specific PR (shorthand)
/pr-land https://github.com/EdgeApp/edge-react-gui/pull/123  # Specific PR (URL)
/pr-land https://app.asana.com/0/1234/5678        # Asana task → resolves linked PRs
/pr-land https://app.asana.com/.../task/<parent>  # Parent task → walks subtasks
/pr-land edge-react-gui#123 edge-core-js          # Mix: explicit PR + repo scan
```

Arguments are classified automatically:
- **No args** → queries the configured Asana "PR Pipeline" section (GID hardcoded in `pr-land-discover.sh`), filters to incomplete tasks assigned to the current Asana user (resolved from `ASANA_TOKEN` via `~/.cursor/skills/asana-whoami.sh`), and walks each task's attachments + subtasks for GitHub PR links. Tasks with no PR link are reported in `errors` but do not block.
- **`--branch-scan`** → legacy behavior: scans all EdgeApp repos for `$GIT_BRANCH_PREFIX/*` PRs.
- **Repo names** → branch-prefix scan, limited to the named repos.
- **PR URLs / shorthand** (`repo#N`) → fetched directly, no branch-prefix filter.
- **Asana task URLs** → resolved to linked GitHub PRs via Asana API (requires `ASANA_TOKEN`). Parent tasks are walked: each subtask's attachments are scanned for PRs; subtasks without a linked PR are skipped silently (e.g. a verification-only subtask).
</usage>

<rules description="Non-negotiable constraints.">
<rule id="scripts-only">All GitHub API calls go through companion scripts that use `gh` CLI internally. Do NOT call `gh` or `curl` directly for GitHub operations — use the scripts.</rule>
<rule id="gh-auth">If a script exits code 2 with `PROMPT_GH_AUTH`, prompt the user to run `gh auth login`.</rule>
<rule id="code-conflicts">Code conflicts → Skip PR. Abort the rebase to leave the repo clean, continue with remaining PRs. Report all skipped PRs at the end.</rule>
<rule id="stale-prs">Stale PRs → Skip and report. Old PRs with multiple conflicts should be skipped like code conflicts. Don't block the flow.</rule>
<rule id="changelog-conflicts">CHANGELOG conflicts (any section, including staging): Agent resolves semantically, scripts verify the result.</rule>
<rule id="verification">Verification is mandatory. Built into scripts, no bypass.</rule>
<rule id="no-force-push">Do NOT force-push without explicit user confirmation.</rule>
<rule id="no-editors">Never open editors. All git operations must be non-interactive: `GIT_EDITOR=true` for commit messages, `GIT_SEQUENCE_EDITOR=:` for rebase todo lists.</rule>
<rule id="unexpected-exit">Unexpected exit codes → STOP immediately. If any script returns an exit code not documented in this file, STOP and report to user. Do NOT attempt to interpret, retry, or work around unexpected errors.</rule>
<rule id="sequential-rebase">Sequential merging requires rebase. Each subsequent PR MUST be rebased onto the updated base branch after the previous merge.</rule>
<rule id="publish-gating">Don't publish if outstanding PRs remain. Only offer to publish a repo when ALL approved PRs for that repo are merged. If any were skipped or held back, do NOT publish that repo.</rule>
<rule id="npm-otp-required">`npm publish` MUST be run with `--otp=<code>` supplied by the user. Do NOT attempt `npm publish` without an OTP. Do NOT run `npm login` — auth comes from the `_authToken` in `~/.npmrc`. If `npm whoami` fails before the first publish, STOP and report; do not try to re-authenticate.</rule>
<rule id="defer-gui">If the discovered PR set contains BOTH `edge-react-gui` PRs and at least one non-GUI PR, all GUI PRs are DEFERRED — they do NOT enter steps 3-7 (prepare/push/merge/publish/upgrade-dep). GUI PRs are processed in step 8 (new) after step 7's dep upgrades land on develop. If the batch is pure GUI or pure non-GUI, no deferral — proceed as normal.</rule>
<rule id="asana-last">Asana updates are LAST. Do NOT update Asana tasks until ALL merges, publishes, and GUI dependency upgrades are complete. Only update status for PRs that are fully landed (merged, and if non-GUI: published + GUI deps updated).</rule>
</rules>

<scripts description="Companion scripts and their expected exit codes.">

| Script | Purpose |
|--------|---------|
| `pr-land-discover.sh` | Discover PRs and approval status |
| `pr-land-comments.sh` | Check for recent unaddressed feedback (inline threads, review bodies, top-level comments) |
| `git-branch-ops.sh` | Shared autosquash / push helper for explicit git branch actions |
| `pr-land-prepare.sh` | Rebase + conflict detection + verification |
| `verify-repo.sh` | Verification (CHANGELOG + code; lint scoped to changed files when `--base` given) |
| `pr-land-merge.sh` | Rebase + verify + merge via GitHub API |
| `pr-land-publish.sh` | Version bump, changelog update, commit + tag (no push) |
| `staging-cherry-pick.sh` | Cherry-pick merged PR commits onto staging (see `/staging-cherry-pick` skill) |
| `asana-task-update.sh` | Update linked Asana tasks after merge |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `pr-land-discover.sh` | Success | Error | Auth needed | - | - |
| `pr-land-comments.sh` | Success | Error | - | - | - |
| `git-branch-ops.sh` | Success | Error | - | - | - |
| `pr-land-prepare.sh` | Ready | All failed | - | - | - |
| `verify-repo.sh` | Pass | Code fail | CHANGELOG fail | - | - |
| `pr-land-merge.sh` | Merged | Verify fail | - | - | CHANGELOG conflict |
| `staging-cherry-pick.sh` | All cherry-picked | Error | Auth needed | CHANGELOG conflict | - |
| `pr-land-publish.sh` | Ready (needs push) | Verify fail | No unreleased | - | - |
| `asana-task-update.sh` | Success | Error | Needs user input | - | - |

**Any exit code not in this table = STOP immediately and report to user.**
</scripts>

<step id="1" name="Discovery">
ONE tool call:

```bash
~/.cursor/skills/pr-land/scripts/pr-land-discover.sh [args...]
```

Args can be repo names, PR URLs, PR shorthand (`repo#N`), Asana task URLs (mixed freely), or `--branch-scan`.
No args = pull incomplete tasks assigned to me from the Asana "PR Pipeline" section and walk each for PR attachments + subtask PR attachments. Use `--branch-scan` for the legacy "scan all EdgeApp repos for `$GIT_BRANCH_PREFIX/*` PRs" behavior.

Returns JSON: `{ "prs": [...], "errors": [...] }`. Each PR has `repo`, `prNumber`, `branch`, `title`, `approved`, `changesRequested`, `reviewers`. Errors include Asana resolution failures or PR fetch failures.

<sub-step name="Split by type">
After discovery, partition `prs` into `nonGuiPrs` (`repo !== "edge-react-gui"`) and `guiPrs` (`repo === "edge-react-gui"`).

1. If BOTH arrays are non-empty → mixed-batch path per `defer-gui`: only `nonGuiPrs` flow through steps 3-7. Tell the user: `Deferring <N> GUI PR(s) until after non-GUI deps are published and upgraded on develop.`
2. If only one array is non-empty → no deferral; all PRs flow through steps 3-7 normally.
</sub-step>
</step>

<step id="2" name="Comment Check and Addressing">
```bash
echo '[{"repo":"...","prNumber":123,"branch":"<prefix>/..."}]' | ~/.cursor/skills/pr-land/scripts/pr-land-comments.sh
```

Returns PRs with unaddressed feedback posted after the last commit. The script checks **three sources** and includes the IDs needed to reply or mark them addressed:

1. **Unresolved inline review threads** — threads where `isResolved: false` with comments newer than last commit
2. **Review bodies** — the latest review from each non-author/non-bot reviewer, if it has a non-empty body newer than last commit (catches feedback written in the approve/reject dialog, regardless of review state)
3. **Top-level PR comments** — non-author/non-bot comments newer than last commit

Items previously marked with `<!-- addressed:review:ID -->` or `<!-- addressed:comment:ID -->` markers are automatically excluded.

<sub-step name="Comment handling">
1. AI/bot comments: Already filtered out by the script.
2. Human reviewer comments are **blocking until the user decides how to handle them**. Use the `approved` and `changesRequested` fields from discovery to determine the path:
   1. **`changesRequested: true`**:
      - Treat the feedback as re-review-blocking
      - If the user wants it addressed now, make the fix as a visible fixup commit, push it, reply/resolve the feedback, and **remove the PR from the merge set** so it can go back for review
      - If the user does not want to address it now, leave the PR out of the merge set and report it as blocked by requested changes
   2. **`approved: true` and `changesRequested: false`**:
      - Present the recent human comments to the user and ask whether to **ignore** them or **address** them before continuing
      - If the user chooses **ignore**: leave the code unchanged and continue the landing workflow
      - If the user chooses **address**:
        1. Read the comment and understand the requested change
        2. Make the fix as a fixup commit: `~/.cursor/skills/lint-commit.sh --fixup <hash> [files...]`
        3. Push the updated branch with `~/.cursor/skills/git-branch-ops.sh push --force-with-lease --branch <branch>`. Use `--force-with-lease` because `lint-commit.sh --fixup` may autosquash immediately.
        4. Reply on the PR item explaining what was fixed (1 sentence, factual):
           - **Inline** (`type: "inline"`): Use `commentId` and `threadId` from `pr-land-comments.sh` output with `~/.cursor/skills/pr-address/scripts/pr-address.sh reply ...` followed by `resolve-thread ...`
           - **Review body** (`type: "review-body"`): Use `reviewId` with `~/.cursor/skills/pr-address/scripts/pr-address.sh mark-addressed --type review ...`
           - **Top-level** (`type: "top-level"`): Use `commentId` with `~/.cursor/skills/pr-address/scripts/pr-address.sh mark-addressed --type comment ...`
        5. Continue the landing workflow immediately — do **not** remove the PR from the merge set solely because an already-approved reviewer left optional comments
   3. Continue with remaining PRs that have no outstanding blocking comment decision
   4. Report ignored comments, addressed-and-continued PRs, and set-aside PRs at the end of the workflow

**Do NOT block the rest of the flow** for PRs with comments.
</sub-step>
</step>

<step id="3" name="Prepare Branches">
When the `defer-gui` rule applies (mixed batch), feed only `nonGuiPrs` into `pr-land-prepare.sh`. GUI PRs enter prepare in step 8.

ONE tool call per batch:

```bash
echo '[{"repo":"...","branch":"<prefix>/feature"}]' | ~/.cursor/skills/pr-land/scripts/pr-land-prepare.sh
```

The prepare script handles: clone/checkout, autosquash fixups, rebase onto upstream, conflict detection, and verification.

**Exit codes:**
- `0` = At least one PR ready to push (skipped PRs reported in JSON output)
- `1` = All PRs failed (verification or other errors, none ready)

<sub-step name="On code conflict">PR is skipped and reported in the `skipped` array. Rebase is aborted to leave repo clean. Other PRs continue.</sub-step>

<sub-step name="On CHANGELOG conflict">Agent resolves semantically (upstream entries first, then ours), then re-runs prepare.</sub-step>

<sub-step name="On CHANGELOG placement warning">
If any entry in `prepared[i].placementWarnings` is non-empty, the PR added CHANGELOG entries under a DATED released heading (e.g. `## 4.46.0 (2026-03-20)`) instead of `## Unreleased (develop)` or `## X.Y.Z (staging)`. This usually means the author placed the entry under the then-current released version but the PR actually targets a later unreleased version.

Do NOT push (step 4) until the user decides. For each warning, show the user the `line`, `section`, and `text`, then ask exactly:
```
CHANGELOG entry under released section "<section>":
  <text>
(a) leave as-is  (b) move to ## Unreleased (develop)  (c) move to ## X.Y.Z (staging)
```

1. If user picks **(a)**: continue to step 4.
2. If user picks **(b)** or **(c)**: use the Edit tool to move the offending line(s) into the target section, preserving `added → changed → deprecated → fixed → removed → security` ordering within that section. Then stage and amend the top commit on the branch:
   ```bash
   git -C <repoDir> add CHANGELOG.md && GIT_EDITOR=true git -C <repoDir> commit --amend --no-edit
   ```
   Re-run `pr-land-prepare.sh` to re-verify before pushing. Do NOT bypass precommit hooks.
</sub-step>
</step>

<step id="4" name="Push">
After prepare succeeds, push with `--force-with-lease`.
Use:

```bash
~/.cursor/skills/git-branch-ops.sh push --force-with-lease --branch <branch>
```
</step>

<step id="5" name="Merge">
Ask for user confirmation, then:

```bash
echo '[{"repo":"...","prNumber":123,"branch":"<prefix>/..."}]' | ~/.cursor/skills/pr-land/scripts/pr-land-merge.sh [method]
```

The merge script processes PRs **sequentially** with automatic rebase-before-merge:

1. **Check if already merged** — skip (handles re-runs after CHANGELOG resolution)
2. **Fetch + rebase onto upstream** — ALWAYS done, even for first PR
3. **Conflict handling during rebase:**
   - No conflict → continue
   - CHANGELOG-only (any section) → **exit 4** (agent resolves, re-runs)
   - Code conflict → **skip PR**, abort rebase, continue
4. **Push `--force-with-lease`**
5. **Run local verification** (MANDATORY)
6. **Merge via GitHub API**

**Exit codes:**
- `0` = All (non-skipped) PRs merged
- `1` = Verification failed
- `4` = CHANGELOG-only conflict (agent resolves, re-runs)

**On exit 4:** Agent resolves semantically, pushes, re-runs merge. Script detects already-merged PRs and skips them.
</step>

<step id="6" name="Publish">
**Gating:** Only non-GUI repos. Only when ALL approved PRs for the repo are merged. Skip if any were skipped/held back.

Ask for user confirmation:
```
Merged repos ready to publish (all PRs landed):
  - <repo> (<branch>)

Repos with outstanding PRs (not ready to publish):
  - <repo> (N PRs skipped)

Publish ready repos to npm? [y/N]
```

If confirmed:

```bash
echo '[{"repo":"...","branch":"master"}]' | ~/.cursor/skills/pr-land/scripts/pr-land-publish.sh
```

**Exit codes:**
- `0` = Version bumped, committed, tagged (check `needsPush` in JSON output)
- `1` = Verification failed
- `2` = No unreleased changes in CHANGELOG

After script completes:

<sub-step name="Push version commit + tag">
1. Show version bump details to user (repo, old → new version, entries).
2. Ask user to confirm the push.
3. If confirmed, push master and tag: `cd <repoDir> && git push origin master && git push origin v<version>`.
</sub-step>

<sub-step name="Sanity-check npm auth (once, before first publish)">
Before publishing the first repo of the run, verify the token:
```bash
cd <repoDir> && npm whoami
```
If it fails or prints an unexpected username: STOP and tell the user to check `~/.npmrc`. Do NOT attempt `npm login`. Do NOT prompt for credentials.
</sub-step>

<sub-step name="Publish each repo with OTP from user">
For each repo, in sequence:

1. Ask the user exactly: `OTP for <repo> (npm publish)?` — wait for a 6-digit code.
2. Run:
   ```bash
   cd <repoDir> && npm publish --otp=<otp>
   ```
3. On success: capture the published version from output, proceed to the next repo.
4. On failure with `EOTP` / "OTP required" / any auth error: treat as a stale OTP (OTPs are single-use and ~30s-lived). Ask for a fresh OTP and retry. Retry at most **2 times**; on third failure STOP and report.
5. On any other failure (network, registry error, version conflict): STOP and report — do not retry.

After all repos publish successfully, proceed to step 7 automatically. Do NOT ask for a second confirmation — the exit codes are the confirmation.
</sub-step>
</step>

<step id="7" name="Update GUI Dependencies">
**Trigger:** Only if non-`edge-react-gui` repos were published successfully in step 6 (exit 0 per repo). All non-GUI EdgeApp repos are GUI dependencies, so publishing always requires a GUI dep upgrade. Flows directly from step 6 — no additional user confirmation.

<sub-step name="Sync develop once (before any upgrade)">
`upgrade-dep.sh` assumes it is run on a clean `develop` synced to origin and does NOT manage the branch itself (running it N times would otherwise reset develop N times and wipe prior-package commits). Do this ONCE before the upgrade loop:

```bash
cd <gui-repo-dir>
# Stash any uncommitted working changes so the reset is safe
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  git stash -u
fi
git checkout develop
git fetch origin develop
git reset --hard origin/develop
```

Stashes remain stashed — the user can restore them after the run.
</sub-step>

<sub-step name="Upgrade each published package">
1. Run `upgrade-dep.sh` for each published package, sequentially, on the now-clean `develop`:
   ```bash
   cd <gui-repo-dir> && ~/.cursor/skills/pr-land/scripts/upgrade-dep.sh <package-name>
   ```
   Each invocation bumps the version in package.json, runs install + prepare + prepare.ios via the repo's package manager (npm or yarn, auto-detected), and commits package.json + lockfile. On success it prints `UPGRADE_READY ... sha=<commit_sha>`. If any run fails, STOP and report. Ask user how to proceed.

2. After all dependency upgrades succeed, show the created `develop` commit SHA(s) to the user and ask for confirmation to land them:
   ```bash
   ~/.cursor/skills/git-branch-ops.sh push --branch develop
   ```
   This push is required before the workflow can treat GUI dependency updates as landed. Do NOT proceed to staging cherry-pick or Asana updates until the `develop` push is confirmed complete.
</step>

<step id="8" name="Prepare and Merge GUI PRs (deferred)">
**Trigger:** Only runs when `guiPrs` was populated at step 1 AND step 7's dep upgrades pushed to develop successfully. Skip entirely if no GUI PRs exist. If step 7 failed or was skipped due to no non-GUI merges, also skip this step.

At this point, `origin/develop` contains the new dep-upgrade commits from step 7, so each GUI PR will rebase cleanly onto a develop that already has its new dep versions.

Re-run steps 3, 4, and 5 against `guiPrs`:

1. Feed `guiPrs` into `pr-land-prepare.sh` (same invocation shape as step 3).
2. On CHANGELOG conflict: resolve semantically, `git add CHANGELOG.md && GIT_EDITOR=true git rebase --continue`, re-run prepare — same flow as step 3's CHANGELOG sub-step.
3. For each prepared GUI branch, push with `~/.cursor/skills/git-branch-ops.sh push --force-with-lease --branch <branch>` (step 4).
4. Feed `guiPrs` into `pr-land-merge.sh` (step 5).

Do NOT re-enter steps 6 or 7 — GUI does not publish to npm and has no deps of its own to upgrade.
</step>

<step id="9" name="Staging Cherry-Pick">
**Trigger:** Only for `edge-react-gui` commits that target the `## X.Y.Z (staging)` CHANGELOG section (not `## Unreleased`). This includes both merged PR commits and GUI dependency upgrade commits from step 7.

Check CHANGELOG diffs to determine which commits qualify — if the entry was added under a `(staging)` heading, it needs cherry-picking.

**Skip** this step entirely if no commits have staging CHANGELOG entries.

For qualifying PRs/commits, invoke the `/staging-cherry-pick` skill:

```bash
echo '[{"repo":"edge-react-gui","prNumber":123,"mergeSha":"abc123"}]' | ~/.cursor/skills/staging-cherry-pick/scripts/staging-cherry-pick.sh
```

Pass the `mergeSha` from the merge step's JSON output. For dep upgrade commits, pass the commit SHA from step 7. The script cherry-picks individual (non-merge) commits onto the staging branch.

**On exit 3 (CHANGELOG conflict):** Resolve semantically (existing staging entries first, then the new entry), then `git add CHANGELOG.md && GIT_EDITOR=true git cherry-pick --continue`. Re-run for remaining PRs.

**On exit 1 (code conflict):** STOP and report to user.

After cherry-picks succeed, ask user to confirm push:
```bash
git push origin staging
```

Then restore the previous branch.
</step>

<step id="10" name="Update Asana Tasks">
**Runs ONLY after ALL merges, cherry-picks, publishes, and GUI dep upgrades are complete.**

Only update for fully landed PRs:
- GUI PRs: merged
- Non-GUI PRs: merged AND published AND GUI deps updated

Do NOT update for: skipped PRs, addressed-but-not-re-reviewed PRs, or repos not published.

<sub-step name="Extract Asana task GIDs">
Pipe the PR metadata through the new helper so you only consume the Asana link once per PR:

```bash
printf '[{"repo":"edge-react-gui","prNumber":123}]' | ~/.cursor/skills/pr-land/scripts/pr-land-extract-asana-task.sh > /tmp/asana.json
```

The helper outputs JSON like `{ "tasks": [{ "taskGid": "...", "label": "repo#123" }], "missing": [{ "label": "...", "reason": "..." }] }`.

**Parent-walking:** `taskGid` is the PR's linked task's PARENT when a parent exists (the feature-level task that represents the unit of work across repos). Standalone tasks (no parent) return themselves. Only updates the parent — leave subtasks alone; they have their own state that is managed separately. Sibling subtasks of the same parent dedupe to one entry; `label` lists all contributing PRs (e.g. `"edge-react-gui#123, edge-core-js#456"`).

Review the `missing` array, report any entries lacking an Asana link, and skip those PRs for Asana updates.
</sub-step>

<sub-step name="Update tasks">
For each task in `.tasks`, run:

```bash
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --set-board-state "QA Verification" \
  --unassign
```

Writes to the new Board State 🤖 field. The legacy Status field is no longer updated.

**Exit codes per call:**
- `0` = success
- `1` = error
- `2` = needs user input
</sub-step>
</step>

<step id="11" name="End-of-Workflow Report">
```
=== PR Land Summary ===

Fully landed:
  ✓ <repo>#<number> (<branch>) — merged, cherry-picked to staging, Asana → QA Verification
  ✓ <repo>#<number> (<branch>) — merged, Asana → QA Verification
  ✓ <repo>#<number> (<branch>) — merged, published v<version>, GUI deps updated, Asana → QA Verification

Addressed but needs re-review:
  ⚠ <repo>#<number> (<branch>) — fixup pushed, awaiting review

Skipped (conflicts):
  ⚠ <repo>#<number> (<branch>) — stale / code conflict in <file>

Not published (outstanding PRs):
  ⚠ <repo> — N PRs skipped, publish deferred
```
</step>

<conflict-handling description="Summary of conflict types and resolution.">

| Conflict Type | Script Behavior | Agent Action |
|---|---|---|
| Code files | Skip PR, abort rebase, continue | Report to user at end |
| CHANGELOG only (prepare) | Report conflict | Resolve semantically, re-run prepare |
| CHANGELOG only (merge) | **exit 4** with instructions | Resolve semantically, push, re-run merge |

Both prepare and merge scripts can detect CHANGELOG-only conflicts. In either case:
1. Script outputs clear resolution instructions
2. Agent resolves semantically (upstream entries first)
3. `git add CHANGELOG.md && GIT_EDITOR=true git rebase --continue`
4. Push with `~/.cursor/skills/git-branch-ops.sh push --force-with-lease --branch <branch>`
5. Re-run the script to verify and proceed
</conflict-handling>

<changelog-resolution description="How the agent resolves CHANGELOG conflicts.">
```
# Typical conflict:
<<<<<<< HEAD
- added: Feature from upstream
=======
- changed: Our feature
>>>>>>> our-commit

# Resolution: Upstream first, then ours:
- added: Feature from upstream
- changed: Our feature
```

<sub-step name="During prepare (no push yet)">
1. Read CHANGELOG.md with conflict markers
2. Resolve semantically using StrReplace
3. `git add CHANGELOG.md && GIT_EDITOR=true git rebase --continue`
4. Re-run `~/.cursor/skills/pr-land/scripts/pr-land-prepare.sh`
</sub-step>

<sub-step name="During merge (already pushed, GitHub reports conflict)">
1. `cd <repoDir>`
2. `git fetch origin && git rebase origin/master` (or `origin/develop`)
3. Read CHANGELOG.md with conflict markers
4. Resolve semantically using StrReplace
5. `git add CHANGELOG.md && GIT_EDITOR=true git rebase --continue`
6. `~/.cursor/skills/git-branch-ops.sh push --force-with-lease`
7. Re-run `~/.cursor/skills/pr-land/scripts/pr-land-merge.sh` — verification runs automatically
</sub-step>

Verification checks: no conflict markers remaining, proper entry format (`- type: description`), no malformed entries. If verification fails after resolution, the script prompts the user.
</changelog-resolution>

<safety-guarantees>
1. Code conflicts skip cleanly — scripts abort rebase and skip, no dirty state
2. CHANGELOG conflicts are scripted — agent resolves semantically (any section including staging), verification validates
3. Verification is mandatory — built into merge script, physically blocks merge on failure
4. Pre-merge is safe — can force-push as many times as needed
5. Sequential merging with auto-rebase — each PR rebased onto updated base
6. No bypasses — scripts enforce rules, agent cannot skip steps
7. Unexpected errors halt execution — undocumented exit codes stop immediately
8. Publish gating — repos with outstanding PRs are not published
9. Asana is last — task updates only after full pipeline completes
10. GUI deferral prevents incomplete migrations — GUI never lands before its coordinated non-GUI deps are published and upgraded on develop
</safety-guarantees>
