---
name: coinhub
description: Maintain the Coinhub white-label build of edge-react-gui. Use when a task involves the `coinhub` branch, the Coinhub app, rebasing coinhub onto develop, fixing a Coinhub build/CI failure, updating Coinhub branding/config, or regenerating Coinhub jest snapshots. Coinhub is a white-label app built automatically from the `coinhub` git branch.
---

<goal>Land correct, review-clean changes onto the edge-react-gui `coinhub` branch head, which auto-builds the Coinhub customer app, without leaking Edge-specific functionality and without breaking the coinhub-config jest snapshots CI renders.</goal>

<context>
- The Coinhub app is a white-label build of edge-react-gui. CI (Jenkins) builds whatever is at the `coinhub` branch HEAD and ships it to the customer.
- `coinhub` is NOT a feature branch off develop; it is a long-lived branch carrying a small set of customization commits replayed over a periodically-refreshed develop base.
- The app config is selected by `ENV.APP_CONFIG`. Coinhub sets `APP_CONFIG=coinhub`, which loads `src/theme/coinhubConfig.ts` and the `coinhubDark`/`coinhubLight` themes (NunitoSans fonts, Coinhub palette). Edge default is `APP_CONFIG=edge` (Quicksand fonts).
- CI copies `jenkins-files/coinhub/env.json` (which sets `APP_CONFIG=coinhub`) over the checkout's env.json before `npm test` and the native builds. `jenkins-files` is a separate Jenkins-managed repo, not in the gui checkout.
</context>

<rules description="Non-negotiable constraints.">
<rule id="correct-head-is-the-deliverable">The deliverable is a CORRECT `coinhub` branch HEAD — that head is what auto-builds into the customer app. A working branch plus PR is VALID and PREFERRED (it gives clean automated review / bugbot coverage before customer-facing code ships), but the run is NOT done until the reviewed commits are on `coinhub`'s head. Promote by merging the reviewed PR into `coinhub`, or by fast-forwarding `coinhub` to the reviewed head. Opening a PR is a means to review; landing the correct head is the end.</rule>
<rule id="snapshots-under-coinhub-config">ALWAYS regenerate jest snapshots under the config CI renders: `APP_CONFIG=coinhub` AND `ALLOW_DEVELOPER_MODE=false`, never a plain dev env.json. CI renders under `jenkins-files/coinhub/env.json` (NunitoSans fonts, developer mode off), so snapshots generated under `APP_CONFIG=edge` (Quicksand) fail every CI branch on a ~90-snapshot mismatch, and a dev env with `ALLOW_DEVELOPER_MODE=true` adds the developer-mode settings card (SettingsScene.tsx gates it on `ENV.ALLOW_DEVELOPER_MODE`) that the production render omits, failing the SettingsScene snapshot. Use `scripts/regen-coinhub-snapshots.sh`, which forces both flags, regenerates, runs a clean `jest --ci`, and asserts zero `Quicksand` leakage. Verify green locally with the EXACT CI command: `TZ=America/Los_Angeles npx jest --ci` (exit 0). env.json is gitignored; the flips are local-only and never committed.</rule>
<rule id="no-edge-specific-content">The Coinhub app must contain ZERO Edge-specific/mentioning functionality. When rebasing onto develop, audit the newly-added develop commits for Edge-branded promos/links/referral, new ramp providers Coinhub does not use, and location/permission additions the Coinhub widget must not request. Omit them per the branch's established stance (see the coinhub commits' history for what has been stripped before, e.g. "Revert to legacy ramps", "Remove location permission").</rule>
<rule id="theme-drift-is-expected">`src/theme/variables/coinhubDark.ts` and `coinhubLight.ts` are STANDALONE full `Theme` objects, not spreads of the edge theme, so they drift out of the `Theme` type on every multi-month rebase. tsc reports it as an EXCESS property first; only after removing the excess does it reveal the MISSING props (the excess-property check masks the missing set). Re-run `npx tsc --noEmit` after each fix until clean; add missing props with Coinhub-palette-safe values.</rule>
<rule id="commit-via-lint-commit">Every commit goes through `~/.cursor/skills/lint-commit.sh` (raw `git commit` is forbidden, `--no-verify` doubly so). A snapshot/config-fix commit on this white-label branch gets NO CHANGELOG entry — the CHANGELOG is for user-facing edge-app changes, not Coinhub build fixtures.</rule>
<rule id="no-blind-force-push">Do not force-push `coinhub`. Add commits on top (fast-forward) whenever possible. A history rewrite of `coinhub` is a shared-branch destructive op: do it only with explicit operator authorization AND `--force-with-lease`, never bare `--force`. Confirm `git merge-base --is-ancestor origin/coinhub HEAD` before any push to prove it is a fast-forward.</rule>
<rule id="document-env-json">Document the `env.json` deltas the build box needs since Coinhub's last push. `APP_CONFIG: "coinhub"` is the one load-bearing key. Diff `src/envConfig.ts` between the coinhub base and develop: additions that are `asOptional`/plugin-init with defaults under a top-level `.withRest` schema need NO build-box change; call those out as optional so the operator is not misled into thinking a key is required.</rule>
</rules>

