#!/usr/bin/env bash
# friction-scorecard.sh — zero-LLM trend table of run friction + testing outcomes.
#
# Reads resolve-run manifests (the same `friction` block the process-friction
# eval dimension grades) and prints one row per run: how hard the run ground
# (hook blocks, tool errors, builds, compactions) and what it reached (drives,
# attempt walls/successes, Testing->first-drive delta). Use it between /eval-run
# cohorts to see whether footgun fixes reduce struggle, without spending model
# tokens. Judgment dimensions (proof pixels, report honesty) still need /eval-run.
#
# Usage:
#   friction-scorecard.sh --since 2026-07-01          # enumerate runs via resolve-run
#   friction-scorecard.sh --manifest <file.json>      # pre-resolved manifest array
#
# Output: TSV to stdout (open in any viewer; pipe to `column -t -s$'\t'`).

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SINCE=""; MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)    SINCE="$2";    shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$SINCE" || -n "$MANIFEST" ]] || { echo "Usage: friction-scorecard.sh --since <date> | --manifest <file>" >&2; exit 1; }

JSON=""
if [[ -n "$MANIFEST" ]]; then
  JSON="$(cat "$MANIFEST")"
else
  JSON="$("$DIR/resolve-run.sh" --since "$SINCE")"
fi

echo "$JSON" | jq -r '
  def mins($a; $b): if ($a != null and $b != null)
    then ((($b | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - ($a | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 60 | round)
    else null end;
  ["gid","task","hook_blocks","top_hook","tool_errs","builds","compacts","drives","attempt_walls","attempt_ok","testing_to_drive_min"],
  (.[] |
    (.friction // {}) as $f |
    ($f.hook_blocks.by_hook // {} | to_entries | sort_by(-.value) | .[0] // null) as $top |
    [ .gid,
      (.task_name // "?" | .[0:34]),
      ($f.hook_blocks.total // "-"),
      (if $top then "\($top.key | sub("\\.sh$"; "")):\($top.value)" else "-" end),
      ($f.tool_errors // "-"),
      ($f.build_invocations // "-"),
      ($f.compact_boundaries // "-"),
      ($f.maestro_run_calls // "-"),
      ([.blocking.attempt_log[]? | select(.result | test("^(failed|blocked|loss):"))] | length),
      ([.blocking.attempt_log[]? | select(.result | test("^success"))] | length),
      (mins($f.first_testing_ts; $f.first_maestro_run_ts) // "-")
    ]) | @tsv'
