# edge-dev-agents

Complete agent-assisted development workflow for Edge repositories:
slash skills, companion scripts, coding standards, review standards,
and meta-tooling for maintaining the workflow itself.

The distributable Cursor content lives under `.cursor/`. This repo is the
versioned home for those skills, rules, scripts, and docs.

## Installation

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
- [Skills](#skills-slash-skills)
- [Companion Scripts](#companion-scripts)
- [Shared Modules](#shared-modules)
- [Rules](#rules-mdc-files)
- [Design Principles](#design-principles)

## Architecture

```text
edge-dev-agents/
├── README.md          # Repo overview
└── .cursor/
    ├── README.md      # Source for convention-sync PR descriptions
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
| [`/convention-sync`](.cursor/skills/convention-sync/SKILL.md) | Sync `~/.cursor/` with this repo and update PR descriptions from `.cursor/README.md` |
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
| [`upgrade-dep.sh`](.cursor/skills/pr-land/scripts/upgrade-dep.sh) | GUI deps | Stash local work, reset `develop`, upgrade deps, and emit ready commit SHAs |
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
| [`convention-sync.sh`](.cursor/skills/convention-sync/scripts/convention-sync.sh) | Sync `~/.cursor/` and `edge-dev-agents` in either direction |
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
