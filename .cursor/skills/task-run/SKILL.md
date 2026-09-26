---
name: task-run
description: Orchestrated run for a task whose deliverable is NOT a pull request (Asana agent_deliverable = Task; agent_lane says whether it gets a simulator): research, replays, audits, harness or doc work, investigations on a simulator. Plan, do the work, post one findings comment, attach a run report, Complete. The watcher invokes it as `/task-run --yolo <asana-url>`; it is the no-PR counterpart of /one-shot.
compatibility: Requires jq and ASANA_TOKEN (exported by the spawn script). A run whose agent_lane includes iOS Sim also has AGENT_SIM_UDID and AGENT_METRO_PORT.
metadata:
  author: j0ntz
---

<goal>Deliver a non-PR task end to end in one hands-off turn: ingest, plan, do the work, post the findings as one Asana comment, attach the run report, set Complete.</goal>

<rules description="Non-negotiable constraints. The run-wide rules (`yolo-execution`, `yolo-true-blockers`, `mid-run-state-file`, `operator-hold`, `never-self-respawn`, `no-script-bypass`, `ignore-refired-one-shot`, `ignore-watchdog-revive-ping`, `usage-pause`, `watchdog-dialog-declined`) live in `~/.cursor/skills/one-shot/references/run-rules.md`, injected at every context boundary, and bind here exactly as written there.">
<rule id="no-pr-no-worktree">This shape opens no pull request, creates no worktree, and never calls `pr-create.sh`, `setup-task-workspace.sh`, `/build-and-test` or `/pr-land`. Work that turns out to need a PR is surfaced, not done: say so in the findings comment and the report, and finish this task as a Task deliverable. The operator re-files the code work as a PR task.</rule>
<rule id="status-walk">Statuses via `~/.config/agent-watcher/update-status.sh <gid> <Status>`: `Planning` when ingestion starts, `Developing` while doing the work (scripts, replays, drives, reading, writing), `Complete` at the end. No `Testing` or `Reviewing`. A `review-field-routes` run stays at `Planning` through the reviews and goes straight to `Complete`. STATUS LEADS THE WORK: set the status when the kind of work starts, never retroactively.</rule>
<rule id="review-field-routes">The `agent_review` field is an operator ask on this shape. Resolve it at intake with `~/.cursor/skills/asana-review-field.sh <gid> --variant`. Any output other than `none` makes the deliverable one `/pr-review` round at that level on every open PR attached to the task or its subtasks (enumerate with `~/.cursor/skills/pr-land/scripts/pr-land-discover.sh <asana-task-url>`: the full URL, since a bare gid parses as a release filter), run in addition to anything the description asks. On a FOLLOWUP the round is scope, beyond what `check-followup-scope.sh` lists, when the field changed since the previous segment OR no earlier run report on the task records a review round at this level. Invoke `/pr-review <pr-url> <level> --comment` per PR: the field is the posting direction, so findings post through pr-review's step-6 submit under its `review-event-mapping`. Non-operator comments on the task are review context, not proposals awaiting a ruling: the route never enters `Developing`, so task-review `operator-final-say` does not block it. The findings comment lists, per PR, the verdict submitted, the findings posted (severity, file:line) and the ones rejected in curation; the report's Testing section carries the same.</rule>
<rule id="sim-only-when-provisioned">`AGENT_SIM_UDID` set means the task's `agent_lane` provisioned a simulator: the slot's simulator and Metro port are yours for the whole run, and the sim mechanics (select, preflight, capture, proof frames) are the ones build-and-test's scripts implement; read only the section of `~/.cursor/skills/build-and-test/SKILL.md` that the task's drive needs, never the whole skill. `AGENT_SIM_UDID` unset means a Task run: no simulator exists for this task, and provisioning one (simctl clone, pool scripts) is forbidden; if the task needs a device, that is a true blocker (`yolo-true-blockers`), not a workaround.</rule>
<rule id="findings-comment">The findings are delivered as exactly ONE Asana comment, posted before the run report is attached (comments before attachments, per one-shot `report-as-attachment`): `~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task <gid> --comment-file <file>`. Plain text, no em dashes, /no-slop. Lead with the answer, then the numbers, then what was not done and why. Link every artifact the run produced (a file path on this box, a gist revision, a doc) so a reader can verify without the transcript. Nothing else is posted during the run.</rule>
<rule id="artifacts-stay-local-unless-asked">Files the run writes live under the path the task names, or under `~/.config/<area>/` when it names none. No commits, pushes, or gist edits unless the task asks for them; a task that asks for a gist push lints the file with `~/.cursor/skills/no-slop/scripts/no-slop-lint.sh` first.</rule>
<rule id="report-shape">The run report uses the same template and attach path as /one-shot (`~/.cursor/skills/one-shot/references/report.md`, rule `report-as-attachment`, binds here). Frontmatter for this shape: `pr: none`, `repo: ""`, `branch: ""`, `verified: n/a` when nothing had a runtime surface to exercise, otherwise `pass`/`partial`/`not-run` with the same honesty rule. The Finalize Gate section reads `N/A: no PR deliverable` and nothing else. Every other section is filled or `_None observed._`.</rule>
</rules>

