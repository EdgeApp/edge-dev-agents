---
name: build-and-test
description: Run build and test verification for the active repo. Detects edge-react-gui and runs a real iOS UI test via maestro (Buy $500 quote with proof screenshot); detects Node/TypeScript repos and runs `tsc --noEmit` + smoke checks; falls back to a placeholder ack for unknown repo shapes. Use during the Testing phase of /one-shot.
metadata:
  author: j0ntz
---

<goal>
Verify the active repo builds cleanly before /one-shot marks a task complete. Returns a clear PASS/FAIL signal the caller can include in the Asana summary or use to gate the watch loop.
</goal>

<rules description="Non-negotiable constraints.">
<rule id="autodetect-repo-shape">Inspect the current working directory to decide what to run:
1. If `package.json` `name` is `edge-react-gui` → iOS UI test (maestro) path (step 0). Check this first.
2. Else if the repo is an EdgeApp gui DEPENDENCY (per `gui-dependency-integration`) → run its own checks (the TS/Node path below) AND the gui integration test. A dep change is NOT done until it runs in the app.
3. Else if `package.json` exists and a `tsconfig.json` exists → Node + TypeScript path (step 1).
4. Else if `package.json` exists with a `test` script but no tsconfig → Node path (step 2).
5. If `Cargo.toml` exists → not implemented yet, fall through to placeholder.
6. Otherwise → placeholder mode (step 3).</rule>
<rule id="report-failures-actionable">On FAIL, surface the exact command, exit code, and last 30 lines of output. Do not try to fix anything inside this skill — the caller decides whether to amend or block.</rule>
<rule id="no-mutation">This skill does NOT edit source code, commit, push, or change Asana state by default — verification + results only. The only exceptions are the explicitly scoped rules below: `testid-backfill-commit` (separate testID commit), `gui-dependency-integration` (gui-side changes a dep actually needs, committed on the gui branch), and `single-asset-plugin-trim` (LOCAL-ONLY, never committed).</rule>
<rule id="testid-backfill-commit">Scoped exception to `no-mutation`, test-infrastructure only. When the maestro flow had to fall back to coordinate-based taps because a component it drives lacks a `testID` prop, add `testID`s to those component(s) so the selector can target them stably, then commit JUST those testID additions as a SEPARATE commit — message `test: add missing testIDs for maestro selectors` — distinct from the feature commit, so PR history stays clean and future runs are faster and less brittle. Constraints: only when a real coordinate-fallback actually occurred (testIDs genuinely missing); change ONLY `testID` props, never component logic; update the corresponding maestro selector(s) to use the new testID. If no coordinate fallback was needed, do nothing.</rule>
<rule id="single-asset-plugin-trim">OPTIMIZATION (optional, LOCAL-ONLY — never committed). When the task targets a SINGLE asset and the maestro test needs to drive that asset's wallet, you MAY temporarily comment out the unrelated currency plugins in the gui worktree's `src/util/corePlugins.ts` (the `currencyPlugins` map) — keeping the plugin(s) the task needs — to cut app load/init time (fewer plugins to spin up). This is a test-harness speedup ONLY: it must NEVER land in a commit or PR. Revert it before any commit, or rely on it living only in the throwaway test build; if you commit after trimming, verify `git status`/`git diff` does NOT include `corePlugins.ts`. Skip entirely for multi-asset tasks or tasks that don't drive a wallet.</rule>
<rule id="scripts-over-inline">Deterministic operations (sim selection, RN build, capture loop) MUST run via the companion scripts under `~/.cursor/skills/build-and-test/scripts/`. Do not inline their logic as raw bash blocks in this SKILL.md or in agent reasoning.</rule>
<rule id="lockfile-driven-pm">Never assume a repo's package manager — repos migrate between npm and yarn (edge-react-gui is currently yarn-locked; package-lock.json was removed upstream). All install/run/pack operations go through the shared dispatcher `~/.cursor/skills/pm.sh`, which detects the lockfile (`package-lock.json`→npm, `yarn.lock`→yarn, both/neither→npm). Companion scripts in this skill already dispatch through it; do not hand-write `npm ...`/`yarn ...` against a repo without checking `pm.sh detect`.</rule>
<rule id="gui-dependency-integration">A change to an EdgeApp gui DEPENDENCY is NOT fully tested until it runs in the app — its own `tsc`/jest passing is necessary but NOT sufficient. Gui dependencies = the Edge-owned repos `edge-react-gui` consumes: `edge-core-js`, `edge-currency-accountbased`, `edge-currency-plugins`, `edge-exchange-plugins`, `edge-login-ui-rn`, `edge-currency-monero`, `react-native-piratechain`, `react-native-zcash`, `react-native-zano`. When the repo under test is one of these, after its own checks you MUST also run the gui integration test, autonomously (NO prompting):
1. **Co-located gui worktree:** ensure one exists — create via `~/.config/agent-watcher/setup-task-workspace.sh --task-gid <gid> --repo edge-react-gui` if absent (sibling of the dep worktree under `~/git/.agent-worktrees/<gid>/`, so updot can find it).
2. **Link the MODIFIED dep into the app — the mechanism, and whether you flip any `DEBUG_*` flag, is YOUR per-task call** (depends on what the task changed and how you want to verify it; it is NOT a fixed per-dep rule). Run repo scripts with each repo's package manager (lockfile: `yarn.lock`→yarn, `package-lock.json`→npm; **yarn is being phased out — check, don't assume**). The toolbox:
   - **`updot` — bakes the built dep into the gui's `node_modules`.** Works for ANY dep, no dev-server, no runtime race → the safe default for headless/automated runs. `<pm> updot <dep>` then the gui's `prepare` (npm form: `npm run updot -- <dep> && npm run prepare`; add `prepare.ios` for native-module deps), then rebuild. The dep's `DEBUG_*` flag stays FALSE (you baked it in).
   - **`DEBUG_<dep>` flag + the dep's live webpack dev-server — webview-plugin deps only** (`DEBUG_ACCOUNTBASED`:8082, `DEBUG_EXCHANGES`:8083, `DEBUG_CURRENCY_PLUGINS`:8084, `DEBUG_PLUGINS`:8101). Set the flag TRUE in the gui's `env.json` AND run the dep's `yarn start`/`npm start` (webpack serve) backgrounded for the test; the webview loads the local bundle live (sim reaches host localhost), no gui rebuild. Pick this when live iteration helps; if it flakes (dev-server unreachable, ATS/cleartext, recompile race) fall back to updot.
   - **`edge-core-js`: prefer `updot`, avoid `DEBUG_CORE`.** `DEBUG_CORE` loads the WHOLE core from hardcoded `http://localhost:8080/` (`edge-core-js/.../react-native-webview.tsx`: `source={debug ? 'http://localhost:8080/' : null}`) — races init, cleartext/ATS-sensitive, and any hiccup takes the entire app down (the long-standing "DEBUG_CORE is buggy"). updot is reliable for core.
   Only link the dep(s) THIS task modifies; leave every other dep's `DEBUG_*` at its env.json default. Keep flags consistent with what you actually linked — a `DEBUG_*` left true with no dev-server running will break that dep.
