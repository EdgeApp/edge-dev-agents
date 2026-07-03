---
name: pr-land
description: Land approved PRs. By DEFAULT verifies locally first (autosquash + rebase + verify), then arms GitHub auto-merge and watches CI until each PR merges on green; falls back to a fully local rebase + verify + merge only for conflicts, unsupported repos, or an explicit immediate-merge request. Use when the user wants to merge/land pull requests.
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
<rule id="code-conflicts">Code (non-CHANGELOG) conflicts → ATTEMPT semantic resolution when confidently determinable; the prepare/merge scripts leave the rebase IN PROGRESS (no auto-abort) so you resolve in place. "Confidently determinable" = the two sides have independent intent you can preserve without guessing: dependency/version bumps, lockfile regeneration, accepting an upstream file deletion, non-overlapping edits. To resolve: read each conflicted file, edit to keep BOTH sides' intent (the upstream change AND our change), regenerate lockfiles via the repo's package manager if deps changed (`npm install` or `yarn install` per the repo's lockfile), `git add <files> && GIT_EDITOR=true git rebase --continue`, then re-run the script to verify (re-verification catches any follow-on issue, e.g. a formatting fix needed via `eslint --fix`). SKIP only when resolution is NOT confidently determinable — overlapping logic in the same function, unclear semantic intent, or you would be guessing: `git rebase --abort`, continue with remaining PRs, report. Never guess at a merge. CHANGELOG conflicts keep their `changelog-conflicts` handling.</rule>
<rule id="stale-prs">Stale PRs → Skip and report. Old PRs with multiple conflicts should be skipped like code conflicts. Don't block the flow.</rule>
<rule id="changelog-conflicts">CHANGELOG conflicts (any section, including staging): Agent resolves semantically, scripts verify the result.</rule>
<rule id="verification">Verification is mandatory. On the DEFAULT path a PR is gated twice: first locally (Step 3 prepare runs `verify-repo.sh` before the branch is pushed and auto-merge is armed), then by GitHub's REQUIRED status checks (auto-merge will not merge until they pass). Do NOT also merge locally on this path — GitHub owns the merge; the agent watches CI to completion (see Step 5). On the local fallback path, verification is built into `pr-land-merge.sh`, no bypass. Either way a PR never lands without green checks.</rule>
<rule id="no-force-push">Do NOT force-push without explicit user confirmation.</rule>
<rule id="no-editors">Never open editors. All git operations must be non-interactive: `GIT_EDITOR=true` for commit messages, `GIT_SEQUENCE_EDITOR=:` for rebase todo lists.</rule>
<rule id="unexpected-exit">Unexpected exit codes → STOP immediately. If any script returns an exit code not documented in this file, STOP and report to user. Do NOT attempt to interpret, retry, or work around unexpected errors.</rule>
<rule id="sequential-rebase">Sequential merging requires rebase. Each subsequent PR MUST be rebased onto the updated base branch after the previous merge.</rule>
<rule id="publish-gating">Don't publish if outstanding PRs remain. Only offer to publish a repo when ALL approved PRs for that repo are merged. If any were skipped or held back, do NOT publish that repo.</rule>
<rule id="npm-otp-required">`npm publish` requires the user's npm 2FA. Two paths, depending on the account's 2FA type — never skip 2FA on either:
- **TOTP (authenticator app):** run with `--otp=<code>` from a 6-digit code the user supplies. Never run `npm publish` without the `--otp` flag on a TOTP account.
- **Passkey / WebAuthn (no 6-digit code):** run `npm publish` with NO `--otp` flag; npm opens a browser / prints a URL for the user to approve with their passkey (relies on `auth-type=web`).
If you do not know which the account uses, ask the user. Do NOT run `npm login` — auth comes from the `_authToken` in `~/.npmrc`; the user owns login. If `npm whoami` fails before the first publish, STOP and report; do not try to re-authenticate.</rule>
<rule id="defer-gui">If the discovered PR set contains BOTH `edge-react-gui` PRs and at least one non-GUI PR, all GUI PRs are DEFERRED — they do NOT enter steps 3-7 (prepare/push/merge/publish/upgrade-dep). GUI PRs are processed in step 8 (new) after step 7's dep upgrades land on develop. If the batch is pure GUI or pure non-GUI, no deferral — proceed as normal.</rule>
<rule id="asana-last">Asana updates are LAST. Do NOT update Asana tasks until ALL merges, publishes, and GUI dependency upgrades are complete. Only update status for PRs that are fully landed (merged, and if non-GUI: published + GUI deps updated).</rule>
<rule id="build-field-routing">During discovery, resolve each linked task's Build field: `~/.cursor/skills/asana-build-field.sh <task-gid>`. `staging` → the PR is staging-targeted: step 9 MUST cherry-pick its commits after merge even when its CHANGELOG entry sits under `## Unreleased` — a field/CHANGELOG disagreement is a placement question (offer to move the entry to the `(staging)` section per step 3's placement-warning flow), never a silent skip of the cherry-pick. A cheese value (`feta|gouda|halloumi|cheddar`) changes NOTHING about landing: land the task's FEATURE branch PR normally; a `test-*` branch is never a landing target (skip + report any discovered PR whose head branch matches `test-*`; see cheese `pointer-not-workspace`), and no re-cheese follows a land — CI builds wherever the landing happened (develop, or develop + staging).</rule>
</rules>

