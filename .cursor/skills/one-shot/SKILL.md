---
name: one-shot
description: End-to-end flow for a task: plan/context, implementation, PR creation, and Asana PR attach in one command.
compatibility: Requires git, gh, node, jq. ASANA_TOKEN for Asana integration. ASANA_GITHUB_SECRET is OPTIONAL — only needed when the Asana ↔ GitHub widget integration is enabled at the workspace level. Workflow does not depend on it; the Asana link in the PR body is the canonical link.
metadata:
  author: j0ntz
---

<goal>Run the full task-to-PR workflow in one command by orchestrating `/asana-plan`, `/im`, and `/pr-create`.</goal>

<rules description="Non-negotiable constraints.">
<rule id="orchestrate-existing-skills">Do not re-implement logic already defined in `/asana-plan`, `/im`, or `/pr-create`. Delegate to those skills.</rule>
<rule id="no-attach-default">By default, do NOT pass `--asana-attach` to `/pr-create`. The Asana ↔ GitHub widget integration is not assumed to be enabled, and the Asana link is already embedded in the PR body by `pr-create` whenever a task GID is available. Only pass `--asana-attach` when the caller explicitly opts in via `--asana-attach`. Do NOT pass `--asana-assign` — reviewer assignment is out of scope for this workflow (see `pr-create`'s `no-reviewer-assignment` rule).</rule>
<rule id="task-gid-for-pr-body-link">When a task GID is available (from Asana URL input or explicit `--asana-task` flag), always pass `--asana-task <gid>` to `/pr-create` so it injects the Asana link into the PR body. This is the canonical Asana ↔ PR link consumed by `pr-land`, standup, and other downstream skills.</rule>
<rule id="no-script-bypass">If any delegated skill or companion script fails, report and stop. Do not bypass with manual alternatives.</rule>
<rule id="pr-body-owned-by-pr-create">Do not draft alternate PR markdown formats inside this workflow. `/pr-create` owns PR body generation and template compliance.</rule>
<rule id="ignore-watchdog-revive-ping">If the user message is literally `<watchdog-revive-ping>` (and nothing else), respond with a single word `pong` and continue normal operations. Do NOT treat it as input to any pending question, do NOT advance or change plans, do NOT bind to any prior prompt. This is a watchdog-injected wake message used to revive a dead Remote Control bridge; it carries no user intent.</rule>
<rule id="agent-status-on-pending-task">When a task GID is available (from URL or `--asana-task`) AND that task has an `agent_status` custom field, update `agent_status` at each step boundary via `~/.config/agent-watcher/update-status.sh <task_gid> <Status>`. Status names: `Planning` (step 2), `Developing` (step 3), `Reviewing` (step 4), `Testing` (step 5, stays through step 6 watch loop), `Complete` (step 7 only — set ONLY when the watch loop reports all-green). If the task has no `agent_status` field (ordinary non-agent task), silently skip the updates — do not fail.</rule>
<rule id="yolo-hands-off-mode">When the `--yolo` flag is passed, run hands-off: do NOT pause for user confirmation of `/asana-plan` output, do NOT ask clarifying questions on uncertain choices, pick a defensible default and proceed. Record each deferred decision (question, chosen default, reversibility) under a "Deferred Decisions" section in the final report. Soft uncertainty (naming choices, code-style options, whether to add tests) is always deferrable.</rule>
<rule id="yolo-single-turn-execution">In `--yolo` mode, run ALL phases (Planning → Developing → Reviewing → Testing → Complete) within ONE agent turn. Invoke each delegated skill (`/asana-plan`, `/im`, `/pr-create`, `/build-and-test`) by reading its SKILL.md from `~/.cursor/skills/<name>/SKILL.md` and executing its logic inline, OR via the Skill tool — but do NOT end your turn between phases or write phase-completion messages that imply a hand-off back to the user. The only acceptable mid-task turn end is when (a) `agent_status` reaches `Complete` and the final report has been delivered, or (b) `blocked = Yes` is being set due to a true-blocker condition.</rule>
<rule id="yolo-true-blockers">Even in `--yolo`, STILL pause and set `blocked = Yes` on Asana when any of these apply: (a) destructive op with no recovery path (force push outside a PR branch, git history rewrite on shared branch, file deletion outside scratch/build dirs); (b) user-only credential needed (2FA, password, OAuth re-auth, signing key passphrase); (c) no defensible default exists (genuine ambiguity that could flip task outcome wholesale); (d) risk of overwriting unstaged user work (dirty working tree on a non-agent-created branch). When `blocked = Yes` is set, also write the reason to the Asana task as a comment.</rule>
<rule id="yolo-stop-at-pr">In `--yolo` mode, NEVER merge the PR, tag a release, deploy, publish a package, or perform any other "land/ship" action. The agent's terminal action is reaching `agent_status = Complete` after the watch loop reports all-green. Merging is the human's decision. Force-pushing to the PR's own branch (to apply review/CI fixes) is allowed and expected.</rule>
<rule id="pr-watch-loop-amend-pattern">When iterating on PR feedback (CI failures, bugbot findings, etc.) inside the watch loop, prefer `git commit --amend --no-edit` + `git push --force-with-lease` over fixup commits. The PR's history should stay a single clean commit (or the minimum set of logically distinct commits the original implementation needed). Never use `--force` without `--with-lease` — if the branch has been touched by someone else, that's a true-blocker (set `blocked = Yes`).</rule>
</rules>

<step id="1" name="Collect input">
Accept one of:

1. Asana task URL
2. Text/file requirements

Optional flags:

- `--asana-task <gid>` (explicit Asana GID override)
- `--asana-attach` (opt-in to the Asana ↔ GitHub widget attach step — requires the integration to be enabled at the workspace and `ASANA_GITHUB_SECRET` to be set; off by default per `no-attach-default`)
- `--yolo` (hands-off mode: defer soft questions to a final summary, only block on true-blockers — see `yolo-hands-off-mode` and `yolo-true-blockers` rules)
</step>

<step id="2" name="Plan/context phase">
Set agent_status=Planning (see `agent-status-on-pending-task`). Then run `/asana-plan` with the provided input mode:

- Asana URL mode: fetch task context and create plan
- Text/file mode: create plan from provided requirements

If `--yolo` is active, do NOT wait for user confirmation — accept the plan and move to step 3 immediately. Otherwise wait for user confirmation handled by `/asana-plan`.
</step>

<step id="3" name="Implementation phase">
Set agent_status=Developing. Then run `/im` using the approved `/asana-plan` output.
</step>

<step id="4" name="PR phase">
Set agent_status=Reviewing. Then run `/pr-create` — always pass `--asana-task <gid>` (so the Asana link gets embedded in the PR body, per `task-gid-for-pr-body-link`), and pass `--asana-attach` ONLY if the user explicitly opted in (per `no-attach-default`). Never pass `--asana-assign`.

Task GID source priority:

1. explicit `--asana-task <gid>`
2. Asana task URL from step 1
3. chat context from prior steps
</step>

<step id="5" name="Build and test phase">
Set agent_status=Testing. Run `/build-and-test` for local verification. If it fails, amend HEAD with the fix (`git commit --amend --no-edit`), `git push --force-with-lease`, and re-run `/build-and-test`. Repeat up to 2 times. If still failing after 2 attempts, set `blocked = Yes` with reason and stop — the watch loop is not entered.
</step>

<step id="6" name="PR watch loop (gate to Complete)">
The agent's session stays alive here, polling external green signals before marking `Complete`. Budget: 30 minutes total. Status stays at `Testing` throughout this loop.

Iterate until all-green OR budget exhausted:

1. **CI checks**: `gh pr checks <pr-num>`. Treat the rollup as:
   - All `pass` → CI is green
   - Any `pending` or `running` → wait, do not act yet
   - Any `fail` → read the failing job's log via `gh run view --log-failed`, apply a fix, `git commit --amend --no-edit`, `git push --force-with-lease`, restart loop
2. **Bugbot**: invoke `/bugbot` (per its own SKILL.md). It scans `cursor[bot]` threads and fixes valid findings. If bugbot self-schedules a recurring cycle, observe its progress on the next poll rather than blocking on it.
3. **Sleep 60 seconds** between iterations to avoid burning API quota.

Exit conditions:
- **All green** (CI pass + bugbot reports clean + no unresolved review threads): proceed to step 7.
- **30 min elapsed**: set `blocked = Yes` with a comment summarizing what was still red, then stop.
- **True-blocker hit during a fix attempt**: set `blocked = Yes` per `yolo-true-blockers`, stop.

Honor `yolo-stop-at-pr` strictly: never merge, never tag, never deploy. The loop's only mutations are force-pushes to the PR's own branch.
</step>

<step id="7" name="Report">
Set agent_status=Complete. Return the final PR URL and which delegated phases ran:

- planning: `/asana-plan`
- implementation: `/im`
- PR creation: `/pr-create`
- build/test: `/build-and-test`
- watch loop: number of CI iterations, bugbot iterations, time elapsed

If `--yolo` was active, include a "Deferred Decisions" section listing every soft question that was auto-defaulted: each entry has (a) the question, (b) the default chosen, (c) reversibility/blast-radius assessment. If no decisions were deferred, write "Deferred Decisions: none".
</step>

<edge-cases>
<case name="No Asana input with attach enabled">Fail fast and ask for `--asana-task <gid>` or disable the attach with `--no-asana-attach`.</case>
<case name="Ad-hoc text task">Allow workflow with `--no-asana-attach` when no task link/GID exists.</case>
</edge-cases>
