#!/usr/bin/env bash
# judge-log.sh: where the completion judge's provenance log lives, and the ONE
# writer of its operator-override line. Sourced by completion-judge.sh, the
# judge gate (hooks/require-completion-judgment.sh), judge-report-section.sh and
# resolve-run.sh. The log dir default had three copies and resolve-run ignored
# the COMPLETION_JUDGE_LOG_DIR override; the override line had two writers with
# different fields.
#
# judge_log_dir                     the log directory (COMPLETION_JUDGE_LOG_DIR,
#                                   else $XDG_STATE_HOME/agent-watcher/judge)
# judge_log_path <gid>              <dir>/<gid>.jsonl
# judge_log_override <gid> <event> <kind> <source> <directive> [<evidence_hash>] [<comment_at>]
#     Appends {ts, gid, event, evidence_hash, nonce:"override", verdict:"override",
#     override, source, comment_at, directive}. source is "operator waiver" or
#     "operator comment"; directive is cut to 300 chars on one line.

judge_log_dir() {
  printf '%s\n' "${COMPLETION_JUDGE_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/judge}"
}

judge_log_path() { printf '%s/%s.jsonl\n' "$(judge_log_dir)" "$1"; }

judge_log_override() {
  local gid="$1" event="$2" kind="$3" source="$4" directive="$5" hash="${6:-}" at="${7:-}" dir
  dir=$(judge_log_dir); mkdir -p "$dir" 2>/dev/null
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gid "$gid" --arg event "$event" \
    --arg hash "$hash" --arg kind "$kind" --arg source "$source" --arg at "$at" \
    --arg directive "$(printf '%s' "$directive" | head -c 300 | tr '\n' ' ')" \
    '{ts: $ts, gid: $gid, event: $event, evidence_hash: (if $hash == "" then null else $hash end),
      nonce: "override", verdict: "override", override: $kind, source: $source,
      comment_at: (if $at == "" then null else $at end), directive: $directive}' \
    >> "$dir/$gid.jsonl" 2>/dev/null
}
