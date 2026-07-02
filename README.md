# edge-dev-agents

Complete agent-assisted development workflow for Edge repositories:
slash skills, companion scripts, coding standards, review standards,
and meta-tooling for maintaining the workflow itself.

The distributable Cursor content lives under `.cursor/`. This repo is the
versioned home for those skills, rules, scripts, and docs.

The canonical local doc lives at `~/.cursor/README.md`. During
`/convention-sync`, that file is mirrored to `edge-dev-agents/README.md`, and
the repo copy should not keep a second `.cursor/README.md`.

## Installation

**Fresh machine (one command):** clone this repo and run the bootstrap — it
installs everything (cursor skills/rules, the orchestration system, and shared
memories) into your home dir, seeds `credentials.json` from the example, and
links skills + shared memory:

```bash
git clone <this-repo> ~/git/edge-dev-agents && cd ~/git/edge-dev-agents && ./bootstrap.sh
# then edit ~/.config/agent-watcher/credentials.json with your real asana_token
```

For incremental onboarding instead of the full bootstrap:

**1. Set the required env var** in your `~/.zshrc`:

```bash
export GIT_BRANCH_PREFIX=yourname   # e.g. jon, paul, sam
```

This drives branch naming and PR discovery across the workflow.

**2. Sync the repo copy into `~/.cursor/`:**

This repo treats `~/.cursor/` as the canonical working copy. Use
`/convention-sync` to move local changes into `edge-dev-agents`, or run the
companion script directly when onboarding:

```bash
~/.cursor/skills/convention-sync/scripts/convention-sync.sh \
  --repo-to-user --stage
```

**3. Verify prerequisites:**

- `gh` CLI: `gh auth login`
- `jq`: `brew install jq`
- `ASANA_TOKEN` env var for Asana-backed workflows

## Table of Contents

