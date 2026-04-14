#!/usr/bin/env bash
set -euo pipefail

# Standalone replacement for the upgrade_dep shell function.
# Usage: upgrade-dep.sh <package> [version]
#
# Stashes any working changes on the current branch, switches to develop,
# hard-resets to origin/develop, upgrades a dependency in package.json,
# runs yarn + prepare, and creates a commit with the resulting lockfile / pod
# updates. Stashes remain stashed; the caller decides what to do with them.

usage() {
    echo "Usage: upgrade-dep.sh <package> [version]"
    exit 1
}

package=""
new_version=""
orig_branch="$(git branch --show-current)"

has_working_changes() {
    ! git diff --quiet HEAD 2>/dev/null || \
    ! git diff --cached --quiet HEAD 2>/dev/null || \
    [[ -n "$(git ls-files --others --exclude-standard)" ]]
}

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

# Stash any working changes before switching to develop:
if has_working_changes; then
    git stash -u
    echo ">> STASHED=true branch=$orig_branch"
else
    echo ">> STASHED=false branch=$orig_branch"
fi

git checkout develop
git fetch origin develop
git reset --hard origin/develop

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
yarn && yarn prepare && yarn prepare.ios

# Remove git+ prefixes from yarn.lock
sed -i "" "s/git+//" yarn.lock

# Stage and commit
git add -A
git commit -m "Upgrade $package@$new_version" --no-verify
echo ">> UPGRADE_READY package=$package version=$new_version sha=$(git rev-parse HEAD) branch=$(git branch --show-current)"
