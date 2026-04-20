#!/usr/bin/env bash
# cheese-build.sh
# Hard-reset a test-* branch to a source ref and force-push to trigger a
# Jenkins test build. Optionally pin unreleased dep repos as prebuilt
# tarballs so the build server doesn't run each dep's prepare script.
#
# Usage:
#   cheese-build.sh --branch <name> [--from <ref>] [--pin <path>]...
#
# Options:
#   --branch   Target cheese branch (e.g. test-feta). Required.
#   --from     Source ref to reset to. Default: current HEAD.
#   --pin PATH Absolute path to a dep repo checkout. Repeatable.
#              Runs yarn + yarn prepare + yarn pack in the dep, copies
#              the resulting tarball into the GUI root with a timestamp
#              suffix, and rewrites package.json to point at it.
#
# Must be run from inside an edge-react-gui checkout with a clean tree.
#
# Exit codes:
#   0  success
#   1  runtime error
#   2  invalid input / precondition not met

set -euo pipefail

BRANCH=""
FROM=""
PINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --pin) PINS+=("$2"); shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$BRANCH" ]] || { echo "--branch required" >&2; exit 2; }

# Must be inside edge-react-gui checkout
GUI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not in a git repo" >&2; exit 2;
}
GUI_NAME="$(jq -r '.name // empty' "$GUI_ROOT/package.json" 2>/dev/null)"
[[ "$GUI_NAME" == "edge-react-gui" ]] || {
  echo "must run from within edge-react-gui (found: $GUI_NAME)" >&2; exit 2;
}
cd "$GUI_ROOT"

# Require clean working tree — cheese builds can't stash safely
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "working tree has uncommitted changes — commit or stash first" >&2
  exit 2
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "working tree has untracked files — clean or add to .gitignore first" >&2
  exit 2
fi

# Resolve source ref (default current HEAD)
if [[ -z "$FROM" ]]; then
  FROM="$(git rev-parse --abbrev-ref HEAD)"
fi
if [[ "$FROM" == "$BRANCH" ]]; then
  echo "--from must differ from --branch ($BRANCH)" >&2; exit 2
fi
FROM_SHA="$(git rev-parse "$FROM")" || {
  echo "cannot resolve ref: $FROM" >&2; exit 2;
}

echo ">> cheese build: reset $BRANCH -> $FROM ($(git rev-parse --short "$FROM_SHA"))"

# Checkout cheese branch (create if needed)
git fetch origin "$BRANCH" --quiet 2>/dev/null || true
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout "$BRANCH" >/dev/null
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git checkout -b "$BRANCH" "origin/$BRANCH" >/dev/null
else
  echo ">> creating new local branch: $BRANCH"
  git checkout -b "$BRANCH" >/dev/null
fi

git reset --hard "$FROM_SHA" >/dev/null
echo ">> reset complete"

# --- Pin deps (optional) ---
TARBALL_FILES=()
DEP_REFS=()

if [[ ${#PINS[@]} -gt 0 ]]; then
  STAMP="$(date +%Y%m%dT%H%M)"

  for DEP_ROOT in "${PINS[@]}"; do
    [[ -d "$DEP_ROOT" ]] || { echo "dep repo not found: $DEP_ROOT" >&2; exit 2; }
    [[ -f "$DEP_ROOT/package.json" ]] || {
      echo "no package.json in $DEP_ROOT" >&2; exit 2;
    }

    DEP_NAME="$(jq -r .name "$DEP_ROOT/package.json")"
    DEP_VERSION="$(jq -r .version "$DEP_ROOT/package.json")"
    DEP_SHA="$(git -C "$DEP_ROOT" rev-parse HEAD)"
    DEP_REFS+=("$DEP_NAME @ $DEP_SHA")

    echo ">> packing $DEP_NAME@$DEP_VERSION ($DEP_SHA)"

    # Build lib/ fresh before packing
    if [[ -x "$HOME/.cursor/skills/install-deps.sh" ]]; then
      (cd "$DEP_ROOT" && "$HOME/.cursor/skills/install-deps.sh")
    else
      (cd "$DEP_ROOT" && yarn install --non-interactive && yarn prepare)
    fi

    (cd "$DEP_ROOT" && yarn pack --quiet >/dev/null)

    SRC_TGZ="$DEP_ROOT/${DEP_NAME}-v${DEP_VERSION}.tgz"
    [[ -f "$SRC_TGZ" ]] || {
      echo "yarn pack did not produce $SRC_TGZ" >&2; exit 1;
    }

    # Verify tarball contains lib/ — build server will fail without it
    if ! tar -tzf "$SRC_TGZ" | grep -q '^package/lib/'; then
      echo "tarball missing package/lib/ — run 'yarn prepare' in $DEP_ROOT and retry" >&2
      rm -f "$SRC_TGZ"
      exit 1
    fi

    DST_NAME="${DEP_NAME}-${DEP_VERSION}-${STAMP}.tgz"
    cp "$SRC_TGZ" "$GUI_ROOT/$DST_NAME"
    rm -f "$SRC_TGZ"
    TARBALL_FILES+=("$DST_NAME")

    # Rewrite package.json (preserve formatting approximately)
    node -e '
      const fs = require("fs");
      const path = process.argv[1];
      const name = process.argv[2];
      const target = "./" + process.argv[3];
      const raw = fs.readFileSync(path, "utf8");
      const pkg = JSON.parse(raw);
      const deps = pkg.dependencies || {};
      if (!(name in deps)) {
        console.error("not in gui dependencies: " + name);
        process.exit(1);
      }
      deps[name] = target;
      const trailing = raw.endsWith("\n") ? "\n" : "";
      fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + trailing);
    ' "$GUI_ROOT/package.json" "$DEP_NAME" "$DST_NAME"

    echo ">> pinned $DEP_NAME -> ./$DST_NAME"
  done

  echo ">> yarn install (refresh lock)"
  yarn install --non-interactive

  # Commit via lint-commit.sh (handles --no-verify, staging, etc.)
  MSG_BODY="$(
    echo "Pin dependencies for cheese build"
    echo ""
    for ref in "${DEP_REFS[@]}"; do echo "- $ref"; done
  )"

  "$HOME/.cursor/skills/lint-commit.sh" -m "$MSG_BODY" \
    package.json \
    yarn.lock \
    "${TARBALL_FILES[@]}"
fi

# --- Push ---
echo ">> force-push-with-lease -> origin/$BRANCH"
"$HOME/.cursor/skills/git-branch-ops.sh" push --force-with-lease --branch "$BRANCH"

FINAL_SHA="$(git rev-parse HEAD)"
REMOTE_URL="$(
  git remote get-url origin \
    | sed -E 's|git@github.com:(.*)\.git$|https://github.com/\1|' \
    | sed -E 's|\.git$||'
)"
echo ">> DONE: ${REMOTE_URL}/tree/${BRANCH} (${FINAL_SHA})"