<scripts description="Companion scripts and their expected exit codes.">

| Script | Purpose |
|--------|---------|
| `pr-land-discover.sh` | Discover PRs and approval status |
| `pr-land-comments.sh` | Check for recent unaddressed feedback (inline threads, review bodies, top-level comments) |
| `git-branch-ops.sh` | Shared autosquash / push helper for explicit git branch actions |
| `pr-land-prepare.sh` | Rebase + conflict detection + verification |
| `verify-repo.sh` | Verification (CHANGELOG + code; lint scoped to changed files when `--base` given; accommodates both Unreleased-style and legacy versions-only CHANGELOG formats; prepare invokes it with `--require-changelog`, so every landed PR must include a CHANGELOG entry) |
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
| `pr-land-merge.sh` | Merged | Verify fail | - | - | Conflict needs resolution (CHANGELOG or code) |
| `staging-cherry-pick.sh` | All cherry-picked | Error | Auth needed | CHANGELOG conflict | - |
| `pr-land-publish.sh` | Ready (needs push) | Verify fail | No unreleased | - | - |
| `asana-task-update.sh` | Success | Error | Needs user input | - | - |

**Any exit code not in this table = STOP immediately and report to user.**

<prepare-statuses description="Per-PR `status` values in pr-land-prepare.sh's JSON output, and the prescribed action for each. The script exits 0 if ANY branch is ready or has a resolvable CHANGELOG conflict — always read per-PR statuses, not just the exit code.">

| `status` | Meaning | Prescribed action |
|----------|---------|-------------------|
| `ready` | Prepared + verified | Proceed to push (step 4). Check `placementWarnings` first. |
| `changelog_conflict` | CHANGELOG-only rebase conflict, left in progress | Resolve semantically, `git add CHANGELOG.md && GIT_EDITOR=true git rebase --continue`, re-run prepare. |
| `code_conflict` | Code-file rebase conflict, rebase LEFT IN PROGRESS | Resolve semantically in place when confidently determinable (dep/version bumps, lockfile regen, accept upstream deletion, non-overlapping edits): keep both sides' intent, regenerate lockfiles if deps changed, `git add` + `GIT_EDITOR=true git rebase --continue`, re-run prepare. `git rebase --abort` + skip ONLY if not confidently resolvable. See `code-conflicts`. |
| `verification_failed` | verify-repo.sh failed | Read `failedStep` + `logPath` from the JSON; inspect the log tail (`tail -40 <logPath>`); fix only if trivially in-scope, else report. Special case `failedStep: "CHANGELOG entry existence check"` — prepare REQUIRES every landed PR to have updated CHANGELOG.md: add a correctly-formatted entry for the PR's change (under `## Unreleased`, or the topmost version section in legacy versions-only repos), amend it onto the branch, and re-run prepare. Only if an entry is genuinely unwarranted (e.g. CI-only change), ask the user whether to land without one. |
| `install_failed` | Dependency install failed | Report; usually environmental. Do not retry blindly. |
| `autosquash_failed` | Fixup autosquash rebase failed (aborted) | Report; branch likely needs manual history repair. |
| `checkout_failed` | Fetch/checkout failed | Report the git error. Note: dirty trees no longer cause this — they are auto-stashed (see `dirty-tree-policy`). |
| `clone_failed` | Initial clone failed | Report; check repo name/access. |

**Dirty-tree policy (`dirty-tree-policy`):** prepare operates on the PRIMARY checkout at `~/git/<repo>` (or a worktree already holding the branch) — NOT a scratch clone — so it can collide with in-progress local work. If the tree is dirty at checkout, prepare auto-stashes it (including untracked) under a labeled stash `pr-land-autostash <ISO-date> (was on <branch>)` and reports it in the per-PR JSON (`autostash`) and the summary. ALWAYS surface auto-stashes to the user in your final report — the stash is their uncommitted work; recovery is `git stash list | grep pr-land-autostash` then `git stash pop <ref>`.
</prepare-statuses>
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

