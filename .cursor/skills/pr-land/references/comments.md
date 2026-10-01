Governs step 2 of `/pr-land` (comment check and addressing); the core step map points here.

<scripts description="This phase's companion scripts and their exit codes. Any exit code not listed here or in the core table = STOP and report (`unexpected-exit`).">

| Script | Purpose |
|--------|---------|
| `pr-land-comments.sh` | Check for recent unaddressed feedback (inline threads, review bodies, top-level comments) + unresolved reviewer-bot threads (`botThreads`, no recency filter — see `bot-thread-gate`) |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `pr-land-comments.sh` | Success | Error | - | - | - |
</scripts>

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
1. Bot findings: each PR entry's `botThreads` array lists unresolved reviewer-bot threads — these BLOCK arming per `bot-thread-gate`. Address every entry (fix-or-refute, reply, resolve) before the PR proceeds to step 5. Bot chatter that is not an unresolved thread is already filtered out.
2. Human reviewer comments are **blocking until the user decides how to handle them**. Use the `approved` and `changesRequested` fields from discovery to determine the path:
   1. **`changesRequested: true`**:
      - Treat the feedback as re-review-blocking
      - If the user wants it addressed now, make the fix as a visible fixup commit, push it with `~/.cursor/skills/pr-finalize-fixups.sh --owner <o> --repo <r> --pr <n>` (the review is active, so the plumbing push is gate-blocked while fixups are on the branch), reply/resolve the feedback, and **remove the PR from the merge set** so it can go back for review
      - If the user does not want to address it now, leave the PR out of the merge set and report it as blocked by requested changes
   2. **`approved: true` and `changesRequested: false`**:
      - DEFAULT: **address** the comments via the /pr-address flow below, without asking — the reviewer already approved, so follow-up comments are nits to fix, not re-review gates. Ask the user ONLY when a comment is ambiguous, expands scope beyond the PR, or you cannot determine the concrete change it wants.
      - To address each comment:
        1. Read the comment and understand the requested change
        2. Make the fix as a fixup commit: `~/.cursor/skills/lint-commit.sh --fixup <hash> --for human -m "<what changed and which comment it answers>" [files...]`
        3. Push the updated branch with `~/.cursor/skills/git-branch-ops.sh push --force-with-lease --branch <branch>`. Use `--force-with-lease` because `lint-commit.sh --fixup` may autosquash immediately.
        4. Reply on the PR item explaining what was fixed (1 sentence, factual):
           - **Inline** (`type: "inline"`): Use `commentId` and `threadId` from `pr-land-comments.sh` output with `~/.cursor/skills/pr-address/scripts/pr-address.sh reply ...` followed by `resolve-thread ...`
           - **Review body** (`type: "review-body"`): Use `reviewId` with `~/.cursor/skills/pr-address/scripts/pr-address.sh mark-addressed --type review ...`
           - **Top-level** (`type: "top-level"`): Use `commentId` with `~/.cursor/skills/pr-address/scripts/pr-address.sh mark-addressed --type comment ...`
        5. Continue the landing workflow immediately — do **not** remove the PR from the merge set solely because an already-approved reviewer left optional comments
   3. **`approved: false` and `changesRequested: false` with feedback present** — the Force Land shape (no human review exists): the comments are the ONLY human signal on the PR, so they get the SAME address flow as 2.2 (fix as fixup, push, reply, mark addressed), and a behavioral fix re-runs the relevant verification before the PR proceeds. One stricter default: a comment that disputes the approach or expands scope is treated as changes-requested in spirit — remove the PR from the merge set and report it; Force Land authorizes landing without a review, never landing over an objection.
   4. Continue with remaining PRs that have no outstanding blocking comment decision
   5. Report addressed-and-continued PRs, comments escalated to the user, and set-aside PRs at the end of the workflow

**Do NOT block the rest of the flow** for PRs with comments.
</sub-step>
</step>
