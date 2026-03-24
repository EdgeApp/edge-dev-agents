# Global Rules

# Auto-generated from ~/.cursor/rules/ (alwaysApply: true files only).
# Do not edit manually. Re-generate via convention-sync.

---

## answer-questions-first

# Answer Questions Before Acting

Before using any code editing tools, scan the user's message for `?` characters and determine if it's a question.

- **Ignore** `?` inside code, URLs or query parameters (e.g. `?param=x`, `?key=value` , `const x = ifTrue ? 'yes' : 'no'`)
- **Treat all other `?`** as question statements, if they appear to be questions.

If questions are detected:

1. Read `~/.cursor/skills/q/SKILL.md` and follow its workflow to answer every question.
2. **Workflow context**: If a skill was invoked earlier in this conversation, note which one. When a question or critique references agent behavior from that execution, load the skill definition before answering and evaluate whether the skill should have governed that behavior. If it should have but didn't, that's a workflow gap — treat it as the primary concern per `fix-workflow-first.mdc`.
3. Do **not** edit files, create files, or run mutating commands until the user responds.
4. Only proceed with implementation after the user permits it in a follow-up message.

---

## load-standards-by-filetype

<goal>Load language-specific coding standards before editing or investigating lint/type errors in files, without redundant reads.</goal>

<rules>
<rule id="check-before-read">Before using any code editing tool on a file OR investigating lint/type errors in that file type, check if the matching standards rule is already present in `cursor_rules_context`. Only read the rule file if it is NOT already in context.</rule>
<rule id="read-before-edit">If the rule is not in context, read it using the Read tool and follow its contents BEFORE making the edit or investigating the error.</rule>
</rules>

<standards-map>

| File glob           | Standards file                               |
|---|----|
| `**/*.ts`,`**/*.tsx` | `~/.cursor/rules/typescript-standards.mdc` |

</standards-map>

---

## no-format-lint

# No Manual Formatting or Lint Fixing

- Do NOT run `yarn lint`, `yarn fix`, `yarn verify`, or any lint/format shell commands unless explicitly asked.
- Do NOT manually fix formatting issues (whitespace, quotes, semicolons, trailing commas, line length). The `lint-commit.sh` script runs `eslint --fix` (including Prettier) before each commit.
- Only use `ReadLints` to check for logical or type errors, not formatting. If the only lint errors are formatting-related, ignore them.
- Focus tokens on correctness and logic, not style.

---

## workflow-halt-on-error

<rules description="Non-negotiable constraints.">

<rule id="cursor-workflow-paths">All workflow-related skill definitions (`*.md` / `SKILL.md`) and workflow companion scripts (`*.sh`) are sourced from `~/.cursor/`. When executing skills, prefer explicit `~/.cursor/...` paths and do not assume repo-local workflow files unless the skill explicitly points to one.</rule>

<rule id="skill-script-path-resolution">When a skill mentions a script path, resolve it under `~/.cursor/skills/<skill>/scripts/` unless the skill explicitly specifies an absolute path elsewhere. Do not assume repo-relative `scripts/` paths without verifying the skill directory contents.</rule>

<rule id="halt-on-error">When ANY shell command fails (non-zero exit code) while executing an active skill workflow, a delegated subskill from that workflow, or a companion-script step required by that workflow (except where explicitly allowed by `auto-fix-verification-failures` or `companion-script-nonzero-contracts`):
1. **STOP** — do not retry, work around, substitute, or continue the workflow.
2. **Report** — show the user the exact command, exit code, and error output.
3. **Diagnose** — classify the failure: missing tool (`command not found`), wrong path, permissions, or logic error.
4. **Evaluate workflow** — if the failure reveals a gap in a skill definition, follow the fix-workflow-first rules below.
5. **Wait** — do not resume until the user responds.
</rule>

<rule id="fix-workflow-first">When a workflow gap is discovered in an active skill definition:
1. **Stop immediately** — do not continue the current task or apply any workaround.
2. **Identify the root cause** in the skill (`.cursor/skills/*/SKILL.md`) definition.
3. **Propose the fix** to the user and wait for approval before proceeding.
4. **Fix the skill** using `/author` after approval.
5. **Resume the original task** only after the skill is updated.

Fixing the skill takes **absolute priority** over all other actions — including workarounds, continuing the original task, or applying temporary fixes. Do NOT apply workarounds or manual fixes before proposing the skill update. The correct sequence is: identify gap → propose fix → get approval → apply fix → then resume original task. This applies to all workflow issues — missed steps, incorrect output, wrong tool usage, shell failures, formatting problems, etc. The skill is the source of truth; patching around it creates drift.
</rule>

<rule id="skill-scope-only">These workflow halt rules are for skill-driven execution, especially hands-off/orchestrated skills and their dependencies. They do not automatically apply to ad hoc exploration, incidental verification, or low-risk authoring work unless that command is part of an active skill contract.</rule>

<rule id="auto-fix-verification-failures">Exception to `halt-on-error`: For verification/code-quality failures where diagnostics are explicit and local, continue automatically with bounded remediation.

Allowed auto-fix scope:
- TypeScript/compiler failures (`tsc`) with clear file/line diagnostics
- Lint failures (`eslint`) with clear file/line diagnostics
- Test failures (`jest`/`yarn test`) when stack traces or assertion output identify failing test files
- `verify-repo.sh` code-step failures that resolve to one of the above

Required behavior:
1. Briefly log rationale: failure type, affected files, and why scope is unambiguous.
2. Apply the minimal fix in the failing repo.
3. Re-run the failing verification step.
4. Limit to 2 remediation attempts; if still failing or scope expands, fall back to `halt-on-error`.

Never auto-fix:
- Missing tools/auth (`command not found`, `PROMPT_GH_AUTH`)
- Wrong path/permissions
- Companion script contract/usage failures
- Unexpected exit codes from orchestrator scripts
- Any failure requiring destructive operations or workflow bypasses
</rule>

<rule id="companion-script-nonzero-contracts">Respect documented companion script exit-code contracts. Non-zero does NOT always mean fatal.

For `~/.cursor/skills/im/scripts/lint-warnings.sh`:
- `0` = no remaining lint findings after auto-fix
- `1` = remaining lint findings after auto-fix (expected actionable state)
- `2` = execution error (fatal)

Required behavior:
1. If exit `1`, continue workflow by fixing the remaining lint findings before implementation.
2. If the script auto-fixes pre-existing lint issues, commit those changes in a separate lint-fix commit immediately before feature commits, even if no findings remain.
3. If exit `2`, apply `halt-on-error`.
</rule>

<rule id="no-silent-substitution">Do NOT silently substitute an alternative tool or approach when a command fails. If `rg` is not found, do not fall back to `grep`. If a script exits non-zero, do not manually replicate what the script does. The failure is the signal — report it.</rule>

</rules>

<slash-command-detection description="Detect /command invocations in user messages, analogous to answer-questions-first.mdc for '?' characters.">

Scan the user's message for `/word` tokens. A token is a **command invocation** when ALL of:
- `/word` is preceded by whitespace, a newline, or is at the start of the message
- `word` contains only lowercase letters and hyphens (e.g., `/im`, `/pr-create`, `/author`)
- `/word` is NOT inside a file path, URL, or code block

When detected:
1. Read `~/.cursor/skills/<word>/SKILL.md` and follow it immediately.
2. If the file does not exist, inform the user: "Skill `/<word>` not found in `~/.cursor/skills/`."

**Ignore `/`** in: file paths (`/Users/...`, `~/...`), URLs (`https://...`), mid-word (`and/or`), backticks/code blocks.

</slash-command-detection>


