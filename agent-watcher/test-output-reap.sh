#!/usr/bin/env bash
# test-output-reap.sh: delete old UI test output from the user temp dir by age.
#
# Two trees grow there with no owner to remove them:
#   edge-flow-runs/<udid>/<run>/     one per xcuitest-run.sh run (build-and-test):
#                                    flow.json, xcodebuild.log, result.xcresult. Runs
#                                    are read while their task is active, so they stay
#                                    --flow-days (default 7). A sim folder left empty
#                                    goes with its last run.
#   maestro_xctestrunner_xcodebuild_output*/
#                                    Maestro's iOS driver output, one per driver start.
#                                    Nothing reads it after the driver exits, so it
#                                    stays --maestro-days (default 2).
#
# Age is the folder's mtime. Any folder a running process holds a file open inside is
# skipped whatever its age. A failed lsof skips the whole pass (exit 1), because the
# in-use check is what makes the age limits safe.
#
# Called on a 6-hourly cadence by session-watchdog.js, detached.
#
# Usage:   test-output-reap.sh [--flow-days <n>] [--maestro-days <n>] [--root <dir>] [--dry-run]
# Output:  one "REAP <folder> (<MB>MB)" or "SKIP <folder> (in use)" line per candidate,
#          then a summary line
# Exit:    0 = done (including nothing to reap), 1 = lsof failed, 2 = usage error

set -euo pipefail

ROOT="$(getconf DARWIN_USER_TEMP_DIR)"
FLOW_DAYS=7
MAESTRO_DAYS=2
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow-days)    FLOW_DAYS="${2:-}"; shift 2 ;;
    --maestro-days) MAESTRO_DAYS="${2:-}"; shift 2 ;;
    --root)         ROOT="${2:-}"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ "$FLOW_DAYS" =~ ^[0-9]+$ && "$MAESTRO_DAYS" =~ ^[0-9]+$ && -n "$ROOT" ]] || {
  echo "usage: test-output-reap.sh [--flow-days <n>] [--maestro-days <n>] [--root <dir>] [--dry-run]" >&2
  exit 2
}
ROOT="${ROOT%/}"
# macOS hands out /var/folders/...; lsof reports the /private/var/folders/... real path.
ROOT="$(cd "$ROOT" && pwd -P)"

CANDIDATES=()
if [[ -d "$ROOT/edge-flow-runs" ]]; then
  while IFS= read -r -d '' d; do CANDIDATES+=("$d"); done \
    < <(find "$ROOT/edge-flow-runs" -mindepth 2 -maxdepth 2 -type d -mtime +"$FLOW_DAYS" -print0)
fi
while IFS= read -r -d '' d; do CANDIDATES+=("$d"); done \
  < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name 'maestro_xctestrunner_xcodebuild_output*' -mtime +"$MAESTRO_DAYS" -print0)

REAPED=0
SKIPPED=0
FREED_MB=0
if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
  # lsof exits 1 when some file could not be reported, which is normal; no output at
  # all is the failure.
  OPEN="$(lsof -Fn 2>/dev/null | sed -n 's/^n//p' | grep -F "$ROOT/" || true)"
  if [[ -z "$(lsof -Fn -p $$ 2>/dev/null)" ]]; then
    echo "test-output-reap: lsof returned nothing; skipping this pass" >&2
    exit 1
  fi
  for d in "${CANDIDATES[@]}"; do
    if [[ -n "$OPEN" ]] && grep -qF "$d/" <<< "$OPEN"; then
      echo "SKIP $d (in use)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    mb=$(( $(du -sk "$d" 2>/dev/null | cut -f1) / 1024 ))
    echo "REAP $d (${mb}MB)"
    if ! $DRY_RUN; then rm -rf -- "$d"; fi
    REAPED=$((REAPED + 1))
    FREED_MB=$((FREED_MB + mb))
  done
fi

if ! $DRY_RUN && [[ -d "$ROOT/edge-flow-runs" ]]; then
  find "$ROOT/edge-flow-runs" -mindepth 1 -maxdepth 1 -type d -empty -delete
fi
echo "test-output-reap: reaped $REAPED folder(s), ${FREED_MB}MB; skipped $SKIPPED in use"
