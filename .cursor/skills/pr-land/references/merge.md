Governs step 5 of `/pr-land` (auto-merge, watch, local fallback) and step 8 (the deferred GUI PRs, which reuse step 5); the core step map points here.

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="bot-thread-gate">REVIEWER BOTS FINISH BEFORE AUTO-MERGE IS ARMED. Armed auto-merge fires the instant REQUIRED checks go green; reviewer bots are not required checks, so a bot still reviewing HEAD loses that race and its finding lands on an already-merged PR, costing a second PR to fix what a fixup would have covered. Required CI blocks the merge by itself, so arming early buys nothing. `pr-land-automerge.sh` enforces this: `waiting` + exit 76 while any reviewer-bot check-run is PENDING on HEAD, `blocked` on an unresolved reviewer-bot thread. Wait for the bots and re-run the same call; never route around the gate. A reviewer that posts NO check-run is unavailable, not pending, and never holds a land. ANY force-push to an ARMED PR (comment fixups, NEEDS_REBASE re-prepare) re-runs the bots under live auto-merge, which is the same race: `pr-land-automerge.sh --disarm` FIRST, push, then re-arm through the gate. Unresolved reviewer-bot threads block arming with NO recency exemption — bot findings on old commits still gate (`pr-land-comments.sh` emits them under `botThreads`, detected by `__typename == "Bot"` on the thread's first comment, the same shared detection one-shot's finalize-gate prescribes): address each entry (evaluate the finding; fix valid ones as a fixup + reply + resolve, refute invalid ones with a reply + resolve — /bugbot semantics). A bot check-run conclusion of `skipping`/`NEUTRAL` is not findings-clean; the unresolved-thread query is the gate. ONE EXCEPTION, operator-only: with `--no-bugbot-wait` (discovery `noBugbotWait: true`), step 5 arms while reviewer check-runs are still pending; unresolved bot threads still block arming, and findings that arrive after a merge are harvested by step 9b. An agent never adds the flag on its own.</rule>
<rule id="force-land-review-bypass">Force Land is NOT a CI bypass — it substitutes for exactly ONE thing: the human APPROVED review. When branch protection requires an approving review that does not exist, armed auto-merge can never fire; `pr-merge-watch.sh` surfaces this as `BLOCKED_ON_REVIEW` (exit 6), and it does so ONLY once every check on HEAD is complete and green with zero pending. Only at that verdict, and only when the landing authority is Force Land (`~/.cursor/skills/asana-force-land.sh <gid>` prints `land-approved`), merge with `gh pr merge --admin` — the admin flag bypasses exactly the review requirement. COMMENTS GATE THE ADMIN MERGE: immediately before `--admin`, re-run `pr-land-comments.sh` on the PR — feedback can arrive between arming and the verdict, and the admin merge is the moment a human review would normally intervene. Any unresolved feedback (human or bot) is addressed per Step 2's comment handling first (a fix pushes new commits, which restart CI and the watch — the admin merge waits for the NEXT clean BLOCKED_ON_REVIEW); a substantive objection removes the PR from the merge set per Step 2 comment path 3. NEVER `--admin` over pending, queued, or failing checks (a red or running check always waits or follows CHECK_FAILED/NEEDS_REBASE handling), never for DIRTY/BEHIND (rebase first), and never without Force Land authority — a human-approved PR merges via auto-merge on its own, and a PR with neither approval nor Force Land is reported as waiting on review. THE RATIONALE GOES ON THE PR, immediately after the comment recheck and immediately before `--admin`: `force-land-rationale.sh --owner <o> --repo <r> --pr <n> --task-gid <gid> --rationale "<one clause>"`. Write the rationale as the change class that made review unnecessary — a docs-only change, a minor UI-only change, a copy tweak — never "the operator set Force Land", which is the authority the script already states. Still disclose the merge in the landing's Asana comment (what was bypassed, under which authority): the two comments have different readers.</rule>
<rule id="sequential-rebase">Sequential merging requires rebase. Each subsequent PR MUST be rebased onto the updated base branch after the previous merge.</rule>
<rule id="same-repo-batching">Multiple PRs against the SAME repo land serially, not in parallel: arming auto-merge on all at once makes each merge invalidate the others' rebases (every survivor goes DIRTY/BEHIND on the shared CHANGELOG and re-conflicts, one round per merge). Arm/watch one PR per repo at a time; when `pr-merge-watch.sh` exits NEEDS_REBASE for the next PR, re-run prepare — its CHANGELOG conflict resolves mechanically via `changelog-union-merge.sh <repoDir> --continue`, then push and rearm. PRs in DIFFERENT repos proceed in parallel as usual.</rule>
</rules>

