Governs step 0d-0f of `/build-and-test` (driving the app on the sim: the flow library, selectors, the corePlugins levers, runtime inspection); the core step map points here. Proof-frame rules are in `references/evidence.md`, funding rules in `references/funding.md`.

<scripts description="This phase's companion script (under `~/.cursor/skills/build-and-test/scripts/`).">

| Script | Purpose | Exit codes |
|--------|---------|------------|
| `capture-buy-quote.sh [--flow <yaml>] [--driver xcuitest\|maestro] [--login-role <role>]` | Run one flow on the XCUITest interpreter (default, signed in as the roster's default role unless `--login-role` names another) or the maestro CLI (device and driver port pinned from the slot env), then capture via an external simctl screenshot burst; up to 5 retry cycles | 0 = captured; nonzero = FAIL (step 0e) |
</scripts>

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="maestro-flows-are-shortcuts">Before the sim-test phase, READ `~/.cursor/skills/build-and-test/references/sim-testing-playbook.md`: it holds the working knowledge (funding floors, account roster/switching, feature-enablement gotchas, investigation order) that otherwise gets re-learned every run.
- **Compose, don't re-derive.** Parameterized subflows live in `~/.cursor/skills/build-and-test/maestro/common/` (`login-if-needed`, `relaunch-and-login`, `dismiss-startup-modals`, `dismiss-logbox-banner`, `select-swap-pair`, `find-wallet`, `confirm-slider`, plus the one-invocation `swap-drive.yaml` above them; the slider gesture is SOLVED there, never re-derive it; the playbook's flow table lists every flow and its params). Copy the subflows you need next to your task flow and `runFlow` them; author NEW task-specific `.yaml` liberally for what the task actually changed. Task flows stay LOCAL (`.syncignore`d from the agent repo; never committed to the gui repo, whose `maestro/` is the heavyweight verification suite, reference-only for selectors). What DOES get committed to the gui: missing `testID`s, per `testids-over-coordinates`.
- **One proof flow.** For the repeatable PROOF run compose ONE yaml flow and run it once via `capture-buy-quote.sh --flow <your.yaml>`; that run produces the PR evidence screenshots.
- **Do not deep link past the screen the task changed.** The committed flows reach their scene by deep link (`openLink`) by default; pass the flow's `MANUAL_PATH: "true"` so the drive walks through the changed screen.
- **Explore and prove per `explore-on-interpreter-prove-on-flow`; propose playbook and flow changes per `playbook-and-flow-proposals`.**
</rule>
<rule id="explore-on-interpreter-prove-on-flow">EXPLORATION ON THE INTERPRETER (iOS), PROOF ON A FLOW RUN. On iOS, read the current screen with `xcuitest-run.sh --inspect` (one line per element: type, `id=` testID, label, value, frame, `hit|nohit|offscreen`; `--full` lists every node) and try a selector with `xcuitest-run.sh --steps '<yaml>'` (one command or a short list against the live app; add `--inspect` to print the screen after it). Neither relaunches the app nor binds a host port. A printed `id=` is a `tapOn: {id: ...}` selector and a printed label is a text selector; `nohit covered-by=` names what sits over the element. Only a session whose `agent_lane` includes Android has the maestro MCP tools. The iOS remainder the interpreter cannot read or drive goes to the maestro CLI at the canonical slot invocation below: a screen of another app (inspect reads only the app under test plus a SpringBoard alert over it) with the `hierarchy` subcommand in place of `test <flow>`, and a command its preflight rejects (`clearState`, anything missing from `references/xcuitest-interpreter.md`) with `test <flow>`. When you do use the MCP, the daemon binds to one device and DRIFTS: `maestro-mcp-wrapper.sh` start-pins it, but the pin does not survive slot-sim relaunch cycling, and the daemon can rebind to another slot's sim mid-run. So: (1) re-verify its bound device (list_devices + an inspect matching your app's expected state) at the START OF EVERY MCP observation block; (2) ALL PROOF evidence comes from a CLI flow run: on iOS `xcuitest-run.sh --flow` per `ios-flows-run-on-xcuitest`; on Android, or when the task asks for Maestro, the maestro CLI, canonical slot invocation `maestro --device "$AGENT_SIM_UDID" --driver-host-port $((AGENT_METRO_PORT + 1000)) test <flow>` (the per-slot driver port keeps parallel slots' iOS drivers apart; hook-enforced; the MCP daemon uses +2000 via its wrapper), plus `simctl io` against that SAME UDID. NEVER an MCP screenshot, and NEVER a `simctl io` against a different device than the CLI drove. If a verify shows the MCP on the wrong device, drop to CLI for the rest of the run.</rule>
<rule id="playbook-and-flow-proposals">PROPOSALS, NEVER DIRECT EDITS. The playbook and the flow library are operator-curated: entries may be trusted without re-verification because the operator reviewed and promoted each one. Task runs never promote; proposals wait in run reports for the eval's manually-triggered flow-consolidation pass. In the report's Dev Notes & Gotchas section:
  - `[playbook]`: durable knowledge, one bullet.
  - `[flow]`: a NEW reusable drive sequence: name, params, one-line purpose, and the FULL yaml EMBEDDED as a fenced block (worktrees are pruned on retention; the report attachment is the durable copy).
  - `[flow-update]`: a change to an EXISTING library flow (genericize, new param, split into subflows): name the flow, the change, and the compatibility argument. New params MUST default to current behavior so existing callers are unaffected, and a rename/split must say so explicitly (callers get grepped at promotion).
- **Scope a `[playbook]` proposal tightly.** It earns a slot ONLY if it is (1) SIM-TESTING WORKING KNOWLEDGE: how to drive, fund, enable, or verify a change in the running app (a provider floor/geo-block, an executable test-pair recipe, a funding path, a feature-enablement gotcha, a crash mitigation, a flow/selector gotcha); AND (2) a STABLE EXTERNAL fact that would shorten or unblock a FUTURE sim test; AND (3) PARALLEL-SAFE: if the recipe relies on a shared host resource (a fixed localhost port, a single dev-server, the master sim, the maestro MCP daemon), propose the slot-safe variant (e.g. `updot` over a fixed-port debug dev-server) or a one-line WARNING instead. Do NOT propose as `[playbook]`: orchestration/watchdog/slot/revive/resource-release behavior, eval-tooling or rubric observations, one-off task specifics, or anything an existing rule already covers. Those belong in the report's Orchestration Issues or Skill Gaps sections, which the eval routes separately.</rule>
<rule id="ios-flows-run-on-xcuitest">On iOS, RUN flow YAML with the native XCUITest interpreter, not `maestro test`: `~/.cursor/skills/build-and-test/scripts/xcuitest-run.sh --flow <flow.yaml> [--env K=V ...]` (slot UDID from `$AGENT_SIM_UDID`; no host port, so parallel slots never collide). It runs the same flow files (library `common/` flows included) and writes `takeScreenshot` output to the same paths; `capture-buy-quote.sh` uses it by default. Use the maestro CLI only when the task asks for Maestro, on Android, or for a flow the interpreter rejects. The interpreter preflights the whole flow tree and exits 2 before step 1 when a command or argument is unsupported, naming the command and the flow: rewrite that step with supported commands, or run that one flow on the maestro CLI and name the rejected command in the run report. There is no automatic fallback. Pass `--animations on` when the task is about an animation (the default turns them off). The same script reads and probes the screen (`--inspect`, `--steps`) per `explore-on-interpreter-prove-on-flow`. The run stops this slot's maestro MCP daemon; the next MCP tool call starts a new one (a call in flight fails once, retry it), so never run an MCP call while an interpreter run is going. Supported commands, semantics and the other flags: `references/xcuitest-interpreter.md`; usage, output and exit codes: the script header.</rule>
<rule id="testids-over-coordinates">Scoped exception to `no-mutation`, test-infrastructure only. TESTIDS FIRST, COORDINATES LAST. When a flow needs to drive an element that has no stable selector (text match fails and no `testID` exists), ADD the missing `testID` prop to that component in the gui worktree and drive via it. A `testID` is a JS-only prop: Metro reload picks it up in seconds (no native rebuild), so adding one is cheaper than a single round of coordinate trial-and-error, and it de-brittles the suite for every future run. Coordinate taps are permitted ONLY for surfaces you cannot edit (system dialogs, native pickers, third-party views that don't forward `testID`) or when a reload would destroy unrecoverable in-flight app state, and any coordinate tap that survives into the PROOF flow must be called out in the run report with why a testID was not possible.
- **Commit discipline:** commit the testID additions as a SEPARATE commit, distinct from any feature commit; change ONLY `testID` props, never component logic; update the flow selector(s) to use them.
- **Message names the surface:** subject `test: add testIDs to <scene/component>` (e.g. `test: add testIDs to ExchangeScene swap pills`), with every added id listed in the body. Never a generic subject: identical subjects across runs make these commits indistinguishable when a human cherry-picks between branches.
- **Where the commit lands:** always THE TASK'S SINGLE GUI PR, the one whose test surfaced the need; NEVER a separate testID-only PR. A task has at most ONE gui PR: for a gui-feature task the testID commit rides that feature PR; for a DEP-repo task whose test drives the gui, the testIDs go in the task's ONE gui integration PR (if the testIDs are the only gui change, that PR IS the task's gui PR), on the SAME `<prefix>/<gid-or-slug>` gui branch the run already provisioned.
If no selector was missing, this rule is a no-op.</rule>
<rule id="single-asset-plugin-trim">OPTIMIZATION (optional, LOCAL-ONLY, never committed). When the task targets a SINGLE asset and the test needs to drive that asset's wallet, you MAY temporarily comment out the unrelated currency plugins in the gui worktree's `src/util/corePlugins.ts` (the `currencyPlugins` map), keeping the plugin(s) the task needs, to cut app load/init time. This is a test-harness speedup ONLY: it must NEVER land in a commit or PR. Revert it before any commit, or rely on it living only in the throwaway test build; if you commit after trimming, verify `git status`/`git diff` does NOT include `corePlugins.ts`. Skip entirely for multi-asset tasks or tasks that don't drive a wallet.</rule>
<rule id="force-swap-provider-locally">To FORCE a specific swap provider for a test (so the engine routes through it instead of a competitor), edit the gui worktree's `src/util/corePlugins.ts` `swapPlugins` map and set every OTHER provider to `false`, leaving only the target's `*_INIT` truthy. LOCAL-ONLY, same never-committed discipline as `single-asset-plugin-trim`. Do NOT force a provider by toggling the in-app **Settings → Exchange Settings**: that state is ACCOUNT-SYNCED, so on a shared roster account it thrashes against every parallel session and persists to the next run. Use Exchange Settings only to READ/diagnose why a provider is absent, never to set routing. (`Preferred`/`preferPluginId` also do not pin: the engine reverts to best-rate in about 60s.) See sim-testing-playbook "Feature-enablement check".</rule>
<rule id="runtime-inspection-via-debugger">When verification needs RUNTIME state from the running app (why a check evaluates false, the actual value of a variable, which code path executed), use the `/debugger` skill (`~/.cursor/skills/debugger/SKILL.md`); do NOT hand-roll a CDP/WebSocket attach. It sets a `file:line` breakpoint over Metro's Hermes inspector and reports the call stack + locals, and it is slot-aware: `check-metro.sh` and `cdp-attach.js` default to `$AGENT_METRO_PORT`. Static questions (where is X defined) stay grep/read.</rule>
<rule id="agent-account-first">Every drive on a roster account runs on the roster's `defaultRole` (the `agent` account); `references/funding.md` `agent-account-acquires-by-swap` owns when a test may move off it. The account is settled BEFORE the first drive, never assumed:
1. `scripts/pin-agent-login.sh --check <gui-checkout>` on the checkout the app was built from. Exit 1 (unpinned, or pinned to another role: the state of any checkout that skipped workspace init, such as the primary checkout a Task-shape run builds from) → run it without `--check`.
2. `scripts/metro-fresh.sh --port $AGENT_METRO_PORT --file config.json` (`--file env.json` on a branch that keeps YOLO there). Anything but `VERDICT=FRESH` means the app still loads the old pin: apply the remedy the script header names, then re-check.
3. Cold-launch the app (`common/relaunch-and-login.yaml`): YOLO auto-login signs in on launch.
4. Run every flow that can meet a PIN scene with `xcuitest-run.sh --login-role agent`. It hands the account to `common/login-if-needed.yaml`, which fails within 5s, with no tap, when the PIN scene shows another account.
A PIN digit is never tapped on a PIN scene that shows another account (a wrong PIN locks that account out for a growing interval). A drive that ran on another account names the account and its `agent-account-acquires-by-swap` reason in the run report. "The sim was already on that account" is not a reason.</rule>
<rule id="asset-priority">When the task does not name the asset, pick it from this baked order, top down (largest market cap first). Never fetch market caps, and never choose by reading the wallet picker and taking the largest balance.

| # | Asset | Deep-link asset (`sellAsset` / `buyAsset`) |
|---|-------|--------------------------------------------|
| 1 | BTC | `bitcoin` |
| 2 | ETH | `ethereum` |
| 3 | USDT | `ethereum_0xdac17f958d2ee523a2206206994597c13d831ec7` |
| 4 | XRP | `ripple` |
| 5 | BNB | `binancesmartchain` |
| 6 | SOL | `solana` |
| 7 | USDC | `ethereum_0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` |
| 8 | DOGE | `dogecoin` |
| 9 | TRX | `tron` |
| 10 | ADA | `cardano` |
| 11 | BCH | `bitcoincash` |
| 12 | LTC | `litecoin` |
| 13 | AVAX | `avalanche` |
| 14 | XLM | `stellar` |

Source side: the first entry the account holds above the provider floor (playbook funding floors). Destination side: the first other entry. `select-swap-pair.yaml` defaults to entries 1 and 2, so a drive that leaves the defaults alone already follows the order. Go below an entry only when it cannot fund the drive on the account in use, and name the skipped entries in the run report. The order is baked and revised by the operator, never per run.</rule>
<rule id="workaround-into-local-flow">A workaround found mid-run (an extra dismiss, a reordered step, a different selector) goes into the run's local flow copy BEFORE the next drive, so the next drive runs it from the file. The file change is what the `[flow-update]` proposal quotes; a workaround applied by hand on two drives was never tested as a flow.</rule>
<rule id="redact-secrets-before-attach">A frame, step log or inspect dump that shows a seed, private key, password or 2FA code is redacted before it is attached or posted anywhere (PR, Asana, run report), on a throwaway account too: an opaque box over the region of an image, a mask over the value in text (`inputText` arguments in a step log included). The unredacted original stays on this box. Account names and PINs are not secrets (`funded-test-accounts`) and are not redacted.</rule>
<rule id="missed-input-is-a-finding">An input step (tap, swipe, typed text) that reports ok and changes nothing on screen is a FINDING: stop the drive, keep the step log and one frame of the unchanged scene, and report the step (`<flow> #<n>`), what it should have changed and what the screen showed. The interpreter marks the tap (`ok, but the screen did not change within 1.0s`, `references/xcuitest-interpreter.md`), and the scene-advanced check after it is what fails the flow. A repeat of that input is the operator's call; the library carries a conditional re-tap only where the operator approved one. On a value-moving scene (the confirm slider) the input is never repeated.</rule>
</rules>

<step id="0" name="iOS UI test, edge-react-gui only: drive half (0d-0f)">

### 0d. Run the capture

```bash
~/.cursor/skills/build-and-test/scripts/capture-buy-quote.sh
```

Drives `maestro/buy-quote-input.yaml` (login → Buy → 500 in the account's fiat) on the XCUITest interpreter (`--driver maestro` for the maestro CLI), signed in as the roster's default role (`--login-role <role>` for another), then captures via an external simctl screenshot burst, keeping the last frame taken while the app was alive. Retries up to 5 cycles. Writes `/tmp/agent-mvp-buy-quote-screenshot.png` on success.

### 0e. PASS / FAIL contract

On capture-buy-quote.sh exit 0, the screenshot must visibly show **500** in the fiat field (its code follows the account's ramp region: USD for a US region, EUR for a euro one), a non-empty **Amount BTC**, and the **`1 BTC = <rate> <fiat>`** line. Emit:

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

<rule id="spaced-pin-taps">Edge's RN keypad drops digits tapped too fast → wrong PIN → exponential lockout (465s → 914s → …). Each PIN digit tap in `buy-quote-input.yaml` uses `waitToSettleTimeoutMs`. Never speed it up. If a run logs "Invalid PIN: Account locked for N seconds", wait; do NOT tap.</rule>
<rule id="no-hideKeyboard">Driver-specific. On the Maestro driver, on this debug build, `hideKeyboard` reliably triggers an RN Fabric text-measure SIGABRT: do not add `hideKeyboard` to a flow that runs there (Android, `--driver maestro`), and leave the keyboard up. On the XCUITest interpreter `hideKeyboard` works and an iOS-only flow may use it. The committed flows run on both drivers, so they stay free of `hideKeyboard`.</rule>
</step>

<edge-cases>
<case name="capture-buy-quote.sh exhausts retries">Emit FAIL with the maestro tail. Do NOT set `blocked = Yes` unless the failure mode is clearly a true-blocker (e.g. simulator died entirely, app uninstalled). A normal capture exhaustion is a real test FAIL the caller (watch loop) should react to.</case>
</edge-cases>
