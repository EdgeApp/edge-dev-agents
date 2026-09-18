#!/usr/bin/env bash
# downscale-phone-screenshots.sh — PreToolUse(Read).
#
# A phone screenshot Read at full size costs ~2,500 tokens and is re-sent on every
# later model call until the next compaction. Half resolution is ~600 and stays
# legible for the UI assertions these frames carry (a fee row, a button state).
# REWRITE, never block: the Read is redirected to a cached half-size copy, so the
# agent needs no knowledge of this and no retry is burned.
#
# PHONE APP ONLY — deliberately not by geometry. site-orch's WEB verify captures
# a mobile-viewport page at 390x844 @2x, which is phone-SHAPED but is a website,
# and websites are explicitly out of scope. Only provenance separates them, and
# it is established two ways, in this order:
#
#   1. The capture ledger (lib/phone-capture-ledger.sh). A PostToolUse hook
#      records where each `simctl io ... screenshot` / `adb exec-out screencap`
#      wrote, so a frame qualifies because a simulator or a device produced it,
#      whatever it was named or whichever directory it landed in. This is what
#      covers ad-hoc working captures and session-scratchpad frames, neither of
#      which has a stable name to list.
#   2. PHONE_SHOT_GLOBS below, for captures the ledger cannot see: a frame
#      written by a tool that names no destination (maestro's own failure
#      screenshots), or one whose path was a variable nothing could resolve.
#
# Both fail CLOSED: a frame that neither establishes is left alone. A PNG nothing
# captured (a design comp, a downloaded asset, a web preview) is in neither, so
# non-sim scratchpad files are untouched. NOT matched, on purpose: /tmp/preview-*
# (site-orch web previews, including the -mobile variant).
#
# Cache: $TMPDIR/agent-shot-half/<basename>-<inode>-<mtime>-<target>.png, so a re-Read of
# the same frame reuses the copy and an edited frame re-renders. Already-cached
# paths pass through, which makes the hook idempotent.
#
# Fails OPEN everywhere: no sips (non-macOS), unreadable file, conversion error,
# or malformed payload all emit nothing and the original Read proceeds.

set -uo pipefail

INPUT=$(cat)

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$FILE" ] || exit 0

case "$FILE" in
  *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG) ;;
  *) exit 0 ;;
esac

CACHE="${TMPDIR:-/tmp}/agent-shot-half"
case "$FILE" in
  "$CACHE"/*) exit 0 ;;   # already a downscaled copy
esac

# /private/tmp and /tmp are the same file; compare one form so neither the globs
# nor the ledger need twin entries.
MATCH="$FILE"
case "$MATCH" in /private/tmp/*) MATCH="${MATCH#/private}" ;; esac

# Every element stays FULLY QUOTED so it remains a literal case-pattern. Leaving a
# `*` unquoted here pathname-expands at assignment time, replacing the pattern
# with whatever files happen to exist, which matches by accident and stops
# matching the moment the directory is empty.
PHONE_SHOT_GLOBS=(
  "/tmp/agent-*"
  "/tmp/probe-*"
  "/tmp/arc-shot*"
  "$HOME/.maestro/tests/*/screenshot-*"
  "$HOME/.config/site-orch/*/verify-*"
)
matched=0
for g in "${PHONE_SHOT_GLOBS[@]}"; do
  # shellcheck disable=SC2053 -- glob match is the point
  case "$MATCH" in $g) matched=1; break ;; esac
done

# Ledger second: it costs a subprocess, the globs cost a string compare.
if [ "$matched" != 1 ]; then
  LEDGER_LIB="$HOME/.config/agent-watcher/hooks/lib/phone-capture-ledger.sh"
  # shellcheck source=lib/phone-capture-ledger.sh
  if [ -r "$LEDGER_LIB" ] && . "$LEDGER_LIB" 2>/dev/null; then
    ledger_says_phone "$FILE" 2>/dev/null && matched=1
  fi
fi
[ "$matched" = 1 ] || exit 0

[ -r "$FILE" ] || exit 0
command -v sips >/dev/null 2>&1 || exit 0

W=$(sips -g pixelWidth "$FILE" 2>/dev/null | awk -F': ' '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$FILE" 2>/dev/null | awk -F': ' '/pixelHeight/{print $2}')
case "$W$H" in ''|*[!0-9]*) exit 0 ;; esac
# SIZE IS SET AGAINST WHAT THE MODEL ACTUALLY SEES, NOT THE FILE. The harness
# already caps a displayed image at HARNESS_CAP px on its long edge, so a
# 1320x2868 frame reaches the model at 921x2000 whatever the file says. Scaling
# the FILE by a ratio is therefore meaningless: half of 2868 is 1434, but half of
# a 5000px original is 2500, which the harness caps straight back to 2000 for
# zero saving.
#
# Token cost tracks pixel AREA, so the target is expressed as a fraction of the
# displayed AREA and converted to a long edge by sqrt. Halving the area (the
# default) means ~71% of each dimension and ~half the tokens, and it lands on the
# same size for every device rather than varying with how far the original
# happened to sit above the cap. A quarter of the area is legible to a model but
# too small to review by eye, which is the reason this is not more aggressive.
#
# AGENT_SHOT_AREA_PCT overrides the fraction; AGENT_SHOT_MAX_EDGE pins the long
# edge outright and skips the computation.
HARNESS_CAP=2000
AREA_PCT=${AGENT_SHOT_AREA_PCT:-25}
MAX=$(( W > H ? W : H ))
SEEN=$(( MAX < HARNESS_CAP ? MAX : HARNESS_CAP ))
if [ -n "${AGENT_SHOT_MAX_EDGE:-}" ]; then
  TARGET=$AGENT_SHOT_MAX_EDGE
else
  # long_edge = seen * sqrt(pct/100), integer-only.
  TARGET=$(awk -v s="$SEEN" -v p="$AREA_PCT" 'BEGIN{printf "%d", s*sqrt(p/100)}')
fi
case "$TARGET" in ''|*[!0-9]*) exit 0 ;; esac
# Never scale UP, and leave small frames alone: below this the text these frames
# are read for stops surviving.
[ "$TARGET" -ge 400 ] || exit 0
[ "$MAX" -gt "$TARGET" ] || exit 0

mkdir -p "$CACHE" 2>/dev/null || exit 0
STAMP=$(stat -f '%i-%m' "$FILE" 2>/dev/null || stat -c '%i-%Y' "$FILE" 2>/dev/null) || exit 0
OUT="$CACHE/$(basename "${FILE%.*}")-$STAMP-$TARGET.png"

if [ ! -s "$OUT" ]; then
  sips -Z "$TARGET" "$FILE" --out "$OUT" >/dev/null 2>&1 || exit 0
  [ -s "$OUT" ] || exit 0
fi

jq -nc --arg p "$OUT" --arg orig "$FILE" --arg dims "${W}x${H}" --arg target "$TARGET" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: { file_path: $p },
    additionalContext: ("Reading a half-resolution copy of \($orig) (\($dims) -> long edge \($target)). Phone screenshots are downscaled on Read to cut context cost; re-Read the original path only if a detail is genuinely illegible.")
  }
}'
exit 0
