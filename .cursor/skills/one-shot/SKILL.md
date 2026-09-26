---
name: one-shot
description: End-to-end flow for a task: plan/context, implementation, PR creation, and Asana PR attach in one command.
compatibility: Requires git, gh, node, jq. ASANA_TOKEN for Asana integration. ASANA_GITHUB_SECRET is OPTIONAL — only needed when the Asana ↔ GitHub widget integration is enabled at the workspace level. Workflow does not depend on it; the Asana link in the PR body is the canonical link.
metadata:
  author: j0ntz
---

<goal>Run the full task-to-PR workflow in one command by orchestrating `/asana-plan`, `/im`, and `/pr-create`.</goal>

<rules description="Non-negotiable constraints. A segment can violate these before it reaches any phase, so they live here; every other rule lives in the phase reference that owns it (see <step-map>).">
<rule id="orchestrate-existing-skills">Do not re-implement logic already defined in `/asana-plan`, `/im`, or `/pr-create`. Delegate to those skills.</rule>
<rule id="run-rules">The run-wide rules `no-script-bypass`, `never-self-respawn`, `yolo-execution`, `mid-run-state-file`, `ignore-refired-one-shot`, `ignore-watchdog-revive-ping`, `usage-pause`, `watchdog-dialog-declined` and `operator-hold` live in `references/run-rules.md` and bind exactly as if written here; the SessionStart run-context hook injects that file at every context boundary, so it is in context from the first tool call. They are shared with `/task-run` (the no-PR run shape), which is why they are not in this body.</rule>
<rule id="agent-status-on-pending-task">When a task GID is available (from URL or `--asana-task`) AND that task has an `agent_status` custom field, update `agent_status` at each step boundary via `~/.config/agent-watcher/update-status.sh <task_gid> <Status>`. Status names: `Planning` (step 2), `Developing` (step 3 code implementation), `Testing` (step 4 on-sim/local verification — its own phase, after Developing and before the PR), `Reviewing` (step 5 PR creation through the step-6 watch loop — the PR is up and under review by CI, reviewer bots, and humans), `Complete` (step 7 only — set ONLY when the watch loop reports all-green per `finalize-gate`). STATUS LEADS THE WORK: set the phase status when you START doing that kind of work, never retroactively and never as a side effect of a terminal action — the board must describe what you are doing NOW. The step numbers above assume the full feature flow; when a run's shape differs (investigation-only with no code changes, a followup that jumps straight to verification, a re-gate pass), map by the KIND of work: reading/planning = `Planning`, editing code = `Developing`, exercising behavior (sim drives, live-chain repros, test suites) = `Testing`, PR up and being watched = `Reviewing`. Skipping a phase that genuinely has no work (e.g. no `Developing` on an investigation-only run) is correct; doing a phase's work under an earlier phase's status is not (the FIO run drove the sim for 25+ minutes under `Planning`, only setting `Testing` inside its block call). If the task has no `agent_status` field (ordinary non-agent task), silently skip the updates — do not fail.</rule>
</rules>

<task-routing description="Check these BEFORE anything else: each one redirects the whole run away from the build flow in <step-map>.">

**LAND/MERGE TASK ROUTING (check FIRST).** If the task's deliverable is to LAND or MERGE an existing PR rather than build something (per `yolo-stop-at-pr`'s land-task carve-out — name/description like "land", "merge", "finish landing <X> PR", or it points at a specific open PR with no new code expected), do NOT run the build flow (plan/im/pr-create). Move `agent_status` to `Reviewing`, run `/pr-land` against that PR (its default enables GitHub auto-merge so it lands when CI is green), then finalize: set `agent_status = Complete` once the PR is merged (or has auto-merge armed and is just waiting on green CI — say which in the report). This is the sanctioned land path in `--yolo`. Everything below is for normal build tasks.

**REVIEW-TASK ROUTING (check second).** If the task's deliverable is REVIEWING PR(s) rather than building or landing (signals: name/description like "review <X>", or the notes list PR URLs to review with no code deliverable), do NOT run the build flow and do NOT provision worktrees. Run `/pr-review` per named PR (deep default; pass a level only if the task names one). Statuses map by kind of work: `Planning` through the reviews, `Complete` after the report — no `Developing`/`Testing`, and `tested` is `Untested`. Posting follows pr-review's `posting-gate` orch default (no-post, drafts delivered in the run report and chat) unless the task text explicitly directs posting. The run report carries the curated findings; steps 3-6 below are all n/a.

**EXISTING-PR / COMMENT-ADDRESS ROUTING (check before building).** If this task already has an OPEN non-draft PR — a resume after a `Pending` bounce, OR a fresh-spawn whose prior transcript was pruned — do NOT rebuild from scratch and do NOT open a second PR. Detect it from the task's attached PR link (attached on the prior run per `attach-prs-by-default`), falling back to `gh pr list --state open --head "${GIT_BRANCH_PREFIX:-jon}/<short-name>"`. Re-provision on that PR's branch (`~/.config/agent-watcher/setup-task-workspace.sh --task-gid <gid> --repo <name> --existing-branch <pr-head-branch>`), then, in order: if `check-followup-scope.sh` reports a FIELD delta, re-enter the phase each changed field governs per `field-deltas-are-re-entry` (an `agent_review` value set after a Complete is re-armed HERE and nowhere else); if the PR has unresolved review threads, enter the comment-address path per `followup-reopens-status` (4); then re-gate, or resume the watch per `finalize-gate` when neither applies. This makes the comment-address loop correct whether or not the resume restored the prior transcript.

</task-routing>

<step-map description="The phase sequence. Each row names the phase, the `agent_status` it runs under, and the reference file carrying that phase's rules and step body. READ the reference file when you ENTER its phase; its rules bind exactly as if they were written here, and its rule ids are cited by id from anywhere.">

| # | Phase | agent_status | Reference (under `~/.cursor/skills/one-shot/`) |
|---|---|---|---|
| 1 | Intake and workspace | not set yet | `references/intake.md` |
| 2-3 | Plan and implementation | `Planning`, then `Developing` | `references/implementation.md` |
| 4 | Local verification | `Testing` | `references/testing.md` |
| 4.5 | Self-review (only when `agent_review` asks for it) | `Testing` | `references/review.md` |
| 5 | PR creation | `Reviewing` | `references/pr.md` |
| 6 | PR watch | `Reviewing` | `references/watch.md` |
| 7.0 | Land / cheese routing | `Reviewing` | `references/landing.md` |
| 7.1 | Run report | `Reviewing` | `references/report.md` |
| 7.2 | Finalize gate and Complete | `Complete` | `references/finalize.md` |

Cross-cutting. Read the file the moment its condition fires, whatever phase you are in:

| Condition | Reference |
|---|---|
| Followup: resumed on a task you already finished, or operator scope added since the last run report | `references/followup.md` |
| True-blocker: any blocked completion | `references/blocking.md` |
| Outbound comms: the deliverable includes a message to a human | `references/comms.md` |

</step-map>

<edge-cases>
<case name="No Asana input with attach enabled">Fail fast and ask for `--asana-task <gid>` or disable the attach with `--no-asana-attach`.</case>
<case name="Ad-hoc text task">Allow workflow with `--no-asana-attach` when no task link/GID exists.</case>
</edge-cases>
