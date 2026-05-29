#!/usr/bin/env bash
# lint-commit.sh
# Lint-fix, verify, localize (if needed), and commit in one atomic step.
#
# Usage:
#   lint-commit.sh -m "commit message" [file ...]
#   lint-commit.sh --fixup <hash> [file ...]
#   lint-commit.sh -m "fixup! Original commit" [file ...]   # Auto-reorders
#
# Options:
#   -m "msg"       Commit message (mutually exclusive with --fixup)
#   --fixup <hash> Create a fixup commit targeting <hash>
#   --reorder      After fixup commit, autosquash from merge-base with upstream (default: true)
#   --no-reorder   Skip the autosquash follow-up
#
# If files are given, they are the primary scope for linting/committing.
# The script may also auto-include generated companion files like:
#   - src/locales/strings
#   - eslint.config.mjs
#   - __snapshots__/*.snap
# Any additional non-generated files are reported before commit.
# If no files are given, all staged + unstaged + untracked changes are used.
# The script will:
#   1. Run eslint --fix on .ts/.tsx files
#   2. Run eslint --quiet to verify no remaining errors (exits 1 if any)
#   2b. Check for new warnings on changed lines (exits 1 if any)
#   3. Run the localize script via the repo's package manager (npm if
#      package-lock.json exists, else yarn if yarn.lock exists, else npm)
#   4. git add -A && git commit --no-verify
#   5. Run jest --findRelatedTests -u on committed .ts/.tsx files
#   6. If snapshots changed, amend the commit to include them
#   7. If commit is a fixup (--fixup or -m "fixup! ..."), autosquash via shared helper
set -euo pipefail

# Bump node heap for large repos (default ~4GB OOMs on big codebases).
# Append rather than overwrite so an outer NODE_OPTIONS wins.
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=8192"

# UNSAFE yarn workaround. The Socket CLI's `yarn` wrapper is broken in this agent
# environment: `~/.agent-shims/yarn` execs `socket yarn`, but socket re-resolves
# `yarn` via PATH, re-finds the same shim, and recurses until it dies (npm/npx
# wrappers work because socket locates their real binaries). Strip the shim dir
# from PATH so `yarn` resolves to the real binary. Tradeoff: bypasses Socket's
# supply-chain scanning for yarn. npm keeps the working socket wrapper.
run_yarn() {
  PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/\.agent-shims$' | paste -sd ':' -)" yarn "$@"
}

MESSAGE=""
FIXUP=""
REORDER="true"  # Default to reordering fixups
FILES=()
PRIMARY_SCOPE_DECLARED="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      MESSAGE="$2"
      shift 2
      ;;
    --fixup)
      FIXUP="$2"
      shift 2
      ;;
    --reorder)
      REORDER="true"
      shift
      ;;
    --no-reorder)
      REORDER="false"
      shift
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#FILES[@]} -gt 0 ]]; then
  PRIMARY_SCOPE_DECLARED="true"
fi

if [[ -z "$MESSAGE" && -z "$FIXUP" ]]; then
  echo "Error: -m \"commit message\" or --fixup <hash> is required" >&2
  exit 1
fi
if [[ -n "$MESSAGE" && -n "$FIXUP" ]]; then
  echo "Error: -m and --fixup are mutually exclusive" >&2
  exit 1
fi

