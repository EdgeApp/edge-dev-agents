Governs step 0a-0c of `/build-and-test` (preflight, simulator selection, RN build, linking a gui dependency into the app); the core step map points here.

<scripts description="This phase's companion scripts (under `~/.cursor/skills/build-and-test/scripts/`) and their exit codes.">

| Script | Purpose | Exit codes |
|--------|---------|------------|
| `slot-preflight.sh` | Boot the slot sim and print the build plan (`PLAN:`, `INVOKE:`, `WAIT:` lines) | 0 = plan printed |
| `select-ios-sim.sh` | Resolve (and with `--boot`, boot) the simulator; prints the UDID | 2 = ambiguous device/runtime |
| `ios-rn-build.sh` | Build, install and launch the app; `--detach` returns at once | 2 = sim not booted |
| `ios-rn-build-wait.sh` | Wait on a detached build in bounded chunks | 0/1/2 = the build's own result; 7 = still running, re-run it; 3 = stalled (no log output for 10 min) and already killed: read the printed log tail, fix, start a fresh `--detach`; 4 = no build to wait on: start one |
</scripts>

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="preflight-before-build-decisions">START the sim-testing phase with ONE call: `~/.cursor/skills/build-and-test/scripts/slot-preflight.sh` (defaults to `$AGENT_SIM_UDID`/`$AGENT_METRO_PORT`; pass `--repo <gui-worktree>` when cwd is not the gui repo). It boots the sim if needed and answers deterministically: is Metro mine or squatted, is the app installed, does the installed native side match the worktree (`.agent-native-build-stamp` vs `ios/Podfile.lock`), are node_modules present. OBEY its final `PLAN:` line (`ready` = drive now, no build; `js-only`/`install`; or `full-rebuild`) and run the exact `INVOKE:` command it prints (verbatim; no flag-guessing), then its `WAIT:` command when it prints one. Do NOT re-derive any of its checks manually, and do NOT start a second Metro when it reports one running.</rule>
<rule id="slot-sim-is-the-clone">In a watcher slot (`$AGENT_SIM_UDID` set), resolve your simulator ONLY via `select-ios-sim.sh --accept-udid "$AGENT_SIM_UDID"`, NEVER by `--runtime`/`--device`. Raw `simctl ... booted` is hook-blocked in slot sessions (several sims boot concurrently, so `booted` is ambiguous): pass `$AGENT_SIM_UDID` explicitly to every ad-hoc simctl call, and select that device in the maestro MCP before driving. By-name resolution targets the SHARED MASTER sim ("iPhone 16 Pro Max"); builds or drives on the master pollute the golden image every clone is cut from. `select-ios-sim.sh` refuses by-name in slot mode (override: `--allow-master`).
- **Trust the clone.** Once booted it carries the Edge app and the logged-in test account (APFS copy-on-write from the master). `get_app_container` returns NOTHING on a SHUT/never-booted clone, a FALSE negative: boot first (the scripts do). Do NOT trigger a fresh rebuild on that false negative: it wastes minutes AND wipes the cloned login state.
- **Let the script's own rebuild run.** `ios-rn-build.sh` forces a rebuild when the cached app's NATIVE build drifted from the worktree (its `ios/Podfile.lock` stamp no longer matches). A reinstall keeps the data container, so login survives; do not pass `--skip-install` to dodge it. A JS-only change leaves Podfile.lock identical and takes the fast path.
- **Recycled sim.** If `$AGENT_SIM_UDID` is set but `select-ios-sim --accept-udid` HARD-FAILS ("not found"), you are a RESUMED session whose slot sim was recycled; you cannot fix it in-process (no self-respawn). Report it and set `blocked = Yes`, noting the operator must re-provision via `~/.config/agent-watcher/resume-task.sh --task-gid <gid>`. Do NOT fall back to the master or a by-name sim.</rule>
<rule id="gui-dependency-integration">A change to an EdgeApp gui DEPENDENCY is NOT fully tested until it runs in the app; its own `tsc`/jest passing is necessary but NOT sufficient. Gui dependencies = the Edge-owned repos `edge-react-gui` consumes: `edge-core-js`, `edge-currency-accountbased`, `edge-currency-plugins`, `edge-exchange-plugins`, `edge-login-ui-rn`, `edge-currency-monero`, `react-native-piratechain`, `react-native-zcash`, `react-native-zano`. When the repo under test is one of these, after its own checks you MUST also run the gui integration test, autonomously (NO prompting):
1. **Co-located gui worktree:** ensure one exists; create via `~/.config/agent-watcher/setup-task-workspace.sh --task-gid <gid> --repo edge-react-gui` if absent (sibling of the dep worktree under `~/git/.agent-worktrees/<gid>/`, so updot can find it).
2. **Link the MODIFIED dep into the app. The mechanism, and whether you flip any `DEBUG_*` flag, is YOUR per-task call** (it depends on what the task changed and how you want to verify it). Run repo scripts with each repo's package manager (`lockfile-driven-pm`). The toolbox:
   - **`updot`: bakes the built dep into the gui's `node_modules`.** Works for ANY dep, no dev-server, no runtime race: the safe default for headless/automated runs. `<pm> updot <dep>` then the gui's `prepare` (npm form: `npm run updot -- <dep> && npm run prepare`; add `prepare.ios` for native-module deps), then rebuild. The dep's `DEBUG_*` flag stays FALSE (you baked it in).
   - **`DEBUG_<dep>` flag + the dep's live webpack dev-server, webview-plugin deps only** (`DEBUG_ACCOUNTBASED`:8082, `DEBUG_EXCHANGES`:8083, `DEBUG_CURRENCY_PLUGINS`:8084, `DEBUG_PLUGINS`:8101; these ports are HARDCODED in each dep package's `debugUri` and are HOST-GLOBAL). Set the flag TRUE in the gui's `env.json` AND run the dep's `yarn start`/`npm start` (webpack serve) backgrounded for the test; the webview loads the local bundle live (sim reaches host localhost), no gui rebuild. Pick this when live iteration helps; if it flakes (dev-server unreachable, ATS/cleartext, recompile race) fall back to updot.
     - **Parallel-slot port rule:** a `DEBUG_<dep>` dev-server port is a SINGLE-OCCUPANT host resource; only ONE slot can serve a given dep at a time. Before starting the dev-server, check the port is free: `lsof -nP -iTCP:<port> -sTCP:LISTEN`; if another slot holds it, use updot. Your slot's Metro runs on `$AGENT_METRO_PORT` (base **8181**), deliberately OUTSIDE the 808x DEBUG range; do NOT pass a `--port` that drags Metro back into 808x. When in doubt in a parallel slot, prefer updot: it has no shared port.
     - **`DEBUG_EXCHANGES` crash-loop trap:** the gui's `allowDebugging` flag (which permits the cleartext localhost load) is OR-gated on `DEBUG_ACCOUNTBASED || DEBUG_CORE || DEBUG_CURRENCY_PLUGINS || DEBUG_PLUGINS`. **`DEBUG_EXCHANGES` is NOT in that set**, so enabling it ALONE crash-loops the app. Co-enable one that IS (e.g. `DEBUG_ACCOUNTBASED`); that drags in its 8082 dev-server, so plan ports per the rule above. Swap/exchange plugin code runs in **edge-core-js's webview context, not the Metro bundle**: serve patched dep code via the dev-server (or `updot`-bake it); do NOT sync patched `lib/` into `node_modules` expecting Metro to bundle it.
   - **`edge-core-js`: prefer `updot`, avoid `DEBUG_CORE`.** `DEBUG_CORE` loads the WHOLE core from hardcoded `http://localhost:8080/`: it races init, is cleartext/ATS-sensitive, and any hiccup takes the entire app down.
   Only link the dep(s) THIS task modifies; leave every other dep's `DEBUG_*` at its env.json default. Keep flags consistent with what you actually linked: a `DEBUG_*` left true with no dev-server running breaks that dep.
