# Sim-testing playbook (edge-react-gui)

Working knowledge for driving the app on the sim. Read once before the test
phase; it is cheap context that saves expensive UI churn. This is a LIVING doc:
when a run teaches you something durable about driving the app, append a concise
entry (the human audits and prunes it periodically — keep entries dense).

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
- **Test-account ROSTER (exhaustive — search no further)**: `edge-funds`
  (PIN 0000 — the heavily-funded swap-execution account, holds HYPE; **the
  default YOLO login**, pinned into every worktree env.json by workspace init),
  `edge-rjqa2` (PIN 1111), `edge-rjqa3` (PIN 1111), `test-funds` (PIN 0000).
  The sim image also contains many junk/leftover accounts — they are NOT test
  accounts; never trawl beyond the roster. **Switching among roster accounts
  mid-test is normal and expected** — check them for the asset you need before
  acquiring it, and BEFORE creating a new wallet ("no account holds X" is not a
  valid conclusion until each ROSTER account was actually checked).
- **HOW to switch accounts: edit env.json, do NOT drive the UI.** The canonical
  switch is: set `YOLO_USERNAME`/`YOLO_PIN` in the WORKTREE's `env.json` (a
  local-only, gitignored copy) to the target roster account, then
  `xcrun simctl terminate <udid> co.edgesecure.app` + `launch` — YOLO auto-login
  lands you in that account on startup. Seconds, deterministic, no side-menu /
  account-dropdown churn (an agent burned 20+ min fumbling that dropdown).
  Drive the in-app account switcher ONLY when you must preserve live in-app
  state across the switch (rare).
- **PIN space:** every roster PIN is one of `0000` / `1111` (exact mapping in
  the roster above). If you're ever at a PIN prompt unsure which: prefer looking
  it up; at most try the two, ONCE each — wrong-PIN retries trigger exponential
  lockout (465s → 914s → …), so never brute-force, and back off immediately on
  "Account locked".
- **Wallet creation is a SUPPORTED test path — not to be avoided.** Prefer an
  existing funded wallet when the task doesn't involve creation (faster, no
  setup), but create wallets freely when the task targets creation behavior or
  no account holds the needed asset.
- **The "SQLite crash on wallet creation" is a PRODUCT bug, not an environment
  one, and is NOT actually caused by creating a wallet** (diagnosed in Asana
  1215619633542395, 2026-06-11; the env fix it hoped for does not exist). Root
  cause: the OLD `react-native-piratechain` module (a ZcashLightClientKit fork,
  `piratelc_*` Rust FFI, `PirateSdk_mainnet…pirate_data.db`) opens TWO SQLite
  connections on the same `data.db` — a Swift SQLite.swift reader and a Rust
  `rusqlite` writer — with no shared locking. When the Rust scanner holds the DB
  (`processNewBlocks` → `block_height_extrema` / balance) while the Swift
  `CompactBlockProcessor.resolveMempools` mempool consumer reads via
  `TransactionSQLDAO.find(rawID:)`, the read gets `SQLITE_BUSY`, SQLite.swift
  throws, and the async mempool task does not catch it → `swift_unexpectedError`
  / `EXC_BREAKPOINT`. It fires from the edge-funds account's BACKGROUND ARRR/ZEC
  sync at any time (it crash-looped 15× on 2026-06-09/10), independent of your
  actions, account (edge-funds + test-funds both), and JS diff. The DB is NOT
  corrupt and disk is NOT full — neither resetting the sim data container nor
  re-cloning the master fixes it (the race re-arms on every re-sync), which is
  why this is left to the in-flight Piratechain SDK rewrite (Asana
  1214721783909451 / accountbased #1055 / gui #6021) that REPLACES this module.
  Practical handling, in order:
  1. **PRESCRIBED mitigation when the task is NOT piratechain/zcash-related and
     the test needs wallet creation/import (or the crash recurs): disable
     piratechain locally.** In the gui worktree edit
     `src/util/corePlugins.ts` → `piratechain: false` (it is hardcoded `true`,
     not ENV-gated), then relaunch the app — JS-only, Metro reload picks it up,
     no native rebuild. Core never initializes the plugin, the background ARRR
     scanner never starts, and the race cannot fire, while you keep edge-funds
     and all its funding. REVERT IMMEDIATELY after the test
     (`git checkout -- src/util/corePlugins.ts`); never commit the flip. Off
     limits when the task under test IS piratechain/zcash (e.g. the SDK rewrite
     chain) — there the module must run.
  2. Lighter alternative when you don't need edge-funds' balances: switch to a
     roster account with NO ARRR wallet — the crash fires from the logged-in
     account's background ARRR sync, so no ARRR wallet means no trigger.
  3. Otherwise: it's intermittent, so relaunch and continue — the app usually
     runs fine for long stretches; capture the `Edge-*.ips` crash log if it
     recurs, note it as a known product blocker (link 1215619633542395), and
     fall back to an existing wallet. Do NOT spend the slot trying to "fix the
     sim."
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
  is a DOWNGRADE concession the `require-concession-validation.sh` gate catches;
  the concession-validator DENIES it because a documented continue-workaround
  exists. **The direct-verification fallback below is GATED: it is legitimate
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
- **SideShift is US-geo-blocked from this host's egress IP** (found 2026-06-12,
  Asana 1214800712844381): in-app quotes and the confirm slider render, but
  shift CREATION is denied at ANY amount — the denial is geographic, not a
  floor/funding problem, so do not burn the slot retrying amounts or pairs. An
  executed SideShift shift needs non-US egress (VPN/proxy), which the slot does
  not have; verify via direct API + quote/slider proof, document the geo-block
  as the external precondition, and move on.
