#!/usr/bin/env bash
# evidence-privacy.sh: classify evidence frames as clean, SECRET or USERNAME,
# and write hatched copies. Local only: macOS Vision OCR, no network calls.
#
# The classes are defined by the rule `redact-secrets-before-attach`
# (build-and-test references/drive.md); evidence-privacy.js reads frames
# against it and documents every subcommand and the record format.
#
# Usage:
#   evidence-privacy.sh classify [--roster <json>] [--list <file>] [--explain] [<image>...]
#   evidence-privacy.sh redact   [--roster <json>] <in> <out>
#   evidence-privacy.sh hatch    [--roster <json>] <in> <out> <x,y,w,h>...
#
# The roster defaults to ~/.config/edge-secrets/test-accounts.json
# (EVIDENCE_ROSTER overrides it). The Vision reader is compiled from
# frame-vision.swift on first use into ${XDG_CACHE_HOME:-~/.cache}/agent-evidence,
# keyed by the source hash, so an edited source rebuilds itself.
#
# Exit codes:
#   0  every frame has a verdict (read the class from each JSON record)
#   1  bad usage
#   3  the detector could not run or could not read a frame. Callers refuse
#      to publish: a frame with no verdict is never treated as clean.
#   4  redact refused a SECRET frame and wrote nothing

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${FRAME_VISION:-}" ]]; then
  SRC="$DIR/frame-vision.swift"
  CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-evidence"
  HASH="$(shasum -a 256 "$SRC" | cut -c1-16)" || { echo "evidence-privacy: cannot hash $SRC" >&2; exit 3; }
  FRAME_VISION="$CACHE/frame-vision-$HASH"
  if [[ ! -x "$FRAME_VISION" ]]; then
    mkdir -p "$CACHE"
    BUILD="$FRAME_VISION.build-$$"
    if ! xcrun swiftc -O -swift-version 5 "$SRC" -o "$BUILD" 2> "$BUILD.log"; then
      echo "evidence-privacy: cannot build the Vision reader (needs macOS with the Swift toolchain):" >&2
      tail -5 "$BUILD.log" >&2 || true
      rm -f "$BUILD" "$BUILD.log"
      exit 3
    fi
    rm -f "$BUILD.log"
    # A rename is atomic, so a concurrent run sees the old state or the new.
    mv -f "$BUILD" "$FRAME_VISION"
  fi
fi

export FRAME_VISION
exec node "$DIR/evidence-privacy.js" "$@"
