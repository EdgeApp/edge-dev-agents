#!/usr/bin/env bash
set -euo pipefail

# verification-prepare-cmd.sh — print the verification-safe `prepare` command
# for a repo.
#
# Verification-time installs run build steps only — never runtime bootstrap.
# By Edge convention a script named `setup` is runtime bootstrap (database /
# service initialization that needs live network access), so a trailing
# `&& npm run setup` / `&& yarn setup` in scripts.prepare is stripped here.
# Callers (install-deps.sh, verify-repo.sh) execute what this prints instead
# of the raw prepare script.
#
# STRIPPED commands run via `sh -c` with node_modules/.bin prefixed to PATH,
# outside the npm lifecycle env — build steps must not depend on npm_* vars.
#
# Usage: verification-prepare-cmd.sh <repo-dir>
# stdout line 1: FULL | STRIPPED | NONE
# stdout line 2: command string (STRIPPED only; FULL = caller runs the PM's
#                normal `<pm> run prepare`; NONE = nothing to run)
# Exit: 0 = resolved, 2 = usage.

repo_dir="${1:-}"
[ -n "$repo_dir" ] || { echo "usage: verification-prepare-cmd.sh <repo-dir>" >&2; exit 2; }

cd "$repo_dir"
node -e '
const path = require("path");
let pkg;
try {
  pkg = require(path.join(process.cwd(), "package.json"));
} catch (e) {
  console.log("NONE");
  process.exit(0);
}
const p = ((pkg.scripts || {}).prepare || "").trim();
if (p === "" || /^(?:npm run|yarn) setup$/.test(p)) {
  console.log("NONE");
  process.exit(0);
}
const m = p.match(/^(.*?)\s*&&\s*(?:npm run|yarn) setup\s*$/);
if (m == null) {
  console.log("FULL");
  process.exit(0);
}
const rest = m[1].trim();
if (rest === "") {
  console.log("NONE");
} else {
  console.log("STRIPPED\n" + rest);
}
'
