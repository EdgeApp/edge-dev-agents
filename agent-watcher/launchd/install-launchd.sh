#!/usr/bin/env bash
# install-launchd.sh — render the launchd job templates in this directory into
# ~/Library/LaunchAgents and (re)load them. The templates are the source of
# truth for every com.jontz.* job; the installed plists are generated output.
#
# Placeholders substituted at render time:
#   __HOME__      the installing user's home directory
#   __NODE_BIN__  the newest nvm node bin dir (node/npm/sfw); jobs that need it
#                 are skipped with a warning when nvm has no node installed
#
# A job whose program path does not exist after rendering (a script this repo
# does not carry, e.g. ~/.bin/config-watch.sh) is rendered but NOT loaded, and
# named in the summary, so a fresh machine never loads a job that fails on start.
#
# Usage:
#   install-launchd.sh [--dry-run] [--only <label>[,<label>...]]
#   --dry-run  render to a temp dir and diff against the installed plists; load nothing
#   --only     restrict to the given labels (with or without the com.jontz. prefix)
# Idempotent: an unchanged, already-loaded job is left alone (no bootout/bootstrap).
# Exit 0 on success, 1 on a render/load error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Library/LaunchAgents"
DRY=false; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=true; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    *) echo "install-launchd: unknown arg $1" >&2; exit 1 ;;
  esac
done

NODE_BIN=""
for d in "$HOME/.nvm/versions/node"/*/bin; do
  [[ -d "$d" ]] || continue
  if [[ -z "$NODE_BIN" ]] || [[ "$(printf '%s\n%s\n' "${NODE_BIN%/bin}" "${d%/bin}" | sort -V | tail -1)" == "${d%/bin}" ]]; then NODE_BIN="$d"; fi
done

wanted() { # label -> 0 if selected
  [[ -z "$ONLY" ]] && return 0
  local l; for l in ${ONLY//,/ }; do [[ "$l" == "$1" || "com.jontz.$l" == "$1" ]] && return 0; done
  return 1
}

UID_NUM=$(id -u)
mkdir -p "$DEST"
TMP=$(mktemp -d)
rc=0; loaded=(); unchanged=(); skipped=(); rendered=()
for tpl in "$HERE"/com.jontz.*.plist; do
  label=$(basename "$tpl" .plist)
  wanted "$label" || continue
  if grep -q '__NODE_BIN__' "$tpl" && [[ -z "$NODE_BIN" ]]; then
    skipped+=("$label (needs nvm node; none installed)"); continue
  fi
  out="$TMP/$label.plist"
  sed -e "s#__NODE_BIN__#$NODE_BIN#g" -e "s#__HOME__#$HOME#g" "$tpl" > "$out"
  if ! plutil -lint "$out" >/dev/null 2>&1; then echo "install-launchd: $label renders to an invalid plist" >&2; rc=1; continue; fi
  prog=$(plutil -extract ProgramArguments json -o - "$out" | jq -r '.[0]')
  # /bin/bash -c "<script>" style: the real program is the last argument
  case "$prog" in /bin/bash|/bin/sh|/usr/bin/env) prog=$(plutil -extract ProgramArguments json -o - "$out" | jq -r '.[-1]' | awk '{print $1}') ;; esac
  if [[ ! -e "$prog" ]]; then
    skipped+=("$label (program missing: $prog)"); rendered+=("$label")
    $DRY || cp "$out" "$DEST/$label.plist"
    continue
  fi
  if $DRY; then
    if [[ -f "$DEST/$label.plist" ]] && diff -q "$out" "$DEST/$label.plist" >/dev/null; then unchanged+=("$label")
    else echo "--- $label (would change):"; diff "$DEST/$label.plist" "$out" 2>/dev/null | head -20 || echo "    (new)"; rendered+=("$label"); fi
    continue
  fi
  if [[ -f "$DEST/$label.plist" ]] && diff -q "$out" "$DEST/$label.plist" >/dev/null && launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
    unchanged+=("$label"); continue
  fi
  cp "$out" "$DEST/$label.plist"
  launchctl bootout "gui/$UID_NUM/$label" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$UID_NUM" "$DEST/$label.plist" 2>/dev/null; then loaded+=("$label")
  else echo "install-launchd: bootstrap failed for $label" >&2; rc=1; fi
done
rm -rf "$TMP"
$DRY && echo "DRY_RUN (nothing loaded)"
[[ ${#loaded[@]} -gt 0 ]] && printf 'LOADED: %s\n' "${loaded[@]}"
[[ ${#rendered[@]} -gt 0 ]] && $DRY && printf 'WOULD_RENDER: %s\n' "${rendered[@]}"
[[ ${#unchanged[@]} -gt 0 ]] && echo "UNCHANGED: ${unchanged[*]}"
[[ ${#skipped[@]} -gt 0 ]] && printf 'SKIPPED: %s\n' "${skipped[@]}"
exit $rc
