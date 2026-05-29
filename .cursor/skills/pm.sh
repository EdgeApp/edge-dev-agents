#!/usr/bin/env bash
# pm.sh
# Package-manager dispatcher that auto-detects npm vs yarn from the lockfile
# in the current working directory, so skill scripts can stay PM-agnostic
# while repos migrate between npm and yarn.
#
# Detection (in order):
#   - package-lock.json present → npm
#   - yarn.lock present         → yarn
#   - neither present           → npm (default for new/scratch trees)
#   - both present              → npm (mid-migration repos typically leave
#                                  yarn.lock around until cleanup)
#
# Usage:
#   pm.sh install                        # `npm install --no-audit --no-fund` OR `yarn install --non-interactive`
#   pm.sh run <script> [args...]         # `npm run --silent <script>`        OR `yarn <script>`
#   pm.sh pack                           # `npm pack --silent`                OR `yarn pack --quiet`; prints tarball path
#   pm.sh detect                         # prints "npm" or "yarn"
#   pm.sh lockfile                       # prints "package-lock.json" or "yarn.lock"
#
# Exit codes:
#   0 = success
#   2 = usage error
#   * = forwarded from the underlying npm/yarn command

set -euo pipefail

if [[ -f package-lock.json ]]; then
  PM="npm"
  LOCK="package-lock.json"
elif [[ -f yarn.lock ]]; then
  PM="yarn"
  LOCK="yarn.lock"
else
  PM="npm"
  LOCK="package-lock.json"
fi

case "${1:-}" in
  detect)
    echo "$PM"
    ;;
  lockfile)
    echo "$LOCK"
    ;;
  install)
    shift || true
    if [[ "$PM" == "npm" ]]; then
      exec npm install --no-audit --no-fund "$@"
    else
      exec yarn install --non-interactive "$@"
    fi
    ;;
  run)
    shift
    [[ $# -gt 0 ]] || { echo "pm.sh run: missing script name" >&2; exit 2; }
    if [[ "$PM" == "npm" ]]; then
      exec npm run --silent "$@"
    else
      exec yarn "$@"
    fi
    ;;
  pack)
    # Both managers create the tarball in CWD; print its filename on stdout
    # so callers can pipe/capture without parsing tool-specific output.
    if [[ "$PM" == "npm" ]]; then
      # npm pack writes the filename to stdout (last line with --silent).
      npm pack --silent | tail -n 1
    else
      yarn pack --quiet >/dev/null
      # yarn pack uses the {name}-v{version}.tgz convention.
      node -e 'const p=require("./package.json");process.stdout.write(`${p.name}-v${p.version}.tgz`)'
      echo
    fi
    ;;
  ""|--help|-h)
    sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# //;s/^#//;/^set -euo/d'
    exit 2
    ;;
  *)
    echo "pm.sh: unknown subcommand '$1'" >&2
    echo "Usage: pm.sh {install|run <script>|pack|detect|lockfile}" >&2
    exit 2
    ;;
esac
