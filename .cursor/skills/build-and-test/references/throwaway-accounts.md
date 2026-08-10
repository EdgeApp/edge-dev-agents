# Throwaway test accounts (shared ledger)

Accounts created by `maestro/common/create-throwaway-account.yaml`. They are
EMPTY, disposable, and **reusable across sessions** — a followup does not need to
create a new one, and there is no need to delete them at the end of a run.
Uniqueness is what matters: the flow's default username is
`agent-tw-<random>`, so two sessions never collide.

Use one of these instead of a roster account whenever a test would otherwise
mutate ACCOUNT-SYNCED state that other sessions share: `activePromotions`,
referral/affiliate attribution (`installerId`, `CreationReason.json`), Exchange
Settings, Privacy/mixnet toggles, wallet lists. The roster accounts
(`edge-funds`, `edge-rjqa2`, `edge-rjqa3`, `test-funds`) stay for FUNDED work.

Log in the usual way: set `YOLO_USERNAME`/`YOLO_PIN` in the worktree `env.json`,
then `simctl terminate` + `launch`. Restore the roster account when done.

**Append a row when you create one. Do not delete rows for accounts you did not
delete.**

| Username | Password | PIN | Sim | Created | Wallets | Notes |
|---|---|---|---|---|---|---|
| `agent-tw-65912400` | `Agent3Throwaway1` | `1234` | agent-sim-pool-0 | 2026-08-07 | BTC, ETH, LTC, BCH, DASH (app defaults) | Empty. Region unset. |
| `agent-tw-571866930` | `Agent3Throwaway1` | `1234` | agent-sim-pool-0 | 2026-08-07 | app defaults | Empty. Region unset. |
| `agent-tw-597658918` | `Agent3Throwaway1` | `1234` | agent-sim-pool-0 | 2026-08-07 | app defaults | Empty. Region unset. |

Notes on the sim column: the account's device stash lives on ONE simulator, so a
row is only usable from that sim (or from any clone cut after it was created).
On a different pool sim, create a fresh one rather than trying to import.

An account whose test dirtied synced state (an activated promo code, an
affiliate attribution) should say so in Notes, or be left off the reusable list.
