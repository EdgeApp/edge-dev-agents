---
name: pr-address
description: Address PR feedback with fixup commits, resolving each comment after replying. Use when the user wants to address review comments on a pull request.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Address PR feedback with fixup commits, resolving each comment after replying with how it was addressed.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">Do NOT call `gh` directly. Use `~/.cursor/skills/pr-address/scripts/pr-address.sh` for all GitHub API interactions (it uses `gh` internally).</rule>
<rule id="no-script-bypass">If a companion script fails, report the error and STOP. Do NOT fall back to raw `gh`, `curl`, or other workarounds.</rule>
<rule id="no-git-editor">All git commands that may open an editor (`rebase --continue`, `commit` without `-m`) MUST be prefixed with `GIT_EDITOR=true` to prevent blocking on `COMMIT_EDITMSG` in the IDE.</rule>
<rule id="no-gitkraken">NEVER use `git_log_or_diff:GitKraken`. Use local `git` commands directly.</rule>
<rule id="this-file-wins">If any other instruction conflicts with this file, **this file wins** for `pr-address`.</rule>
<rule id="commit-via-script">Commit fixups using `~/.cursor/skills/lint-commit.sh --no-reorder -m "fixup! {headline}" [files...]`. `--no-reorder` is required — the default reorder runs `rebase --autosquash` which squashes fixups immediately, conflicting with step 4's conditional autosquash. Do NOT manually run eslint — the commit script handles it.</rule>
<rule id="slot-after-each-fixup">Immediately after every successful `lint-commit.sh` call, run `~/.cursor/skills/slot-fixup.sh` to slot the new fixup next to its target's group. This keeps the "every fixup sits next to its target" invariant continuously. If `slot-fixup.sh` exits non-zero (rebase conflict), report and STOP — do not continue the address-pass.</rule>
<rule id="script-timeouts">GitHub API scripts can take up to 30s. Set `block_until_ms: 60000` when invoking `pr-address.sh`.</rule>
<rule id="reply-before-resolve">ALWAYS reply explaining how a comment was addressed BEFORE resolving or marking it. No silent resolutions.</rule>
<rule id="non-owner-reply-only">If you do NOT author the PR (`isOwner: false` in `fetch` output — i.e. `currentUser !== prAuthor`), you may reply to threads and push fixups, but you must NEVER resolve threads (`resolve-thread`) or post `mark-addressed` markers. Resolving/marking mutates the owner's PR state; leave every thread unresolved for the owner. This pairs with the finalize ownership guard (non-owner ⇒ `preserve` mode, never autosquash) — on a PR you don't own: push fixups + reply, never rewrite history, never resolve.</rule>
<rule id="resolution-source-of-truth">Only explicitly resolved threads (`isResolved: true`) or `<!-- addressed:... -->` markers count as resolved. Recency (commits after a comment) does NOT mean resolved.</rule>
<rule id="never-sets-completion">`/pr-address` is a ONE-OFF: it addresses the review comments present right now and stops. It must NEVER set `agent_status=Complete` or otherwise declare the task done — automated reviews (bugbot, CI, other reviewer bots) can land AFTER it finishes, so a one-off can't know the PR is finally green. Completion is owned by the continuous monitor (one-shot's step-6 watch, or `/bugbot`'s `finalize-gate` when invoked with a task GID). pr-address addresses comments and exits.</rule>
</rules>

<step id="0" name="Ensure correct branch">
Before any other work, ensure the PR's branch is checked out and up to date:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh ensure-branch --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

The script:
- If the PR branch is already checked out in **another git worktree** → pulls latest there and reports `WORKTREE_PATH=<dir>`, leaving the main checkout untouched (git forbids the same branch in two worktrees)
- If already on the PR branch → pulls latest
- If on a different branch → stashes uncommitted changes (if any), checks out the PR branch, pulls latest
- In every case, if the target directory has no `node_modules`, installs deps (`npm ci` or `yarn install` per the lockfile) so `lint-commit.sh`'s eslint resolves. **This can take several minutes on a cold worktree — invoke `ensure-branch` with `block_until_ms: 600000`.**

