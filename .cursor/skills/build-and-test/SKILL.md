---
name: build-and-test
description: Run build and test verification for the active repo. Detects edge-react-gui and runs a real iOS UI test via maestro (Buy $500 quote with proof screenshot); detects Node/TypeScript repos and runs `tsc --noEmit` + smoke checks; falls back to a placeholder ack for unknown repo shapes. Use during the Testing phase of /one-shot.
metadata:
  author: j0ntz
---

<goal>
Verify the active repo builds cleanly before /one-shot marks a task complete. Returns a clear PASS/FAIL signal the caller can include in the Asana summary or use to gate the watch loop.
</goal>

<rules description="Non-negotiable constraints that bind in every phase. Phase rules live in the reference that owns them (see <step-map>).">
<rule id="autodetect-repo-shape">Inspect the current working directory to decide what to run:
1. If `package.json` `name` is `edge-react-gui` → iOS UI test path (step 0: `references/build.md`, then `references/drive.md`). Check this first.
2. Else if the repo is an EdgeApp gui DEPENDENCY (per `gui-dependency-integration`) → run its own checks (the TS/Node path below) AND the gui integration test. A dep change is NOT done until it runs in the app.
3. Else if `package.json` exists and a `tsconfig.json` exists → Node + TypeScript path (step 1).
4. Else if `package.json` exists with a `test` script but no tsconfig → Node path (step 2).
5. If `Cargo.toml` exists → not implemented yet, fall through to placeholder.
6. Otherwise → placeholder mode (step 3).</rule>
<rule id="report-failures-actionable">On FAIL, surface the exact command, exit code, and last 30 lines of output. Do not try to fix anything inside this skill: the caller decides whether to amend or block.</rule>
<rule id="no-mutation">This skill does NOT edit source code, commit, push, or change Asana state by default: verification + results only. The only exceptions are the explicitly scoped rules: `testids-over-coordinates` (testID additions as a separate commit IN the task's single gui PR, never a separate testID-only PR), `gui-dependency-integration` (gui-side changes a dep actually needs, committed on the gui branch), and the LOCAL-ONLY, never-committed corePlugins edits: `single-asset-plugin-trim` (currency trim) and `force-swap-provider-locally` (force a swap provider).</rule>
<rule id="scripts-over-inline">Deterministic operations (sim selection, RN build, capture loop) MUST run via the companion scripts under `~/.cursor/skills/build-and-test/scripts/`. Do not inline their logic as raw bash blocks in this skill's files or in agent reasoning.</rule>
<rule id="blocking-in-turn-waits">A critical-path wait (build, Metro bundle, screenshot, app-ready: anything you cannot proceed without) MUST be a single BLOCKING call inside the CURRENT turn. NEVER end your turn and hand the wait to a backgrounded shell expecting the background task to re-invoke you when it finishes: your forward progress then depends on an external re-invoke, and when the wait cannot complete you idle forever with no one driving. Same contract as one-shot's `never-self-respawn` and `pr-watch-bounded-poll`; an outside watchdog is NOT the safety net.
- **Do the wait, get a result, react, all in this turn.** Foreground it. Background-completion re-invoke is for parallel/optional work, NOT for a step the next step depends on.
- **Bound every wait with `timeout <seconds>`** so it ALWAYS terminates (success OR timeout) and control returns to you. (`timeout` is on PATH via the portable shim `~/.cursor/skills/timeout.sh`; macOS ships none.) An unbounded `until grep <marker> <logfile>; do sleep 5; done` hangs forever when the marker never appears. A timed-out wait is a real FAIL/retry to handle now, never a reason to spawn another waiter.
- **iOS builds run detached, then wait in chunks.** A cold build outlives the Bash tool's 600s cap, so never run a full build as one foreground call or under a hand-rolled nohup/poll loop: use step 0c's two commands (`references/build.md`, which also lists the wait's exit codes) and re-run `ios-rn-build-wait.sh` in this turn while it exits 7.
- **Any other long compile** (gradle, a hand-run xcodebuild) needs a stall check inside its bounded wait: log mtime frozen with no live compiler children means HUNG now; kill, diagnose, retry instead of waiting out the timeout. Use `capture-buy-quote.sh` (bounded retry cycles) for app capture.
- **Detect readiness against the resource you actually started, not a guessed log line:** `timeout`-bounded `curl` against the Metro you launched on its REAL port (`/status`, then the `index.bundle` URL); never `grep` a logfile whose name or marker you assumed.</rule>
<rule id="lockfile-driven-pm">Never assume a repo's package manager: repos migrate between npm and yarn. All install/run/pack operations go through the shared dispatcher `~/.cursor/skills/pm.sh`, which detects the lockfile (`package-lock.json`→npm, `yarn.lock`→yarn, both/neither→npm). Companion scripts in this skill already dispatch through it; do not hand-write `npm ...`/`yarn ...` against a repo without checking `pm.sh detect`.</rule>
<rule id="platform-ios-default-android-on-callout">PLATFORM: default to iOS. Provision the iOS sim, run the iOS flow, and credit `iOS Sim` UNLESS the task EXPLICITLY calls out Android (task title/description says Android, the task is tagged Android, or the change is under `android/` only). For an Android-called-out task, run the ANDROID path instead of (or in addition to) iOS: `./gradlew :app:assembleDebug` from the gui worktree's `android/` is the build verification, and a successful APK is the terminal-success signal for a BUILD-ONLY fix (GitHub `pr-checks.yml` does NOT build Android, so the local assembleDebug is the only check that catches these regressions). Credit `Android Sim` and log the attempt via `log-attempt.sh --category test-drive --result success|failed:<why>`. The Android build needs gitignored secrets the node_modules clone does not carry (`android/app/google-services.json`, `EdgeApiKey.java`, `android/app/src/main/assets/edge-core/plugin-bundle.js`, a generated `android/local.properties` with `sdk.dir`); `setup-task-workspace.sh` copies them, and the Android SDK (`ANDROID_HOME`/`ANDROID_SDK_ROOT`) must be present in the env. Run gradle with `--no-daemon` (or a per-slot `GRADLE_USER_HOME`) for parallel-safety; assembleDebug is CPU/RAM-heavy, so do not run many concurrently. A genuine in-app Android drive (AVD + maestro) is a larger path; the build-only check closes the regression gap for build/native fixes. If a task touches BOTH platforms, exercise iOS and credit both.</rule>
<rule id="test-on-sim-by-default">DEFAULT to physically exercising the change in the running app on the sim. Almost ANY task can be tested in-app: a swap, a send, a settings toggle, an onboarding/account-creation flow, a specific wallet action, a bug repro. `tsc`/jest/build passing is NECESSARY BUT NOT SUFFICIENT: a change is not verified until you have driven the actual changed behavior in the app and seen the expected result, to its TERMINAL success, not a precursor (`test-drives-the-real-action` sets the bar). Do NOT skip the sim test because static analysis "looks right", because the diff is small, or because authoring a flow is effort. Before setting `blocked = Yes` with reason "can't verify / no defensible default" on a bug, repro, or investigation task, you MUST first attempt the most-specific RUNTIME REPRO you can construct: build the relevant flavor (e.g. `ENABLE_MAESTRO_BUILD=true` for test-server flows) and drive the precise flow. "I can only trace it statically" is NOT a blocker. Block only if the repro is genuinely un-runnable here (missing creds/KYC/datastore the slot can't provide). For FUNDS specifically: the ONLY funds blocker is an OBSERVED TRUE LOSS, an attempted swap/send that failed AND lost principal. Fees/slippage NEVER count as loss (budgeted at $15 equivalent per run, per the playbook), and blocked-ness is established by ATTEMPTING, never predicted.</rule>
<rule id="test-drives-the-real-action">The test is COMPLETE only when the ACTUAL end-to-end user action the task is about has EXECUTED successfully in the app and you've captured proof of its terminal success state, NOT a precursor or a partial step. Per-action bar: a SWAP is done at the executed-swap success scene (e.g. "Congratulations" / order submitted), NEVER at the quote; a SEND at the broadcast/confirmation screen, not an address entered; a feature at its real user-visible outcome, not "it builds" / "the plugin loaded". (Exception: when the task's deliverable IS the precursor, e.g. the buy-quote smoke test exists to render a quote, that is the bar. Identify the actual user-facing outcome and drive to IT.)
ALL prerequisites to reach that terminal state are MANDATORY and not skippable, and the first one is finishing the IMPLEMENTATION itself: complete EVERY code change across ALL required repos so the feature is integrated and actually RUNNABLE in the sim: the core/dep change AND the gui-side wiring it needs (plugin init / apiKey, provider/plugin registration, imports, config). Do NOT stop at "core change written" or "it compiles". THEN: link the modified dep into core+gui (`gui-dependency-integration`), build, fund or switch accounts (`funded-test-accounts`), force the provider (`force-swap-provider-locally`, the local corePlugins edit, NOT in-app Exchange Settings), and execute. Drive through every step EAGERLY; do not declare done, and do not block, until the real action has actually run, unless you hit a genuine precondition the slot truly cannot satisfy (real funds/KYC/finality), in which case capture what you have and `blocked = Yes` with the specific precondition.
CEILING: the bar is the IN-APP success state, not EXTERNAL finality. Once the success scene shows and you've captured proof, you are DONE; do NOT then wait for on-chain settlement, full balance sync, or provider-side completion. Run each flow as a SINGLE bounded in-turn call (`timeout <seconds> maestro test <flow>`), never backgrounded-and-polled (`blocking-in-turn-waits`); bound every `extendedWaitUntil`.</rule>
<rule id="log-every-attempt">LOG every value-moving action and every test-drive/repro the moment it resolves, via `~/.config/agent-watcher/log-attempt.sh --gid <gid> --action "<what>" --result success|failed:<why>|loss:<detail>|blocked:<precond> --category swap|send|sweep|test-drive|repro`. This attempt-log (`$XDG_STATE_HOME/agent-watcher/attempts/<gid>.jsonl`) is the AUTHORITATIVE record of what the run actually attempted: the concession-validation gate reads it to tell a real wall (`loss:`/`failed:`/`blocked:` after an attempt) from a predicted one, on BOTH a formal `--blocked yes` AND a silent DOWNGRADE-finalize (completing or opening a PR without reaching the prescribed in-app success), and the eval reads it as ground truth for testing depth instead of trusting transcript narration. RESULT semantics: `success` = reached terminal success; `failed:<why>` = attempted, no success, principal safe (fees only); `loss:<detail>` = attempted, FAILED, principal unrecoverable (the ONLY funds condition that legitimizes a block); `blocked:<precond>` = attempted up to a precondition the slot genuinely cannot satisfy (real provider halt, geo-block confirmed by attempt).</rule>
<rule id="build-the-test-harness">The test harness is YOURS to build; its absence is NEVER a blocker. When driving the real behavior needs scaffolding that does not exist yet, CREATE it locally and uncommitted: author a new `.yaml` flow (per `maestro-flows-are-shortcuts`, expected, not exceptional), add a missing `testID` (`testids-over-coordinates`), trim unrelated plugins (`single-asset-plugin-trim`), disable a crashing module, or HARD-CODE the inputs the code path reads: fixtures, seed data, info-server/remote-config payloads, feature-flag state, a forced provider. "No flow exists for this", "the data comes from a remote server I don't control", "there's no fixture", "the feature isn't enabled by default" are NOT blockers and NOT reasons to stop at static analysis: they are scaffolding to BUILD. KEY DISTINCTION: hard-code the INPUTS to REACH and exercise the real logic, never fake the OUTPUT to fabricate a pass. Injecting a disable-map into the store so the REAL `isSpendBrandDisabled` filter runs against controlled data is correct; hard-coding "this brand is hidden" to skip the filter is not: the changed code path must actually execute. LOCAL-ONLY discipline (same as `single-asset-plugin-trim`): this scaffolding must NEVER land in a commit/PR. Revert it before any commit (verify `git status`/`git diff` is clean of it), or rely on it living only in the disposable test build. If you find yourself writing `blocked = Yes` or "could not test because <scaffolding> doesn't exist", stop: build the scaffolding and drive the test.</rule>
</rules>

<step-map description="Where the sim-test rules live. READ a reference when you ENTER its phase; its rules bind exactly as if written here, and its rule and step ids are cited by id from anywhere. The gates in the last column also deliver each slice at the call that starts its phase.">

| Phase | Reference (under `~/.cursor/skills/build-and-test/`) | Rules it owns | Delivered by the gate at |
|---|---|---|---|
| Step 0a-0c: preflight, sim selection, RN build, linking a gui dependency into the app | `references/build.md` | `preflight-before-build-decisions`, `slot-sim-is-the-clone`, `gui-dependency-integration` | first `slot-preflight.sh`, `select-ios-sim.sh`, `ios-rn-build.sh` or `ios-rn-build-wait.sh` call |
| Step 0d-0f: driving the app | `references/drive.md` | `maestro-flows-are-shortcuts`, `testids-over-coordinates`, `single-asset-plugin-trim`, `force-swap-provider-locally`, `runtime-inspection-via-debugger`, `spaced-pin-taps`, `no-hideKeyboard`, `no-hierarchy-polling-on-buy` | first maestro drive or `capture-buy-quote.sh` call |
| Proof frames, forced visual states, un-runnable assets | `references/evidence.md` | `proof-screenshots-for-pr`, `hack-verify-visual-changes`, `unrunnable-asset-proxy-verification` | first maestro drive or `capture-buy-quote.sh` call |
| Any test that needs a funded asset or moves value (swap, send, sweep) | `references/funding.md` | `funded-test-accounts`, `executable-pair-must-complete`, `create-missing-destination-wallet` | first `log-attempt.sh --category swap\|send\|sweep` (a backstop: read it yourself BEFORE choosing an account or a pair) |
| Steps 1-3: Node/TypeScript, Node, placeholder | this file | n/a | n/a |

Sim working knowledge (funding floors, roster switching, feature-enablement gotchas, investigation order) is in `references/sim-testing-playbook.md`; `maestro-flows-are-shortcuts` owns when to read it.

</step-map>

<step id="1" name="Node + TypeScript path">
Run, in order:

```bash
[ -d node_modules ] || ~/.cursor/skills/pm.sh install
npx tsc --noEmit
```

Emit PASS:
```
build-and-test: PASS (tsc --noEmit clean)
```

Or FAIL with the last 30 lines of failing output:
```
build-and-test: FAIL — <command> exit <code>
<last 30 lines>
```
</step>

<step id="2" name="Node path (no TypeScript)">
```bash
[ -d node_modules ] || ~/.cursor/skills/pm.sh install
~/.cursor/skills/pm.sh run test
```

Same PASS/FAIL contract as step 1.
</step>

<step id="3" name="Placeholder fallback (unknown repo shape)">
Emit exactly:
```
build-and-test: placeholder mode — no commands executed (repo shape not auto-detected).
```
Return success.
</step>
