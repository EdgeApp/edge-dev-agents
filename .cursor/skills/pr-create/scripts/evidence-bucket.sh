#!/usr/bin/env bash
# evidence-bucket.sh: put, get, list and delete objects in the orch asset
# bucket, and read or write a PR's evidence manifest there.
#
# Usage:
#   evidence-bucket.sh check
#   evidence-bucket.sh put <file> <key>
#   evidence-bucket.sh get <key> [<out>]
#   evidence-bucket.sh exists <key>
#   evidence-bucket.sh delete <key>
#   evidence-bucket.sh list [<prefix>]
#   evidence-bucket.sh url <key>
#   evidence-bucket.sh manifest-key <owner/repo> <pr>
#   evidence-bucket.sh manifest-get <owner/repo> <pr> [<out>]
#   evidence-bucket.sh manifest-put <owner/repo> <pr> <file>
#
# Every object in the bucket is public by URL. A frame goes through
# evidence-privacy.sh before it is put here; pr-attach-screenshots.sh does that
# for every attach.
#
# Exit codes: 0 ok; 1 bad usage, no config, or a failed request; 4 the object
# does not exist (get, exists, manifest-get). evidence-bucket.js documents the
# config file and the manifest key.

set -euo pipefail
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence-bucket.js" "$@"
