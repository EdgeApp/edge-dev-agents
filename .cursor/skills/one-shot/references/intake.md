Governs the intake and workspace-provisioning phase of `/one-shot` (before any `agent_status` is set); the core step map row `1. Intake and workspace` points here.

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="on-complete-is-not-scope">The task's `agent_on_complete` field is context, never scope: it lists what the operator wants done as the run's last action, right before `Complete` (finalize `on-complete-actions`). Do not execute, plan, or verify any of its lines earlier in the run, and do not count them as deliverables in the report.</rule>
<rule id="lane-release-after-plan">Immediately after planning resolves the task's COMPLETE target repo set, run ONE call: `~/.config/agent-watcher/lane-release.sh --task-gid <gid> --repos <a,b,c>` (comma-separated, every repo the plan touches). For a LAND/MERGE task (the `yolo-stop-at-pr` carve-out: the deliverable is landing an existing PR, no new code), run `lane-release.sh --task-gid <gid> --land` instead and skip workspace provisioning entirely (pr-land manages its own checkouts). The script owns the sim keep/release decision by lane union (capabilities.sh): your testing PLAN never enters it — a gui-dependency repo keeps the sim even when you believe unit tests suffice (that belief is the documented bias the test-evidence gate exists to correct, and correcting it must not require re-provisioning). Call it ONCE with the full list, never per-worktree (worktree order is not lane order; a mixed gui+reports task must keep its sim). Repos discovered later only ADD capability needs; do not re-run the release. If the repo set is uncertain, skip the call (an unreleased sim is the cheap error).</rule>
</rules>

<step id="1" name="Collect input">
Accept one of:

1. Asana task URL
2. Text/file requirements

Optional flags:

- `--asana-task <gid>` (explicit Asana GID override)
- `--no-asana-attach` (opt OUT of the GitHub-widget attach step; attach is ON by default per `attach-prs-by-default`. Attach uses `ASANA_GITHUB_SECRET` from credentials.json and degrades to a warning if absent)
- `--yolo` (hands-off mode: defer soft questions to a final summary, only block on true-blockers — see `yolo-execution` and `yolo-true-blockers` rules)

**Per-task worktrees (you create them).** When the agent-watcher spawns this session as a parallel slot, the working directory is `~/git` — NOT a pre-made worktree. Once the plan (step 2) identifies the target repo(s), create a dedicated, co-located worktree for each repo this task will modify:

`~/.config/agent-watcher/setup-task-workspace.sh --task-gid <gid> --repo <name> --branch "${GIT_BRANCH_PREFIX:-jon}/<short-name>"` → prints the worktree path. Derive `<short-name>` as a short kebab-case slug from the task title (same convention as `/im`'s `$GIT_BRANCH_PREFIX/<short-description>`, e.g. `upgrade-piratechain-sdks`) — descriptive, NOT the opaque task GID. Use the SAME `<short-name>` branch across every repo of this task.

They land together under `~/git/.agent-worktrees/<task-gid>/<repo>/` on the branch you passed, off `origin/develop`, with `env.json` copied in and `node_modules` APFS-cloned, so tooling + secrets work without extra setup. `cd` into the PRIMARY repo's worktree and do all build/test/commit/push there. (Manual, non-watcher runs already sit in a normal `~/git/<repo>` checkout — skip this provisioning.)

**Editing an EdgeApp gui dependency (edge-core-js, edge-currency-accountbased, edge-exchange-plugins, edge-currency-plugins, edge-login-ui-rn, …).** Create a co-located worktree for each repo the task actually modifies, under the same `~/git/.agent-worktrees/<task-gid>/` dir. For a dependency-only task that's just the dep; for a task that also changes gui code, both. That's ALL one-shot does for deps — it does NOT touch `DEBUG_*`/`updot`/`env.json`. Linking the modified dep into the app and exercising it is **entirely `/build-and-test`'s job** (`gui-dependency-integration`), which creates the co-located `edge-react-gui` worktree itself if the task didn't already. (Run repo scripts with each repo's package manager per its lockfile — yarn is being phased out, don't assume.)
</step>