3. **Login:** the test account auto-logs-in via the `YOLO_*` env knobs (already set: `YOLO_USERNAME=edge-rjqa3`, `YOLO_PIN=1111`, consumed in `LoginScene.tsx`). Keep them set so the maestro run reaches the logged-in app; when the change is to `edge-login-ui-rn` specifically, these are the lever for exercising the login flow — adjust only if the change requires driving the login UI differently.
4. **Run the gui maestro path (step 0)** against that build. If the dep change needs gui-side adjustments to work in-app, make them and commit on the gui worktree's branch — autonomously, do NOT prompt.
PASS requires the maestro app test to pass with the dep change linked. A dep whose unit checks pass but that breaks or doesn't function in the app is a FAIL.</rule>
</rules>

<step id="0" name="iOS UI test (maestro) — edge-react-gui only">

A real on-simulator UI test that logs into the pre-provisioned test account, navigates to the Buy tab, requests a $500 quote, and captures a proof screenshot. PASS requires the screenshot to actually render the resolved quote.

**Parallel-session env contract:** when the agent-watcher spawns this session as one of several parallel slots, it exports `$AGENT_SIM_UDID` (the slot's cloned simulator) and `$AGENT_METRO_PORT` (the slot's Metro port) into the shell. The scripts below honor them automatically — `select-ios-sim.sh --accept-udid "$AGENT_SIM_UDID"` skips name/runtime resolution and trusts the clone, and `ios-rn-build.sh` falls back to `$AGENT_SIM_UDID` / `$AGENT_METRO_PORT` when `--udid` / `--port` are not passed (forwarding a non-8081 port to `react-native run-ios`). On a manual run with neither var set, behavior is unchanged: resolve the iOS 18 sim by name and use Metro 8081.

### 0a. Prerequisites (check, install if missing)

