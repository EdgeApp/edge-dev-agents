#!/usr/bin/env bash
# record-file-writes.test.sh -- every vector of the write ledger hook against a
# sandbox ledger. Exit 0 all pass, 1 otherwise.
set -uo pipefail
HOOK="$HOME/.config/agent-watcher/hooks/record-file-writes.sh"
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export AGENT_WRITE_LEDGER="$SB/ledger.jsonl" AGENT_WRITE_LEDGER_STAMPS="$SB/stamps" AGENT_WRITE_LEDGER_ROOTS="$SB/root"
mkdir -p "$SB/root/sub/node_modules"; echo old > "$SB/root/old.sh"; sleep 1
FAIL=0
ev() { printf '%s' "$1" | "$HOOK"; }
has() { jq -e --arg s "$1" --arg p "$2" --arg v "$3" 'select(.session==$s and .path==$p and .via==$v)' "$AGENT_WRITE_LEDGER" >/dev/null 2>&1; }
check() { if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
absent() { ! grep -qF "$1" "$AGENT_WRITE_LEDGER" 2>/dev/null; }

ev '{"hook_event_name":"PostToolUse","tool_name":"Edit","session_id":"S1","tool_input":{"file_path":"/x/a.md"}}'
ev '{"hook_event_name":"PostToolUse","tool_name":"Read","session_id":"S1","tool_input":{"file_path":"/x/read.md"}}'
ev '{"hook_event_name":"PostToolUse","tool_name":"Write","session_id":"S2","agent_id":"sub9","tool_input":{"file_path":"/x/b.md"}}'
ev '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"S3","tool_use_id":"tu_1","tool_input":{"command":"x"}}'
ev '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"S5","tool_use_id":"tu_long","tool_input":{"command":"sleep 600"}}'
sleep 1
mkdir -p "$SB/root/skills/synced"; echo m > "$SB/root/skills/synced/manifest.json"
echo new > "$SB/root/sub/new.sh"; echo d > "$SB/root/sub/node_modules/dep.js"; echo l > "$SB/root/run.log"
ev '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"S3","tool_use_id":"tu_1","tool_input":{"command":"cd sub && python3 -c \"open(\\\"new.sh\\\",\\\"w\\\")\""}}'
ev '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"S5","tool_use_id":"tu_long","tool_input":{"command":"sleep 600"}}'
ev '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"S4","tool_use_id":"nostamp","tool_input":{"command":"x"}}'
printf 'garbage' | "$HOOK"; GARBAGE=$?

check "Edit records its file_path"            has S1 /x/a.md tool
check "Read is never a write"                 absent /x/read.md
check "subagent write lands on the session"   has S2 /x/b.md tool
kept() { jq -e 'select(.session=="S2" and .agent=="sub9")' "$AGENT_WRITE_LEDGER" >/dev/null 2>&1; }
check "subagent id is kept"                   kept
check "Bash write found by mtime"             has S3 "$SB/root/sub/new.sh" bash
check "overlapping call that never names the file is weak" has S5 "$SB/root/sub/new.sh" bash-window
check "plugin manifest churn is skipped"      absent manifest.json
check "file older than the stamp is skipped"  absent old.sh
check "node_modules is skipped"               absent dep.js
check "logs are skipped"                      absent run.log
check "Bash without a stamp records nothing"  absent '"S4"'
check "stamp is removed after use"            test -z "$(ls "$SB/stamps")"
check "unparseable input exits 0"             test "$GARBAGE" -eq 0
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || exit 1