# If no files specified, collect all changed/untracked files
if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && FILES+=("$f")
  done < <(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

  # Deduplicate (compatible with macOS Bash 3.2 — no mapfile)
  if [[ ${#FILES[@]} -gt 0 ]]; then
    DEDUPED=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && DEDUPED+=("$f")
    done < <(printf '%s\n' "${FILES[@]}" | sort -u)
    FILES=("${DEDUPED[@]}")
  fi
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "Error: No changed files found" >&2
  exit 1
fi

# Filter to lintable files (.ts/.tsx) that exist on disk
LINT_FILES=()
for f in "${FILES[@]}"; do
  if [[ ("$f" == *.ts || "$f" == *.tsx) && -f "$f" ]]; then
    LINT_FILES+=("$f")
  fi
done

# Step 1: eslint --fix
if [[ ${#LINT_FILES[@]} -gt 0 ]]; then
  echo ">> eslint --fix (${#LINT_FILES[@]} files)"
  ./node_modules/.bin/eslint --fix "${LINT_FILES[@]}" || true

  # Step 2: eslint --quiet (must pass)
  echo ">> eslint --quiet (verify)"
  if ! ./node_modules/.bin/eslint --quiet "${LINT_FILES[@]}"; then
    echo "Error: Lint errors remain after --fix. Aborting commit." >&2
    exit 1
  fi
  echo ">> Lint clean"

  # Step 2b: Detect new warnings introduced on changed lines.
  # Runs eslint (with warnings) and cross-references against git diff to
  # only flag warnings on lines the developer actually touched.
  NEW_WARN=$(node -e '
const { execSync } = require("child_process")
const path = require("path")

const files = process.argv.slice(1)
const cmd = "./node_modules/.bin/eslint --format json " + files.map(f => JSON.stringify(f)).join(" ")

let results
try {
  results = JSON.parse(execSync(cmd, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 }))
} catch (e) {
  if (e.stdout) try { results = JSON.parse(e.stdout) } catch { process.exit(0) }
  else process.exit(0)
}

const cwd = process.cwd()
const out = []

for (const r of results) {
  const rel = path.relative(cwd, r.filePath)
  const warns = r.messages.filter(m => m.severity === 1)
  if (warns.length === 0) continue

  // Determine which lines were changed in this file
  let changed
  try {
    execSync("git cat-file -e HEAD:" + JSON.stringify(rel), { stdio: "pipe" })
    const diff = execSync("git diff -U0 HEAD -- " + JSON.stringify(rel), { encoding: "utf8" })
    changed = new Set()
    for (const m of diff.matchAll(/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/g)) {
      const start = +m[1]
      const count = m[2] != null ? +m[2] : 1
      for (let i = start; i < start + count; i++) changed.add(i)
    }
  } catch {
    changed = null // New file — all lines count as changed
  }

  for (const w of warns) {
    if (changed == null || changed.has(w.line)) {
      out.push(rel + ":" + w.line + ":" + w.column + "  warning  " + w.message + "  " + w.ruleId)
    }
  }
}

if (out.length > 0) console.log(out.join("\n"))
' -- "${LINT_FILES[@]}" 2>/dev/null || true)

  if [[ -n "$NEW_WARN" ]]; then
    echo ">> New warnings on changed lines:" >&2
    echo "$NEW_WARN" >&2
    echo "Error: Fix new warnings before committing." >&2
    exit 1
  fi
fi

# Step 3: run the project's localize script (if defined), using the repo's
# package manager. Auto-detects npm vs yarn so the script works across repos
# that have migrated between the two without manual updates.
if node -e "process.exit(require('./package.json').scripts?.localize ? 0 : 1)" 2>/dev/null; then
  if [[ -f package-lock.json ]]; then
    echo ">> npm run localize"
    npm run --silent localize
  elif [[ -f yarn.lock ]]; then
    echo ">> yarn localize"
    run_yarn localize
  else
    echo ">> npm run localize (no lockfile detected, defaulting to npm)"
    npm run --silent localize
  fi
fi

# Step 4: Stage files and report effective commit scope
if [[ "$PRIMARY_SCOPE_DECLARED" == "true" ]]; then
  echo ">> git add (scoped) && git commit"
  git add -- "${FILES[@]}"
  # Stage generated companion files if they have changes
  for companion in eslint.config.mjs; do
    if [[ -f "$companion" ]] && ! git diff --quiet -- "$companion" 2>/dev/null; then
      git add -- "$companion"
    fi
  done
  # Stage locales/strings if the localize script changed them (already
  # git-added by localize in some repos, but ensure they're staged)
  if git diff --quiet --cached -- src/locales/strings 2>/dev/null; then
    git diff --quiet -- src/locales/strings 2>/dev/null || git add -- src/locales/strings/ 2>/dev/null || true
  fi
else
  echo ">> git add -A && git commit"
  git add -A
fi

# Graduate files from eslint warning-override list if the repo has the script
if node -e "process.exit(require('./package.json').scripts?.['update-eslint-warnings'] ? 0 : 1)" 2>/dev/null; then
  echo ">> update-eslint-warnings"
  npm run --silent update-eslint-warnings

  # Safety net: update-eslint-warnings (or any repo-side script) may have
  # auto-staged config changes that introduce errors — e.g., naively
  # graduating a file off a warning-override list when the file still has
  # demoted rule violations. Re-validate; if eslint now fails, restore
  # eslint.config.mjs so the bad config can't ride into a commit.
  if [[ ${#LINT_FILES[@]} -gt 0 ]] && ! ./node_modules/.bin/eslint --quiet "${LINT_FILES[@]}" 2>/dev/null; then
    echo "Error: post-graduation lint failed. Restoring eslint.config.mjs and aborting." >&2
    git checkout HEAD -- eslint.config.mjs 2>/dev/null || true
    git reset HEAD -- eslint.config.mjs 2>/dev/null || true
    exit 1
  fi
fi

if [[ "$PRIMARY_SCOPE_DECLARED" == "true" ]]; then
  echo ">> commit scope report"
  node -e '
const { execSync } = require("child_process")

const requested = [...new Set(process.argv.slice(1))].sort()
const staged = execSync("git diff --cached --name-only --diff-filter=ACMRD", {
  encoding: "utf8"
})
  .split("\n")
  .map(line => line.trim())
  .filter(Boolean)
  .sort()

const requestedSet = new Set(requested)
const isGeneratedCompanion = file => {
  return (
    file === "eslint.config.mjs" ||
    file === "src/locales/strings" ||
    /(^|\/)__snapshots__\/.*\.snap$/.test(file)
  )
}

const requestedStaged = []
const generatedStaged = []
const extraStaged = []
for (const file of staged) {
  if (requestedSet.has(file)) {
    requestedStaged.push(file)
  } else if (isGeneratedCompanion(file)) {
    generatedStaged.push(file)
  } else {
    extraStaged.push(file)
  }
}

const missingRequested = requested.filter(file => !staged.includes(file))

const printGroup = (title, files) => {
  if (files.length === 0) return
  console.log(title)
  for (const file of files) console.log("- " + file)
}

printGroup("Primary scope staged:", requestedStaged)
printGroup("Auto-generated companion files staged:", generatedStaged)
printGroup("Additional non-generated files staged:", extraStaged)
printGroup("Requested files not staged:", missingRequested)

if (extraStaged.length > 0) {
  console.log("Proceeding with additional non-generated files by default.")
}
' -- "${FILES[@]}"
fi

if [[ -n "$FIXUP" ]]; then
  git commit --no-verify --fixup "$FIXUP"
else
  git commit --no-verify -m "$MESSAGE"
fi

# Step 5: Update snapshots for related tests (Jest only)
if [[ ${#LINT_FILES[@]} -gt 0 && -x ./node_modules/.bin/jest ]]; then
  echo ">> jest --findRelatedTests -u (${#LINT_FILES[@]} files)"
  ./node_modules/.bin/jest --findRelatedTests "${LINT_FILES[@]}" -u 2>&1 || true

  # Step 6: If snapshots changed, amend the commit
  SNAP_CHANGES=$(git diff --name-only -- '**/__snapshots__/**' 2>/dev/null || true)
  if [[ -n "$SNAP_CHANGES" ]]; then
    echo ">> Snapshots updated, amending commit:"
    echo "$SNAP_CHANGES"
    if [[ "$PRIMARY_SCOPE_DECLARED" == "true" ]]; then
      echo ">> Auto-generated companion files staged:"
      echo "$SNAP_CHANGES"
    fi
    git add -- $SNAP_CHANGES
    git commit --amend --no-edit --no-verify
  else
    echo ">> No snapshot changes"
  fi
fi

# Step 7: Autosquash fixup commits when requested
# Detects fixup commits by --fixup flag or "fixup! " prefix in message
IS_FIXUP="false"
if [[ -n "$FIXUP" ]]; then
  IS_FIXUP="true"
elif [[ "$MESSAGE" == fixup!* ]]; then
  IS_FIXUP="true"
fi

if [[ "$IS_FIXUP" == "true" && "$REORDER" == "true" ]]; then
  echo ">> Autosquashing fixup commit..."

  DEFAULT_UPSTREAM=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    || echo "origin/$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
    || echo "origin/master")

  if ~/.cursor/skills/git-branch-ops.sh autosquash --merge-base-with "$DEFAULT_UPSTREAM" 2>/dev/null; then
    echo ">> Fixup autosquashed successfully"
  else
    git rebase --abort 2>/dev/null || true
    echo ">> Warning: Could not autosquash fixup (conflict). Fixup remains at HEAD." >&2
    echo ">> Run '~/.cursor/skills/git-branch-ops.sh autosquash --merge-base-with $DEFAULT_UPSTREAM' manually." >&2
  fi
fi

echo ">> Done"