<scripts description="This phase's companion scripts and their exit codes. Any exit code not listed here or in the core table = STOP and report (`unexpected-exit`).">

| Script | Purpose |
|--------|---------|
| `pr-land-automerge.sh` | Arm GitHub auto-merge (or turn it off with `--disarm`), gated on reviewer bots being done and bot threads clear (see `bot-thread-gate`); `--no-bugbot-wait` drops the reviewer wait only |
| `pr-merge-watch.sh` | Babysit armed PRs: poll until all merge (`ALL_MERGED <repo#num>=<mergeSha> ...`), a check fails, one needs a rebase (DIRTY, or BEHIND with green checks — auto-merge never updates a BEHIND branch), or one is green but blocked solely on a missing approving review |
| `pr-land-merge.sh` | Rebase + verify + merge via GitHub API |
| `force-land-rationale.sh` | Post the pre-merge rationale comment an admin merge requires and write the marker its gate reads (see `force-land-review-bypass`) |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `pr-land-automerge.sh` | All armed/disarmed/merged | Blocked / unsupported / error | Usage or missing dep | - | - |
| `pr-merge-watch.sh` | All merged | Usage error | - | Needs rebase (re-prepare listed PRs) | Check failed |
| `pr-land-merge.sh` | Merged | Verify fail | - | - | Conflict needs resolution (CHANGELOG or code) |
| `force-land-rationale.sh` | Posted (marker written) | Checks not green / error | Usage, or no Force Land authority | - | - |

(`pr-land-automerge.sh` exit 75 = another session holds the repo land lease, per `repo-land-mutex`. Exit 76 = at least one PR is only WAITING on a reviewer bot: nothing to fix and nothing armed — let the bots finish, then re-run the same call.)

(`pr-merge-watch.sh` exit 5 = overall timeout with PRs still pending. Exit 6 = `BLOCKED_ON_REVIEW`: all checks green, only the approving review missing — handle per `force-land-review-bypass`. Exit 7 = `CONTINUE`: the per-call cap hit (each invocation self-bounds under the Bash foreground limit) — re-invoke with the SAME args immediately; the overall --timeout budget persists across calls, so this is one bounded watch, not a fresh one.)
</scripts>

<step id="5" name="Merge">
**DEFAULT: local-gate, then arm auto-merge, then watch CI.** The default land path verifies locally first, then hands the merge to GitHub and babysits CI to completion:

1. **Local gate (Steps 3-4):** run Step 3 `pr-land-prepare.sh` (autosquash + rebase onto upstream + `verify-repo.sh`) and Step 4 push FIRST. This catches breakage locally before CI spends time on it. Only branches that reach `status: ready` and are pushed proceed to arm.
2. **Confirm + arm (after the bots, never before):** after Step 1-2 (discovery + comments addressed/approved) and the local gate, confirm with the user, then arm GitHub auto-merge so each PR merges itself when its required CI checks go green (GitHub owns the rebase/queue and the actual merge). Arming waits on the reviewer bots completing on the PUSHED head per `bot-thread-gate`:

   ```bash
   echo '[{"repo":"...","prNumber":123}, ...]' | ~/.cursor/skills/pr-land/scripts/pr-land-automerge.sh
   ```

   When discovery returned `noBugbotWait: true`, run the same call with the flag instead:

   ```bash
   echo '[{"repo":"...","prNumber":123}, ...]' | ~/.cursor/skills/pr-land/scripts/pr-land-automerge.sh --no-bugbot-wait
   ```

   Per-PR result lines: `armed` (auto-merge on; GitHub merges on green), `merged` (already merged), `waiting` (a reviewer bot is still running on HEAD — NOT armed), `blocked` (changes requested, or an unresolved reviewer-bot thread — resolve first), `unsupported` (repo disallows auto-merge/merge-commit → use the local fallback below), `error`. Exit 0 = all armed/merged. Exit 76 = `waiting` only: let the bots' check-runs finish (`gh pr checks <n>`, or `watch-pr.sh` in an orchestrated run), then re-run the SAME call — nothing was armed, so the re-run is the whole remedy.
