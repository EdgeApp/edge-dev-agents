Governs steps 3-4 of `/pr-land` (prepare and push), and every CHANGELOG or code conflict a later step hits; the core step map points here.

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="code-conflicts">Code (non-CHANGELOG) conflicts → ATTEMPT semantic resolution when confidently determinable; the prepare/merge scripts leave the rebase IN PROGRESS (no auto-abort) so you resolve in place. "Confidently determinable" = the two sides have independent intent you can preserve without guessing: dependency/version bumps, lockfile regeneration, accepting an upstream file deletion, non-overlapping edits. To resolve: read each conflicted file, edit to keep BOTH sides' intent (the upstream change AND our change), regenerate lockfiles via the repo's package manager if deps changed (`npm install` or `yarn install` per the repo's lockfile), `git add <files> && GIT_EDITOR=true git rebase --continue`, then re-run the script to verify (re-verification catches any follow-on issue, e.g. a formatting fix needed via `eslint --fix`). SKIP only when resolution is NOT confidently determinable — overlapping logic in the same function, unclear semantic intent, or you would be guessing: `git rebase --abort`, continue with remaining PRs, report. Never guess at a merge. CHANGELOG conflicts keep their `changelog-conflicts` handling.</rule>
<rule id="changelog-conflicts">CHANGELOG conflicts (any section, including staging): Agent resolves semantically, scripts verify the result. NEVER narrated: a CHANGELOG conflict happens on nearly every land and resolves mechanically, so it earns zero words in chat, comments, or reports — conflict mentions during a land are reserved for NON-trivial (code) conflicts per `code-conflicts`, and upfront conflict status is banned everywhere (writing-style; `block-upfront-conflict-probe.sh`).</rule>
<rule id="verification">Verification is mandatory. On the DEFAULT path a PR is gated twice: first locally (Step 3 prepare runs `verify-repo.sh` before the branch is pushed and auto-merge is armed), then by GitHub's REQUIRED status checks (auto-merge will not merge until they pass). Do NOT also merge locally on this path — GitHub owns the merge; the agent watches CI to completion (see Step 5). On the local fallback path, verification is built into `pr-land-merge.sh`, no bypass. Either way a PR never lands without green checks. Every local verification (prepare, merge, publish) first waits via `wait-for-quiet-load.sh` for machine load, minus this session's own process tree, to fall below twice the CPU count (bounded; it never blocks a land), because test suites carry fixed per-test timeouts that unrelated load trips and a run must not wait out load it generates itself. A verification failure consisting ONLY of test timeouts is a load failure, not a code failure: re-run the same step (the wait runs again); the two-attempt remediation bound of `auto-fix-verification-failures` counts attempts made at quiet load. Any failure with an assertion or compile error is a real failure and follows the normal bound.</rule>
<rule id="broken-develop-gate">A base branch the master-build memo marks unbuildable (`~/.config/agent-watcher/develop-buildable.sh` exit 3: `origin/develop` HEAD equals `failed_sha` in `master-build.json`) is not landed onto. `pr-land-prepare.sh` refuses such a PR before touching the checkout (status `base_unbuildable`, exit 3 when nothing else was ready); report it as "base branch unbuildable, land the fix first" and stop the train for that repo. `--allow-broken-develop` is operator-only, for the one PR that IS the fix: an orch run never passes it and reports the refusal instead. The gate opens by itself once develop moves.</rule>
<rule id="dep-sanction-at-land">A PR labeled `awaiting-dep-publish` has CI that cannot pass until a dependency publishes (one-shot `dep-blocked-pr-vs-bump`); landing is where that sanction ends. Immediately before preparing ANY PR (step 3, or step 8 for a deferred GUI PR, by which point step 6 has published its dependency), run `~/.cursor/skills/dep-publish-sanction.sh check --repo <owner/repo> --pr <n>` and act on its exit code. `5` = no sanction: an ordinary PR. `0` or `4` = the dependency is still unpublished: do NOT prepare or land the PR; report it under "Not landed (awaiting dependency publish)" with the awaited package from the verdict line. `3` = the dependency has published: land the PR normally, on a base branch that already carries the bump (step 7 of this run, or an earlier land; a missing bump shows up as a prepare verification failure). `1` = npm or GitHub unreachable: retry once, then skip the PR and report it. For a PR that read `3`, remove the sanction right after its step 4 push with `~/.cursor/skills/dep-publish-sanction.sh clear --repo <owner/repo> --pr <n>`, then arm as usual; auto-merge still waits for green CI. A label left on a PR whose dependency has published is a defect, so clear it even when the PR then fails to land.</rule>
</rules>

<scripts description="This phase's companion scripts and their exit codes. Any exit code not listed here or in the core table = STOP and report (`unexpected-exit`).">

| Script | Purpose |
|--------|---------|
| `pr-land-prepare.sh` | Rebase + conflict detection + verification |
| `~/.cursor/skills/dep-publish-sanction.sh` | `check`: is this PR waiting on an unpublished dependency. `clear`: remove the `awaiting-dep-publish` label and body line (`dep-sanction-at-land`) |
| `verify-repo.sh` | Verification (CHANGELOG + code; lint scoped to changed files when `--base` given; accommodates both Unreleased-style and legacy versions-only CHANGELOG formats; prepare invokes it with `--require-changelog`, so every landed PR must include a CHANGELOG entry) |
| `changelog-union-merge.sh` | Mechanically resolve a CHANGELOG rebase/cherry-pick conflict (union, dedupe, type-order). Shared with /develop-staging, which adds whole-section merging behind `--release-merge`; pr-land never passes that flag |
| `wait-for-quiet-load.sh` | Blocks (bounded) until the 1-min load average, minus this session's own process tree, is at or below 2 x CPUs; called by every verification path, exits 0 always |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `pr-land-prepare.sh` | Ready | All failed | - | Base branch unbuildable (`broken-develop-gate`) | - |
| `dep-publish-sanction.sh check` | Still unpublished (skip the PR) | npm or GitHub unreachable | Usage | Published (land, then `clear`) | Still unpublished (skip the PR) |
| `verify-repo.sh` | Pass | Code fail | CHANGELOG fail | - | - |
| `changelog-union-merge.sh` | Resolved (+continued) | No markers / continue failed | Usage | - | - |

<prepare-statuses description="Per-PR `status` values in pr-land-prepare.sh's JSON output, and the prescribed action for each. The script exits 0 if ANY branch is ready or has a resolvable CHANGELOG conflict — always read per-PR statuses, not just the exit code.">

| `status` | Meaning | Prescribed action |
|----------|---------|-------------------|
| `ready` | Prepared + verified | Proceed to push (step 4). Check `placementWarnings` first. |
| `changelog_conflict` | CHANGELOG-only rebase conflict, left in progress | Run `changelog-union-merge.sh <repoDir> --continue` (mechanical union: dedupe + type-order), re-run prepare. Resolve by hand only if the script exits non-zero. |
| `code_conflict` | Code-file rebase conflict, rebase LEFT IN PROGRESS | Resolve semantically in place when confidently determinable (dep/version bumps, lockfile regen, accept upstream deletion, non-overlapping edits): keep both sides' intent, regenerate lockfiles if deps changed, `git add` + `GIT_EDITOR=true git rebase --continue`, re-run prepare. `git rebase --abort` + skip ONLY if not confidently resolvable. See `code-conflicts`. |
| `verification_failed` | verify-repo.sh failed | Read `failedStep` + `logPath` from the JSON; inspect the log tail (`tail -40 <logPath>`); fix only if trivially in-scope, else report. Special case `failedStep: "CHANGELOG entry existence check"` — prepare REQUIRES every landed PR to have updated CHANGELOG.md: add a correctly-formatted entry for the PR's change (under `## Unreleased`, or the topmost version section in legacy versions-only repos), amend it onto the branch, and re-run prepare. Only if an entry is genuinely unwarranted (e.g. CI-only change), ask the user whether to land without one. |
| `install_failed` | Dependency install failed | Read the error: a Socket Firewall HTML page ("Please connect to Socket Firewall") is a transient proxy outage — retry the prepare ONCE, then report. Runtime-setup steps in `scripts.prepare` are already stripped during verification installs (see `verification-prepare-cmd.sh`), so a persistent failure is a real install problem: report, do not retry further. |
| `autosquash_failed` | Fixup autosquash rebase failed (aborted) | Report; branch likely needs manual history repair. |
| `checkout_failed` | Fetch/checkout failed | Report the git error. A dirty tree never causes this: it is auto-stashed (see `dirty-tree-policy`). |
| `clone_failed` | Initial clone failed | Report; check repo name/access. |

**Dirty-tree policy (`dirty-tree-policy`):** prepare operates on the PRIMARY checkout at `~/git/<repo>` (or a worktree already holding the branch) — NOT a scratch clone — so it can collide with in-progress local work. If the tree is dirty at checkout, prepare auto-stashes it (including untracked) under a labeled stash `pr-land-autostash <ISO-date> (was on <branch>)` and reports it in the per-PR JSON (`autostash`) and the summary. ALWAYS surface auto-stashes to the user in your final report — the stash is their uncommitted work; recovery is `git stash list | grep pr-land-autostash` then `git stash pop <ref>`.
</prepare-statuses>
</scripts>

<step id="3" name="Prepare Branches">
When the `defer-gui` rule applies (mixed batch), feed only `nonGuiPrs` into `pr-land-prepare.sh`. GUI PRs enter prepare in step 8.

First run the `dep-sanction-at-land` check on each PR about to be prepared and leave out the ones still waiting on a dependency (`dep-publish-sanction.sh check` exit 5 = no sanction on the PR, the usual case).

ONE tool call per batch:

```bash
echo '[{"repo":"...","branch":"<prefix>/feature","buildField":"staging"}]' | ~/.cursor/skills/pr-land/scripts/pr-land-prepare.sh
```

Include `buildField` per branch with the task's Build field value already resolved during discovery (`build-field-routing`) — `"staging"` arms the deterministic CHANGELOG placement check below; omit it for tasks with no Build field.

The prepare script handles: clone/checkout, autosquash fixups, rebase onto upstream (the repo's actual default branch via origin/HEAD; `origin/develop` for the GUI), conflict detection, and verification. It operates on the PRIMARY checkout at `~/git/<repo>` — not a scratch clone — so in-progress local work there is auto-stashed per `dirty-tree-policy`. Per-PR outcomes are the `status` values in `<prepare-statuses>`; act on each as prescribed there.

**Exit codes:**
- `0` = At least one PR ready to push, OR a resolvable conflict (code/CHANGELOG) was left in progress (reported in `codeConflicts` / `changelogConflicts`)
- `1` = All PRs failed (verification or other errors, none ready or resolvable)
- `3` = Every PR was refused because its base branch is memoized as unbuildable (`baseUnbuildable`); apply `broken-develop-gate`

<sub-step name="On code conflict">The rebase is LEFT IN PROGRESS (status `code_conflict`, reported in `codeConflicts`). Resolve per the `code-conflicts` rule: if confidently determinable, edit each conflicted file to keep both sides' intent, regenerate lockfiles if deps changed, `git add` + `GIT_EDITOR=true git rebase --continue`, then re-run prepare to verify. If NOT confidently resolvable, `git rebase --abort` and skip, continuing with other PRs.</sub-step>

<sub-step name="On CHANGELOG conflict">Run `~/.cursor/skills/pr-land/scripts/changelog-union-merge.sh <repoDir> --continue`, then re-run prepare. Only resolve by hand (upstream entries first, then ours) if the script exits non-zero.</sub-step>

<sub-step name="On CHANGELOG placement warning">
Each entry in `prepared[i].placementWarnings` carries a `reason` that selects its handling. The staging placement check runs only for CHANGELOGs that have a `(staging)` section (the GUI); dependency repos ship by npm version and their entries belong under `## Unreleased`, so no warning appears there. `prepared[i].newEntrySections` lists the section headings the branch's new entries sit under; keep it for step 9.

**`reason: "staging-task-under-unreleased"`** — the task's Build field is `staging` (operator intent) but the entry sits under `## Unreleased (develop)`. Deterministic, NO user ask (a yolo run has no one to ask, and the field already IS the decision): use the Edit tool to move the entry line(s) into the `## X.Y.Z (staging)` section, preserving `added → changed → deprecated → fixed → removed → security` ordering, then amend the top commit and re-run prepare exactly as in step 2 of the interactive case below. This is what keeps develop's changelog honest — without the move, the fix ships in the staging release but both branches list it as unreleased, and it double-appears in the NEXT version's notes.

**`reason: "released-section"`** — the PR added CHANGELOG entries under a DATED released heading (e.g. `## 4.46.0 (<date>)`) instead of `## Unreleased (develop)` or `## X.Y.Z (staging)`. This usually means the author placed the entry under the then-current released version but the PR actually targets a later unreleased version. A judgment call:

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