3. **Login:** the test account auto-logs-in via the `YOLO_*` env knobs (set by workspace init to the roster's `agent` account from `~/.config/edge-secrets/test-accounts.json`, consumed in `LoginScene.tsx`, pinned by `setup-task-workspace.sh` on every worktree's env.json copy). Keep them set so the run reaches the logged-in app; when the change is to `edge-login-ui-rn` specifically, these are the lever for exercising the login flow: adjust only if the change requires driving the login UI differently.
4. **Make the gui-side changes the feature NEEDS to run, then run the gui path (step 0)** against that build. A dep change almost always needs gui-side wiring to function: plugin init / apiKey, provider/plugin registration, imports, config. Those gui changes are PART OF THE WORK: complete ALL of them (and commit on the gui worktree's branch) so the app is fully runnable with the feature, autonomously, do NOT prompt. If the feature doesn't load/run in the app yet, the implementation is NOT done.
PASS requires the app test to pass with the dep change linked AND the actual feature exercised to its terminal success (`test-drives-the-real-action`). A dep whose unit checks pass but that isn't fully wired into a runnable app, or that runs but whose real action was never executed, is a FAIL.
SCOPE DOES NOT EXEMPT THE TEST: a task that scopes its deliverable to the dep repo, calls itself a prototype, or explicitly defers PRODUCTION gui integration to follow-up work still gets THIS integration test. The wiring in steps 1-4 is TEST SCAFFOLDING in the task's gui WORKTREE (plugin registration, env.json keys, dep linking), not an unrequested production change; nothing lands in the gui repo unless the task asks for it. Likewise "the plugin is unvetted prototype code, a real swap through it is irreversible" is NOT a blocker: vetting it with a small sanctioned-roster swap is what this test exists to do (see one-shot `yolo-true-blockers` carve-out).</rule>
</rules>

<step id="0" name="iOS UI test, edge-react-gui only: build half (0a-0c)">

A real on-simulator UI test that logs into the pre-provisioned test account, navigates to the Buy tab, requests a $500 quote, and captures a proof screenshot. Steps 0d-0f (the drive and the PASS/FAIL contract) are in `references/drive.md`.

**Parallel-session env contract:** when the agent-watcher spawns this session as one of several parallel slots, it exports `$AGENT_SIM_UDID` (the slot's cloned simulator) and `$AGENT_METRO_PORT` (the slot's Metro port). The scripts honor them automatically: `select-ios-sim.sh --accept-udid "$AGENT_SIM_UDID"` skips name/runtime resolution and trusts the clone, and `ios-rn-build.sh` falls back to `$AGENT_SIM_UDID` / `$AGENT_METRO_PORT` when `--udid` / `--port` are not passed (forwarding a non-8081 port to `react-native run-ios`). In a slot, `preflight-before-build-decisions` replaces 0b-0c: run the preflight and obey its plan. On a manual run with neither var set: resolve the iOS 18 sim by name and use Metro 8081, as below.

### 0a. Prerequisites (check, install if missing)

- `xcrun -version` → Xcode CLT
- `maestro --version` (Android, or a flow the XCUITest interpreter rejects) → install with `curl -Ls "https://get.maestro.mobile.dev" | bash`, then add `$HOME/.maestro/bin` to PATH. maestro needs JDK 11+; Temurin 17 works.

### 0b. Resolve + boot the simulator

There can be multiple "iPhone 16 Pro Max" devices across runtimes. **Only the iOS 18 device holds the test accounts** (the `funded-test-accounts` roster; default login: the `agent` account). The iOS 26.x device does NOT.

```bash
UDID=$(~/.cursor/skills/build-and-test/scripts/select-ios-sim.sh \
  --runtime "iOS 18" --device "iPhone 16 Pro Max" --boot)
```

If the script exits 2 (ambiguous), narrow `--runtime` (e.g. `"iOS 18.6"`).

### 0c. Build + install + launch the app

```bash
~/.cursor/skills/build-and-test/scripts/ios-rn-build.sh \
  --udid "$UDID" --bundle-id co.edgesecure.app --detach
~/.cursor/skills/build-and-test/scripts/ios-rn-build-wait.sh --udid "$UDID"   # re-run while it exits 7
```

Skips the full RN build when the app is already installed (cached path: seconds; a fresh build is usually a few minutes, the Hermes prebuilt is prefetched). Pass `--force-rebuild` to always rebuild.

</step>

<edge-cases>
<case name="Simulator selection ambiguous (exit 2)">Re-run `select-ios-sim.sh` with a more specific `--runtime` (e.g. `"iOS 18.6"`). If still ambiguous, surface the list to the caller and set `blocked = Yes` on the Asana task with the candidate UDIDs and ask which to use.</case>
<case name="Simulator boot fails">`xcrun simctl shutdown all && xcrun simctl erase <UDID>` is destructive: do NOT run it. Set `blocked = Yes` with the boot error.</case>
<case name="ios-rn-build.sh exits 2 (sim not booted)">Re-run step 0b. If it fails twice, set `blocked = Yes`.</case>
<case name="Cold RN build needed and would take >30 min">Acceptable in --yolo. The watch loop should NOT timeout the iteration during a known cold-build window; /one-shot's `iOS prep budget` policy handles that.</case>
<case name="maestro install fails">Set `blocked = Yes` with the install error and a note about the JDK requirement.</case>
<case name="Repo is edge-react-gui but the test account / sim was wiped">Set `blocked = Yes`: the test relies on the roster accounts (default: the `agent` account) being present on the sim image. Re-provisioning is a human step.</case>
</edge-cases>
