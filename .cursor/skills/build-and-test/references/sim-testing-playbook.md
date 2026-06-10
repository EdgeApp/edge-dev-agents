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
- **Avoid new-wallet creation on debug builds when an existing funded wallet
  exists anywhere** — wallet creation has hit a native SQLite crash on debug
  builds (HyperEVM run); an existing wallet on another account sidesteps it.
- **High-value wallets are sanctioned funding sources.** BTC / ETH / USDC and
  similar majors (which nearly every swap provider supports) MAY be swapped FROM
  to fund the asset a test needs. You are allowed to spend them for testing;
  prefer the smallest amount that clears the ~$10 floor with margin.

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
