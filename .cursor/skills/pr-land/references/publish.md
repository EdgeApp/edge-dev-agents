Governs steps 6-7 of `/pr-land` (batched npm publish and GUI dependency bumps); the core step map points here.

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="publish-gating">Don't publish if outstanding PRs remain. Only publish a repo when ALL approved PRs for that repo are merged. If any were skipped or held back, do NOT publish that repo. DEP-REPO LANDS INCLUDE THE RELEASE CHAIN (2026-07-24): merging a PR in a GUI-dependency repo (edge-core-js, edge-exchange-plugins, edge-currency-*, edge-login-ui-rn, ...) does NOT complete the land at merge, even when the batch contains no dependent GUI PR — the fix cannot reach the app until it is published and the GUI consumes it. After that repo's approved PRs are merged: run the publish step (version bump + tag + push + npm publish; the npm-2FA AUTH_URL boundary follows one-shot `land-on-approval`: bounded link wait, then a blocked completion), then land the GUI dep-bump once the publish lands. A BUMP-ONLY change (package.json + lockfile + CHANGELOG line, no code) is PUSHED DIRECTLY TO develop — no PR, no branch, per one-shot `dep-pr-draft-vs-bump` ("a task comment on the subtask suffices and NO PR is needed"); opening a PR for it is wasted CI and review. Cherry-pick it to staging as well when the dep fix is wanted in the current staging release. A dep-repo change carrying real GUI code beyond the bump is a normal PR. The 2026-07-24 NYM max-amount land deferred all of this as "not part of this land" and Completed at merge — that deferral is exactly what this sentence forbids. Skip the chain ONLY when the operator's task explicitly scopes the land as merge-only.</rule>
<rule id="npm-publish-auth">`npm publish` requires the user's npm 2FA — never skip it. The DEFAULT path is web/link auth via `npm-publish-web.sh` (step 6): it preflights `npm whoami`, runs `npm login --auth-type=web` FIRST when needed (login and publish are separate auth events), then publishes; both phases run under a PTY it owns and it emits `AUTH_URL <phase> <url>` lines, one fresh link per attempt. Run it in the background writing to a log file, then wait on that log in the FOREGROUND with `npm-auth-wait.sh <log>...` (Bash `timeout: 150000`) and re-run the wait after every relay until it exits 3. It returns within 3 s of each new `AUTH_URL`/`AUTH_DONE`/`LOGGED_IN`/`PUBLISHED`/`FAILED` line, and its `RELAY` lines carry the newest untapped link of every log still waiting: relay exactly those urls, never one quoted from an earlier message or from memory. Wait no other way: a Monitor's events queue behind the running foreground tool, a hand-written poll returns on its own clock, and a background watch leaves the turn with nothing holding it, so each relays a link after it dies (the script header has the detail). An operator asking for a new link gets the newest `RELAY` url when it was minted under 3 minutes ago; otherwise kill that `npm-publish-web.sh` by its PID, start it again to the same log, and wait as above. RELAY MEANS BOTH, EVERY TIME: (a) the bare url in chat text as a clickable link (not inside backticks, which are not linkified; not only in a tool result) AND (b) a PushNotification carrying the url. `require-npm-link-relay.sh` blocks the next wait until the last link it returned is in both (chat text alone outside orch runs). A fresh url supersedes the old one: relay it the same way; never say "use the link above". THE TAP IS AN EVENT TOO: `AUTH_DONE login <user>` (login link tapped) and `AUTH_DONE publish <pkg>@<version>` (publish link tapped and npm accepted the upload) each get the same two-channel relay the moment they print ("login done, publish link next"; "publish accepted, waiting for the registry to serve it"), because an operator who tapped and hears nothing is left waiting on the agent. The publish link can trail the login by many minutes: the script runs the repo's `prepack` first, and for a native package (react-native-monero's `prepack` is its full native build) that is tens of minutes, so the relay names the wait instead of going quiet. The operator reporting a 404 or "already approved" means: re-read the log for the newest `AUTH_URL`, `AUTH_DONE publish`, and `PUBLISHED` lines before saying anything. A fresh link with no `AUTH_DONE publish` before it means that approval never reached npm (the link expired first). The `PUBLISHED` line (or `npm view <pkg>@<version>`) is the publish confirmation, not the operator's tap — ask no separate y/N. The script stops, with npm's own output on stderr and the capture dir kept, when npm exits on its own after auth: read that output; do not restart the script to get another link. In orchestrated runs deliver the link via push notification, never Slack (self-sent Slack messages do not notify). Publishes in the same run may reuse the auth session (no second link); the script handles that. TOTP (`--otp=<code>`) is the FALLBACK, only when the user explicitly offers a 6-digit code: retry a stale OTP at most 2 times, then STOP.</rule>
</rules>