- `xcrun -version` → Xcode CLT
- `maestro --version` → install with `curl -Ls "https://get.maestro.mobile.dev" | bash`, then add `$HOME/.maestro/bin` to PATH. maestro needs JDK 11+; Temurin 17 works.

### 0b. Resolve + boot the simulator

There can be multiple "iPhone 16 Pro Max" devices across runtimes. **Only the iOS 18 device holds the test account** (`edge-rjqa3`, PIN `1111`, region California/USA, BTC wallet). The iOS 26.x device does NOT.

```bash
UDID=$(~/.cursor/skills/build-and-test/scripts/select-ios-sim.sh \
  --runtime "iOS 18" --device "iPhone 16 Pro Max" --boot)
```

If the script exits 2 (ambiguous), narrow `--runtime` (e.g. `"iOS 18.6"`).

### 0c. Build + install + launch the app

```bash
~/.cursor/skills/build-and-test/scripts/ios-rn-build.sh \
  --udid "$UDID" --bundle-id co.edgesecure.app
```

Skips the full RN build when the app is already installed (cached path: seconds; cold build: 30–60 min). Pass `--force-rebuild` to always rebuild.

### 0d. Run the maestro capture

```bash
~/.cursor/skills/build-and-test/scripts/capture-buy-quote.sh
```

Drives `maestro/buy-quote-input.yaml` (login → Buy → $500), then captures via an external simctl screenshot burst — keeping the last frame taken while the app was alive. Retries up to 5 cycles. Writes `/tmp/agent-mvp-buy-quote-screenshot.png` on success.

### 0e. PASS / FAIL contract

On capture-buy-quote.sh exit 0, the screenshot must visibly show **USD 500**, a non-empty **Amount BTC**, and the **`1 BTC = <rate> USD`** line. Emit:

```
build-and-test: PASS (iOS maestro — Buy $500 quote)
screenshot: /tmp/agent-mvp-buy-quote-screenshot.png
```

On exit nonzero, emit FAIL with the last 30 lines of the script's output:

```
build-and-test: FAIL — Buy $500 quote not captured
<last 30 lines>
```

Return success exit only on PASS.

### 0f. Critical gotchas baked into the flow (do not "fix" them)

<rule id="spaced-pin-taps">Edge's RN keypad drops digits tapped too fast → wrong PIN → exponential lockout (465s → 914s → …). Each PIN digit tap in `buy-quote-input.yaml` uses `waitToSettleTimeoutMs`. Never speed it up. If a run logs "Invalid PIN: Account locked for N seconds", wait — do NOT tap.</rule>
<rule id="no-hideKeyboard">On this debug build, `hideKeyboard` reliably triggers an RN Fabric text-measure SIGABRT. The flow leaves the keyboard up. Do not add `hideKeyboard` steps.</rule>
<rule id="no-hierarchy-polling-on-buy">`assertVisible`/`extendedWaitUntil` traverse the a11y hierarchy on a poll loop, provoking the same Fabric crash on the Buy scene. The flow stops polling once the amount is entered; the capture script uses external simctl screenshots (no hierarchy traversal).</rule>

</step>

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

<edge-cases>
<case name="Simulator selection ambiguous (exit 2)">Re-run `select-ios-sim.sh` with a more specific `--runtime` (e.g. `"iOS 18.6"`). If still ambiguous, surface the list to the caller and set `blocked = Yes` on the Asana task with the candidate UDIDs and ask which to use.</case>
<case name="Simulator boot fails">Run `xcrun simctl shutdown all && xcrun simctl erase <UDID>` is destructive — do NOT run it. Set `blocked = Yes` with the boot error.</case>
<case name="ios-rn-build.sh exits 2 (sim not booted)">Re-run step 0b. If it fails twice, set `blocked = Yes`.</case>
<case name="Cold RN build needed and would take >30 min">Acceptable in --yolo. Watch loop should NOT timeout the iteration during a known cold-build window — that's handled by /one-shot's `iOS prep budget` policy.</case>
<case name="capture-buy-quote.sh exhausts retries">Emit FAIL with the maestro tail. Do NOT set `blocked = Yes` unless the failure mode is clearly a true-blocker (e.g. simulator died entirely, app uninstalled). A normal capture exhaustion is a real test FAIL the caller (watch loop) should react to.</case>
<case name="maestro install fails">Set `blocked = Yes` with the install error and a note about JDK requirement.</case>
<case name="Repo is edge-react-gui but the test account / sim was wiped">Set `blocked = Yes` — the test relies on `edge-rjqa3` with PIN 1111. Re-provisioning is a human step.</case>
</edge-cases>
