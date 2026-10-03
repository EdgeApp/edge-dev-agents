#!/usr/bin/env bash
# task-fields.sh: the ONE reading of "the task fields the orch cares about",
# from the registry in asana-config.json (custom_fields.<key>.gid/.name plus
# task_fields.run_params / never_delta; see task_fields._doc there).
#
# Fields are matched by GID, never by name: a multi-homed task also carries
# other boards' fields, two of them named "Status", and a name-keyed read let
# whichever came last win.
#
# task_field_registry               [{gid, name}] for every registered field
# task_field_snapshot  < task.json  {name, completed, <field name>: display_value}
#                                   for an Asana task GET response (.data)
# task_field_deltas <old> <new> [<orch_writes>]
#                                   [{field, was, now, run_param}] between two
#                                   snapshots: registry fields + name/completed
#                                   only, never_delta fields dropped, and a field
#                                   whose new value equals the orch's own last
#                                   write (orch-field-writes ledger, {field:
#                                   [names]}) dropped too
# task_field_line   < task.json     "name=value; ..." for every registered field
#                                   except never_delta (the judge's bundle line)

TF_CONFIG="${TF_CONFIG:-$HOME/.config/agent-watcher/asana-config.json}"

task_field_registry() {
  jq -c '[.custom_fields | to_entries[] | select(.value.gid) | {gid: .value.gid, name: (.value.name // .key)}]' "$TF_CONFIG" 2>/dev/null || echo "[]"
}

_tf_lists() {
  jq -c '{run_params: (.task_fields.run_params // []), never_delta: (.task_fields.never_delta // [])}' "$TF_CONFIG" 2>/dev/null \
    || echo '{"run_params":[],"never_delta":[]}'
}

task_field_snapshot() {
  jq -c --argjson reg "$(task_field_registry)" '
    .data as $t
    | ($reg | map({(.gid): .name}) | add // {}) as $byg
    | {name: $t.name, completed: $t.completed}
      + ([$t.custom_fields[]? | select((.gid | type) == "string" and $byg[.gid] != null) | {($byg[.gid]): (.display_value // null)}] | add // {})'
}

task_field_deltas() {
  local old="$1" new="$2" orch="${3:-}"
  [ -n "$orch" ] || orch='{}'
  jq -nc --argjson old "$old" --argjson new "$new" --argjson orch "$orch" \
    --argjson reg "$(task_field_registry)" --argjson lists "$(_tf_lists)" '
    (["name", "completed"] + [$reg[].name]) as $known
    | [ (($old | keys) + ($new | keys) | unique)[]
        | select(. as $k | $known | index($k))
        | select(. as $k | $lists.never_delta | index($k) | not)
        | select($old[.] != $new[.])
        | select(. as $k | ($orch[$k] != null and ($new[$k] // "" | split(", ") | sort) == $orch[$k]) | not)
        | {field: ., was: $old[.], now: $new[.], run_param: (. as $k | $lists.run_params | index($k) != null)} ]'
}

task_field_line() {
  jq -r --argjson reg "$(task_field_registry)" --argjson lists "$(_tf_lists)" '
    .data as $t
    | [$reg[] | select(.name as $n | $lists.never_delta | index($n) | not)
        | . as $r | ($t.custom_fields[]? | select(.gid == $r.gid)) as $f
        | "\($r.name)=\($f.display_value // "null")"] | join("; ")'
}
