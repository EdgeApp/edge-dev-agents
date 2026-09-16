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

# Orchestrated worktrees: setup-task-workspace.sh may still be reinstalling
# node_modules in the background (.stale-node-modules carries installer_pid).
# Installing concurrently into the same tree corrupts it, so wait for that
# worker first; after our own install, drop the marker once the installed tree
# matches the lockfile (lib/node-modules-freshness.sh). No-op outside the orch.
NM_LIB="$HOME/.config/agent-watcher/lib/node-modules-freshness.sh"
if [ -f "$NM_LIB" ] && [ -f "$repo_dir/.stale-node-modules" ]; then
  . "$NM_LIB"
  if nm_installer_alive "$repo_dir"; then
    echo "Waiting for the background node_modules reinstall (up to ${INSTALL_DEPS_REINSTALL_WAIT:-900}s)..." >&2
    nm_wait_installer "$repo_dir" "${INSTALL_DEPS_REINSTALL_WAIT:-900}" || {
      echo "✗ background node_modules reinstall still running; not installing over it" >&2
      exit 1
    }
  fi
fi

echo "Installing dependencies (using $PM)..." >&2

if [ "$PM" = "npm" ]; then
  (cd "$repo_dir" && npm install --no-audit --no-fund)
else
  (cd "$repo_dir" && yarn install)
fi

if [ -f "$NM_LIB" ] && [ -f "$repo_dir/.stale-node-modules" ]; then
  . "$NM_LIB"
  nm_clear_marker_if_fresh "$repo_dir" \
    || echo "⚠ $repo_dir/.stale-node-modules kept: node_modules still differs from package-lock.json" >&2
fi

# Run the verification-safe prepare command. A trailing runtime-setup step
# (`npm run setup` / `yarn setup`) is stripped — see verification-prepare-cmd.sh
# for the convention and output contract.
prep_out=$("$(cd "$(dirname "$0")" && pwd)/verification-prepare-cmd.sh" "$repo_dir")
prep_mode=$(printf '%s\n' "$prep_out" | head -1)
prep_cmd=$(printf '%s\n' "$prep_out" | tail -n +2)

case "$prep_mode" in
  FULL)
    echo "Running prepare (using $PM)..." >&2
    if [ "$PM" = "npm" ]; then
      (cd "$repo_dir" && npm run prepare)
    else
      (cd "$repo_dir" && yarn prepare)
    fi
    ;;
  STRIPPED)
    echo "Running prepare (runtime setup step skipped)..." >&2
    (cd "$repo_dir" && PATH="$repo_dir/node_modules/.bin:$PATH" sh -c "$prep_cmd")
    ;;
  NONE)
    echo "⏭  No verification-relevant prepare script — skipping" >&2
    ;;
  *)
    echo "✗ verification-prepare-cmd.sh returned unexpected mode: $prep_mode" >&2
    exit 1
    ;;
esac

echo "✓ Dependencies installed and prepared (via $PM)" >&2
