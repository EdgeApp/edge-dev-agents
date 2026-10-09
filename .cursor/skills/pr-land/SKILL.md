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
/pr-land                                          # Asana "Merge/Finalize" section, my incomplete tasks, lowest release only
/pr-land 4.52                                     # Same section, only Release 4.52 tasks (= --release 4.52)
/pr-land --all-releases                           # Same section, every release
/pr-land --branch-scan                            # All EdgeApp repos with $GIT_BRANCH_PREFIX/* PRs (legacy)
/pr-land edge-react-gui                           # Specific repo (branch-prefix scan)
/pr-land edge-react-gui edge-core-js              # Multiple repos
/pr-land edge-react-gui#123                       # Specific PR (shorthand)
/pr-land https://github.com/EdgeApp/edge-react-gui/pull/<num>  # Specific PR (URL)
/pr-land https://app.asana.com/0/1234/5678        # Asana task → resolves linked PRs
/pr-land https://app.asana.com/.../task/<parent>  # Parent task → walks subtasks
/pr-land edge-react-gui#123 edge-core-js          # Mix: explicit PR + repo scan
/pr-land 4.52 --no-bugbot-wait                    # Arm without waiting on running reviewer bots
```

Arguments are classified automatically:
- **No args** → queries the Engineering Board's "Merge/Finalize" section (matched by name at call time in `pr-land-discover.sh`; a missing section errors with the names that exist), filters to incomplete tasks assigned to the current Asana user (resolved from `ASANA_TOKEN` via `~/.cursor/skills/asana-whoami.sh`), and walks each task's attachments + subtasks for GitHub PR links. Tasks with no PR link are reported in `errors` but do not block. Only ONE release lands per run: by default the lowest "Release (4.x.x)" among those tasks (4.51 and 4.52 both queued → only 4.51 lands). Later-release tasks and tasks with no release set come back in `deferredTasks`, unresolved.
- **A release** (`4.52`, or `--release 4.52`) → the same section scan, limited to that release. **`--all-releases`** → the same section scan with no release filter. Both refuse to combine with explicit args (exit 2); explicit args are never release-filtered.
- **`--branch-scan`** → legacy behavior: scans all EdgeApp repos for `$GIT_BRANCH_PREFIX/*` PRs.
- **Repo names** → branch-prefix scan, limited to the named repos.
- **PR URLs / shorthand** (`repo#N`) → fetched directly, no branch-prefix filter.
- **Asana task URLs** → resolved to linked GitHub PRs via Asana API (requires `ASANA_TOKEN`). Parent tasks are walked: each subtask's attachments are scanned for PRs; subtasks without a linked PR are skipped silently (e.g. a verification-only subtask).
- **`--no-bugbot-wait`** → combines with any form above. Pass it to discovery with the other args; discovery echoes it as `noBugbotWait: true` and step 5 reads it from there. Only the operator turns it on (their word "bugbot" covers every reviewer bot).
</usage>

<rules description="Non-negotiable constraints that bind in every phase. Phase rules live in the reference that owns them (see <step-map>).">
<rule id="scripts-only">All GitHub API calls go through companion scripts that use `gh` CLI internally. Do NOT call `gh` or `curl` directly for GitHub operations — use the scripts.</rule>
<rule id="gh-auth">If a script exits code 2 with `PROMPT_GH_AUTH`, prompt the user to run `gh auth login`.</rule>
<rule id="stale-prs">Stale PRs → Skip and report. Old PRs with multiple conflicts should be skipped like code conflicts. Don't block the flow.</rule>
<rule id="no-force-push">Do NOT force-push without explicit user confirmation.</rule>
<rule id="no-editors">Never open editors. All git operations must be non-interactive: `GIT_EDITOR=true` for commit messages, `GIT_SEQUENCE_EDITOR=:` for rebase todo lists.</rule>
<rule id="unexpected-exit">Unexpected exit codes → STOP immediately. If any script returns an exit code not documented in this file or in the phase reference that runs it, STOP and report to user. Do NOT attempt to interpret, retry, or work around unexpected errors.</rule>
<rule id="repo-land-mutex">One land train per repo at a time, MACHINE-WIDE — not just per invocation. land-on-approval means two approved tasks in the same repo can reach finalize concurrently; interleaved rebase/merge/publish trains against one base branch race each other. The companion scripts (prepare, merge, automerge, publish) enforce this mechanically via `repo-land-lock.sh` (lease per repo, 30-min TTL, renewals by the same session): exit 75 means another session holds the repo's land lease — WAIT (bounded, e.g. `sleep 120`) and retry the same call; never work around the lock, never start a parallel train, never release a lease you do not own. Prepare also exits 75 when the agent-watcher master-build refresh is building in the repo's primary checkout (stderr names its pid): same wait-and-retry, but it can run 20-90 min; never kill it (a killed build memoizes `failed_sha` fleet-wide). Operator shells share one owner id and self-coordinate.</rule>
<rule id="land-hold">Hold every repo the run touches for the WHOLE run, not only while a script runs. The agent-watcher refreshers (`refresh-master-build.sh`, `refresh-main-checkouts.sh`) reset, fast-forward and install in the same primary checkouts and skip any repo with an unexpired land lease; the per-script leases end with each call, so without a hold a refresh starts between steps and stomps the land. Right after step 1, take a run-level hold on every repo in `prs` plus `edge-react-gui`:
```bash
for r in <repo> [<repo>...] edge-react-gui; do ~/.cursor/skills/pr-land/scripts/repo-land-lock.sh acquire --hold --ttl 21600 --repo "$r" --owner "${AGENT_SESSION_UUID:-op-${USER:-shell}}"; done
```
Exit 75 on a repo = another session is landing there: wait and retry per `repo-land-mutex`. Re-run the same loop at the start of steps 6 and 8 (it renews; the expiry never shortens). Release it as the last action of the run on EVERY exit path (finished, partial, blocked, or stopped on an error): the same loop with `release --hold` in place of `acquire --hold --ttl 21600`. A hold left behind blocks the refreshers and every other land in those repos for up to 6 hours.</rule>
<rule id="defer-gui">If the discovered PR set contains BOTH `edge-react-gui` PRs and at least one non-GUI PR, all GUI PRs are DEFERRED — they do NOT enter steps 3-7 (prepare/push/merge/publish/upgrade-dep). GUI PRs are processed in step 8 (new) after step 7's dep upgrades land on develop. If the batch is pure GUI or pure non-GUI, no deferral — proceed as normal.</rule>
<rule id="asana-last">Asana updates are LAST, and they are PART OF THE LAND — a land is not finished until every fully-landed task got `--set-board-state "QA Verification" --unassign` (the handoff to QA). Do NOT update Asana tasks until ALL merges, publishes, and GUI dependency upgrades are complete. Only update status for PRs that are fully landed (merged, and if non-GUI: published + GUI deps updated). `agent_status = Complete` is a DIFFERENT field owned by one-shot and does NOT substitute for the board-state handoff: returning to one-shot's finalize before this step leaves the task assigned and out of Verification.</rule>
<rule id="build-field-routing">During discovery, resolve each linked task's Build field: `~/.cursor/skills/asana-build-field.sh <task-gid>`. `staging` → the PR is staging-targeted: pass `buildField: "staging"` for it in the step 3 prepare input (arming the `staging-task-under-unreleased` placement check, which moves a misplaced entry to the `(staging)` section mechanically — see step 3's placement-warning flow), and step 9 MUST cherry-pick its commits after merge even when its CHANGELOG entry sat under `## Unreleased` — a field/CHANGELOG disagreement is never a silent skip of the cherry-pick. A cheese value (anything the script's `--kind` mode classifies as `cheese`, never a list of names carried here) changes NOTHING about landing: land the task's FEATURE branch PR normally; a `test-*` branch is never a landing target (skip + report any discovered PR whose head branch matches `test-*`; see cheese `pointer-not-workspace`), and no re-cheese follows a land — CI builds wherever the landing happened (develop, or develop + staging).</rule>
</rules>

<step-map description="The phase sequence. READ a phase's reference file when you ENTER that phase; its rules bind exactly as if written here, and its rule and step ids are cited by id from anywhere. The script gate also delivers a slice at its phase's first companion-script call.">

| Step | Phase | Reference (under `~/.cursor/skills/pr-land/`) |
|---|---|---|
| 1 | Discovery, land hold, split by type | this file |
| 2 | Comment check and addressing | `references/comments.md` |
| 3-4 | Prepare and push; CHANGELOG and code conflicts at any step | `references/prepare.md` |
| 5 | Merge: auto-merge and watch, local fallback | `references/merge.md` |
| 6-7 | Batched publish, GUI dependency bumps | `references/publish.md` |
| 8 | Deferred GUI PRs, one at a time | `references/merge.md` |
| 9, 9b, 10 | Staging cherry-pick, late bot findings sweep, Asana QA handoff | `references/post-merge.md` |
| 11 | Return checkouts, release the hold, report | this file |

Step 9 runs no pr-land script, so the gate cannot deliver `references/post-merge.md` before it: read that file yourself before step 9.

</step-map>

<scripts description="Scripts every phase uses. Each phase reference lists its own scripts and exit codes.">

| Script | Purpose |
|--------|---------|
| `pr-land-discover.sh` | Discover PRs and approval status |
| `git-branch-ops.sh` | Shared autosquash / push helper for explicit git branch actions |
| `repo-land-lock.sh` | Per-repo land lease (`repo-land-mutex`); `acquire --hold` / `release --hold` for the run-level hold (`land-hold`) |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `pr-land-discover.sh` | Success | Error | Auth needed | - | - |
| `git-branch-ops.sh` | Success | Error | - | - | - |
| `repo-land-lock.sh` | Acquired / renewed / released / kept (held) | Not the owner, or lease expired (renew, release) | Usage | No lease (renew only) | - |

(`repo-land-lock.sh acquire` exit 75 = another session holds the lease; wait and retry per `repo-land-mutex`.)

**Any exit code not in this table or the running phase's table = STOP immediately and report to user.**
</scripts>

<step id="1" name="Discovery">
ONE tool call:

```bash
~/.cursor/skills/pr-land/scripts/pr-land-discover.sh [args...]
```

Args can be repo names, PR URLs, PR shorthand (`repo#N`), Asana task URLs (mixed freely), or `--branch-scan`.
No args = pull incomplete tasks assigned to me from the Engineering Board's "Merge/Finalize" section, keep only the lowest release, and walk each for PR attachments + subtask PR attachments. Use `--branch-scan` for the legacy "scan all EdgeApp repos for `$GIT_BRANCH_PREFIX/*` PRs" behavior.

Release selection is the operator's call, never the agent's: pass `--release <v>` only when the operator names a release ("land 4.52", "/pr-land 4.52 tasks" → `--release 4.52`, dropping the non-release words), and `--all-releases` only when they ask for every release. Otherwise run with no args and let the lowest-release default stand. Name the selected release in the landing summary and list every `deferredTasks` entry (name + release, or "no release set") as not landed.

Returns JSON: `{ "prs": [...], "errors": [...] }`, plus `release` (`mode`: lowest/requested/all, `selected`) and `deferredTasks` on a section scan. Each PR has `repo`, `prNumber`, `branch`, `title`, `approved`, `changesRequested`, `reviewers`. Errors include Asana resolution failures or PR fetch failures. `notOpen` lists named PRs that are already merged or closed (`state`): they are not in `prs` and need no work; list each in the step 11 summary. `noBugbotWait: true` is present only when the operator passed `--no-bugbot-wait`.

<sub-step name="Take the land hold">Run the `land-hold` acquire loop over the repos in `prs` plus `edge-react-gui`. From here on, every exit path ends with the release loop.</sub-step>

<sub-step name="Split by type">
After discovery, partition `prs` into `nonGuiPrs` (`repo !== "edge-react-gui"`) and `guiPrs` (`repo === "edge-react-gui"`).

1. If BOTH arrays are non-empty → mixed-batch path per `defer-gui`: only `nonGuiPrs` flow through steps 3-7. Tell the user: `Deferring <N> GUI PR(s) until after non-GUI deps are published and upgraded on develop.`
2. If only one array is non-empty → no deferral; all PRs flow through steps 3-7 normally.
</sub-step>
</step>

<step id="11" name="End-of-Workflow Report">
Before printing the summary, in this order:
1. Return every checkout this run prepared in to its default branch: `git -C ~/git/<repo> checkout <develop for edge-react-gui, master otherwise>`. A dirty tree stays as-is and goes in the summary.
2. Release the hold: the `land-hold` release loop.

```
=== PR Land Summary ===

Fully landed:
  ✓ <repo>#<number> (<branch>) — merged, cherry-picked to staging, Asana → QA Verification (N QA items)
  ✓ <repo>#<number> (<branch>) — merged, Asana → QA Verification
  ✓ <repo>#<number> (<branch>) — merged, published v<version>, GUI deps updated, Asana → QA Verification

Addressed but needs re-review:
  ⚠ <repo>#<number> (<branch>) — fixup pushed, awaiting review

Skipped (conflicts):
  ⚠ <repo>#<number> (<branch>) — stale / code conflict in <file>

Not published (outstanding PRs):
  ⚠ <repo> — N PRs skipped, publish deferred

Not landed (awaiting dependency publish):
  ⚠ <repo>#<number> (<branch>) — waits on <pkg>@<version>

Already merged/closed at discovery:
  - <repo>#<number> — merged

Late bot findings:
  ⚠ <repo> — N findings, M PRs unreviewed → <TASK_URL>
```
</step>