<step id="1" name="Provision workspace on coinhub">
Provision a co-located worktree on the coinhub branch:
`~/.config/agent-watcher/setup-task-workspace.sh --task-gid <gid> --repo edge-react-gui --existing-branch coinhub`
(orchestrated runs). For a review-gated change, branch off coinhub with `--branch <prefix>/coinhub-<short-name>` instead, and plan to land the reviewed head back onto coinhub per `correct-head-is-the-deliverable`. `cd` into the worktree.
</step>

<step id="2" name="Apply the change">
- REBASE task (refresh onto latest develop): `git rebase --onto origin/develop <merge-base> coinhub`. Resolve conflicts commit-by-commit, keeping Coinhub branding and the legacy-ramps stance while adopting develop's new structure. Drop any stale "Update snapshots" commit (regenerate in step 3 instead). Apply `no-edge-specific-content` and `theme-drift-is-expected`.
- TARGETED fix (e.g. a CI break, a branding/config tweak): make the minimal edit directly. If the fix is only stale snapshots, skip to step 3.
</step>

<step id="3" name="Regenerate snapshots + verify like CI">
Run the companion script from the worktree:
`~/.cursor/skills/coinhub/scripts/regen-coinhub-snapshots.sh`
It sets `APP_CONFIG=coinhub`, runs `jest -u`, runs a clean `jest --ci` (must exit 0), and asserts zero `Quicksand` leakage. Then run `npx tsc --noEmit` (clean) per `theme-drift-is-expected`. For a behavioral or branding change, also do a Coinhub login/sanity drive on the sim (the app runs this worktree's coinhub JS over the slot Metro; no native rebuild needed when slot-preflight reports `ready`).
</step>

<step id="4" name="Commit + document env.json">
Commit via `~/.cursor/skills/lint-commit.sh -m "<message>"` (per `commit-via-lint-commit`). Produce the `env.json` build-box documentation per `document-env-json`.
</step>

<step id="5" name="Land the correct coinhub head">
Per `correct-head-is-the-deliverable`:
- Review-gated path: push the working branch, open a PR (`/pr-create`), let automated review run clean, then land the reviewed head onto `coinhub`.
- Direct path (operator-authorized, low-risk fixture/config fix): confirm the fast-forward (`git merge-base --is-ancestor origin/coinhub HEAD`), then `git push origin HEAD:coinhub`.
Never leave the run with the fix only on a side branch: `coinhub`'s head must carry it.
</step>

<edge-cases>
<case name="All four CI branches failed">Jenkins runs iOS/Android x Build/Maestro in parallel, each doing `npm ci` + `npm test` before its native build. One shared unit-test (snapshot) failure fails all four before any native build runs. Fix the shared unit-test break first; do not assume four independent native failures.</case>
<case name="Jenkins not reachable from the agent">There is no GitHub PR/check-run for the coinhub branch build; CI is Jenkins-only and not watchable via `gh`/`watch-pr.sh`. Verify by reproducing the exact failing CI command locally (`TZ=America/Los_Angeles npx jest --ci` under coinhub config) and note in the report that the operator re-runs the Jenkins job to confirm green.</case>
<case name="Snapshot fix only, no runtime change">A `.snap`-only change cannot alter app behavior (snapshots never ship). Skip the sim re-drive and say so; do not re-verify unchanged app code.</case>
</edge-cases>