- [Architecture](#architecture)
- [Orchestration & Memory](#orchestration--memory)
- [Skills](#skills-slash-skills)
- [Companion Scripts](#companion-scripts)
- [Shared Modules](#shared-modules)
- [Rules](#rules-mdc-files)
- [Design Principles](#design-principles)

## Orchestration & Memory

The orchestration system runs Asana tasks to PRs autonomously: a watcher picks up
`Pending` tasks, spawns one isolated agent session per task, and a watchdog tends
the live sessions. Post-hoc evals grade what each run did.

### How a run flows

1. **Watcher** (`agent-watcher/asana-watcher.js`, launchd every 120s): polls the
   project for `agent_status = Pending`. It skips the tick when a resource
   guardrail trips (1-minute load over `max_load_avg`, or free RAM under
   `min_free_ram_gb`) or the concurrency cap (`max_concurrent`, default 4) is full.
   For each pickable task it refreshes the iOS-sim pool and allocates a slot (a git
   worktree, a cloned simulator, a Metro port). Before recloning the pool it runs
   `refresh-master-build.sh`: if `develop` has advanced and its native side
   (`ios/Podfile.lock`) changed, it rebuilds the master sim from `develop` and
   reclones so runs test against a current build instead of a pinned-stale one. A
   JS-only `develop` advance skips the rebuild (clones bundle JS live from Metro);
   the check is a cheap `git fetch` plus a SHA compare, and a build failure is
   non-fatal (provisioning continues on the last-good master). A NEVER-run task is spawned fresh:
   `agent_status = Planning`, a tmux session `claude-asana-(gid)` running
   `/one-shot --yolo (task-url)`. A task with a PRIOR transcript (a revisit) is
   RESUMED instead (its conversation restored on the fresh slot, via `resume-task`).
   So re-engaging a finished task is one signal: set it back to `Pending` and it
   continues with memory plus working resources, never a fresh session. This is the
   single re-engagement entry point. Both the fresh-spawn and the resume path route
   through `spawn-test-session.sh`, which pins the session's model and reasoning
   effort from the task's `agent_model` / `agent_effort` Asana fields: the selected
   `agent_model` option maps to a CLI model string (all 1M-context: Fable 5, Opus
   4.8, Opus 4.7, Sonnet 5, Sonnet 4.6), the `agent_effort` option is the CLI level directly
   (low/medium/high/xhigh/max). Unset falls back to the config defaults
   (`.watcher.agent_model` = Opus 4.8 1M, `.watcher.agent_effort` = high), so new
   tasks and follow-ups honor the same per-task overrides.
2. **The run** (`/one-shot --yolo`, a single agent turn): seven phases, status
   advanced via `update-status.sh` at each boundary. Planning (`/asana-plan`),
   Developing (`/im`), local verify (`/build-and-test`), Reviewing (`/pr-create`),
   Testing (CI watch + reviewer bots), Complete. The agent runs hands-off: no
   interactive prompts, no self-respawn, every wait a bounded blocking in-turn call.
3. **Finalize gate**: `Complete` is set only when every primary PR is CI-green,
   every reviewer bot is clean on HEAD, and there are zero unresolved bot review
   threads (bots matched by GraphQL `__typename == "Bot"`, so Cursor's `cursor` and
   `cursor[bot]` logins both count).
4. **Watchdog** (`agent-watcher/session-watchdog.js`, launchd every 120s): tends
   live sessions. RC-bridge revive (only when the bridge is dead), completion sweep
   (`Complete` retires `claude-asana-(gid)` to `done-asana-(gid)`, frees
   sim/Metro/slot, keeps claude alive for re-engagement), blocked sweep (sheds
   sim/Metro while a human is needed), GC (keep newest `keep_completed_sessions` /
   `keep_completed_worktrees`), orphan-Metro reap, idle-dirty-sim reclaim, and
   operator escalation for parked prompts or stuck sessions. It does NOT re-engage
   finished tasks: that is the watcher's job (Pending → resume), so the watchdog and
   watcher are decoupled.
5. **Eval** (post-hoc): `/resolve-run` builds an evidence manifest per run;
   `/agent-eval` grades process compliance and outcome honesty (A-dimensions),
   `/orch-eval` grades infrastructure health (O-dimensions), and `/eval-run`
   orchestrates a cohort.

```mermaid
flowchart TD
  A["Asana project (Pending tasks)"] -->|"watcher tick 120s"| B{"guardrail and cap OK?"}
  B -- no --> A
  B -- yes --> C["allocate slot: worktree + cloned sim + Metro port"]
  C --> D["spawn tmux claude-asana-GID (claude --rc --yolo /one-shot)"]
  D --> E["/one-shot 7 phases: Planning, Developing, Reviewing, Testing"]
  E --> F{"finalize-gate: CI green + bots clean + 0 unresolved threads"}
  F -- "not green" --> E
  F -- green --> G["agent_status = Complete"]
  G -->|"watchdog completion sweep"| H["retire to done-asana-GID; free sim, Metro, slot; claude kept alive"]
  H -->|"operator sets Pending (revisit resumes with memory)"| A
  H -->|"beyond keep_completed_sessions"| I["reaped"]
```

The hands-off contract is enforced by deterministic PreToolUse and Stop hooks
(active only when `AGENT_TASK_GID` is set), not merely documented:

```mermaid
flowchart LR
  AG["orchestrated agent (/one-shot --yolo)"]
  AG -->|"AskUserQuestion"| H1["no-interactive-prompt.sh: DENY, pick a default"]
  AG -->|"ScheduleWakeup, CronCreate, claude --resume, /loop"| H2["no-self-respawn.sh: DENY, wait in-turn"]
  AG -->|"blocked=Yes, or Complete on a wall"| H3["require-concession-validation.sh: needs validator verdict"]
  AG -->|"turn ends, not Complete or blocked"| H4["require-continuation-or-block.sh (Stop): force continue, stuck flag at K"]
  AG -->|"pr-create, Complete"| H5["require-test-evidence + finalize-gate: CI, bots, proof"]
```

### Distribution (what syncs)

Beyond cursor skills/rules, this repo mirrors two more portable trees so a
second Mac is reproducible from a single clone + `./bootstrap.sh`:

- **`agent-watcher/`** — the autonomous agent orchestration system (Asana
  watcher daemon + worktree/iOS-sim pool helpers + watchdog). Canonical home is
  `~/.config/agent-watcher` (XDG config; `~/.agents` is not an established
  standard). Committed: scripts, `*.js`, `asana-config.json`, `README.md`,
  `oom-repro/HANDOFF.md`+`scripts/`, and `credentials.example.json`. **Never
  committed:** `credentials.json` (secret) and machine-local state
  (`pool.json`, `slots.json`, `watchdog-state.json`, `*.state`, `*.log`,
  `oom-repro/forensics`, `oom-repro/logs`).
- **`memory-shared/`** + **`bin/link-shared-memory.sh`** — cross-cutting Claude
  memory notes that should surface regardless of working directory. Canonical
  home `~/.claude/memory-shared`; `link-shared-memory.sh` symlinks them into the
  per-project auto-memory dirs (`~/.claude/projects/<project>/memory/`) and
  maintains a managed block in each `MEMORY.md`. Claude auto-memory itself is
  machine-local (per Anthropic docs) and is intentionally NOT synced — only the
  shared store is. The only officially global Claude file is `~/.claude/CLAUDE.md`
  (generated here from always-apply rules).

`/convention-sync` keeps all of the above in sync (home → repo); `bootstrap.sh`
does the reverse (repo → home) on a new machine.

## Architecture

```text
edge-dev-agents/
├── README.md          # Synced copy of ~/.cursor/README.md
└── .cursor/
    ├── skills/        # Slash skills (*/SKILL.md) + companion scripts
    ├── scripts/       # Shared portability and dashboard scripts
    ├── commands/      # Minimal command wrappers
    └── rules/         # Coding and workflow standards (.mdc)
```

**Separation of concerns:**

- **Skills** (`SKILL.md`) define workflows, rules, and step ordering.
- **Companion scripts** (`.sh`, `.js`) handle deterministic work like git,
  GitHub, Asana, and JSON processing.
- **Rules** (`.mdc`) provide persistent guidance that gets loaded by context.
- **Repo docs** describe the system and how the distribution copy fits
  together.

All GitHub API work uses `gh` CLI. Deterministic git operations should live in
scripts, not be re-described independently across skills.

## Skills (Slash Skills)

### Core Implementation

| Skill | Description |
|------|-------------|
| [`/im`](.cursor/skills/im/SKILL.md) | Implement an Asana task or ad-hoc feature/fix with clean, structured commits |
| [`/one-shot`](.cursor/skills/one-shot/SKILL.md) | Legacy-style task-to-PR flow built from planning, implementation, and PR creation |
| [`/pr-create`](.cursor/skills/pr-create/SKILL.md) | Create a PR from the current branch with repo-aligned title and body |
| [`/dep-pr`](.cursor/skills/dep-pr/SKILL.md) | Create dependent Asana tasks and downstream PR work in another repo |
| [`/changelog`](.cursor/skills/changelog/SKILL.md) | Update CHANGELOG entries using repo conventions |

### Planning and Context

| Skill | Description |
|------|-------------|
| [`/asana-plan`](.cursor/skills/asana-plan/SKILL.md) | Build an implementation plan from Asana or ad-hoc requirements |
| [`/task-review`](.cursor/skills/task-review/SKILL.md) | Fetch and summarize Asana task context |
| [`/q`](.cursor/skills/q/SKILL.md) | Answer questions before taking action |

### Review and Landing

| Skill | Description |
|------|-------------|
| [`/pr-review`](.cursor/skills/pr-review/SKILL.md) | Review a PR against coding and review standards |
| [`/pr-address`](.cursor/skills/pr-address/SKILL.md) | Address PR feedback with fixup commits, replies, and optional autosquash |
| [`/pr-land`](.cursor/skills/pr-land/SKILL.md) | Land approved PRs, including prepare, merge, publish, GUI dep updates, staging cherry-picks, and Asana updates |
| [`/staging-cherry-pick`](.cursor/skills/staging-cherry-pick/SKILL.md) | Cherry-pick landed staging-targeted commits onto the staging branch |

### Asana and Utility

| Skill | Description |
|------|-------------|
| [`/asana-task-update`](.cursor/skills/asana-task-update/SKILL.md) | Generic Asana mutations such as attach PR, assign, unassign, and status updates |
| [`/standup`](.cursor/skills/standup/SKILL.md) | Generate daily standup notes from Asana and GitHub activity |
| [`/chat-audit`](.cursor/skills/chat-audit/SKILL.md) | Audit Cursor chat sessions for waste, drift, and workflow gaps |
| [`/convention-sync`](.cursor/skills/convention-sync/SKILL.md) | Sync `~/.cursor/` with this repo, mirror the local README to repo root, and update PR descriptions from `README.md` |
| [`/author`](.cursor/skills/author/SKILL.md) | Create, revise, and debug skills, scripts, and rules |
| [`/fix-eslint`](.cursor/skills/fix-eslint/SKILL.md) | Apply documented fixes for recurring Edge React GUI ESLint warnings |

## Companion Scripts

### PR Operations

| Script | What it does | API |
|------|-------------|-----|
| [`pr-create.sh`](.cursor/skills/pr-create/scripts/pr-create.sh) | Create a PR for the current branch with standardized body formatting | `gh pr create` |
| [`pr-address.sh`](.cursor/skills/pr-address/scripts/pr-address.sh) | Fetch unresolved feedback, reply, resolve threads, and mark items addressed | `gh api` REST + GraphQL |
| [`github-pr-review.sh`](.cursor/skills/pr-review/scripts/github-pr-review.sh) | Fetch PR context and submit reviews | `gh pr view` + `gh api` |
| [`github-pr-activity.sh`](.cursor/skills/standup/scripts/github-pr-activity.sh) | Gather recent PR activity and CI context for standups | `gh api graphql` |

### PR Landing Pipeline (`/pr-land`)

| Script | Phase | What it does |
|------|-------|-------------|
| [`pr-land-discover.sh`](.cursor/skills/pr-land/scripts/pr-land-discover.sh) | Discovery | Find relevant PRs and approval state |
| [`pr-land-comments.sh`](.cursor/skills/pr-land/scripts/pr-land-comments.sh) | Comment check | Detect unresolved inline, review-body, and top-level comments |
| [`git-branch-ops.sh`](.cursor/skills/git-branch-ops.sh) | Shared git ops | Run deterministic autosquash and push operations for multiple skills |
| [`pr-land-prepare.sh`](.cursor/skills/pr-land/scripts/pr-land-prepare.sh) | Prepare | Autosquash, rebase, detect conflicts, and verify |
| [`pr-land-merge.sh`](.cursor/skills/pr-land/scripts/pr-land-merge.sh) | Merge | Rebase again, verify, and merge sequentially |
| [`pr-land-publish.sh`](.cursor/skills/pr-land/scripts/pr-land-publish.sh) | Publish | Version bump, changelog update, commit, and tag |
| [`pr-land-extract-asana-task.sh`](.cursor/skills/pr-land/scripts/pr-land-extract-asana-task.sh) | Asana extraction | Pull task IDs from landed PR metadata |
| [`upgrade-dep.sh`](.cursor/skills/pr-land/scripts/upgrade-dep.sh) | GUI deps | Bump one package on the current branch, run yarn/prepare, commit lockfile updates. Caller must sync `develop` first. |
| [`staging-cherry-pick.sh`](.cursor/skills/staging-cherry-pick/scripts/staging-cherry-pick.sh) | Staging | Cherry-pick staging-qualified commits onto `staging` |
| [`verify-repo.sh`](.cursor/skills/verify-repo.sh) | Verification | Run changelog and code verification |

### Build, Lint, and Analysis

| Script | What it does |
|------|-------------|
| [`lint-commit.sh`](.cursor/skills/lint-commit.sh) | Run lint-assisted commits and autosquash fixups through the shared git helper |
| [`lint-warnings.sh`](.cursor/skills/im/scripts/lint-warnings.sh) | Auto-fix and summarize remaining TypeScript/ESLint warnings |
| [`install-deps.sh`](.cursor/skills/install-deps.sh) | Install dependencies and run project prepare steps |
| [`cursor-chat-extract.js`](.cursor/skills/chat-audit/scripts/cursor-chat-extract.js) | Parse Cursor chat exports into structured summaries |

### Asana and Portability

| Script | What it does |
|------|-------------|
| [`asana-get-context.sh`](.cursor/skills/asana-get-context.sh) | Fetch task details, comments, subtasks, and attachments |
| [`asana-task-update.sh`](.cursor/skills/asana-task-update/scripts/asana-task-update.sh) | Apply reusable Asana task mutations |
| [`asana-create-dep-task.sh`](.cursor/skills/dep-pr/scripts/asana-create-dep-task.sh) | Create dependent Asana tasks |
| [`asana-whoami.sh`](.cursor/skills/asana-whoami.sh) | Return current Asana identity |
| [`convention-sync.sh`](.cursor/skills/convention-sync/scripts/convention-sync.sh) | Sync `~/.cursor/` and `edge-dev-agents` in either direction, mirroring `~/.cursor/README.md` to repo root `README.md` |
| [`generate-claude-md.sh`](.cursor/skills/convention-sync/scripts/generate-claude-md.sh) | Regenerate `~/.claude/CLAUDE.md` from always-apply rules |
| [`tool-sync.sh`](.cursor/scripts/tool-sync.sh) | Sync Cursor assets into OpenCode and Claude-compatible formats |
| [`port-to-opencode.sh`](.cursor/scripts/port-to-opencode.sh) | Convert Cursor files into OpenCode-friendly mirrors |

## Shared Modules

| Module | Purpose |
|------|---------|
| [`edge-repo.js`](.cursor/skills/pr-land/scripts/edge-repo.js) | Shared repo resolution, git wrappers, conflict detection, verification, and `gh` helpers for the `pr-land` pipeline |

## Rules (`.mdc` files)

| Rule | Purpose |
|------|---------|
| [`workflow-halt-on-error.mdc`](.cursor/rules/workflow-halt-on-error.mdc) | Stop skill execution on script failures and fix the workflow definition first |
| [`load-standards-by-filetype.mdc`](.cursor/rules/load-standards-by-filetype.mdc) | Load language standards before editing or investigating file-specific issues |
| [`answer-questions-first.mdc`](.cursor/rules/answer-questions-first.mdc) | Answer user questions before editing or mutating state |
| [`no-format-lint.mdc`](.cursor/rules/no-format-lint.mdc) | Avoid manual formatting and formatting-only lint work |
| [`typescript-standards.mdc`](.cursor/rules/typescript-standards.mdc) | TypeScript and React editing standards |
| [`review-standards.mdc`](.cursor/rules/review-standards.mdc) | Review-specific bug patterns and conventions |
| [`eslint-warnings.mdc`](.cursor/rules/eslint-warnings.mdc) | Documented fixes for recurring ESLint warnings |
| [`after_each_chat.mdc`](.cursor/rules/after_each_chat.mdc) | Post-chat automation rule used in the local workflow |

## Design Principles

1. **Scripts over duplicated reasoning**. Deterministic git, API, and parsing
   work belongs in shared scripts.
2. **`gh` over raw GitHub HTTP calls**. Use the authenticated CLI for GitHub
   workflows.
3. **Shared helpers over drift**. Reusable mechanics like autosquash and push
   should live in one script and be consumed by multiple skills.
4. **Rules before edits**. Load the relevant standards before editing code or
   evaluating lint/type failures.
5. **Workflow fixes before workarounds**. If a skill is wrong, fix the skill or
   script instead of patching around it in an ad-hoc way.
6. **Canonical local copy**. `~/.cursor/` is the working source of truth;
   `edge-dev-agents` is the distribution and review copy.
