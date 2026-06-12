# Sim-testing playbook (edge-react-gui)

Working knowledge for driving the app on the sim. Read once before the test
phase; it is cheap context that saves expensive UI churn. This is a LIVING doc:
when a run teaches you something durable about driving the app, append a concise
entry (the human audits and prunes it periodically — keep entries dense).

## Money / accounts
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
- **Debug builds crash to springboard (RN Fabric SIGABRT) on two reliable
  triggers: rapid settings-row toggling, and swap-amount keypad entry.** Seen
  repeatedly on the SideShift run. Do NOT keep relaunching to grind through it —
  you'll burn the slot. **The direct-verification fallback below is GATED: it is
  legitimate ONLY after you have actually funded and driven a REAL, available
  swap to the point where THIS crash interrupts execution. It is NOT a substitute
  for an executable swap you already hold.** If a funded, provider-supported pair
  is in hand (both wallets present, e.g. BTC→FTM), you must drive THAT pair to
  completion first (see the `executable-pair-must-complete` rule) — abandoning it
  for a slower/riskier path and then citing "the build crashes" is the exact
  miss this gate exists to prevent. Only once a genuine funded attempt is
  interrupted by the Fabric crash do you switch to **direct verification of the
  code path** as primary proof and treat the in-app run as partial evidence:
  (1) `tsc` clean, (2) boot-time plugin/env validation (the app re-initializing
  the plugin on your new bundle proves the changed init path), (3) hit the real
  provider endpoint yourself (e.g. `curl` the exact request the plugin makes) to
  confirm the behavior the change produces. Capture whatever in-app state you DID
  reach (e.g. a fully-configured swap with source+receiving wallets selected) as
  a proof screenshot before the crash. THAT combination — genuine funded attempt
  + crash + direct proof — is a legitimate PASS; bailing to direct proof BEFORE a
  real funded attempt is not.
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

## Investigate cheap before driving the UI
- **Crawl the code and run `/debugger` EARLY**, not as a last resort. A grinding
  UI loop is the most expensive probe there is. "Why is X missing/failing" is
  usually answerable from source (settings store, plugin registration, env.json
  flags) or one `/debugger` breakpoint — minutes, vs. an hour of taps.
- **Feature-enablement check (the Rango lesson):** when a provider/feature you
  expect simply ISN'T THERE (no quotes from it, not in the list), FIRST suspect
  a setting: swap providers can be individually disabled under
  **Settings → Exchange Settings** (per-account state, so it differs between
  edge-rjqa3 and edge-funds!). Verify via code/state or ONE settings screenshot —
  this is general knowledge, NOT a mandatory physical preflight on every run. The
  same surface is also the lever to FORCE a provider (disable competitors);
  Preferred/preferPluginId do NOT pin (engine reverts to best-rate ~60s).
- If you changed provider/exchange settings on an account to force routing,
  **revert them when the test is done** — the next run (or human) inherits that
  account state.

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
