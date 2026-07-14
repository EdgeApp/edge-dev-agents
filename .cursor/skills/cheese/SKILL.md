---
name: cheese
description: Push a "cheese build" — hard-reset a test-* branch to the current edge-react-gui feature branch and force-push to trigger a Jenkins test build. Optionally pins unreleased dep repos (accb, exch, core, etc.) as prebuilt tarballs when the GUI work depends on unmerged dep changes. Use when the user asks for a "cheese build", "test build", or names a branch like test-feta / test-<name>.
compatibility: Requires jq, yarn. Must be run from within an edge-react-gui checkout.
metadata:
  author: j0ntz
---

<goal>Produce a cheese build by hard-resetting a test-* branch to a source ref and force-pushing it, optionally pinning unreleased dep repos as prebuilt tarballs so the build server can install without running each dep's prepare script.</goal>

<rules description="Non-negotiable constraints.">
<rule id="cheese-branch-only">Target branch MUST match `test-*`. For any other branch name, stop and ask the user to confirm it is scratch space safe to force-push.</rule>
<rule id="pointer-not-workspace">A `test-*` branch is a build-trigger POINTER, never a workspace: all development happens on the working/feature branch and every change is pushed THERE. The cheese operation is exclusively a hard-reset of `test-*` to an already-pushed source ref + force-push (CI auto-builds on `test-*` pushes). Never commit on, develop on, or open a PR from a `test-*` branch, and never land/merge one — the feature branch is what lands (see pr-land `build-field-routing`).</rule>
<rule id="clean-working-tree">Require a clean working tree in edge-react-gui (no staged, unstaged, or untracked files) before starting. Do NOT auto-stash — tell the user to commit or stash first.</rule>
<rule id="tarball-not-git-url">When pinning an unreleased dep, use a prebuilt tarball (`npm pack` or `yarn pack`, auto-detected from the dep repo's lockfile), never a git URL. Git URLs make the build server run the dep's `prepare` script, which fails on native toolchain deps (bs-platform needs python; ed25519 fails to build against current Node v8 ABI).</rule>
<rule id="use-companion-script">Run the full workflow via `~/.cursor/skills/cheese/scripts/cheese-build.sh`. Do not inline git / pack / package-manager operations in chat.</rule>
<rule id="orch-pins-required">ORCHESTRATED runs (an agent session with `$AGENT_TASK_GID`, invoked via one-shot `cheese-build-on-green`): the pin set is NOT optional or user-suggested — it is DEFINED by the task: pin EVERY unpublished dep repo whose changes the gui deliverable requires (the task's own dep-repo PRs, per one-shot `dep-pr-draft-vs-bump`), each `--pin` pointing at that dep's task worktree checked out at ITS PR head. A pointer-only cheese while required dep PRs are unpublished produces a build that cannot demonstrate the change (Jenkins resolves published deps from npm — the Houdini stealth-swap feta miss, 2026-07-14). Record each pinned repo+sha in the run report. YOLO CARVE-OUTS to this skill's interactive confirmations (no human is watching an orch run): pinning 3+ deps → proceed without confirming (the task defines the set); a pin target sitting on its default branch → SKIP that pin (published version suffices) and note it in the report instead of asking; ambiguous pin resolution → the task subtask/PR set IS the resolution, never a question. Human-invoked runs keep the confirmations.</rule>
<rule id="force-with-lease">The script pushes with `--force-with-lease` via `~/.cursor/skills/git-branch-ops.sh`. Never use plain `--force`.</rule>
</rules>

<dep-aliases description="Short names for common Edge dep repos. Resolve to $HOME/git/<repo-name>. Aliases are case-insensitive. Explicit absolute paths are also accepted by --pin.">

| Alias | Repo |
|---|---|
| accb | edge-currency-accountbased |
| exch | edge-exchange-plugins |
| core | edge-core-js |
| monero | edge-currency-monero |
| plugins | edge-currency-plugins |
| login-ui | edge-login-ui-rn |
| info | edge-info-server |

</dep-aliases>

<step id="1" name="Parse inputs">
From the user message, determine:

1. **Cheese branch** — default `test-feta`. Use the user's explicit name if given (e.g. `test-gouda`).
2. **Source ref** — default: current HEAD of `edge-react-gui`. Use an explicit ref if the user names one.
3. **Deps to pin** — from any aliases or paths the user mentions. None is valid (GUI-only cheese build).

Resolve each alias to `$HOME/git/<repo>`. If an alias doesn't map, ask the user for the absolute path.
</step>

<step id="2" name="Confirm plan">
Show the user a one-block summary:

```
Cheese branch: test-<name>
From:          <source-ref> (<short-sha>)
Deps to pin:   (none) | <name1>, <name2>, ...
```

Proceed directly unless any of:
- Cheese branch doesn't match `test-*` → confirm
- Pinning ≥ 3 deps → confirm
- User input was ambiguous → ask

Otherwise go straight to step 3.
</step>

<step id="3" name="Run script">
Invoke with resolved absolute paths:

```bash
~/.cursor/skills/cheese/scripts/cheese-build.sh \
  --branch <cheese-branch> \
  --from <source-ref> \
  [--pin <absolute-path-to-dep-repo>]...
```

The script handles: clean-tree check, checkout + hard reset, per-dep `install + prepare + pack` via `~/.cursor/skills/pm.sh` (auto-detects npm vs yarn from each repo's lockfile), tarball copy + `package.json` rewrite, GUI `install` to refresh the active lockfile, `lint-commit.sh` for the pin commit, and `git-branch-ops.sh push --force-with-lease`.
</step>

<step id="4" name="Report">
Print the remote branch URL and final SHA from the script output. Jenkins picks up the push automatically — no further action needed.
</step>

<edge-cases>
<case name="Currently on cheese branch">Ask the user which feature branch to reset against; cheese branches can't self-reset.</case>
<case name="Dep repo on master/develop">If a pin target is on its default branch, the published version is enough. Warn; proceed only if the user confirms.</case>
<case name="Tarball missing lib/">The script verifies each tarball contains `package/lib/` before committing. If missing, the script aborts — run `~/.cursor/skills/pm.sh run prepare` manually in the dep repo and retry.</case>
<case name="Dirty working tree">Script exits with code 2 and tells the user to commit or stash first. Never auto-stash — their WIP is their responsibility.</case>
<case name="Dep name not in gui's dependencies">Script exits if the dep's npm name isn't in `edge-react-gui/package.json` under `dependencies`. Common cause: dep renamed or devDependency — resolve manually.</case>
</edge-cases>