- **NYM swap is testnet-only and EXECUTABLE today.** One side must be the `nym`
  asset (chainNetwork `sandbox`); the counter-asset comes from {bitcoin,
  litecoin, dash, zcash, cardano, sepolia}. The reliable in-sim pair is
  **Sepolia ETH → NYM**. Needs (a) the NYM testnet `x-api-key` in `env.json`
  `NYM_SWAP_INIT.apiKey`, and (b) Sepolia testnet ETH funded into the app's My
  Sepolia wallet (no in-app faucet — fund the wallet's receive address from a
  pre-funded Sepolia key via a public Sepolia RPC). Live floor 0.005 ETH; a
  ~0.0066 ETH swap clears it.
- **Breez Spark Lightning sends: the Spark balance is SEPARATE from the BTC
  wallet's on-chain UTXOs and starts at 0.** To test a send you must fund the
  Spark wallet first: send on-chain BTC to its `bc1p` Taproot deposit address,
  wait 1 block, Spark auto-claims on sync. The Taproot deposit needs the
  edge-currency-plugins eager-`initEccLib` fix (PR #450) — link it the
  PARALLEL-SAFE way (`updot`/build into the worktree's `node_modules`), NOT the
  fixed-port debug dev-server (see the slot-safety caveat under "Driving the
  app"). Size sends ≤ ~60 sats from a single freshly-claimed leaf
  (leaf-headroom). Mint the receive invoice and verify receipt out-of-band with
  the `@breeztech/breez-sdk-spark` node SDK.
- **edge-funds funding snapshot (2026-07-02, re-verify balances before relying):**
  My Bitcoin (BTC) is EMPTY — a BTC Send triggers the wallet-empty modal. Funded:
  My Base 4 (0.35 ETH, ~$600), My Zano (~$460), L3USD on Fantom (~$240),
  My MAYAChain (CACAO). EVM chains block a SECOND send while one is unconfirmed —
  wait for confirmation before chaining sends. (2026-07-09 eval, Houdini run)

## Navigation
- **Gift Card Marketplace (EdgeSpend):** reachable in-app from Home → 'Spend
  Crypto' tile → the EdgeSpend list → 'Purchase New'. Requires a non-light account
  (edge-funds qualifies) and `ENV.PLUGIN_API_KEYS.phaze.apiKey` set. Real Phaze
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
- **OK** — only now is it a reload/cache question: cold-launch first, then
  `--reset-cache` (a hook requires a fresh triage marker before cache resets).

Hard rules enforced by hooks: hand-writing `RCT_jsLocation` is blocked
(packager pinning belongs to ios-rn-build.sh's cached-launch path, which pins +
terminates + relaunches so it takes effect); cache resets without a fresh triage
are blocked. And when MCP screenshots contradict what the logs say the app is
doing (e.g. "won't foreground" while JS runs), verify with direct
`xcrun simctl io <udid> screenshot` before building theories — the maestro
daemon can drift to another sim, and the 2026-07-22 swapter run spent an hour
debugging screenshots of the wrong device.

## Investigate cheap before driving the UI
- **Crawl the code and run `/debugger` EARLY**, not as a last resort. A grinding
  UI loop is the most expensive probe there is. "Why is X missing/failing" is
  usually answerable from source (settings store, plugin registration, env.json
  flags) or one `/debugger` breakpoint — minutes, vs. an hour of taps.
- **Feature-enablement check (the Rango lesson):** when a provider/feature you
  expect simply ISN'T THERE (no quotes from it, not in the list), FIRST suspect a
  setting: a swap provider can be disabled in **Settings → Exchange Settings**,
  which is PER-ACCOUNT state (differs between edge-rjqa3 and edge-funds). Use this
  only to DIAGNOSE (read it from code/state or ONE screenshot) — do NOT toggle it.
- **FORCE a provider via the LOCAL corePlugins hack, NEVER the in-app Exchange
  Settings.** To isolate one swap provider, edit the gui worktree's
  `src/util/corePlugins.ts` `swapPlugins` map and set every OTHER provider to
  `false`, leaving only the target's `*_INIT` — local, uncommitted (per
  `force-swap-provider-locally`). Exchange Settings are ACCOUNT-SYNCED: toggling
  them on edge-funds thrashes against every other parallel session on the same
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
  better than staring at one signature. (2026-07-09 eval, CEX-signing run)
- **Houdini routes are verifiable fund-free via the partner API:**
  `GET https://api-partner.houdiniswap.com/v2/tokens?chain=<chain>&mainnet=true&pageSize=100`
  then `GET /v2/quotes?amount=<x>&from=<id>&to=<id>`. A same-asset cross-chain pair
  may legitimately return only dex/standard (no private route) — that's an answer,
  not a failure. (2026-07-09 eval, Houdini run)

## Driving the app (mechanics)
- **Compose, don't re-derive.** Reusable subflows live in this skill's
  `maestro/common/` (`login-if-needed`, `dismiss-startup-modals`,
  `select-swap-pair`, `confirm-slider`). Copy them next to your task flow and
  `runFlow` them. The gui repo also has its own heavyweight `maestro/common/`
  (verification suite) — reference for selectors, but dev flows stay OURS/local.
- **The confirm slider** is solved: `common/confirm-slider.yaml`. Do not spend
  calls re-deriving the gesture.
- **Maestro economics:** each `maestro test` invocation pays ~2 min driver
  startup. For EXPLORATION (finding selectors, poking screens) use the **maestro
  MCP tools** (persistent driver, per-command tap/swipe/hierarchy/screenshot —
  select the device matching `$AGENT_SIM_UDID` first). For the REPEATABLE PROOF
  run, compose ONE yaml flow and run it once — that run produces the evidence
  screenshots for the PR.
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
- **Force a provider + pick a quotable pair.** To route a swap through a specific
  DEX provider, disable competitors in **Settings → Exchange Settings** (per-account
  state). A small same-chain stablecoin→native amount may not quote on
  Maya/Thorchain (price-impact/min); a cross-chain destination (e.g. token→BTC)
  quotes reliably and exercises the same source-side token-spend code.
- **Create-wallet entry points.** The Wallets bottom tab is labeled **"Assets"**;
  the create-wallet entry is the header `addButton` (testID) — use it instead of
  scrolling a long wallet list. YOLO auto-login (edge-funds / 0000) lands logged-in
  a few seconds after launch.
- **EVM send-flow drive recipe:** search "Ethereum" in Assets to filter ETH
  wallets → wallet "Send" → address tile "Enter" (regex `.*Enter.*`) → type a
  LOWERCASE 0x address (lowercase sidesteps EIP-55 checksum rejection) → "Next".
  The SafeSlider confirm thumb carries testID `confirmSliderThumb`, so
  `common/confirm-slider.yaml` resolves without coordinate taps. (2026-07-09 eval)
- **edge-exchange-plugins JS fix, in-app verification:** after `npm run prepare`,
  copy `dist/edge-exchange-plugins.js` + `dist/898.chunk.js` + `dist/195.chunk.js`
  over `<app>/edge-exchange-plugins.bundle/`, relaunch, and confirm the INSTALLED
  bundle no longer contains the old symbol before crediting the fix. (2026-07-09 eval)

## Asset & provider specifics
- **`edge-funds` holds a funded My MAYAChain (CACAO) wallet (~$150).** Usable for
  real Maya swap execution (e.g. CACAO→BTC). Maya is the only provider for CACAO
  pairs, so no provider forcing is needed for CACAO sources.
- **keys-only create-wallet exclusion — proxy without the target asset:**
  `bitcoinsv` is hardcoded-enabled in `corePlugins.ts` AND `keysOnlyMode: true`, so
  searching "Bitcoin SV" in "Choose Wallets to Add" shows no creatable result — a
  ready proxy for verifying the keys-only exclusion mechanism when the real asset
  (e.g. Botanix) can't run in the sim.
- **`BOTANIX_INIT` is `false` by default in env.json; enabling it crashes the
  debug build on launch.** So Botanix is absent from `account.currencyConfig` in
  normal builds and never appears in create-wallet regardless of `keysOnlyMode` —
  exercise the gate via the bitcoinsv proxy above, not Botanix itself.
- **`keysOnlyMode` in `SPECIAL_CURRENCY_INFO` can be a computed boolean evaluated
  at module load** (precedents: zcash → `isZecBroken()`, piratechain → inline
  Platform check). A helper it calls must not reference a module-level `const`
  declared AFTER `SPECIAL_CURRENCY_INFO`, or it hits the temporal dead zone at
  import.
- **TON send/sync tests need no swap-to-fund:** edge-funds holds funded
  "My Toncoin" (~3.4 TON) and "My Toncoin 2"; a wallet-to-wallet self-send at
  ~0.0064 TON exercises pending→confirmed reconciliation. (2026-07-09 eval)
- **TON public endpoint rate-limits under parallel slots:** toncenter.com/api/v2
  429s ("Ratelimit exceed") on repeated /sendBoc + /estimateFee; it rejects BEFORE
  any txid is saved (no corruption). Cool down 2-3 min and retry; a clean fee
  estimate is the recovery signal. (2026-07-09 eval, TON run)
- **Maya/Thorchain pending-metadata tests: confirm the FIRST fresh quote.** The
  60s timeout is on the quote re-fetch, not the broadcast — slide immediately,
  don't let the quote expire. edge-funds USDT(Ethereum)→ETH is a reliable
  executable Maya token-source pair; min ~5.21 USDT. (2026-07-09 eval)
- **SideShift geo-gate is per-request from the CURRENT egress — re-verify fresh
  each run:** `curl https://sideshift.ai/api/v2/permissions` →
  `{"createShift":<bool>}`; `POST /api/v2/quotes` returns ACCESS_DENIED when
  blocked. A non-US VPN exit flips createShift true. (2026-07-09 eval)
- **Xgram executable-pair recipe:** only XMR pairs are enabled for Edge's key
  (BTC/LTC/BCH/TRX/SOL ↔ XMR); floors ~$50-100 equivalent (SOL→XMR min 0.62 SOL,
  XMR→BTC min 0.159 XMR, TRX→XMR min 67 TRX — discover live via BELOW_LIMIT).
  SOL→XMR from My Solana → My Monero executes reliably; the confirm slider needs a
  coordinate swipe on the quote scene. (2026-07-09 eval)