3. **Watch until merged or actionable (babysit):** run the watcher over every armed PR (background it for long CI). Do NOT walk away at `armed`:

   ```bash
   ~/.cursor/skills/pr-land/scripts/pr-merge-watch.sh <repo#num> [more...] [--timeout 3600]   # re-invoke on exit 7 (CONTINUE) until a terminal verdict; the 3600s budget spans the calls
   ```

   Act on the exit code — every non-zero exit is actionable, never a stop-and-wait:
   - **0 ALL_MERGED `<repo#num>=<mergeSha> ...`** → record each PR's `mergeSha` (step 9 cherry-picks it; step 9b sweeps the PR), move on.
   - **3 NEEDS_REBASE `<prs>`** → the base moved (DIRTY, or BEHIND with green checks — GitHub auto-merge NEVER updates a BEHIND branch; unwatched it stalls forever). DISARM the listed PRs first (`pr-land-automerge.sh --disarm`): the re-push re-triggers the reviewer bots, and a live auto-merge races them per `bot-thread-gate`. Then loop them back through prepare (step 3; CHANGELOG conflicts resolve via `changelog-union-merge.sh`) and push (step 4), re-run the step 2 comment check once their bot check-runs complete, and re-arm through step 5.2. Re-invoke the watcher.
   - **4 CHECK_FAILED `<pr>`** → report the failing check, leave auto-merge armed unless the user says to disarm, keep watching the others. Do not local-merge around a red check.
   - **5 TIMEOUT** → CI still running; re-invoke to keep watching.
   - **6 BLOCKED_ON_REVIEW `<prs>`** → every check on HEAD is green; the only unmet branch-protection requirement is an approving review. With Force Land authority, admin-merge per `force-land-review-bypass` and disclose it; otherwise leave auto-merge armed and report the PR as waiting on human review.

   Only finalize the land once every armed PR has either merged or been reported as blocked.

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

<step id="8" name="Prepare and Merge GUI PRs (deferred)">
**Trigger:** Only runs when `guiPrs` was populated at step 1 AND every GUI-dep repo that merged in this run has published + upgraded on develop (step 7). Skip entirely if no GUI PRs exist. If a required step 7 upgrade failed, also skip this step. When the batch's non-GUI repos were all non-deps (step 6's GUI-dep check skipped them), there is nothing to wait for — proceed with the GUI PRs directly.

At this point, `origin/develop` contains the new dep-upgrade commits from step 7, so each GUI PR will rebase cleanly onto a develop that already has its new dep versions.

Re-run the `land-hold` acquire loop, then land the GUI PRs ONE AT A TIME (`same-repo-batching`), each through steps 3, 4 and step 5's DEFAULT auto-merge path:

1. Feed the one PR into `pr-land-prepare.sh` (same invocation shape as step 3). On CHANGELOG conflict: `changelog-union-merge.sh <repoDir> --continue`, re-run prepare.
2. Push with `~/.cursor/skills/git-branch-ops.sh push --force-with-lease --branch <branch>` (step 4).
3. Arm with `pr-land-automerge.sh` (step 5.2, adding `--no-bugbot-wait` when discovery returned `noBugbotWait: true`).
4. Watch with `pr-merge-watch.sh` (step 5.3) until `ALL_MERGED`; record its `mergeSha`.
5. Next GUI PR: back to 1 (its prepare rebases onto the PR that just merged).

Use `pr-land-merge.sh` only under step 5's FALLBACK conditions (auto-merge `unsupported`/`blocked`, a conflict needing local resolution, or an explicit immediate-merge request).

Do NOT re-enter steps 6 or 7 — GUI does not publish to npm and has no deps of its own to upgrade.
</step>