<scripts description="This phase's companion scripts and their exit codes. Any exit code not listed here or in the core table = STOP and report (`unexpected-exit`).">

| Script | Purpose |
|--------|---------|
| `pr-land-publish.sh` | Version bump, changelog update, commit + tag (no push) |
| `npm-publish-web.sh` | Login-if-needed + publish via npm web/link auth under a PTY; emits `AUTH_URL` and `AUTH_DONE` lines to relay. `--login-only` stops after the login phase and prints `LOGGED_IN <user>` |
| `npm-auth-wait.sh` | Foreground wait on `npm-publish-web.sh` logs: returns at each new relay line with the newest live link per waiting log |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `pr-land-publish.sh` | Ready (needs push) | Verify fail | No unreleased | - | - |
| `npm-publish-web.sh` | Published | npm exited without publishing | Auth never completed | Terminal registry rejection | Tarball shrank |
| `npm-auth-wait.sh` | New lines (relay, re-run) | Usage | - | Every log finished | Cap passed, nothing new (re-run) |

(`npm-publish-web.sh` exit 5 = `accepted-not-served`: npm accepted the publish, the registry has not served it yet. Re-run to re-check; never re-publish. See `npm-publish-auth`.)
</scripts>

<step id="6" name="Publish">
**Gating:** Only non-GUI repos. Only when ALL approved PRs for the repo are merged. Skip if any were skipped/held back.

**GUI-dep check (owns it — steps 7 and 10 reference):** the GUI's package.json is the source of truth for which repos are GUI dependencies — never assume every non-GUI repo publishes. Resolve per repo:

```bash
pkg=$(jq -r .name <repoDir>/package.json)
jq -e --arg p "$pkg" '.dependencies[$p] // empty' ~/git/edge-react-gui/package.json
```

Exit 0 → GUI dep: publish here, upgrade in step 7. Non-zero (not a dependency — e.g. a deployed server, typically also `"private": true`) → SKIP publish and step 7 for this repo entirely; its land is complete at merge (step 10 counts it fully landed then).

