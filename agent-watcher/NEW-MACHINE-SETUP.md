# New-machine setup — dedicated orchestration Mac

One-time runbook to stand up the Asana agent-orchestration on a fresh Mac, under a
**different macOS user** than the source machine (`jontz`). The orchestration is
`$HOME`-relative, so the only user-specific things to fix are the launchd plists
(absolute paths) — Claude handles that.

**Design goal: your part is minimal.** Claude does the transfer, installs, repo clones,
sims, plist rewrite, and validation. You only do the things a script can't: install
Claude, one toggle on the source Mac, paste secrets, paste two sudo blocks, the App
Store / Apple-ID gate, and `gh auth login`.

## Assumptions
- New Mac is **dedicated** to the orchestration and logged in as the target user
  (iOS sims + LaunchAgents need that user to be the active GUI session).
- Same GitHub user (`j0ntz`) and same secrets as the source for now.

---

## YOUR STEPS (the entire manual part)

**1. Install + log into Claude** (the one thing you named):
```bash
curl -fsSL https://claude.ai/install.sh | bash
```

**2. Transfer the bundle** (no SSH / Remote Login needed). On the source mac the migration
bundle is at `~/Downloads/orchestration-migration.tgz` (configs, secrets, skills, plists —
5 MB). **AirDrop** it to the new mac's Downloads, then on the new mac:
```bash
tar xzf ~/Downloads/orchestration-migration.tgz -C ~ && ~/APPLY.sh && rm ~/APPLY.sh
```
That places `~/.config/agent-watcher` (incl. credentials + this runbook), `~/.cursor/{skills,rules}`,
`~/.claude/{CLAUDE.md,settings.json,memory-shared}`, `env.json`, and the 6 plists, and
regenerates the `~/.claude/skills` symlinks for your user. (Delete the .tgz after — it has secrets.)

**3. Shell env + secrets — nothing to paste.** Your full `.zprofile` + `.zshrc` + `.zshenv`
(all aliases, PATH, and every secret: `ASANA_TOKEN`/`GITHUB_TOKEN`/`NPM_TOKEN`/`YOLO_*`/etc.)
came in the bundle, and `APPLY.sh` already placed them and rewrote `/Users/jontz`→`/Users/eddy`.
Just open a new terminal (or `source ~/.zprofile`).