<step id="1" name="Intake">
Set `Planning`. Ingest the task with `~/.cursor/skills/asana-get-context.sh <gid>` (task, comments, subtasks, attachments into `/tmp/asana-task-<gid>/`). Read every downloaded attachment; attachments are requirements. Resolve `agent_review` per `review-field-routes`; a non-`none` level is scope even when the description is empty. Operator text outranks agent-authored text, newest first. A task that already carries a run report is a FOLLOWUP: run `~/.config/agent-watcher/check-followup-scope.sh --task-gid <gid>` and the scope is only what it lists (one-shot `followup-scope-is-the-deliverable`, in `references/followup.md`, which the run-context hook injects for such tasks).
</step>

<step id="2" name="Plan">
Follow `~/.cursor/skills/asana-plan/SKILL.md` (injected at boot). Write `/tmp/plan-<gid>-<short-title>.md` with the `agent_session_uuid:` stamp, then attach it: `asana-task-update.sh --task <gid> --attach-file <plan> --attach-name plan-<short-title>.md`. The plan names, per ask: the artifact that will answer it, the number or evidence that decides it, and the budget (API spend, wall clock). Start `/tmp/agent-state-<gid>.md` (`mid-run-state-file`).
</step>

<step id="3" name="Do the work">
Set `Developing`. Execute the plan. Every script prints aggregates, never bulk fetched text, so results stay readable and the context stays small. Record each decision and each verified fact in the state file as it happens. A wall that the prescribed remedy does not clear is a true blocker per `yolo-true-blockers` (`~/.cursor/skills/one-shot/references/blocking.md`, read at that moment): `update-status.sh <gid> Complete --blocked yes --reason "<precise blocker>"`, then step 5 with the blocker named.
</step>

<step id="4" name="Findings comment">
Write `/tmp/comment-<gid>.txt` per `findings-comment` and post it. Then, when what was delivered differs from what the description says, refresh the CURRENT STATE tail per one-shot `description-current-state` (`--set-current-state`).
</step>

<step id="5" name="Report and Complete">
Re-read the template `~/.cursor/skills/one-shot/templates/agent-run-report.md` immediately before writing the report (never from memory). Fill it per `report-shape`, write `/tmp/agent-run-report-<gid>-<n>.md`, attach it with `--attach-name agent-run-report.md`, then run the operator's last action per one-shot finalize `on-complete-actions` (`~/.cursor/skills/one-shot/scripts/asana-on-complete-actions.sh --task <gid> --pending`, carry out each line, `--mark` the outcomes), then set `Complete`. The completion judge rules on the comment and the report; a failed verdict names the gap, fix it in this turn and retry.
</step>

<edge-cases>
<case name="The task turns out to need a PR">Do the non-code part, state in the comment exactly what code change is needed and where, finish as Task. Never open the PR from this shape.</case>
<case name="The task names a device but the run is Task (no sim)">True blocker with reason "task needs a simulator; set agent_lane = iOS Sim and re-arm".</case>
<case name="Nothing to verify at runtime">`verified: n/a`, and the Testing section says what evidence stands in for a drive (script output, replay numbers, a diff of a doc).</case>
</edge-cases>
