#!/usr/bin/env bash
# write-ledger.sh -- shared record of WHICH SESSION WROTE WHICH FILE, taken as
# the write happens. Source this; do not execute it.
#
# WHY A LEDGER AND NOT THE TRANSCRIPTS. A transcript shows that a session NAMED a
# path, never that it wrote it: `file_path` is the Read parameter as much as the
# Edit one, a Bash command that contains a path may only have read it, and a
# write made by an inline interpreter (python3 heredoc, node -e) often carries no
# path in any tool input at all. The hook input at write time has none of that
# ambiguity: it names the session, and the filesystem names the file.
#
# Two vectors, recorded with different confidence in `via`:
#   tool   Write / Edit / NotebookEdit. The path is the tool's own file_path.
#   bash   A file a Bash call changed under WRITE_LEDGER_ROOTS (found by mtime
#          against a stamp taken just before the command ran) whose basename the
#          command text also carries. That sees every shell write form (redirect,
#          sed -i, tee, interpreter heredoc) without parsing the command.
#   bash-window  Changed during the call but never named by it. A long-running
#          call (a wait loop, a test suite) overlaps every other session's
#          writes, so on its own this says almost nothing. It exists for the one
#          real case, a script that writes a file the command does not name, and
#          a reader uses it only when the file has no `tool` or `bash` row.
# A run_in_background command returns before it writes, so its writes are not
# recorded. Writes by anything that is not a Claude tool call (an editor, a
# launchd job) are not recorded either; a reader detects that case as a file
# whose mtime no row accounts for.
#
# Ledger: JSONL at the agent-watcher state dir, one object per write:
#   {"ts":<epoch>,"session":"<uuid>","agent":"<subagent id or empty>",
#    "path":"<abs>","via":"tool|bash|bash-window"}
# `session` is the hook input's session_id, which for a subagent's tool call is
# the PARENT session, so delegated edits land on the session that owns the work.
# Machine-local state: never synced, and a box without it just has no rows.
#
# Every function fails by returning non-zero and printing nothing.

WRITE_LEDGER_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
WRITE_LEDGER="${AGENT_WRITE_LEDGER:-$WRITE_LEDGER_DIR/write-ledger.jsonl}"
WRITE_LEDGER_STAMPS="${AGENT_WRITE_LEDGER_STAMPS:-$WRITE_LEDGER_DIR/write-ledger-stamps}"
WRITE_LEDGER_TTL="${AGENT_WRITE_LEDGER_TTL:-5184000}"   # 60 days
WRITE_LEDGER_MAX_BYTES="${AGENT_WRITE_LEDGER_MAX_BYTES:-8388608}"

# The trees the bash vector watches: what convention-sync carries, which is the
# only place attribution is asked for. The tool vector is not limited to these.
WRITE_LEDGER_ROOTS="${AGENT_WRITE_LEDGER_ROOTS:-$HOME/.cursor/skills
$HOME/.cursor/rules
$HOME/.cursor/README.md
$HOME/.config/agent-watcher
$HOME/.claude/workflows
$HOME/.claude/memory-shared}"

# write_ledger_record <session> <agent> <abs-path> <tool|bash>
write_ledger_record() {
  [ -n "${1:-}" ] && [ -n "${3:-}" ] || return 1
  mkdir -p "$WRITE_LEDGER_DIR" 2>/dev/null || return 1
  jq -cn --argjson ts "$(date +%s)" --arg s "$1" --arg a "${2:-}" --arg p "$3" --arg v "${4:-tool}" \
    '{ts:$ts, session:$s, agent:$a, path:$p, via:$v}' >> "$WRITE_LEDGER" 2>/dev/null || return 1
}

# write_ledger_stamp_path <session> <tool-use-id>
#   One stamp per Bash call, so parallel calls in one session keep separate
#   windows. Ids are reduced to filename-safe characters.
write_ledger_stamp_path() {
  local s t
  s=$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_-')
  t=$(printf '%s' "${2:-none}" | tr -cd 'A-Za-z0-9_-')
  [ -n "$s" ] || return 1
  printf '%s/%s.%s\n' "$WRITE_LEDGER_STAMPS" "$s" "$t"
}

# write_ledger_changed_since <stamp-file>
#   Regular files under the roots modified after the stamp. node_modules, VCS
#   dirs, logs and skills/synced (a plugin manifest a daemon rewrites every few
#   minutes) are never authored work.
write_ledger_changed_since() {
  [ -f "${1:-}" ] || return 1
  local root
  while IFS= read -r root; do
    [ -e "$root" ] || continue
    find "$root" \( -name node_modules -o -name .git -o -path '*/skills/synced' \) -prune -o \
      -type f -newer "$1" ! -name '*.log' ! -name '*.pyc' ! -name '.DS_Store' -print 2>/dev/null
  done <<< "$WRITE_LEDGER_ROOTS"
}

# write_ledger_prune
#   Drop rows past the TTL once the file outgrows its cap, and clear stamps whose
#   PostToolUse never came (a killed session). Called by the hook on the rare
#   path only, so the common write stays a single append.
write_ledger_prune() {
  local size cutoff
  size=$(stat -f %z "$WRITE_LEDGER" 2>/dev/null || echo 0)
  [ "$size" -gt "$WRITE_LEDGER_MAX_BYTES" ] || return 0
  cutoff=$(( $(date +%s) - WRITE_LEDGER_TTL ))
  jq -c --argjson c "$cutoff" 'select(.ts >= $c)' "$WRITE_LEDGER" > "$WRITE_LEDGER.tmp" 2>/dev/null \
    && mv "$WRITE_LEDGER.tmp" "$WRITE_LEDGER"
  find "$WRITE_LEDGER_STAMPS" -type f -mmin +1440 -delete 2>/dev/null || true
}