**4. Paste sudo block A — Homebrew** (prompts once for your password, then RETURN):
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**5. Ensure Xcode is current** — the master sim runs iOS 18, which needs **Xcode 16+**.
Run `xcodebuild -version`; if it's older, upgrade via the App Store (Apple ID + 2FA — the
one unavoidable GUI gate). Already 16+? Skip the upgrade. Either way, paste sudo block B —
Xcode setup (copy-paste exactly as-is):
```bash
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

**6. Log into GitHub CLI** (account `j0ntz`, follow the device-code prompts):
```bash
gh auth login
```

**7. Launch Claude and paste the PART C prompt.** That's it — Claude does the rest
(repos, sims, plist rewrite, validation), pausing only if a gate needs you.
```bash
claude --dangerously-skip-permissions
```

Everything below this line is for Claude, not you.

---

## PART C — the setup prompt (paste into Claude on the new Mac)

> You are bootstrapping a dedicated Asana agent-orchestration on this fresh Mac, logged
> in as the user (`eddy`) it will run under. Homebrew and Xcode are already installed; the
> bundle has been extracted and `APPLY.sh` has run — so config trees, the full shell env +
> all secrets (`~/.zprofile`+`~/.zshrc`, already path-fixed `/Users/jontz`→`$HOME`), the
> plists (also path-fixed), and the skill symlinks are all in place. `gh` is authed as
> `j0ntz`. Do the following, reporting each step. Pause only if you hit a credential/Apple-ID gate.
>
> 1. **Verify the transferred config** (already placed by the bundle + APPLY.sh — no SSH):
>    confirm `~/.config/agent-watcher/credentials.json` (mode 600), `~/git/edge-react-gui/env.json`
>    (147 keys, incl. `BREEZ_API_KEY`), `~/.cursor/skills` + `~/.cursor/rules`, the 6
>    `~/Library/LaunchAgents/com.jontz.*.plist`, and that `~/.claude/skills/one-shot/SKILL.md`
>    resolves (its symlink should now point into THIS user's `~/.cursor`, not `/Users/jontz`).
> 2. **Toolchain** (no sudo — Homebrew exists): `brew install jq gh tmux watchman cocoapods`.
>    Install nvm and `nvm install v24.15.0` (pin it — keeps the launchd node path identical
>    except for the username). Install maestro (`curl -Ls https://get.maestro.mobile.dev | bash`).
>    Install oh-my-zsh WITHOUT clobbering the placed `.zshrc` (which sources it):
>    `RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"`
>    Set `git config --global user.name "Jonathan Tzeng"` and `user.email jnthntzng@gmail.com`.
>    Verify `jq gh tmux watchman`, `node -v` (== v24.15.0), `maestro -v`.
> 3. **iOS sims.** Install the iOS 18 runtime (`xcodebuild -downloadPlatform iOS`; if it
>    needs Apple ID, tell me). Create the master sim matching
>    `~/.config/agent-watcher/asana-config.json` → `.watcher.master_sim` (iPhone 16 Pro Max,
>    iOS 18). Boot it once to confirm.
> 4. **Repos.** Clone every EdgeApp repo into `~/git` via `gh repo clone EdgeApp/<name>`
>    (uses the gh auth, HTTPS, no SSH key needed):
>    ```bash
>    for r in edge-automations edge-change-server edge-conventions edge-core-js \
>      edge-currency-accountbased edge-currency-bitcoin edge-currency-monero \
>      edge-currency-plugins edge-dev-agents edge-exchange-plugins edge-info-server \
>      edge-login-server edge-login-ui-rn edge-monitor-server edge-plugin-bity \
>      edge-rates-server edge-referral-server edge-reports-server edge-swap-server \
>      edge-zignal fee-metrics react-native-piratechain react-native-zano react-native-zcash; do
>      [ -d "$HOME/git/$r" ] || gh repo clone "EdgeApp/$r" "$HOME/git/$r"
>    done
>    ```
>    Clone `edge-react-gui` too, preserving the `env.json` the bundle already placed
>    (clone needs an empty dir, so move it aside and back):
>    ```bash
>    mv ~/git/edge-react-gui/env.json /tmp/env.json.keep 2>/dev/null || true
>    rm -rf ~/git/edge-react-gui
>    gh repo clone EdgeApp/edge-react-gui ~/git/edge-react-gui
>    mv /tmp/env.json.keep ~/git/edge-react-gui/env.json 2>/dev/null || true
>    ```
>    Check out the test branch the Asana project uses (ask me if unsure), confirm `env.json`
>    is the real 147-key file, then `npm install` so a populated `node_modules` exists for
>    the per-worktree APFS clone. All repos are gh-cloned, so remotes are already HTTPS
>    (required — the launchd agents have no ssh-agent). If any local-only test repo isn't on
>    GitHub, tell me and I'll have you pull it from the bundle/source separately.
> 5. **launchd plists** — `APPLY.sh` already rewrote `/Users/jontz`→`$HOME` in the plists and
>    in `~/.claude/settings.json`, so just VERIFY each `~/Library/LaunchAgents/com.jontz.*.plist`:
>    the node path is `$HOME/.nvm/versions/node/v24.15.0/bin/node` and resolves (you pinned
>    that version in step 2); `PATH` includes `$(brew --prefix)/bin` (Apple Silicon =
>    `/opt/homebrew`; if this is an Intel mac, fix to `/usr/local`). `plutil -lint` each. For a
>    dedicated box bootstrap `asana-watcher`, `session-watchdog`, `runaway-guard`;
>    `mem-trace`/`memory-monitor`/`config-watch` are optional — skip unless I ask.
> 6. **Fresh machine state.** `rm -f ~/.config/agent-watcher/{pool.json,pool.lock,watchdog-state.json}`
>    and `rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/slots.json"`. Then
>    `~/.config/agent-watcher/ensure-sim-pool.sh --size 2` to build a fresh pool.
> 7. **Load + validate.** `launchctl bootstrap gui/$(id -u) <plist>` for the chosen agents.
>    Confirm `launchctl list | grep com.jontz`, run one `asana-watcher.js` tick and confirm it
>    reaches "guardrail ok" + fetches tasks, and `resume-agent.sh --list` runs clean. Do NOT
>    spawn a real task yet. End with a report: installed tools, pool sim UDID(s), loaded
>    agents, and anything needing me.

