# QA running phase

<rules>
<rule id="drive-through-build-and-test">Drive with `/build-and-test`, scoped to the approved cases. Read only the sections of `~/.cursor/skills/build-and-test/SKILL.md` and its references that the cases need. Its `qa-mode` rule binds: no hack edits, no tracked-file edits beyond the documented runtime switches, each switch reverted before the verdict.</rule>
<rule id="reuse-the-dev-app">The dev run's app comes from the native app cache: `ios-rn-build.sh` installs it with no compile. A cache miss builds once; say so in the report's environment line.</rule>
<rule id="log-every-attempt">build-and-test's `log-every-attempt` binds: every drive, funding attempt and repro goes through `~/.config/agent-watcher/log-attempt.sh`. The verdict judge reads only lines logged after this phase started.</rule>
</rules>

<step id="1" name="Drive">
Work in `REPO_DIR` on `SIM` / `METRO_PORT` from `qa-start.sh`. For each case in `APPROVED_PLAN`, in order: set its preconditions (account per the plan, funds per build-and-test's funding rules), drive its steps, capture a proof frame at the expected result, and record pass, fail or blocked with the frame name.
1. Result matches the expected → pass.
2. Result differs → reproduce once more on the same sha. Reproduced and caused by the app → fail. Not reproduced or caused by the harness → blocked, class `harness`.
3. A wall after the documented attempts (swap-to-fund, the 1Password Agent Share vault, a server probe) → blocked with its class; later cases still run when the wall does not stop them.
4. The expected result is arguable and the task does not settle it → blocked, class `task-drafting`, both readings stated.
</step>

<step id="2" name="Revert and verdict">
Revert every runtime switch, then confirm `git -C <REPO_DIR> status --porcelain` matches the start. Pick the verdict: any fail → Failed; else any blocked → Blocked; else Passed. Post per `references/verdict.md`.
</step>
