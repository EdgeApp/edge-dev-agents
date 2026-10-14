#!/usr/bin/env bash
# cheese-pin-commit.test.sh: cheese-build.sh --pin commits its pinned tarball
# in an app repo whose .gitignore ignores root-level tarballs (/*.tgz).
#
# Runs the real cheese-build.sh and lint-commit.sh in a throwaway app repo with
# a throwaway dep repo. The package manager wrapper, the dependency installer
# and the push helper are stand-ins in a private HOME, so nothing is installed
# and nothing is pushed.
set -uo pipefail

REAL="$HOME/.cursor/skills"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cheese-pin-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}

# Private HOME: the two real scripts, three stand-ins.
FH="$TMP/home"
mkdir -p "$FH/.cursor/skills/cheese/scripts"
cp "$REAL/cheese/scripts/cheese-build.sh" "$FH/.cursor/skills/cheese/scripts/"
cp "$REAL/lint-commit.sh" "$FH/.cursor/skills/"
cat > "$FH/.cursor/skills/pm.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  lockfile) echo package-lock.json ;;
  install) echo "{\"lockfileVersion\":3,\"stamp\":\"$RANDOM$RANDOM\"}" > package-lock.json ;;
  pack)
    mkdir -p .pack/package/lib
    echo 'module.exports = 1' > .pack/package/lib/index.js
    cp package.json .pack/package/
    tar -czf fake-dep-1.0.0.tgz -C .pack package
    rm -rf .pack
    echo fake-dep-1.0.0.tgz ;;
  *) exit 0 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FH/.cursor/skills/install-deps.sh"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/push.log"\n' "$TMP" > "$FH/.cursor/skills/git-branch-ops.sh"
chmod +x "$FH"/.cursor/skills/*.sh "$FH"/.cursor/skills/cheese/scripts/*.sh

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset AGENT_TASK_GID

git init -q "$TMP/dep"
echo '{"name":"fake-dep","version":"1.0.0"}' > "$TMP/dep/package.json"
git -C "$TMP/dep" add -A && git -C "$TMP/dep" commit -qm "dep"

# make_app <dir> <gitignore-content>
make_app() {
  git init -q --bare "$1.origin.git"
  git init -q -b feature "$1"
  echo '{"name":"edge-react-gui","dependencies":{"fake-dep":"1.0.0"}}' > "$1/package.json"
  echo '{"lockfileVersion":3}' > "$1/package-lock.json"
  printf '%s\n' "$2" > "$1/.gitignore"
  git -C "$1" add -A && git -C "$1" commit -qm "app"
  git -C "$1" remote add origin "$1.origin.git"
}

# run_case <label> <gitignore-content>
run_case() {
  local APP="$TMP/app-$1" OUT RC TGZ
  make_app "$APP" "$2"
  : > "$TMP/push.log"
  OUT=$(cd "$APP" && HOME="$FH" bash "$FH/.cursor/skills/cheese/scripts/cheese-build.sh" \
    --branch test-scratch --pin "$TMP/dep" 2>&1)
  RC=$?
  check "$1: exit code" "$RC" 0
  [[ $RC -eq 0 ]] || echo "$OUT" | tail -5 | sed 's/^/      /'
  TGZ=$(git -C "$APP" show --name-only --format= HEAD | grep -c '^fake-dep-1\.0\.0-.*\.tgz$')
  check "$1: tarball is in the pin commit" "$TGZ" 1
  check "$1: package.json is in the pin commit" \
    "$(git -C "$APP" show --name-only --format= HEAD | grep -c '^package\.json$')" 1
  check "$1: lockfile is in the pin commit" \
    "$(git -C "$APP" show --name-only --format= HEAD | grep -c '^package-lock\.json$')" 1
  check "$1: package.json points at the tarball" \
    "$(git -C "$APP" show HEAD:package.json | grep -c '"fake-dep": "\./fake-dep-1\.0\.0-.*\.tgz"')" 1
  check "$1: commit subject" "$(git -C "$APP" log -1 --format=%s)" "Pin dependencies for cheese build"
  check "$1: tree is clean after the commit" "$(git -C "$APP" status --porcelain | wc -l | tr -d ' ')" 0
  check "$1: push step ran once" "$(wc -l < "$TMP/push.log" | tr -d ' ')" 1
}

run_case ignored "/*.tgz"
run_case plain "node_modules"

echo "---"
if [[ $FAILS -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