---

## PART D — first real test (run this ON the new mac, after Claude reports green)
The source Mac's watcher is off, so the new mac is the only watcher — no double-pick.
**On the new mac**, drop a Pending task in the Asana test kanban, then watch (these are
the new mac's logs/sessions):
```bash
tail -f /tmp/asana-watcher.out      # tick decisions
tail -f /tmp/asana-watcher.err      # provisioning (worktree/sim/env.json)
tmux ls                             # the spawned agent session
```

## PART E — later: signed commits + per-machine traceability
Same GitHub identity on both machines = commits aren't attributable by author. The
**signed-commits requirement solves this for free** if you do it per-machine:

1. On this box, generate a dedicated **passphraseless** SSH signing key (passphraseless so
   the launchd agents can sign non-interactively):
   `ssh-keygen -t ed25519 -C "orchestrator-<machine>" -N "" -f ~/.ssh/commit-signing`
2. Add `~/.ssh/commit-signing.pub` to GitHub (`j0ntz`) as a **Signing key** (not an Auth key).
3. `git config --global gpg.format ssh`, `git config --global user.signingkey ~/.ssh/commit-signing.pub`,
   `git config --global commit.gpgsign true`.

Commits are then distinguishable by which machine's signing key signed them — so this
*is* the per-machine attribution, and you likely don't need a separate GitHub account.
Until signed commits are required, attribution is implicit (source watcher is off, so
anything new came from this machine). Note: auth/push stays on HTTPS + the gh token; the
signing key is only for signatures.

## Claude Code hooks (manual step — settings.json is not synced)

Agent sessions are gated by two PreToolUse hooks in `~/.claude/settings.json`
(scripts live in this repo's `agent-watcher/hooks/`, installed to
`~/.config/agent-watcher/hooks/` by bootstrap). Both no-op unless
`AGENT_TASK_GID` is set, so interactive sessions are unaffected. Add to the
`hooks.PreToolUse` block (matcher `Bash`):

    { "type": "command", "command": "~/.config/agent-watcher/hooks/block-raw-git-commit.sh", "timeout": 10 },
    { "type": "command", "command": "~/.config/agent-watcher/hooks/require-test-evidence-before-pr.sh", "timeout": 10 }

block-raw-git-commit: commits must go through lint-commit.sh (--amend allowed, --no-verify never).
require-test-evidence-before-pr: pr-create.sh is blocked until a proof screenshot
(/tmp/agent-proof-<gid>-*.png) or a justified blocker note (/tmp/agent-test-blocker-<gid>.md) exists.
    { "type": "command", "command": "~/.config/agent-watcher/hooks/block-simctl-booted.sh", "timeout": 10 },

block-simctl-booted: in slot sessions (AGENT_SIM_UDID set), `simctl ... booted` is
blocked — concurrent runs boot multiple sims and `booted` resolves arbitrarily.
    { "type": "command", "command": "~/.config/agent-watcher/hooks/require-plan-before-developing.sh", "timeout": 10 },
    { "type": "command", "command": "~/.config/agent-watcher/hooks/block-raw-thread-resolve.sh", "timeout": 10 },

require-plan-before-developing: the Planning-to-Developing status transition is blocked
until /tmp/plan-<gid>-*.md exists (asana-plan then attaches it to the task).
block-raw-thread-resolve: raw resolveReviewThread graphql is blocked; threads resolve
through pr-address/bugbot companion scripts, which reply in-thread first.
    { "type": "command", "command": "~/.config/agent-watcher/hooks/require-maestro-device.sh", "timeout": 10 },

require-maestro-device: maestro test/record without --device is blocked in slot
sessions (multiple booted sims make the default driver attachment ambiguous).
