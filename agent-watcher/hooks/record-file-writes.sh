#!/usr/bin/env bash
# record-file-writes.sh -- PreToolUse(Bash) + PostToolUse(Write|Edit|NotebookEdit|Bash).
#
# Records (session, path) for every file a session writes, so a later reader
# (convention-sync's sync-attribution.sh) can say who wrote a file without
# guessing from transcripts. The ledger format, the two vectors, and what each
# one can and cannot see live in lib/write-ledger.sh.
#
# PreToolUse on Bash only drops a stamp file; PostToolUse on Bash records what
# changed under the watched roots since that stamp and removes it. Write, Edit
# and NotebookEdit record their own file_path on PostToolUse, so a denied or
# failed edit is never recorded.
#
# Runs in EVERY session, orchestrated or chat: a sync carries files from both.
# Never blocks and never writes to stdout. Exit 0 always.
set -uo pipefail

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

. "$HOME/.config/agent-watcher/hooks/lib/write-ledger.sh" 2>/dev/null || exit 0

# Unit separator, not tab: tab is IFS whitespace, so empty fields (no agent_id,
# no file_path) would collapse and shift every later field left.
IFS=$'\x1f' read -r EVENT TOOL SESSION AGENT TUID FPATH CMD64 < <(
  printf '%s' "$INPUT" | jq -r '[.hook_event_name // "", .tool_name // "", .session_id // "",
    .agent_id // "", .tool_use_id // "",
    (.tool_input.file_path // .tool_input.notebook_path // ""),
    ((.tool_input.command // "") | @base64)] | join("\u001f")' 2>/dev/null
) || exit 0
[ -n "${SESSION:-}" ] || exit 0

case "$EVENT:$TOOL" in
  PreToolUse:Bash)
    STAMP=$(write_ledger_stamp_path "$SESSION" "$TUID") || exit 0
    mkdir -p "$WRITE_LEDGER_STAMPS" 2>/dev/null && : > "$STAMP"
    ;;
  PostToolUse:Bash)
    STAMP=$(write_ledger_stamp_path "$SESSION" "$TUID") || exit 0
    [ -f "$STAMP" ] || exit 0
    # A file that changed during the window AND is named by the command is this
    # call's write. One that changed but is never named was most likely written
    # by another session while this call ran, so it is kept as a weak row only.
    CMD=$(printf '%s' "${CMD64:-}" | base64 -d 2>/dev/null || true)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$CMD" in
        *"${f##*/}"*) write_ledger_record "$SESSION" "$AGENT" "$f" bash || true ;;
        *)            write_ledger_record "$SESSION" "$AGENT" "$f" bash-window || true ;;
      esac
    done < <(write_ledger_changed_since "$STAMP")
    rm -f "$STAMP"
    write_ledger_prune || true
    ;;
  PostToolUse:Write|PostToolUse:Edit|PostToolUse:NotebookEdit)
    [ -n "${FPATH:-}" ] || exit 0
    write_ledger_record "$SESSION" "$AGENT" "$FPATH" tool || true
    ;;
esac
exit 0
