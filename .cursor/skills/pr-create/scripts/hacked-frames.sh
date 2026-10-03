#!/usr/bin/env bash
# hacked-frames.sh: print which of the given proof-frame paths are HACK-FORCED
# frames, by the ONE naming rule (pr-evidence-table.js parseName: a whole
# `HACKED` token in the slug, never a substring). The report gate, the
# screenshot attach and the completion judge's evidence bundle all ask here.
#
# Usage: hacked-frames.sh <path>...     (missing paths are ignored)
# stdout: one hacked path per line. Exit 0 always (2 on a usage error).
set -uo pipefail
[[ $# -gt 0 ]] || exit 0
exec node -e '
const { parseName } = require(process.argv[1])
const path = require("path")
for (const f of process.argv.slice(2)) if (f && parseName(path.basename(f)).hacked) console.log(f)
' "$(dirname "$0")/pr-evidence-table.js" "$@"