Output includes `BRANCH_READY`, `STASHED`, and (if switched) `PREVIOUS_BRANCH`. If `STASHED=true`, inform the user that changes were stashed on the previous branch.

<rule id="operate-in-worktree">If the output contains `WORKTREE_PATH=<dir>`, ALL subsequent git, commit, and companion-script operations for this PR MUST run inside `<dir>` — `cd "<dir>"` first (or pass `git -C "<dir>"`). Do NOT run them against the main checkout, and do NOT stash/switch the main checkout. The branch lives in that worktree.</rule>
</step>

<step id="1" name="Fetch all unresolved feedback and PR body">
Always fetch live from GitHub. Run both in parallel:

```bash
# Fetch unresolved feedback
~/.cursor/skills/pr-address/scripts/pr-address.sh fetch --owner <OWNER> --repo <REPO> --pr <NUMBER>

# Populate /tmp/pr-body.md from the live PR body (source of truth)
~/.cursor/skills/pr-address/scripts/pr-address.sh fetch-pr-body --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

If either script exits code 2 with `PROMPT_GH_AUTH`, prompt: "`gh` CLI is not authenticated. Please run: `gh auth login`"

The `fetch` output contains:
- **prAuthor**: The PR author's GitHub username (informational only — NOT used for filtering)
- **currentUser**: Your GitHub username (the authenticated `gh` user)
- **hasHumanReviewers**: `true` if any human (not `currentUser`, not bots) has commented — used for autosquash decision. In collab PRs, the GitHub-recorded author counts as a peer reviewer here.
- **humanReviewers**: List of human reviewer usernames (everyone except `currentUser` and bots)
- **threads**: All unresolved inline review threads (includes comments from `currentUser` for context)
- **reviewBodies**: Latest review body per human reviewer (excludes `currentUser` and bots)
- **topLevel**: Top-level comments (excludes `currentUser` and bots)

To inspect a specific inline thread, including an already-resolved one, use:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh fetch-thread \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --thread-id "<PRRT_threadNodeId>"
```

The `fetch-pr-body` call writes the current PR body to `/tmp/pr-body.md`. This file is available for editing throughout the session. If you need to update the PR body (e.g. to revise the description after addressing feedback), edit `/tmp/pr-body.md` via the Write tool and push it back:

```bash
gh pr edit <NUMBER> --body-file /tmp/pr-body.md
```
</step>

<step id="1.5" name="Squash stale fixups (Fixups A → squash before Fixups B)">
Before applying any new fixups for this address-pass, ask the shared finalize helper whether existing fixup commits on the branch are stale relative to the latest human review:

```bash
~/.cursor/skills/pr-finalize-fixups.sh squash-stale --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

The script returns one of:
- `{"action": "autosquash", "mode": "...", "newHead": "..."}` — existing fixups were squashed and force-pushed (clean slate for this pass).
- `{"action": "noop", "mode": "...", "reason": "..."}` — nothing to squash (no existing fixups, or fixups are still part of the current review cycle).

Policy (single source of truth lives in `pr-finalize-fixups.sh`): squash existing fixups when (a) mode is autosquash (no active reviewer), or (b) mode is preserve AND the latest human review timestamp postdates the latest fixup commit (the reviewer has already seen those fixups in their last review and has now come back with new feedback — start fresh). **Exception:** if you are not the PR author (`currentUser !== prAuthor`), squash-stale is always a noop — we never rewrite history on a PR we don't own.

If the script exits non-zero (conflict), report and STOP so the user can resolve manually.
</step>

<step id="2" name="Process all unresolved feedback">
Address every item returned by `fetch`. Group inline threads by file. If the user provided specific files, scope to those only.

<sub-step name="Determine fixup target">
Ask: **"Which commit introduced the behavior/code this comment is about?"**

- List commits touching the file: `git log --oneline -- <file>`
- A specific line/function → fixup the commit that introduced it
- A missing feature/behavior → fixup the commit that should have included it
- A pattern/style issue → fixup the earliest commit where it appears
- Ambiguous → ask the user

Get the target commit headline:
```bash
git log -1 --format='%s' <commit_sha>
```
</sub-step>

<sub-step name="Apply fixes">
For each comment (one fixup at a time):

1. Read the file
2. Apply changes — comment hunks can be narrower than intent; apply consistently within the function/file
3. Commit using `lint-commit.sh`:
   ```bash
   ~/.cursor/skills/lint-commit.sh --no-reorder -m "fixup! {targetHeadline}" [files...]
   ```
4. **Immediately slot the new fixup next to its target's group** (preserves the "every fixup sits next to its target" invariant continuously):
   ```bash
   ~/.cursor/skills/slot-fixup.sh
   ```
   If `slot-fixup.sh` reports a conflict, STOP — do not continue the address-pass. The user must resolve.

Repeat steps 1–4 for each remaining comment. Do not batch fixes across multiple comments before slotting.
</sub-step>
</step>

<step id="3" name="Reply and resolve each comment">
After fixing, reply to every processed comment — addressed or rejected — then resolve it.

**Ownership gate (check `isOwner` from Step 1 `fetch` output first):**
1. `isOwner: true` (you author the PR) → reply, then resolve threads / mark-addressed as described below.
2. `isOwner: false` (`currentUser !== prAuthor`) → **reply only**. Do NOT run `resolve-thread` and do NOT run `mark-addressed`. Leave every thread unresolved for the owner. Skip the resolve/mark sub-steps entirely.

<sub-step name="Inline threads (reply → resolve)">
If a later fix may affect an already-addressed inline thread, inspect the thread first:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh fetch-thread \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --thread-id "<PRRT_threadNodeId>"
```

Use the returned history to decide whether the existing reply still fully reflects the latest fix. If it does not, add one new factual follow-up reply. Multiple replies in the same thread are acceptable when they capture materially new fixes.

1. Reply to the first comment in the thread:
   ```bash
   ~/.cursor/skills/pr-address/scripts/pr-address.sh reply \
     --owner <OWNER> --repo <REPO> --pr <NUMBER> \
     --comment-id <NUMERIC_ID> --body "<what was fixed>"
   ```

   If the comment ID is a GraphQL node ID, resolve to numeric first:
   ```bash
   ~/.cursor/skills/pr-address/scripts/pr-address.sh resolve-id \
     --owner <OWNER> --repo <REPO> --pr <NUMBER> \
     --node-id "<PRRC_nodeId>"
   ```

2. Then mark the thread as resolved:
   ```bash
   ~/.cursor/skills/pr-address/scripts/pr-address.sh resolve-thread --thread-id "<PRRT_threadNodeId>"
   ```
</sub-step>

<sub-step name="Review bodies and top-level comments (reply → mark addressed)">
These have no native resolution mechanism. Post a top-level comment with a machine-readable marker:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh mark-addressed \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --type <review|comment> --target-id <NUMERIC_ID> \
  --body "<what was fixed>"
