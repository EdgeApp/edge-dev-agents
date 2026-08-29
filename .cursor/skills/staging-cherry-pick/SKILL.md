---
name: staging-cherry-pick
description: Cherry-pick merged PR commits onto the staging branch. Use after pr-land merges staging-targeted PRs to develop, or standalone when commits need to land on staging.
compatibility: Requires git, gh, node.
metadata:
  author: j0ntz
---

<goal>Cherry-pick individual commits from merged PRs onto the `staging` branch, resolving CHANGELOG conflicts semantically when they arise.</goal>

<rules description="Non-negotiable constraints.">
<rule id="cherry-picks-only">Staging takes CHERRY-PICKS ONLY (operator ruling 2026-08-28). Never produce a native commit on staging — no `upgrade-dep.sh` run on staging, no direct commits, no merges — even when the script cannot unpack an input. Staging must carry the SAME commits develop carries, as cherry-picks, so the two lines stay traceable commit-for-commit. If the script skips or fails on a qualifying commit, fix the input or resolve the conflict; do NOT route around it with a fresh commit.</rule>
<rule id="individual-commits">Cherry-pick each commit individually — NEVER cherry-pick the merge commit itself. The script extracts by parent count: a merge commit unpacks as `git log --reverse <merge>^1..<merge>^2`; a single-parent commit (a dep bump from `upgrade-dep.sh`) cherry-picks as itself.</rule>
<rule id="pull-first">ALWAYS pull the latest staging branch before cherry-picking.</rule>
<rule id="changelog-conflicts">CHANGELOG conflicts: Agent resolves semantically (existing staging entries first, then the new entry). Code conflicts: STOP and report.</rule>
<rule id="no-force-push">Do NOT force-push staging without explicit user confirmation.</rule>
<rule id="no-editors">Never open editors. All git operations must be non-interactive: `GIT_EDITOR=true` for commit messages.</rule>
<rule id="push-confirmation">After all cherry-picks succeed, ask user before pushing to origin/staging.</rule>
<rule id="scripts-only">Use the companion script for cherry-pick operations. Do NOT manually run git cherry-pick sequences.</rule>
<rule id="unexpected-exit">Unexpected exit codes → STOP immediately and report to user.</rule>
</rules>

<scripts description="Companion scripts and their expected exit codes.">

| Script | Purpose |
|--------|---------|
| `staging-cherry-pick.sh` | Cherry-pick PR commits onto staging |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 |
|--------|--------|--------|--------|--------|
| `staging-cherry-pick.sh` | All cherry-picks succeeded | Error (code conflict, git failure) | Auth needed | CHANGELOG conflict (agent resolves) |

**Any exit code not in this table = STOP immediately and report to user.**
</scripts>

<step id="1" name="Identify Staging PRs">
Determine which merged PRs have CHANGELOG entries in the `## X.Y.Z (staging)` section. These are the PRs that need cherry-picking.

**When called from pr-land:** The caller provides the list of merged PRs and their merge SHAs.

**When called standalone:** Read the CHANGELOG diff for each PR to check if entries target the staging section.
</step>

<step id="2" name="Cherry-Pick">
```bash
echo '[{"repo":"...","prNumber":123,"mergeSha":"abc123"}]' | ~/.cursor/skills/staging-cherry-pick/scripts/staging-cherry-pick.sh
```

The script handles:
1. Fetching the merge commit SHA (from input or GitHub API)
2. Extracting individual commits from the merge
3. Checking out and pulling the staging branch
4. Cherry-picking each commit in order (oldest first)
5. Detecting and classifying conflicts

**On exit 3 (CHANGELOG conflict):**
1. Read the CHANGELOG with conflict markers
2. Resolve semantically: keep existing staging entries, add the new entry
3. `git add CHANGELOG.md && GIT_EDITOR=true git cherry-pick --continue`
4. Re-run the script for any remaining PRs
</step>

<step id="3" name="Push">
After all cherry-picks succeed, show the user what will be pushed:

```
Cherry-picked to staging:
  ✓ <repo>#<number> (<N> commits)
  ✓ <repo>#<number> (<N> commits)

Push to origin/staging? [y/N]
```

If confirmed:
```bash
git push origin staging
```
</step>

<step id="4" name="Restore Branch">
Return to the branch the user was on before cherry-picking:
```bash
git checkout <original-branch>
```
</step>

<edge-cases>
<case name="Empty cherry-pick">If a commit is already on staging (empty cherry-pick), the script skips it automatically.</case>
<case name="Code conflict">Script aborts the cherry-pick and reports the conflicting files. Agent STOPs and reports to user.</case>
<case name="Multiple PRs">Script processes PRs sequentially. Staging is checked out once and reused across PRs.</case>
<case name="No merge SHA provided">Script queries the GitHub API for the merge commit SHA.</case>
</edge-cases>
