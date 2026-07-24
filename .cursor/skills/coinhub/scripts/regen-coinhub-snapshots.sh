#!/usr/bin/env bash
# regen-coinhub-snapshots.sh — regenerate edge-react-gui jest snapshots under the
# coinhub app config (the flavor CI renders) and verify a clean run passes.
#
# WHY: CI copies jenkins-files/coinhub/env.json (APP_CONFIG=coinhub, NunitoSans
# fonts) before `npm test`. A freshly-provisioned worktree's env.json defaults to
# APP_CONFIG=edge (Quicksand). Regenerating snapshots under the default config
# produces edge-flavored .snap files that pass locally but fail CI. This script
# forces the coinhub config, regenerates, and asserts zero edge-font leakage.
#
# Does NOT commit — run lint-commit.sh afterward per the /im contract.
#
# Usage: regen-coinhub-snapshots.sh [--worktree <path>]
#   --worktree <path>  edge-react-gui worktree to operate in (default: cwd)
set -euo pipefail

WORKTREE="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

cd "$WORKTREE"
if [[ ! -f env.json ]]; then
  echo ">> ERROR: no env.json in $WORKTREE (not an edge-react-gui worktree?)" >&2
  exit 1
fi

# env.json is gitignored; these flips are local-only and never committed.
# CI renders under jenkins-files/coinhub/env.json: APP_CONFIG=coinhub AND
# ALLOW_DEVELOPER_MODE off (the developer-mode settings card in SettingsScene is
# gated on ENV.ALLOW_DEVELOPER_MODE; a dev env.json with it true adds a card the
# coinhub production render omits, breaking the SettingsScene snapshot).
BEFORE="$(node -e 'try{process.stdout.write(String(require("./env.json").APP_CONFIG||"edge"))}catch(e){process.stdout.write("edge")}')"
node -e '
  const fs=require("fs"); const p="env.json";
  const j=JSON.parse(fs.readFileSync(p,"utf8"));
  j.APP_CONFIG="coinhub";
  j.ALLOW_DEVELOPER_MODE=false;
  fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
'
echo ">> APP_CONFIG: ${BEFORE} -> coinhub, ALLOW_DEVELOPER_MODE -> false (env.json, gitignored, local only)"

echo ">> regenerating snapshots: TZ=America/Los_Angeles jest -u --ci"
TZ=America/Los_Angeles npx jest -u --ci 2>&1 | tail -6

echo ">> clean verify (must exit 0): TZ=America/Los_Angeles jest --ci"
set +e
TZ=America/Los_Angeles npx jest --ci >/tmp/coinhub-jest-verify.log 2>&1
RC=$?
set -e
tail -6 /tmp/coinhub-jest-verify.log

# Assert no edge-font (Quicksand) leakage remains in committed-tree snapshots.
QUICKSAND=$(grep -rl "Quicksand" src/__tests__/**/__snapshots__/*.snap 2>/dev/null | wc -l | tr -d ' ')
NUNITO=$(grep -rl "NunitoSans" src/__tests__/**/__snapshots__/*.snap 2>/dev/null | wc -l | tr -d ' ')
echo ">> snapshot fonts: Quicksand files=${QUICKSAND} (must be 0), NunitoSans files=${NUNITO}"

if [[ "$RC" -ne 0 ]]; then
  echo ">> FAIL: clean jest run exited ${RC} — snapshots not clean, see /tmp/coinhub-jest-verify.log" >&2
  exit 1
fi
if [[ "$QUICKSAND" -ne 0 ]]; then
  echo ">> FAIL: ${QUICKSAND} snapshot file(s) still contain Quicksand (edge font) — coinhub config was not applied" >&2
  exit 1
fi
echo ">> OK: snapshots regenerated under coinhub config and a clean jest --ci passes. Commit via lint-commit.sh."
