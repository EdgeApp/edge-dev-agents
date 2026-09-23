# Throwaway test accounts

Accounts created by `maestro/common/create-throwaway-account.yaml`. They are
EMPTY and SINGLE-USE: a run creates one for its test, then deletes it with
`maestro/common/delete-throwaway-account.yaml` before the run ends. There is
no ledger and no reuse across sessions. The create flow's default username is
`agent-tw-<random>` and its default password is random per run; both come
back in `output.newAccountUsername` / `output.newAccountPassword`, which the
delete flow reads. Never write either value anywhere: not a ledger, run
report, PR, Asana comment, or skill.

Use one instead of a roster account whenever a test would otherwise mutate
ACCOUNT-SYNCED state that other sessions share: `activePromotions`,
referral/affiliate attribution (`installerId`, `CreationReason.json`), Exchange
Settings, Privacy/mixnet toggles, wallet lists. The roster accounts (see
`~/.config/edge-secrets/test-accounts.json`) stay for FUNDED work.

Log in the usual way: set `YOLO_USERNAME`/`YOLO_PIN` in the worktree `env.json`,
then `simctl terminate` + `launch`. Restore the roster account when done.

If the test funded the throwaway, sweep the funds back to a roster account
before deleting it.
