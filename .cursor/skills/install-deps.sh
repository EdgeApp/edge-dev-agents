#!/usr/bin/env bash
set -euo pipefail

# install-deps.sh — Install dependencies and run prepare script.
# Usage: install-deps.sh [repo-dir]
#
# Detects npm vs yarn from lockfile:
#   - package-lock.json present → npm
#   - yarn.lock present → yarn
#   - both → prefer npm (recently-migrated repos may keep yarn.lock until cleanup)
#   - neither → default to npm
#
# Runs `<pm> install` and `<pm> run prepare` (if prepare script exists).
# Use after: branch creation, rebase onto upstream, checkout.
#
# Exit codes:
#   0 = Success (or no package.json — skipped)
#   1 = Install or prepare failed

repo_dir="${1:-.}"

if [ ! -f "$repo_dir/package.json" ]; then
  echo "⏭  No package.json — skipping dependency install" >&2
  exit 0
fi

# Detect package manager
if [ -f "$repo_dir/package-lock.json" ]; then
  PM="npm"
elif [ -f "$repo_dir/yarn.lock" ]; then
  PM="yarn"
else
  PM="npm"
fi

echo "Installing dependencies (using $PM)..." >&2

if [ "$PM" = "npm" ]; then
  (cd "$repo_dir" && npm install --no-audit --no-fund)
else
  (cd "$repo_dir" && yarn install)
fi

if (cd "$repo_dir" && node -e "process.exit(require('./package.json').scripts?.prepare ? 0 : 1)" 2>/dev/null); then
  echo "Running prepare (using $PM)..." >&2
  if [ "$PM" = "npm" ]; then
    (cd "$repo_dir" && npm run prepare)
  else
    (cd "$repo_dir" && yarn prepare)
  fi
fi

echo "✓ Dependencies installed and prepared (via $PM)" >&2