```

The script appends `<!-- addressed:review:ID -->` or `<!-- addressed:comment:ID -->` to the body. Subsequent `fetch` calls detect these markers and exclude already-addressed items.

**Skip bot-only no-op items**: If a review body or top-level comment is from an automated reviewer AND contains no inline threads with actionable suggestions — only a summary or status message — do NOT post a `mark-addressed` comment. The `fetch` script classifies automated reviewers robustly via GraphQL `author.__typename === 'Bot'` (which also strips the `[bot]` suffix, so every Cursor agent — Bugbot and the Cursor Security Reviewer — appears as `cursor`), plus a `[bot]`-suffix fallback and the hard-coded `chatgpt-codex-connector` User account. Human reviewer items must always be addressed or rejected, even terse ones like "This needs work".
</sub-step>

<sub-step name="Reply guidelines">
- **Addressed**: State what was fixed. Factual, 1 sentence.
- **Invalid/false-positive**: Brief evidence citing code paths or logic. 1-3 sentences.
- No pleasantries, no courtesy enders. Factual tone only. (Full external-prose standard: /no-slop, per writing-style.)
</sub-step>
</step>

<step id="4" name="Finalize fixups (autosquash or push, mode-dependent)">
Delegate the autosquash-vs-push decision and execution to the shared finalize helper. It calls `pr-address.sh review-mode` to derive the mode from the latest human activity, then either autosquashes + force-pushes (autosquash mode) or just force-pushes (preserve mode). Policy lives in that one script and is shared with other skills (bugbot) so behavior never drifts.

**Ownership guard:** if you are not the PR author (`currentUser !== prAuthor`), the helper forces `preserve` mode and never autosquashes — we never rewrite the history of a PR we don't own. Fixups stay on top for the owner to squash at merge.

```bash
~/.cursor/skills/pr-finalize-fixups.sh --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

Output is one line of JSON:
- `{"action": "autosquash", "mode": "autosquash", "newHead": "<sha>"}` — branch history rewritten, force-pushed.
- `{"action": "push", "mode": "preserve", "newHead": "<sha>"}` — fixups left in place for the reviewer to see; force-pushed (per-fixup slotting rewrote tip).

If the script exits non-zero, the autosquash hit a conflict mid-rebase. The working tree is in `REBASE_HEAD` state; report the error and STOP so the user can resolve manually (`git status`, fix files, `GIT_EDITOR=true git rebase --continue`, or `git rebase --abort`).
</step>

<step id="5" name="Verification">
Run full verification to catch issues introduced by fixup commits:

```bash
~/.cursor/skills/verify-repo.sh . --base <upstream-ref>
```

Where `<upstream-ref>` is `origin/develop` for `edge-react-gui` or `origin/master` for other repos. Set `block_until_ms: 120000`.

If verification fails, fix the issue with another fixup commit, then re-run verification.
</step>

<step id="6" name="Post-processing">
Propose modifications to `~/.cursor/rules/typescript-standards.mdc` to prevent similar review comments in the future. Prompt for confirmation before applying.
</step>

<edge-cases>
<case name="No gh auth">Script exits code 2 with `PROMPT_GH_AUTH`. Prompt user to run `gh auth login` and STOP.</case>
<case name="No unresolved feedback">Report "No unresolved comments on this PR" and STOP.</case>
<case name="Reviewer is still active">Mode is `preserve` — fixups are left in place for the reviewer to verify. They get squashed automatically on the NEXT address-pass once the reviewer comes back with more feedback (Step 1.5 squash-stale handles it), or on final merge.</case>
<case name="Comment already addressed in code">If the current code already handles the feedback (e.g., from a previous fixup), still reply explaining this and resolve/mark the comment. Do not leave it unresolved. (Exception: if `isOwner: false`, reply only — never resolve/mark, per `non-owner-reply-only`.)</case>
<case name="Not the PR author (isOwner: false)">When `fetch` reports `isOwner: false` (`currentUser !== prAuthor`), reply to every processed thread explaining the fix, but never resolve threads or mark-addressed — leave them for the owner. Combined with the finalize guard, the whole pass on an unowned PR is: push fixups + reply, with no history rewrite and no resolutions.</case>
<case name="Already resolved thread needs follow-up">Fetch the thread history first. If the prior reply no longer reflects the latest fix, post one additional factual follow-up reply. Do not edit or delete prior replies in this workflow.</case>
<case name="Slot-fixup conflict">If `slot-fixup.sh` exits non-zero, the rebase has been aborted automatically (working tree is clean) but the new fixup is still at tip, not yet slotted next to its target. Report to the user and STOP. They can either resolve the conflict manually or revert the fixup and re-approach.</case>
</edge-cases>
