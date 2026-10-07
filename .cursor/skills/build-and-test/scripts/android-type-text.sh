#!/usr/bin/env bash
# android-type-text.sh — Type text into the focused field on an Android emulator,
# one character per `adb shell input text` call.
#
# A single `input text <string>` call drops characters on a screen whose UI
# thread never goes idle (the Edge password modal); one call per character
# does not. The same screens hang `uiautomator dump` and maestro `tapOn`, so
# focus the field first with `adb shell input tap <x> <y>` (coordinates from a
# screencap or an earlier dump), then call this.
#
# Usage:
#   android-type-text.sh --serial <emulator-NNNN> --env <VAR>
#   android-type-text.sh --serial <emulator-NNNN> --text <literal>
#
#   --env:  name of an environment variable holding the text. Use this for
#           passwords and PINs so the value stays out of the command line the
#           transcript records.
#   --text: literal text (non-secret values only).
#   --delay: seconds between characters (default 0.05).
#
# Output: `TYPED: <n> chars` on stdout (never the text).
# Exit codes: 0 = every character sent; 1 = error (bad args, adb failure).

set -euo pipefail

SERIAL=""
VAR=""
TEXT=""
HAVE_TEXT=false
DELAY="0.05"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --env)    VAR="$2";    shift 2 ;;
    --text)   TEXT="$2"; HAVE_TEXT=true; shift 2 ;;
    --delay)  DELAY="$2";  shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$SERIAL" ]] || { echo "--serial is required" >&2; exit 1; }
if [[ -n "$VAR" ]]; then
  [[ -n "${!VAR+x}" ]] || { echo "env var $VAR is not set" >&2; exit 1; }
  TEXT="${!VAR}"
elif [[ "$HAVE_TEXT" != true ]]; then
  echo "pass --env <VAR> or --text <literal>" >&2; exit 1
fi

ADB="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
[[ -n "$ADB" ]] || { echo "adb not found (set ANDROID_HOME)" >&2; exit 1; }

n=0
for (( i = 0; i < ${#TEXT}; i++ )); do
  c="${TEXT:i:1}"
  # `input text` reads %s as a space; adb shell re-parses the argument on the
  # device, so every other character goes in single quotes ('\'' for a quote).
  case "$c" in
    ' ') arg='%s' ;;
    "'") arg="\"'\"" ;;
    *)   arg="'$c'" ;;
  esac
  "$ADB" -s "$SERIAL" shell input text "$arg" || { echo "android-type-text: adb failed at char $((i + 1))" >&2; exit 1; }
  n=$((n + 1))
  sleep "$DELAY"
done
echo "TYPED: $n chars"
