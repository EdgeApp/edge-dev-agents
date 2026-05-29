#!/usr/bin/env bash
set -euo pipefail

# upgrade-dep.sh
# Upgrade one package on the current branch and commit the bump + lockfiles.
#
# Usage: upgrade-dep.sh <package> [version]
#
# PRECONDITION: caller has already placed us on a clean `develop` (or the
# target branch) synced to origin. This script does NOT stash, checkout,
# fetch, or reset — doing so would wipe commits from a prior `upgrade-dep.sh`
# invocation in the same `/pr-land` run.
#
# Bumps the version in package.json, runs install + prepare + prepare.ios via
# whichever package manager the repo uses (npm or yarn, auto-detected via
# ~/.cursor/skills/pm.sh), and commits package.json + lockfile with message
# "Upgrade <package>@<version>".

usage() {
    echo "Usage: upgrade-dep.sh <package> [version]"
    exit 1
}

package=""
new_version=""

case "$#" in
    1)
        package="$1"
        ;;
    2)
        package="$1"
        new_version="$2"
        ;;
    *)
        usage
        ;;
esac

# Resolve latest version from npm if none provided
if [ -z "$new_version" ]; then
    latest_version=$(npm view "$package" versions --json | jq -r '.[]' | sort -V | tail -n 1)
    new_version="^$latest_version"
fi

# Check if already at target version
current_version=$(jq -r ".dependencies[\"$package\"] // .devDependencies[\"$package\"]" package.json)
if [ "$current_version" = "$new_version" ]; then
    echo "Error: $package is already at version $new_version"
    exit 1
fi

# Update package.json
sed -i "" "s#\"$package\": \".*\"#\"$package\": \"$new_version\"#" package.json

# Install and prepare
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
~/.cursor/skills/pm.sh install
~/.cursor/skills/pm.sh run prepare
~/.cursor/skills/pm.sh run prepare.ios

# yarn.lock-only cleanup: yarn writes git+ prefixes for git deps; npm's
# package-lock does not. Skip the sed when there is no yarn.lock.
if [[ -f yarn.lock ]]; then
  sed -i "" "s/git+//" yarn.lock
fi

# Stage and commit (git add -A picks up whichever lockfile changed)
git add -A
git commit -m "Upgrade $package@$new_version" --no-verify
echo ">> UPGRADE_READY package=$package version=$new_version sha=$(git rev-parse HEAD) branch=$(git branch --show-current)"
