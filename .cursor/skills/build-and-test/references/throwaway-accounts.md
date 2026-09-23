# Throwaway test accounts

Accounts created by `maestro/common/create-throwaway-account.yaml`. They are
EMPTY, disposable, and **reusable across sessions**: a followup does not need to
create a new one, and there is no need to delete them at the end of a run.
Uniqueness is what matters: the flow's default username is
`agent-tw-<random>` and its default password is random per run, so two
sessions never collide.

Use one of these instead of a roster account whenever a test would otherwise
mutate ACCOUNT-SYNCED state that other sessions share: `activePromotions`,
referral/affiliate attribution (`installerId`, `CreationReason.json`), Exchange
Settings, Privacy/mixnet toggles, wallet lists. The roster accounts (see
`~/.config/edge-secrets/test-accounts.json`) stay for FUNDED work.

Log in the usual way: set `YOLO_USERNAME`/`YOLO_PIN` in the worktree `env.json`,
then `simctl terminate` + `launch`. Restore the roster account when done.

**The ledger is local-only:** `~/.config/edge-secrets/throwaway-accounts.md`
(username / password / PIN / which sim / notes). Check it before creating
another, and append a row when you do, including the password the flow
returned in `output.newAccountPassword`. Do not delete rows for accounts you
did not delete. Never copy a row, username, or password into a synced skill,
commit, PR, or report.

Notes on the sim column: the account's device stash lives on ONE simulator, so a
row is only usable from that sim (or from any clone cut after it was created).
On a different pool sim, create a fresh one rather than trying to import.

An account whose test dirtied synced state (an activated promo code, an
affiliate attribution) should say so in its ledger Notes.