**Ordering rationale (owns it — other steps reference, don't restate):** git is retryable, npm is not. A pushed version commit that npm lacks is benign — `npm publish` completes it any time later, no history rewrite. A published npm version whose commit was never pushed is the unrecoverable direction (same-version republish is forbidden even after unpublish). So push BEFORE publish, and gate only the publish on the user's auth link. No y/N confirmations anywhere in this step: the land-and-publish request implies the push, and completing the AUTH_URL link is the publish confirmation (per `npm-publish-auth`).

**Batch shape (owns it):** the operator approves one npm link per publish, so every publish link of the run arrives in ONE window instead of trickling out as each repo finishes merging. Never publish a repo while another non-GUI PR in the batch is still on its way to merging.

0. **Checkpoint.** Re-run the `land-hold` acquire loop. Then wait until every non-GUI PR in the batch has merged (step 5 ALL_MERGED) or is reported as skipped/blocked. The publish set = repos that pass `publish-gating` AND the GUI-dep check above.

1. **Bump + commit + tag, then push, for EVERY repo in the publish set first** (sequentially, one repo at a time):

   ```bash
   echo '[{"repo":"...","branch":"master"}]' | ~/.cursor/skills/pr-land/scripts/pr-land-publish.sh
   cd <repoDir> && git push origin master && git push origin v<version>
   ```

   `pr-land-publish.sh` exit codes: `0` = bumped/committed/tagged (push it), `1` = verification failed (report; that repo leaves the publish set), `2` = no unreleased changes. **Idempotent resume on exit 2:** if the version at HEAD is already bumped but missing from npm (a prior run's publish was abandoned), skip the bump and keep the repo in the publish set; `npm-publish-web.sh` detects an already-published version and exits 0.

2. **Log in once.** Start the login in the background, then wait in the foreground per `npm-publish-auth`, re-running the wait after each relay until it exits 3:

   ```bash
   ~/.cursor/skills/pr-land/scripts/npm-publish-web.sh --login-only <any repoDir in the publish set> > /tmp/npm-login.log 2>&1
   ~/.cursor/skills/pr-land/scripts/npm-auth-wait.sh /tmp/npm-login.log
   ```

   It prints `LOGGED_IN <user>` and exits 0 (immediately when already logged in). Any other exit: handle as the publish exit codes below.

3. **Publish every repo at once.** Start one background publish per repo in the SAME message (parallel tool calls), each to its own log:

   ```bash
   ~/.cursor/skills/pr-land/scripts/npm-publish-web.sh <repoDir> > /tmp/npm-publish-<repo>.log 2>&1
   ```

   Then ONE foreground wait over all the logs, re-run after each relay until it exits 3 (every log has `PUBLISHED` or `FAILED`):

   ```bash
   ~/.cursor/skills/pr-land/scripts/npm-auth-wait.sh /tmp/npm-publish-<repo>.log [/tmp/npm-publish-<repo>.log ...]
   ```

   Relay every `RELAY` url together in one message plus one push notification, per `npm-publish-auth`; each publish has its own link.

   Per-repo exit codes of `npm-publish-web.sh`: `0` = published, `1` = npm exited on its own without publishing, including after a completed auth (STOP for that repo; npm's own output is on stderr and the per-attempt captures are kept in the printed work dir; git stays as-is and the version is resumable), `2` = auth never completed (report; resume later via the idempotent path above), `3` = terminal registry rejection (permission, payment), `4` = the packed tarball shrank vs the previous release, `5` = npm accepted the publish but the registry has not served the version yet. Only an expired or unused link consumes an attempt, and the next link follows at once. After npm accepts the upload the script waits up to `--settle` (default 1800 s) for the registry to serve it, so `PUBLISHED` means installable. **Exit 5 is never a re-publish.** npm accepted the upload (`AUTH_DONE publish` printed), so the version is taken for good and the registry is only lagging: re-run the same script to re-check (it exits 0 once the version is served), and never bump to a new version to get around it.

Once every repo in the publish set is published, proceed to step 7 automatically; the exit codes are the confirmation. A repo that did not publish stays out of step 7 and is reported.
</step>

<step id="7" name="Update GUI Dependencies">
**Trigger:** Only for repos that passed step 6's GUI-dep check AND published successfully (exit 0 per repo). Publishing a GUI dep always requires the matching GUI upgrade. Flows directly from step 6 — no additional user confirmation.

<sub-step name="Sync develop once (before any upgrade)">
`upgrade-dep.sh` assumes it is run on a clean `develop` synced to origin and does NOT manage the branch itself (running it N times would otherwise reset develop N times and wipe prior-package commits). Do this ONCE before the upgrade loop:

```bash
cd <gui-repo-dir>
# Stash any uncommitted working changes so the reset is safe
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  git stash -u
fi
git checkout develop
git fetch origin develop
git reset --hard origin/develop
```

Stashes remain stashed — the user can restore them after the run.
</sub-step>

<sub-step name="Upgrade each published package">
1. Run `upgrade-dep.sh` for each published package, sequentially, on the now-clean `develop`:
   ```bash
   cd <gui-repo-dir> && ~/.cursor/skills/pr-land/scripts/upgrade-dep.sh <package-name>
   ```
   Each invocation bumps the version in package.json, runs install + prepare + prepare.ios via the repo's package manager (npm or yarn, auto-detected), and commits package.json + lockfile. NO CHANGELOG entry: dep bumps are not user-visible release notes (when an upgrade IS the user-facing change, a human writes that entry deliberately). Dep-upgrade commits therefore route to staging in step 9 on the Build field signal alone. On success it prints `UPGRADE_READY ... sha=<commit_sha>`. If any run fails, STOP and report. Ask user how to proceed.

2. After all dependency upgrades succeed, show the created `develop` commit SHA(s) to the user and ask for confirmation to land them:
   ```bash
   ~/.cursor/skills/git-branch-ops.sh push --branch develop
   ```
   This push is required before the workflow can treat GUI dependency updates as landed. Do NOT proceed to staging cherry-pick or Asana updates until the `develop` push is confirmed complete.
</step>