The prepare script handles: clone/checkout, autosquash fixups, rebase onto upstream (the repo's actual default branch via origin/HEAD; `origin/develop` for the GUI), conflict detection, and verification. It operates on the PRIMARY checkout at `~/git/<repo>` — not a scratch clone — so in-progress local work there is auto-stashed per `dirty-tree-policy`. Per-PR outcomes are the `status` values in `<prepare-statuses>`; act on each as prescribed there.

**Exit codes:**
- `0` = At least one PR ready to push, OR a resolvable conflict (code/CHANGELOG) was left in progress (reported in `codeConflicts` / `changelogConflicts`)
- `1` = All PRs failed (verification or other errors, none ready or resolvable)

<sub-step name="On code conflict">The rebase is LEFT IN PROGRESS (status `code_conflict`, reported in `codeConflicts`). Resolve per the `code-conflicts` rule: if confidently determinable, edit each conflicted file to keep both sides' intent, regenerate lockfiles if deps changed, `git add` + `GIT_EDITOR=true git rebase --continue`, then re-run prepare to verify. If NOT confidently resolvable, `git rebase --abort` and skip, continuing with other PRs.</sub-step>

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
**DEFAULT: local-gate, then arm auto-merge, then watch CI.** The default land path verifies locally first, then hands the merge to GitHub and babysits CI to completion:

1. **Local gate (Steps 3-4):** run Step 3 `pr-land-prepare.sh` (autosquash + rebase onto upstream + `verify-repo.sh`) and Step 4 push FIRST. This catches breakage locally before CI spends time on it. Only branches that reach `status: ready` and are pushed proceed to arm.
2. **Confirm + arm:** after Step 1-2 (discovery + comments addressed/approved) and the local gate, confirm with the user, then arm GitHub auto-merge so each PR merges itself when its required CI checks go green (GitHub owns the rebase/queue and the actual merge):

   ```bash
   echo '[{"repo":"...","prNumber":123}, ...]' | ~/.cursor/skills/pr-land/scripts/pr-land-automerge.sh
   ```

   Per-PR result lines: `armed` (auto-merge on; GitHub merges on green), `merged` (already merged), `blocked` (changes requested — resolve first), `unsupported` (repo disallows auto-merge/merge-commit → use the local fallback below), `error`. Exit 0 = all armed/merged.
3. **Watch CI until merged or a check fails (babysit):** for each armed PR, poll its CI/merge state until it lands or a check goes red. Do NOT walk away at `armed`:

   ```bash
   ~/.cursor/scripts/pr-watch.sh --once --repo <repo> --user <user>
   ```

   Poll on a sane interval (about 60s; the script clamps to a safe minimum). Read the PR's state from the output:
   - PR shows **PENDING** → CI still running; keep polling.
   - PR **drops off the open list** → auto-merge fired and it merged; capture the merge and move on.
   - PR shows **BLOCKED** (CI failure / changes requested) → STOP watching that PR, report the failing check, and leave auto-merge armed unless the user says to disarm. Do not local-merge around a red check.

   Resolve `<user>` from the branch-prefix owner (e.g. `Jon-edge`); omit `--user` to watch all of the repo's open PRs. Only finalize the land once every armed PR has either merged or been reported as blocked.

**FALLBACK: local rebase + verify + merge.** Use the local path ONLY when auto-merge is `unsupported`/`blocked`, when a rebase CONFLICT needs local resolution (per `code-conflicts`), or when the user explicitly asks for an immediate local merge. Run Steps 3-4 (prepare/push) first, then:

```bash
echo '[{"repo":"...","prNumber":123,"branch":"<prefix>/..."}]' | ~/.cursor/skills/pr-land/scripts/pr-land-merge.sh [method]
```

The local merge script processes PRs **sequentially** with automatic rebase-before-merge:

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
- `4` = Conflict needs resolution (rebase left in progress) — CHANGELOG-only OR code

**On exit 4:** Resolve per the conflict type (CHANGELOG → `changelog-conflicts`; code → `code-conflicts`, only if confidently determinable, else `git rebase --abort` and skip), push `--force-with-lease`, re-run merge. Script detects already-merged PRs and skips them.
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

<sub-step name="Publish each repo (TOTP or passkey 2FA)">
For each repo, in sequence. First determine the user's npm 2FA type (ask if unknown): **TOTP** (6-digit authenticator code) or **passkey/WebAuthn** (browser approval, no code).

**TOTP path:**
1. Ask the user exactly: `OTP for <repo> (npm publish)?` — wait for a 6-digit code.
2. Run:
   ```bash
   cd <repoDir> && npm publish --otp=<otp>
   ```
3. On success: capture the published version from output, proceed to the next repo.
4. On failure with `EOTP` / "OTP required" / any auth error: treat as a stale OTP (OTPs are single-use and ~30s-lived). Ask for a fresh OTP and retry. Retry at most **2 times**; on third failure STOP and report.

**Passkey / web-auth path:**
1. Tell the user exactly: `Publishing <repo> — approve the npm passkey prompt in your browser when it opens.`
2. Run (NO `--otp` flag; relies on `auth-type=web`):
   ```bash
   cd <repoDir> && npm publish
   ```
3. npm prints a URL / opens a browser; the user approves with their passkey. Use a long timeout — the command blocks until the user completes the browser prompt.
4. On success: capture the published version from output, proceed to the next repo.
5. On failure with a 2FA/auth error (user dismissed or missed the browser prompt): ask the user to retry the approval and re-run. Retry at most **2 times**; on third failure STOP and report.

**Both paths:** On any other failure (network, registry error, version conflict): STOP and report — do not retry.

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
**Trigger:** `edge-react-gui` commits qualify on EITHER signal (per `build-field-routing`): (a) the linked Asana task's Build field is `staging` — the primary, field-driven signal — or (b) the commit's CHANGELOG entry targets the `## X.Y.Z (staging)` section (the backstop for PRs with no linked task). This includes both merged PR commits and GUI dependency upgrade commits from step 7.

Check the Build field of each landed PR's task plus CHANGELOG diffs to determine which commits qualify. On disagreement (field `staging`, entry under `## Unreleased`), the placement question was already surfaced in step 3 — the field wins for routing.

**Skip** this step entirely only when NO commit qualifies on either signal.

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
| Code files | Rebase left in progress | Resolve semantically when determinable (keep both sides, regen lockfiles), `git rebase --continue`, re-run; `git rebase --abort` + skip only if not determinable |
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

<code-conflict-resolution description="How the agent resolves a code (non-CHANGELOG) conflict left in progress by prepare/merge. Governed by the `code-conflicts` rule: resolve only when confidently determinable, else abort + skip.">
The rebase is paused with markers in the conflicted files. Decide FIRST whether the conflict is confidently resolvable (both sides have independent intent you can preserve) or a guess (overlapping logic in the same function). If a guess → `git -C <repoDir> rebase --abort` and skip the PR.

If resolvable, for EACH conflicted file:
1. Read it and resolve the markers so BOTH sides' intent survives. Common determinable shapes:
   - **Dependency / version bump vs our removal/edit**: take the upstream version pin AND apply our add/remove. (e.g. keep upstream's bumped `rollup`, drop the package our branch removed.)
   - **Upstream deleted a file we modified** (or vice versa): take the deletion when it is intentional upstream (e.g. a lockfile dropped in a yarn→npm conversion) — `git rm <file>`.
   - **Non-overlapping edits in the same file**: keep both hunks.
2. If `package.json` dependencies changed, regenerate the lockfile so it matches: `npm install` (npm repos) or `yarn install` (yarn repos) — never hand-merge a lockfile. Stage the regenerated lockfile.
3. `git -C <repoDir> add <files> && GIT_EDITOR=true git -C <repoDir> rebase --continue`
4. Re-run the script (`pr-land-prepare.sh` / `pr-land-merge.sh`). Re-verification is mandatory and catches follow-on issues a resolution can introduce (e.g. a removed import leaving a formatting violation → fix with `eslint --fix` on the file, amend, re-run).
</code-conflict-resolution>

<safety-guarantees>
1. Code conflicts resolve or skip cleanly — scripts leave the rebase in progress for semantic resolution when determinable; the agent aborts + skips (no dirty state) only when not confidently resolvable
2. CHANGELOG conflicts are scripted — agent resolves semantically (any section including staging), verification validates
3. Verification is mandatory — the default path gates locally (Step 3 `verify-repo.sh`) before arming, then watches GitHub's required checks through to a merge; the local fallback builds verification into the merge script, physically blocking merge on failure
4. Pre-merge is safe — can force-push as many times as needed
5. Sequential merging with auto-rebase — each PR rebased onto updated base
6. No bypasses — scripts enforce rules, agent cannot skip steps
7. Unexpected errors halt execution — undocumented exit codes stop immediately
8. Publish gating — repos with outstanding PRs are not published
9. Asana is last — task updates only after full pipeline completes
10. GUI deferral prevents incomplete migrations — GUI never lands before its coordinated non-GUI deps are published and upgraded on develop
</safety-guarantees>
