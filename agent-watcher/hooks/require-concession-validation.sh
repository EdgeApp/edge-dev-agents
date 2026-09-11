#!/usr/bin/env bash
# SHIM (2026-09-10): the concession gate retired into the completion judge. Sessions
# spawned before the settings.json change still carry this hook path in their
# startup snapshot, so this shim forwards them to the live gate. The original is
# kept at hooks/retired/require-concession-validation.sh for reference.
exec "$(dirname "$0")/require-completion-judgment.sh" "$@"
