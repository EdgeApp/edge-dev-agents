# Sim-testing playbook (edge-react-gui)

Working knowledge for driving the app on the sim. Read once before the test
phase; it is cheap context that saves expensive UI churn. This is a LIVING doc:
when a run teaches you something durable about driving the app, append a concise
entry (the human audits and prunes it periodically — keep entries dense).

## Flow library — compose these, never re-derive them
Parameterized subflows in `~/.cursor/skills/build-and-test/maestro/common/`
(compose via `runFlow` with `env:`; copy next to your task flow). Every flow
here runs on the iOS XCUITest interpreter (`scripts/xcuitest-run.sh`) and on the
maestro CLI. Re-deriving
any of these inline is wasted derivation — two 2026-07 sessions independently
rebuilt the entire swap-pair sequence tap-by-tap that `select-swap-pair`
already encodes, params and gotchas included.

| Flow | Params | Does |
|---|---|---|
| `common/login-if-needed.yaml` | PIN_DIGIT, EXPECT_USERNAME, HOME_MARKER, LOGIN_MODE (iOS: `xcuitest-run.sh` sets LOGIN_MODE from the checkout's config, and `--login-role <role>` sets the first two from the roster) | LOGIN_MODE `yolo`: wait for the home scene, no PIN probe. Otherwise PIN login only when the PIN scene shows. With EXPECT_USERNAME set, a PIN scene on another account fails within 5s and no digit is tapped |
| `common/relaunch-and-login.yaml` | PIN_DIGIT, EXPECT_USERNAME, HOME_MARKER | Stop and launch the app (never `clearState`), LogBox toast, login, startup modals, home scene. The launch wait ends on the PIN scene, the home scene or the full login scene (a failure, within 1s) |
| `common/dismiss-logbox-banner.yaml` | LOGBOX_TOAST | Close React Native's LogBox toast (debug builds; label is "! " plus the newest log line). No-op when absent. Run it again right before a tap or swipe on the bottom 50pt of a scene: the toast returns on every new warning or error |
| `common/dismiss-startup-modals.yaml` | AGENT_TEST_MODE (iOS: `xcuitest-run.sh` sets it from the checkout's config) | Clear survey/notification/update modals (runs `dismiss-logbox-banner` first). With AGENT_TEST_MODE `true` the app raises none of them, and the flow only closes a LogBox toast that is present |
| `common/select-swap-pair.yaml` | SRC_ASSET, DST_ASSET, MANUAL_PATH, SRC_WALLET, DST_WALLET, SRC_ROW_ID, DST_ROW_ID, FIAT_AMOUNT, PROVIDER | Swap deep link sets the pair (MANUAL_PATH: Exchange tab → pick wallets via Search Wallets) → amount → quote (+ provider force, amount-field eraseText gotcha). The quote wait ends on the quote OR the "Exchange Error" card, 25s ceiling, and the flow fails within 1s of the error card |
| `common/find-wallet.yaml` | SEARCH_TERM, MATCH_INDEX, ROW_ID | Assets tab → search → open a wallet's detail scene (Receive/Send/Trade). ROW_ID (`walletListRow.<wallet name>.<code>`) picks the exact row when the search text matches several wallets |
| `common/open-settings.yaml` | - | Side menu → Settings list (compose your own subpage nav after) |
| `common/confirm-slider.yaml` | SUCCESS_TEXT, SUCCESS_TIMEOUT | The confirm slider gesture (SOLVED — never re-derive) → success marker. Fails 3s after a slide that did not register, and within 1s of the slider re-arming after a rejected action |
| `common/ramp-set-region-fiat.yaml` | COUNTRY_ROW/SEARCH, STATE_ROW/SEARCH, FIAT_ROW/SEARCH, REGION_BUTTON | Set ramp region + fiat from Buy/Sell scene (row selectors are the COMBINED row string, e.g. "United States of America US", "Netherlands NL", "EUR Euro"). The region button has no testID and its label is the current region's short name: pass REGION_BUTTON (a regex, e.g. `.*Netherlands.*`) when the account's region is outside the default list. Region is ACCOUNT state: restore it in the same run |
| `common/send-to-address.yaml` | CURRENCY_CODE, ADDRESS, AMOUNT, WALLET_SEARCH, MANUAL_PATH, SLIDE | Payment-redirect link → pre-filled Send scene → confirm slider (no CURRENCY_CODE, or MANUAL_PATH: Assets → wallet → Send → address → amount). `SLIDE=false` stops on the armed slider and moves nothing: the proof for any change before the broadcast |
| `common/create-throwaway-account.yaml` | NEW_USERNAME, NEW_PASSWORD, NEW_PIN, NEW_WALLETS, VERIFY_ACCOUNT_INFO | Login scene → new empty account, logged in (never `clearState`). For tests that would dirty a roster account's SYNCED state |
| `common/delete-throwaway-account.yaml` | DELETE_USERNAME, DELETE_PASSWORD | Deletes the logged-in account. REQUIRED before the run ends for every throwaway the run created (throwaways are single-use) |
| `buy-quote-input.yaml` / `buy-quote.yaml` | PIN_DIGIT, EXPECT_USERNAME, BUY_AMOUNT, BUY_ASSET, MANUAL_PATH, FIAT_CODE (see file) | Canonical Buy 500 proof flow; opens Buy by deep link (MANUAL_PATH: Buy tab). The amount field reads "Amount <fiat>" and the fiat follows the account's ramp region: FIAT_CODE pins it, unset takes any. Fails within 1s on an account with no ramp region ("Select your region") |
| `swap-drive.yaml` | every `select-swap-pair` param, PIN_DIGIT, EXPECT_USERNAME, RELAUNCH, QUOTE_SCREENSHOT, CONFIRM, SUCCESS_TEXT, SUCCESS_TIMEOUT | A whole swap drive in ONE runner invocation: relaunch → login → modals → pair and amount → quote → frame → (CONFIRM=true only) slider. Default ends on the live quote and moves nothing. About 50s to a BTC→ETH quote, against one runner start (about 6s of setup each) per stage |
| `swap-quote-input.yaml` / `swap-confirm.yaml` | (see file) | Maya swap quote + confirm pair. Local library only (`.syncignore`), not in the repo: compose `common/select-swap-pair.yaml` + `common/confirm-slider.yaml` instead |

Wrote a NEW sequence a future task will plausibly need? Propose it for the
library with a `[flow]`-tagged bullet in your run report's Dev Notes (name,
params, what it does) and keep the yaml in your worktree — the operator
promotes it into `common/`. Same contract as `[playbook]` bullets.

## Money / accounts
- **App installs must preserve the account — never `simctl uninstall` or
  `simctl erase`.** The sim's logged-in account lives in the app's DATA
  container; `simctl uninstall` deletes it and re-provisioning needs a manual
  login (a hook blocks both commands). In-place `simctl install` upgrades the
  app and KEEPS the account. If an in-place install fails ("Could not hardlink
  copy"), run `~/.config/agent-watcher/sim-app-reinstall.sh --udid <udid>
  --app <path/to/Edge.app>` — it retries after a sim reboot and only ever
  uninstalls with an automatic account restore from a healthy donor sim. If the
  app already shows ONBOARDING (account container gone), restore it with
  `~/.config/agent-watcher/restore-sim-app-container.sh --to <udid>` — never
  onboard by hand and never hand-copy container dirs.
- **Centralized-provider swaps need ~$10+ per side.** Below that, quotes fail or
  error opaquely ("amount too low" at best, provider errors at worst). Don't burn
  cycles trying to swap $2; fund to >$10 first. (DEX-style providers vary; the
  $10 floor is the safe default assumption.)
- **Test-account ROSTER (exhaustive — search no further)** lives in the
  LOCAL-ONLY file `~/.config/edge-secrets/test-accounts.json`: roles `agent`
  (**the default YOLO login**, pinned into every worktree config.json by workspace
  init; 2FA ON, its password + OTP key are in the `credsFile` the roster names,
  so its 2FA is never a user-only-credential wall; set `YOLO_OTP_KEY` from that
  file if a login asks for the code), `funds` (heavily funded, cluttered with
  leftover assets), `qa-a`, and `qa-b` (region California/USA). Each entry carries username, PIN, and notes. Use the
  account's real name in chat, run reports, Asana and local logs; use the ROLE
  in anything public (funding.md `funded-test-accounts`). The sim image also
  contains many junk/leftover accounts — they are NOT test accounts; never trawl
  beyond the roster. **Tests run on the agent account, which acquires assets
  only by swapping** (build-and-test `agent-account-acquires-by-swap` owns the
  order, the multi-hop route and the all-providers requote); no sends into it
  from other roster accounts. A test moves off the agent account only when no
  route, multi-hop included, clears a provider floor, or when it needs what
  only another account has: an old or large-UTXO wallet, many wallets,
  account-specific state, ramps KYC.
- **THROWAWAY accounts for tests that dirty SYNCED state.** `activePromotions`,
  affiliate attribution (`installerId` / `CreationReason.json`), Exchange
  Settings and mixnet toggles all sync to the account, so exercising them on a
  roster account thrashes every parallel session. Create an empty one with
  `common/create-throwaway-account.yaml` and log in the normal config.json way.
  They are SINGLE-USE: delete each one you created with
  `common/delete-throwaway-account.yaml` before the run ends, and never write
  its username or password anywhere (no ledger, report, PR, or skill). The
  flow's random username and password guarantee uniqueness
  (`references/throwaway-accounts.md`).
- **HOW to switch accounts: edit config.json, do NOT drive the UI.** The canonical
  switch is: set `YOLO_USERNAME`/`YOLO_PIN` in the WORKTREE's `config.json` (a
  local-only, gitignored copy) to the target roster account, then
  `xcrun simctl terminate <udid> co.edgesecure.app` + `launch` — YOLO auto-login
  lands you in that account on startup. Seconds, deterministic, no side-menu /
  account-dropdown churn (an agent burned 20+ min fumbling that dropdown).
  Drive the in-app account switcher ONLY when you must preserve live in-app
  state across the switch (rare).
  For the default role use `scripts/pin-agent-login.sh <checkout>` (it prints
  each file's account and role); after either edit run `metro-fresh.sh --file
  config.json` before the relaunch, and drive with `xcuitest-run.sh
  --login-role <role>` so a PIN scene on another account fails the flow
  before any digit is tapped (drive.md `agent-account-first`).
- **PINs:** look the PIN up in the roster file; never guess. Wrong-PIN retries trigger exponential
  lockout (465s → 914s → …), so never brute-force, and back off immediately on
  "Account locked".
- **Wallet creation is a SUPPORTED test path — not to be avoided.** Prefer an
  existing funded wallet when the task doesn't involve creation (faster, no
  setup), but create wallets freely when the task targets creation behavior or
  no account holds the needed asset.
- **Sending to a wallet that does not exist: CREATE it.** When a test sends to
  another wallet (another roster account's same-asset wallet, a second wallet
  on the same account, a swap/transfer/sweep target) and it is missing, create
  it in the account that needs it and continue (build-and-test
  `create-missing-destination-wallet`). A receive-side wallet needs no funds,
  so skip the roster search. A missing destination wallet is never a blocker or
  a concession.
- **Pirate Chain wallets need no crash mitigation.** Do not flip
  `piratechain: false` in corePlugins: develop runs Pirate Chain on
  `react-native-pirate-wallet`, which is stable with several active ARRR and
  ZEC wallets on one account. A crash with `RNPiratechain` or
  `PirateSdk_mainnet` frames means the app binary predates that module:
  rebuild from current develop.
- **If the app aborts at start with a ZEC Rust panic (SIGABRT): disable the
  zcash plugin as a local hack, unless the task involves ZEC.** Set
  `zcash: false` in the gui worktree's `src/util/corePlugins.ts` (it is
  hardcoded `true` there, so `config.json` cannot turn it off) and relaunch.
  The edit is a workaround, UNCOMMITTED and never in a PR: revert it before
  any commit, as build-and-test `single-asset-plugin-trim` requires of every
  local plugin edit. When the task does involve ZEC, leave the plugin on and
  relaunch on hit: the retry survives.
  (`Edge-*.ips` faulting stack: `RNZcash.initialize` → `ZcashRustBackend.initializeRust`
  → `zcashlc_init_on_load` → `unwrap_failed` → `rust_panic` → abort).
  `ZcashRustBackend` (`react-native-zcash`) guards its one-time Rust init with
  a NON-thread-safe static bool; when a login starts several ZEC wallet engines
  concurrently, two initializers can race and the loser panics. It is a
  PRODUCT bug and a boot-time race. It is never a reason to archive ZEC or
  ARRR wallets on the account; there is no wallet count limit on any account.
- **SYNCED-SETTINGS HYGIENE:** Privacy Settings mixnet
  toggles (`networkPrivacy: 'nym'`, toggled ON by NYM/mixfetch test plans)
  sync to every session on the account — a toggle left on routes that
  network's RPC through the flaky NYM mixnet for EVERY subsequent run and
  surfaces as engine error drop-downs at login, fleet-wide. NYM mixfetch and the
  send scene's mixnet spinner are UNRELATED to the Houdini stealth feature
  (HoudiniSwap private routing) — do not conflate them. Turn OFF every
  mixnet toggle your test enabled before the run ends.
- **Debug builds crash on RN Fabric on several reliable triggers: rapid
  settings-row toggling, swap-amount keypad entry (SIGABRT to springboard), and
  `uiManagerDidDispatchCommand` (SIGSEGV).** The SIGSEGV variant ALSO wedges the
  maestro driver into mis-targeting taps afterward — which is how a run drifts
  into "I stopped to avoid an accidental send." Seen repeatedly on the SideShift
  run. Do NOT keep relaunching to grind through it — you'll burn the slot.
  **CONTINUE-WORKAROUND FIRST (this gotcha is documented precisely so you do NOT
  stop on it):** a wedged/mis-targeting maestro driver is recoverable, not a
  wall. Rebuild the correct flavor if the slot image drifted (the `ios-rn-build`
  Podfile.lock stamp self-heal), then drive via the maestro CLI + `simctl io`
  against `$AGENT_SIM_UDID` rather than the drifted MCP daemon (per
  `maestro-flows-are-shortcuts`: the MCP is exploration-only and rebinds devices;
  CLI is the proof path), and re-pin the swap pair via the corePlugins hack so
  the keypad/confirm steps land deterministically. Stopping here — or finalizing
  Complete/pr-create via direct verification — WITHOUT applying this workaround
  is a DOWNGRADE concession the `require-completion-judgment.sh` gate catches;
  the completion judge DENIES it (J5, concession taxonomy) because a documented
  continue-workaround exists. **The direct-verification fallback below is GATED: it is legitimate
  ONLY after you have actually funded and driven a REAL, available swap to the
  point where THIS crash interrupts execution AND no continue-workaround remains.
  It is NOT a substitute for an executable swap you already hold.** Invoking the
  fallback is itself a concession — log the genuine funded attempt and its wall
  via `log-attempt.sh` (`result: failed:fabric-sigsegv` / `blocked:...`) so the
  validator can corroborate it; an un-logged or pre-attempt bail is denied. If a
  funded, provider-supported pair is in hand (both wallets present, e.g. BTC→FTM),
  you must drive THAT pair to completion first (see the
  `executable-pair-must-complete` rule) — abandoning it for a slower/riskier path
  and then citing "the build crashes" is the exact miss this gate exists to
  prevent. Only once a genuine funded attempt is interrupted by the Fabric crash
  AND the continue-workaround above did not recover the driver do you switch to
  **direct verification of the code path** as primary proof and treat the in-app
  run as partial evidence: (1) `tsc` clean, (2) boot-time plugin/env validation
  (the app re-initializing the plugin on your new bundle proves the changed init
  path), (3) hit the real provider endpoint yourself (e.g. `curl` the exact
  request the plugin makes) to confirm the behavior the change produces. Capture
  whatever in-app state you DID reach (e.g. a fully-configured swap with
  source+receiving wallets selected) as a proof screenshot before the crash. THAT
  combination — genuine funded attempt + crash + failed workaround + direct proof
  — is a legitimate PASS; bailing to direct proof BEFORE a real funded attempt,
  or before trying the documented workaround, is not.
- **High-value wallets are sanctioned funding sources.** BTC / ETH / USDC and
  similar majors (which nearly every swap provider supports) MAY be swapped FROM
  to fund the asset a test needs. You are allowed to spend them for testing.
- **Minimum-viable amounts: discover the floor FIRST, then size just above it.**
  Applies to EVERY value-moving action — swaps, sends, sweeps. Before picking an
  amount, find the binding floor: the provider's pair minimum (query its public
  pair/quote endpoint, or read it out of the in-app below-limit error), the
  network dust limit, and fee viability. Then use the smallest amount that
  clears that floor with a 10-20% buffer for rate drift (a $10 provider floor →
  an $11-12 test swap, NOT $20). Never start from a round convenience number —
  discovery comes first. For sends, the bar is one confirmable transaction at
  the minimum spendable amount; sending more proves nothing extra. One
  value-moving action per claim being proven: do not repeat a successful
  swap/send for extra screenshots or "to be sure". The goal is the fewest and
  smallest balance changes that still prove the path end-to-end.
- **Fee/slippage budget: $15 equivalent per run.** Network fees, swap fees, and
  slippage incurred while testing are budgeted operating costs, NOT losses. Spend
  up to ~$15 equivalent per task run on them without hesitation; pick swap
  amounts so the whole test fits the budget. A TRUE LOSS is different and is the
  ONLY funds-related blocker: an attempted swap/send that FAILED and the
  principal did not arrive and is not recoverable. Fees and slippage never count
  as a loss.
- **The device-local account stash is UNRECOVERABLE without the account
  password.** PIN login only unlocks an account the device already knows;
  bootstrap requires a password login. NEVER uninstall the Edge app or wipe a
  sim data container without copying the data container aside first - the
  snapshot costs seconds and the stash cannot be recreated from PIN alone.
- **Blocked-ness is established by ATTEMPTING, never predicted.** No funds-related
  blocker exists until an actual attempted swap/send produced a TRUE loss (or a
  documented build crash interrupted a genuine funded attempt). "Prototype",
  "unvetted code", "might lose funds" are anticipated risks, not blockers — run
  the test.
- **SideShift is US-geo-blocked from this host's egress IP**: in-app quotes and the confirm slider render, but
  shift CREATION is denied at ANY amount — the denial is geographic, not a
  floor/funding problem, so do not burn the slot retrying amounts or pairs. An
  executed SideShift shift needs non-US egress (VPN/proxy), which the slot does
  not have; verify via direct API + quote/slider proof, document the geo-block
  as the external precondition, and move on.
- **NYM swap is testnet-only and EXECUTABLE today.** One side must be the `nym`
  asset (chainNetwork `sandbox`); the counter-asset comes from {bitcoin,
  litecoin, dash, zcash, cardano, sepolia}. The reliable in-sim pair is
  **Sepolia ETH → NYM**. Needs (a) the NYM testnet `x-api-key` in `keys.json`
  `swapPlugins.nymswap.apiKey` (legacy `env.json` `NYM_SWAP_INIT.apiKey`), and (b) Sepolia testnet ETH funded into the app's My
  Sepolia wallet (no in-app faucet — fund the wallet's receive address from a
  pre-funded Sepolia key via a public Sepolia RPC). Live floor 0.005 ETH; a
  ~0.0066 ETH swap clears it.
- **Breez Spark Lightning sends: the Spark balance is SEPARATE from the BTC
  wallet's on-chain UTXOs and starts at 0.** To test a send you must fund the
  Spark wallet first: send on-chain BTC to its `bc1p` Taproot deposit address,
  wait 1 block, Spark auto-claims on sync. If that send to the `bc1p` address
  throws `No ECC Library provided`, the installed edge-currency-plugins
  initializes ECC lazily (`initEccLib` only inside `getECPair` in
  `src/common/utxobased/keymanager/keymanager.ts`): link the eager-init fix
  from its branch `jon/fix/taproot-initecclib-eager` the PARALLEL-SAFE way
  (`updot`/build into the worktree's `node_modules`), NOT the fixed-port debug
  dev-server (see the slot-safety caveat under "Driving the app"). Size sends ≤ ~60 sats from a single freshly-claimed leaf
  (leaf-headroom). Mint the receive invoice and verify receipt out-of-band with
  the `@breeztech/breez-sdk-spark` node SDK.
- **Balances are read on the account, never from notes.** No balance list is
  kept here, since every run moves them. Read the wallet list on the agent
  account, then swap there to fund or create what the test needs
  (build-and-test `agent-account-acquires-by-swap`). A Send from an empty
  wallet raises the wallet-empty modal. EVM chains block a SECOND send while
  one is unconfirmed — wait for confirmation before chaining sends.

## Android physical device
Working knowledge for the physical test device (a Samsung Galaxy S9).

- **Android emulator + slot Metro:** an RN debug build on an emulator connects
  to the dev server at `10.0.2.2:8081` (the emulator's host-loopback alias) and
  IGNORES `adb reverse`. Point the app at the slot's Metro instead:
  `~/.cursor/skills/build-and-test/scripts/android-dev-server.sh --serial <emulator-NNNN> --port "$AGENT_METRO_PORT"`
  (writes RN's per-app `debug_http_host` pref, then relaunches). Re-run it after
  a fresh install or `pm clear`. Do NOT run a host-side `127.0.0.1:8081`
  forwarder: 8081 is host-global, so a second emulator loads the other slot's
  bundle with no error. Symptom when unpointed: red "Unable to load script" +
  repeating logcat `Failed to connect to /10.0.2.2:8081`.
- **Android screens that never go idle (the password modal):** maestro `tapOn`
  and `uiautomator dump` hang there, and one `adb shell input text` call drops
  characters. Locate targets from `adb exec-out screencap -p` or a dump taken
  before the modal opened, focus with `adb shell input tap <x> <y>`, and type
  with `~/.cursor/skills/build-and-test/scripts/android-type-text.sh --serial <emulator-NNNN> --env <VAR>`
  (one character per call; secrets stay in the env var).

- **Builds**: `gradlew` lives under `android/`, not repo root; `sfw ./gradlew`
  fails (spawn ENOENT) — run gradle directly (it spawns `node`, not npx, so the
  sfw hook does not block it). Release APK lands at
  `android/app/build/outputs/apk/release/app-release.apk`.
- **Account survives build swaps**: re-sign RELEASE builds with the Android
  debug keystore (the key the pre-provisioned app already carries); then
  `adb install -r` updates in place and preserves `/data/data`, so the
  logged-in account outlives every swap, no password needed. Device
  provisioning itself is a one-time QR login from a logged-in sim
  (allocate a pool sim for the errand; holds auto-release after 4h).

- **CHECK THE LOCK SCREEN FIRST — it is a hard stop for an agent.** `adb devices`
  showing `device` proves USB debugging, NOT that the UI is reachable. The S9
  carries a numeric lock-screen PIN, and while it is up every `input`/UI drive
  lands on the bouncer: `adb shell dumpsys window | grep mCurrentFocus` reads
  `Window{... Bouncer}` even though `mFocusedApp` already names
  `co.edgesecure.app/.MainActivity` behind it, so a naive focus check reads as
  "the app is running" when nothing is drivable. One call to classify it:
  `adb -s <serial> shell dumpsys window | grep -E "Bouncer|showing="`.
  The unlock PIN is operator-only and is NOT the Edge account PIN space
  (`0000`/`1111`) — do not guess it, a wrong-guess streak escalates to lockout
  and eventually a factory wipe, taking the provisioned account with it. When
  the device is locked, the whole android errand (including "is the test
  account logged in?", which needs the UI) is blocked on a user-only credential
  (one-shot `yolo-true-blockers` (b)); say so and move on rather than grinding.
  Ask the operator to unlock and leave the screen on, or to disable the lock on
  the test device.

- **QR login, sim → physical device** (the provisioning errand above, once the
  device is unlocked): the LOGGED-IN device scans the QR that the logging-in
  device displays. So the physical android shows the code (login scene →
  "Scan QR code" / login-QR entry) and the SIM does the scanning. A simulator
  has no camera, so drive the sim's scanner off an image: save the android's
  QR with `adb -s <serial> exec-out screencap -p > /tmp/qr.png`, push it into
  the sim's photo library with
  `xcrun simctl addmedia "$AGENT_SIM_UDID" /tmp/qr.png`, then pick it from the
  album in the sim's scan modal. Verify by watching the android land on the
  wallet list under the seeded account.
- **Warm-login measurement**: YOLO auto-login (`YOLO_USERNAME`/`YOLO_PIN`) +
  `DEBUG_VERBOSE_LOGGING=true`; one iteration = force-stop, clear logcat,
  launch, capture. The FIRST iteration after a build swap is a cache-populate
  pass, never a measurement.
- **Segment markers** (edge-core, all builds): `Login: decrypted keys` = PIN
  entry t0; `enabledTokenIds ... loaded modern file` = per-wallet file read;
  `Login: emitted account from cache` = cache seed. `Login: complete` is a BAD
  TTI proxy — it waits on the account-repo network sync (7-30s, network
  noise). Anchor TTI to the cache-emit marker plus a confirming screenshot;
  uiautomator dump does not reliably expose the RN-rendered Total Balance node.
- **Stale global HTTP proxy** fails every app fetch fast while ping passes:
  `adb shell settings put global http_proxy :0` before any test.
- **Fast core-pin swap — IN YOUR WORKTREE ONLY, never `~/git/<repo>`**: extract
  the committed `edge-core-js-*.tgz`, `cp -R` over
  `node_modules/edge-core-js` **inside `~/git/.agent-worktrees/<gid>/<repo>`**,
  then `sfw npx patch-package` — skips a full reinstall for a single-dep change.
  NEVER in the shared main checkout: `refresh-master-build.sh` builds the master
  sim from `~/git/<repo>`, and every slot sim is an APFS clone of that image, so
  an unpublished package there ships fleet-wide: the next master build embeds
  it, and unrelated runs then fail on API mismatches between that package and
  clean GUI JS. Tell: a hand-copied package has no `_resolved` in its
  package.json — the master refresh preflights that and runs `npm ci` instead
  of baking it. If you do
  dirty the main checkout, restore it with `sfw npm ci` there.
- **Flashlight** (get.flashlight.dev) ships x86_64-only on macOS: needs
  Rosetta 2 (`softwareupdate --install-rosetta --agree-to-license`).

## Navigation
- **Gift Card Marketplace (EdgeSpend):** reachable in-app from Home → 'Spend
  Crypto' tile → the EdgeSpend list → 'Purchase New'. Requires a non-light account
  (the agent and funds accounts qualify) and `ENV.PLUGIN_API_KEYS.phaze.apiKey` set. Real Phaze
  productIds for a per-brand test come from `GET <phaze baseUrl>/gift-cards/full/US`
  with header `API-Key: <key>` (the on-disk `brands-us.json` cache is encrypted and
  unreadable, so hit the API for live ids).

## "My edit isn't applying" — ownership triage FIRST
The moment you think "my change isn't showing / the app isn't loading my
bundle", STOP — that is an OWNERSHIP question before it is a cache question, and
it has a one-call deterministic answer:

```bash
~/.config/agent-watcher/bundle-ownership.sh --udid <udid> --worktree <your-repo-worktree>
```

It reports which port the app will actually fetch from (RCT_jsLocation pin or
default 8081), who is listening there and from which directory, and a verdict:
- **MISMATCH** — another directory's Metro owns the app's port (the app silently
  loads THAT bundle, no error anywhere). Kill the squatter and start YOUR Metro
  on the port the app already reads. Never redirect the app instead.
- **NO_METRO** — start your Metro on the app's effective port.
- **OK** — only now is it a reload/cache question. Ask whether that Metro
  sees your edit:

  ```bash
  ~/.cursor/skills/build-and-test/scripts/metro-fresh.sh --port "$AGENT_METRO_PORT" [--file <repo-relative path> ...]
  ```

  Metro learns of edits from watchman. The script first checks that watchman
  still observes the checkout (a cookie file must be seen within 5s), then
  that Metro serves each edited `src/` file (or each `--file`); a `.json`
  module is compared with disk value for value.
  - `VERDICT=FRESH`: cold-launch the app (terminate + launch) to load the edit.
  - `VERDICT=STALE watcher=stalled root=<dir>`: watchman stopped observing that
    root, so Metro keeps serving every module as it was before the stall, with
    no error. Stop that Metro (`lsof -nP -iTCP:<port> -sTCP:LISTEN -t` gives
    the pid), `watchman watch-del <dir>`, start Metro on the same port WITHOUT
    `--reset-cache`, re-run the check, then cold-launch.
  - `VERDICT=STALE stale=<n>`: a served `.json` differs from disk with a live
    watcher. Restart that Metro without `--reset-cache` and re-check;
    `--reset-cache` is the last step, only when a restarted Metro still
    reports STALE (a hook requires a fresh triage marker before cache resets).
  A source map proves nothing here: Metro fills `sourcesContent` from disk at
  request time, so the map matches disk while the served module is stale.
- **After any JS or config edit made while Metro is running** (a provider
  force, a log hook, a testID, a `config.json` login pin), run `metro-fresh.sh`
  BEFORE relaunching the app. A stale Metro serves the old module with no
  error, and the drive then tests the code you just replaced. The runner
  (`xcuitest-run.sh`) does not run this check: it costs up to 5s per run on a
  stalled root and most runs follow no edit. The edit is the trigger.
- **The YOLO login pin is a bundled module.** `config.json` (`env.json` on
  older branches) is read at bundle time. A checkout that skipped workspace
  init (the primary checkout a Task-shape run builds from) has no agent pin:
  `scripts/pin-agent-login.sh <checkout>` writes it (with `AGENT_TEST_MODE`), `metro-fresh.sh --file
  config.json` proves Metro serves it, a cold launch signs in. A relaunch that
  stays on another account's PIN scene after a pin is this staleness, not a
  login bug.

Hard rules enforced by hooks: hand-writing `RCT_jsLocation` is blocked
(packager pinning belongs to ios-rn-build.sh's cached-launch path, which pins +
terminates + relaunches so it takes effect); cache resets without a fresh triage
are blocked. And when MCP screenshots contradict what the logs say the app is
doing (e.g. "won't foreground" while JS runs), verify with direct
`xcrun simctl io <udid> screenshot` before building theories — the maestro
daemon can drift to another sim, and its screenshots then show the wrong
device.

## Investigate cheap before driving the UI
- **Scoped tasks: trim the plugin set to the task's WORKING SET before the
  first drive.** When a task names specific asset(s), chain(s), or provider(s),
  apply the local corePlugins hack up front so the app boots with exactly what
  the run needs: the target plugin(s), plus every asset/provider the run will
  fund or swap through, plus nothing else. The working set is plural whenever
  the task is (a multi-provider exploration keeps ALL providers under test
  enabled). Deciding the working set is part of test planning, not a reaction
  to churn: with the full set live, every attempt re-navigates to re-find the
  target and the engine reverts to best-rate in ~60s. Worktree-local and
  uncommitted, same rules as provider forcing.
    - New-chain or single-chain task: enable the target chain + the funding
      sources (e.g. BTC/ETH/USDC), disable the rest.
    - Provider forcing: disable competing `swapPlugins` (provider-forcing entry
      below); keep every provider the task itself is exploring.
    - Buy/sell: trim to the ramp provider(s) under test.
    - FUNDING CARVE-OUT: if funding turns out to need a filtered-out asset or
      provider (a swap route, a source balance), WIDEN or remove the filter to
      unblock, fund, then re-trim if useful. Filtering is a convenience, never
      a constraint — "couldn't fund because the plugin set was trimmed" is a
      self-inflicted blocker, not a concession.
- **Pick the swap test pair via direct provider API before ANY in-sim quote
  probing.** Trying pairs/amounts in the Exchange scene until one quotes is the
  most expensive probe there is. Instead: (1) candidate assets in priority
  order — high-mcap majors first (BTC, ETH, USDC, USDT; these quote reliably on
  nearly every provider), then whatever the roster account already holds a
  larger balance of; (2) confirm the pair + amount with ONE call to the
  provider's public pair/quote endpoint (known endpoints under "Asset &
  provider specifics"; the in-app below-limit error text also names floors);
  (3) drive the sim ONCE with the known-good pair. The sim run is for proving
  the app behavior, never for discovering whether a pair quotes.
- **Hack-verifying a state the sim cannot reach is cheap on JS-only surfaces:**
  force the input state with an uncommitted edit, let Metro fast refresh apply
  it with the app already on the target scene, capture, then swap the code
  variant (`git checkout <ref> -- <file>` and re-apply the hack) for a matched
  before/after pair from the same running app and live data. No relaunch, no
  rebuild between frames.
- **Crawl the code and run `/debugger` EARLY**, not as a last resort. A grinding
  UI loop is the most expensive probe there is. "Why is X missing/failing" is
  usually answerable from source (settings store, plugin registration, config.json/keys.json
  flags) or one `/debugger` breakpoint — minutes, vs. an hour of taps.
- **Feature-enablement check (the Rango lesson):** when a provider/feature you
  expect simply ISN'T THERE (no quotes from it, not in the list), FIRST suspect a
  setting: a swap provider can be disabled in **Settings → Exchange Settings**,
  which is PER-ACCOUNT state (differs between the qa-b and funds accounts). Use this
  only to DIAGNOSE (read it from code/state or ONE screenshot) — do NOT toggle it.
- **FORCE a provider via the LOCAL corePlugins hack, NEVER the in-app Exchange
  Settings.** To isolate one swap provider, edit the gui worktree's
  `src/util/corePlugins.ts` `swapPlugins` map and set every OTHER provider to
  `false`, leaving only the target's `*_INIT` — local, uncommitted (per
  `force-swap-provider-locally`). Exchange Settings are ACCOUNT-SYNCED: toggling
  them on a roster account thrashes against every other parallel session on the same
  account (and persists to the next run / a human), so it is parallel-UNSAFE and
  forbidden as the forcing lever. The corePlugins edit is worktree-local, so
  parallel sessions never collide. (Preferred/preferPluginId do NOT pin — the
  engine reverts to best-rate in ~60s — which is the other reason the local hard
  disable of competitors is the reliable way to force routing.)
- **Stake-plugin label/display changes are verifiable FUND-FREE on the Earn
  scene.** Home → Earn Crypto → Discover → search the asset code: the pool-card
  title comes from `stakeAssets[].displayName ?? currencyCode` in plugin config,
  so no wallet, funding, or RPC is needed to prove a label/display fix. Stop at
  the Discover card for label proofs. Drilling INTO the pool (wallet selector /
  StakeOptions) does need an Optimism wallet + working RPC and can hit a
  debug-build SIGSEGV, so do not go deeper than the card unless the change is in
  the pool flow itself.
- **Deterministic cross-check beats eyeballing for signature/encoding fixes:** for
  BIP-137/message-signing correctness, byte-compare the gui transform against
  `bitcoinjs-message`'s `segwitType` output over many random keys — dependency is
  already present, and identity over N keys proves external-verifier compatibility
  better than staring at one signature.
- **Houdini routes are verifiable fund-free via the partner API:**
  `GET https://api-partner.houdiniswap.com/v2/tokens?chain=<chain>&mainnet=true&pageSize=100`
  then `GET /v2/quotes?amount=<x>&from=<id>&to=<id>`. A same-asset cross-chain pair
  may legitimately return only dex/standard (no private route) — that's an answer,
  not a failure.

## Driving the app (mechanics)
- **Compose, don't re-derive.** Reusable subflows live in this skill's
  `maestro/common/` (the flow table at the top lists every one). Copy them next
  to your task flow and `runFlow` them. The gui repo also has its own heavyweight `maestro/common/`
  (verification suite) — reference for selectors, but dev flows stay OURS/local.
- **The confirm slider** is solved: `common/confirm-slider.yaml`. Do not spend
  calls re-deriving the gesture.
- **A slide that did not register is a finding, never a retry.** The flow fails
  when "Slide to Confirm" still shows 3s after the swipe. Do NOT swipe again:
  a second slide on a value-moving scene can send twice if the first one
  registered late. Read the swipe step's log line (from and to points, thumb
  frame before and after), `--inspect` the scene for what covers the thumb, fix
  that cause, then run the slider step once more.
- **Wait on every terminal marker at once.** A wait that names only the success
  text sits out its whole timeout when the app shows the failure instead. Put
  both in one selector (`visible: "Powered by .*|Exchange Error"`), then assert
  the success text with a 1s timeout so the failure ends the flow there. Size
  the ceiling to the slowest real success, not to a round number.
- **A long wait never follows a tap directly.** After a tap that should leave
  a scene, first prove the scene moved with a check of 5s or less (the tapped
  control is gone, or the next scene's first marker shows), then wait for the
  slow thing. A swallowed tap then fails in 5s instead of at the end of a
  300s wait. The check names every state the next scene can open in (a
  picker-closed check that waits for "Search Wallets" to leave fails when the
  next scene has that field too). The interpreter prints a lint line before
  step 1 for a tap followed by a wait over 20s with no check between.
- **Absence checks: a short `notVisible` wait, not `assertNotVisible`.** On the
  interpreter `assertNotVisible` on text that IS visible holds about 17s
  before it fails; `extendedWaitUntil: {notVisible: ..., timeout: 2000}` fails
  in 2s. A `runFlow: when: visible:` on an absent element waits 7s minus the
  time since the last interaction (`references/xcuitest-interpreter.md`,
  `runFlow` row), so a presence gate right after a tap costs the full 7s:
  gate on `when: true:` with a value known before the run, or probe absence
  first with `when: notVisible:`.
- **Exchange scene, error frames.** The "Exchange Error" card renders under
  the keyboard after Next: wait on the text, never on a frame, and take the
  proof frame after the keyboard is gone. The "Stealth Swap" label is part of
  its switch's touch target: a tap on the label flips the switch, so never use
  that label as a neutral place to tap or as a scroll anchor.
- **Wallet pickers and wallet lists: tap by row id.** Picker rows are
  `walletPickerRow.<wallet name>.<code>`; Assets rows are
  `walletListRow.<wallet name>.<code>`. A label regex misses rows whose label
  has extra text (network tags such as Arc), and after typing in the search
  field the picker's footer covers the lower rows, so type the search text
  first and then tap the id (`SRC_ROW_ID` / `DST_ROW_ID` / `ROW_ID`).
- **Send and Receive scenes have no tab bar.** A flow that ends there backs
  out (`chevronBack`) to the wallet scene before it taps Buy, Sell or
  Exchange. Each payment deep link pushes ONE more Send scene: after two link
  runs, one back tap shows an identical Send scene and the tap step reports
  plain ok, so check for the tab bar after backing out, never count taps.
- **Flow script state lives on `output`.** A `var` declared in one
  `evalScript` or `runScript` step is undefined in the next step; assign to
  `output.<name>`. Header env values are strings (`${X || "default"}`), and a
  YAML plain scalar cannot hold `: ` (quote any ternary).
- **Port lookups: `lsof`, never `pgrep -fl`.** `lsof -nP -iTCP:<port>
  -sTCP:LISTEN -t` prints the listening pid and nothing else. `pgrep -fl` and
  `ps` with argv print every matching process's full command line into the
  transcript, and those command lines can hold credentials.
- **Swipes generally: percentages, short strokes, never re-derived.** Vertical
  scrolling is `swipe: start: "50%, 70%"  end: "50%, 30%"` — always percentage
  coordinates (slot sims differ in scale; absolute pixels are why hand-derived
  swipes fail across slots), repeated short strokes with a wait between beats
  one long fling (momentum overshoots list targets). Start the gesture ON the
  scrollable content: a stroke from the screen edge is an edge-swipe and opens
  the drawer instead of scrolling. Any swipe you find yourself deriving twice
  is a `[flow]` proposal for `common/`.
- **The "Verify your password" modal auto-opens on some launches and blocks
  navigation.** Dismiss with `tapOn: id: "modal-close-button"` (testID exists on
  `EdgeModal`); the dimmed backdrop is not addressable by text.
- **Do not drive the PIN keypad with `common/login-if-needed.yaml` when the
  worktree `config.json` has `YOLO_*` set:** auto-login enters digits concurrently
  and the subflow fails on digit 3. Wait for the logged-in shell, or drive the
  already-running app.
- **Enroll/un-enroll sim biometry without the Simulator UI:**
  `xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1`
  then `notifyutil -p com.apple.BiometricKit.enrollmentChanged` (0 to
  un-enroll, `-g` reads). The app reads biometry type ONCE at startup into
  `state.touch.biometryType`, so terminate + launch after flipping; reload is
  not enough. Parallel-safe (per-simulator).
- **Reaching the login scene on a slot sim:** YOLO auto-login fires from a
  module-level `firstRun` flag in `LoginScene.tsx`, consumed once per bundle
  load, so side-menu logout LANDS on the login scene and stays. To land there
  straight from launch, null BOTH `YOLO_USERNAME` and `YOLO_PIN` in the
  worktree `config.json` (nulling only the username hits a light-account fallback
  that still auto-logs-in), then terminate + launch; restore after.
- **Drive a deep link with `openLink` on the XCUITest interpreter, in its
  `edge://` form.** A custom-scheme link reaches the running app in under a
  second with no "Open in Edge?" dialog, from any scene, whether this
  invocation launched the app or only attached to it, and the committed flows
  use it by default. An `https://edge.app/...` link works only in an invocation
  whose `launchApp` started the app and fails at once otherwise. The app
  normalizes `https://deep.edge.app/<path>` and `https://return.edge.app/<path>`
  to `edge://<path>`, and `https://edge.app/redirect/<x>` shares its parser
  with `edge://redirect/<x>`, so write the `edge://` form (check
  `src/util/DeepLinkParser.ts` for any other `https://edge.app` path). It returns before the app navigates: wait on the target scene's
  text. Avoid `simctl openurl` and Maestro's own `openLink` on
  iOS: the first raises the "Open in Edge?" system dialog, which can background
  the app when tapped, and the second fails to deliver. `YOLO_DEEP_LINK`
  in the worktree `config.json` (read by `DeepLinkingManager`, then
  `simctl terminate` + `launch`) is only for a link that must arrive at cold
  start. When the account holds several wallets for the linked asset the app
  raises its own wallet picker; the flows handle it by wallet name.
- **Nested `runFlow` with `env:` may NOT override a subflow's own `env:`
  defaults** (maestro 2.x, this host): `select-swap-pair` ran its built-in
  `.*Bitcoin.*` while the parent passed `.*Litecoin.*`, and `inputText` logged
  the literal `${SRC_WALLET}`. When a composed flow behaves as if it ignored
  your params, check this BEFORE debugging selectors; inlining the subflow body
  with literal values is the reliable workaround.
- **A `.*<term>.*` regex in a wallet picker can match the SEARCH FIELD's own
  text instead of the wallet row** — the picker silently stays open and the next
  tap lands somewhere unintended (it set the source wallet to the intended
  DESTINATION asset). Anchor wallet-row taps on the wallet NAME ("My Doge"),
  never a substring that also appears in what you just typed.
- **The maestro MCP daemon and the maestro CLI fight over one sim's XCUITest
  driver.** The wrapper pins the daemon to `$AGENT_SIM_UDID` on driver port
  `$AGENT_METRO_PORT + 2000`, but when the CLI starts its own driver on `+1000`
  the run dies mid-flow with `Connection refused` / `unexpected end of stream`
  against the CLI's port while the app stays healthy — the live app is the tell
  that it is a driver collision, not a crash. Before a CLI proof run on a sim
  you explored through the MCP, kill that slot's daemon and its
  `xcodebuild test-without-building` child (match both on YOUR udid, never
  another slot's), then run the CLI.
  `scripts/xcuitest-run.sh` does this itself: it kills the daemon PIDs matched
  on `--udid` and terminates the maestro driver app before its own drive. The
  MCP server does not come back after that kill: the session loses its maestro
  MCP tools, so finish MCP exploration before the first interpreter run.
- **Maestro `visible:` matches the WHOLE text node.** "Powered by Maya
  Protocol" renders inside a node whose text is
  `Powered by Maya ProtocolTap to Change Provider`, so the exact match never
  hits while `"Powered by .*"` does. Anchor quote-ready waits on
  `Slide to Confirm` instead — it appears only once a quote resolves.
- **Driver economics:** each `maestro test` invocation pays ~2 min driver
  startup. For EXPLORATION (finding selectors, poking screens) use the **maestro
  MCP tools** (persistent driver, per-command tap/swipe/hierarchy/screenshot;
  select the device matching `$AGENT_SIM_UDID` first). For the REPEATABLE PROOF
  run, compose ONE yaml flow and run it once: that run produces the evidence
  screenshots for the PR. On iOS the proof run goes through
  `scripts/xcuitest-run.sh --flow <yaml>` (the XCUITest interpreter, see
  `references/xcuitest-interpreter.md`): same YAML, a cached runner, no Maestro
  driver startup, and quiescence waits capped at 1s. The maestro CLI runs iOS
  flows only when the task asks for Maestro or the interpreter's preflight
  rejects a command the flow needs. Android stays on the maestro CLI.
- Modal gauntlet, eraseText-before-inputText, spaced PIN taps: all encoded in the
  `common/` flows — use them instead of remembering.
- **Fixed-port debug dev-servers are NOT slot-safe — use `updot` instead.** The
  dep debug bundles are served from HARDCODED host ports: edge-currency-plugins
  `localhost:8084` (its `debugUri`), edge-core-js `localhost:8101`. Every slot's
  simulator resolves `localhost` to the shared host loopback, so in a parallel
  slot all apps hit the SAME port and whichever slot's dev-server bound it first
  serves ITS bundle to EVERY slot's app — your app silently runs another slot's
  dep code and the test result is false (same wrong-source class as the maestro
  MCP device-pinning bug). For ANY dep runtime change, link it the parallel-safe
  way: `updot` (build the dep, copy the built artifact into THIS worktree's
  `node_modules`), per `gui-dependency-integration`. Reserve the debug dev-server
  for genuinely single-slot, interactive local work only.
- **The iOS clipboard-permission dialog ("Edge would like to paste") stalls
  maestro.** It repeatedly wedges the XCUITest view-hierarchy fetch
  (`XCTPerformOnMainRunLoop timed out 60s`). Tap "Allow Paste" with a
  hierarchy-free point tap, or feed the value through a debug override instead of
  the system clipboard.
- **Re-stabilize a springboard-dropping debug build by trimming plugins.** When
  the build starts crashing to springboard on swap/wallet-selector screens after
  several relaunches, comment out `piratechain` and `stellar` in
  `src/util/corePlugins.ts` (local-only, Metro reload, revert after) — it restores
  stability without losing the logged-in account.
- **Hot-swap an exchange-plugin JS change instead of a ~15 min native rebuild.**
  For an `edge-exchange-plugins` JS change on re-test: rebuild the dep
  (`npm run prepare`) and `cp` the webpacked `edge-exchange-plugins.js` over
  `<app>/edge-exchange-plugins.bundle/edge-exchange-plugins.js` in the installed
  `.app`, then relaunch — the WebView reloads the plugin bundle from the resource
  on launch. Parallel-safe (per-slot `.app`).
- **Force a provider + pick a quotable pair.** To route a swap through one
  provider, edit the gui checkout's `src/util/corePlugins.ts` `swapPlugins` map:
  set every other provider to `false` and keep the target's `*_INIT` (drive.md
  `force-swap-provider-locally`; local only, never committed, revert before any
  commit). Then `metro-fresh.sh`, then cold-launch. Never toggle **Settings →
  Exchange Settings** for this: it is account-synced and persists into every
  other session on that roster account; read it only to diagnose why a
  provider is absent. A small same-chain stablecoin→native amount may not quote
  on Maya/Thorchain (price-impact/min); a cross-chain destination (e.g.
  token→BTC) quotes reliably and exercises the same source-side token-spend code.
- **Create-wallet entry points.** The Wallets bottom tab is labeled **"Assets"**;
  the create-wallet entry is the header `addButton` (testID) — use it instead of
  scrolling a long wallet list. YOLO auto-login (agent roster account) lands logged-in
  a few seconds after launch.
- **EVM send-flow drive recipe:** search "Ethereum" in Assets to filter ETH
  wallets → wallet "Send" → address tile "Enter" (regex `.*Enter.*`) → type a
  LOWERCASE 0x address (lowercase sidesteps EIP-55 checksum rejection) → "Next".
  The SafeSlider confirm thumb carries testID `confirmSliderThumb`, so
  `common/confirm-slider.yaml` resolves without coordinate taps.
- **edge-exchange-plugins JS fix, in-app verification:** after `npm run prepare`,
  copy `dist/edge-exchange-plugins.js` + `dist/898.chunk.js` + `dist/195.chunk.js`
  over `<app>/edge-exchange-plugins.bundle/`, relaunch, and confirm the old
  symbol is absent from the INSTALLED bundle before crediting the fix.

## Asset & provider specifics
- **Maya is the only provider for CACAO pairs,** so a CACAO source (e.g.
  CACAO→BTC) executes a real Maya swap with no provider forcing.
- **keys-only create-wallet exclusion — proxy without the target asset:**
  `bitcoinsv` is hardcoded-enabled in `corePlugins.ts` AND `keysOnlyMode: true`, so
  searching "Bitcoin SV" in "Choose Wallets to Add" shows no creatable result — a
  ready proxy for verifying the keys-only exclusion mechanism when the real asset
  (e.g. Botanix) can't run in the sim.
- **`BOTANIX_INIT` (develop: `config.json` `corePlugins.botanix`) is `false` by default; enabling it crashes the
  debug build on launch.** So Botanix is absent from `account.currencyConfig` in
  normal builds and never appears in create-wallet regardless of `keysOnlyMode` —
  exercise the gate via the bitcoinsv proxy above, not Botanix itself.
- **`keysOnlyMode` in `SPECIAL_CURRENCY_INFO` can be a computed boolean evaluated
  at module load** (precedents: zcash → `isZecBroken()`, piratechain → inline
  Platform check). A helper it calls must not reference a module-level `const`
  declared AFTER `SPECIAL_CURRENCY_INFO`, or it hits the temporal dead zone at
  import.
- **TON send/sync tests:** a wallet-to-wallet self-send between two TON
  wallets on the account at ~0.0064 TON exercises pending→confirmed
  reconciliation.
- **TON public endpoint rate-limits under parallel slots:** toncenter.com/api/v2
  429s ("Ratelimit exceed") on repeated /sendBoc + /estimateFee; it rejects BEFORE
  any txid is saved (no corruption). Cool down 2-3 min and retry; a clean fee
  estimate is the recovery signal.
- **Maya/Thorchain pending-metadata tests: confirm the FIRST fresh quote.** The
  60s timeout is on the quote re-fetch, not the broadcast — slide immediately,
  don't let the quote expire. USDT(Ethereum)→ETH is a reliable
  executable Maya token-source pair; min ~5.21 USDT.
- **SideShift geo-gate is per-request from the CURRENT egress — re-verify fresh
  each run:** `curl https://sideshift.ai/api/v2/permissions` →
  `{"createShift":<bool>}`; `POST /api/v2/quotes` returns ACCESS_DENIED when
  blocked. A non-US VPN exit flips createShift true.
- **Xgram executable-pair recipe:** only XMR pairs are enabled for Edge's key
  (BTC/LTC/BCH/TRX/SOL ↔ XMR); floors ~$50-100 equivalent (SOL→XMR min 0.62 SOL,
  XMR→BTC min 0.159 XMR, TRX→XMR min 67 TRX — discover live via BELOW_LIMIT).
  SOL→XMR from My Solana → My Monero executes reliably; the confirm slider needs a
  coordinate swipe on the quote scene.
