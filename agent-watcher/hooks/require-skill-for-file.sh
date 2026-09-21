#!/usr/bin/env bash
# require-skill-for-file.sh -- PreToolUse(Write | Edit | Bash).
# Blocks a write to a file whose PATH has an owning skill until that skill's
# body has entered context, delivering the body in the denial (deny-with-body,
# lib/skill-read-gate.sh) so the retry passes with the contract in view.
#
# One table, every gated path. Rows are PATH GLOBS, so a row covers a whole
# tree and the next file added to it is gated on arrival, rather than waiting
# for someone to notice a name is missing. Add a row rather than a new hook
# pair; the marker scheme, vectors, and delivery are shared with the script gate
# (require-skill-read-for-scripts.sh) and the prose gate (lint-md-on-write.sh).
#   pattern                       skill      scope
#   */AGENTS.md                   agents-md  all   (an AGENTS.md taxes every
#                                                   future session of its repo,
#                                                   so an interactive careless
#                                                   draft costs as much as an
#                                                   orch one)
#   */CHANGELOG.md                changelog  orch  (the verbose entries come
#                                                   from agents; an operator
#                                                   typing a line by hand should
#                                                   not eat a skill body)
#   */.cursor/skills/*/SKILL.md   author     all   \
#   */.cursor/rules/*.mdc         author     all    | the workflow itself: a
#   */.cursor/skills/*.sh         author     all    | skill, rule, companion
#   */.config/agent-watcher/*.sh  author     all    | script, hook (site-orch's
#   */.config/agent-watcher/*.js  author     all    | tenant hooks included), or
#   */git/site-orch/hooks/*.sh    author     all    | the hook REGISTRATIONS, where
#   */.claude/settings.json       author     all   /  a missing or wrong entry
#                                                     means a hook never fires,
#                                                     with no error. Editing
#                                                     one without the authoring
#                                                     contract in context is how
#                                                     duplicated helpers, prose
#                                                     a mechanism already
#                                                     enforces, and unswept
#                                                     renames get in. `all`
#                                                     because an operator edit
#                                                     drifts the workflow the
#                                                     same as an orch one.
#
# Vectors: Write/Edit by file_path; Bash by redirect, tee, sed -i, perl -pi
# (lib/md-write-target.sh). Reads of the file are never blocked.
#
# Key: AGENT_TASK_GID in orch runs; sess-<session_id> for all-scope rows in
# interactive sessions (mark-skill-read.sh writes the same key there). A
# marker lasts the run segment (inject-run-context.sh expires gid markers at
# segment and compaction boundaries) or the interactive session. On the
# would-block path the transcript is scanned for proof the current body is
# already in context (skill_read_credit_from_transcript: slash-command
# delivery, post-compaction re-injection, paged Reads), which writes the
# marker and allows.
#
# No escape hatch: the denial is the remedy, one round trip, so a loop only
# occurs if the agent refuses the body. Exit 0 allow, exit 2 block.
set -uo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in Write|Edit|Bash) ;; *) exit 0 ;; esac

LIB="$HOME/.config/agent-watcher/hooks/lib"
[ -f "$LIB/skill-read-gate.sh" ] && [ -f "$LIB/md-write-target.sh" ] || exit 0
. "$LIB/skill-read-gate.sh"
. "$LIB/md-write-target.sh"

# path-glob:skill:scope
TABLE="*/AGENTS.md:agents-md:all
*/CHANGELOG.md:changelog:orch
*/.cursor/skills/*/SKILL.md:author:all
*/.cursor/rules/*.mdc:author:all
*/.cursor/skills/*.sh:author:all
*/.config/agent-watcher/*.sh:author:all
*/.config/agent-watcher/*.js:author:all
*/git/site-orch/hooks/*.sh:author:all
*/.claude/settings.json:author:all"

# What the Bash vector searches the command for, derived from the table so a new
# row needs no second edit: a pattern ending in a literal name probes that name,
# one ending in a glob probes its extension (bash_write_target takes either).
PROBES=""
while IFS=: read -r _pat _ _; do
  [ -n "$_pat" ] || continue
  _tail="${_pat##*/}"
  case "$_tail" in
    *\**) _probe="${_tail##*.}" ;;
    *)     _probe="$_tail" ;;
  esac
  case " $PROBES " in *" $_probe "*) ;; *) PROBES="$PROBES $_probe" ;; esac
done <<< "$TABLE"

# Glob-match a resolved path against the table. Lowercased on both sides so
# agents.md / Agents.md gate the same and a case-insensitive volume cannot
# smuggle an edit past a row.
match_row() {
  local t p pat skill scope
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS=: read -r pat skill scope; do
    [ -n "$pat" ] || continue
    p=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
    # shellcheck disable=SC2254 -- glob match is the point
    case "$t" in $p) SKILL="$skill"; SCOPE="$scope"; return 0 ;; esac
  done <<< "$TABLE"
  return 1
}

TARGET=""
case "$TOOL" in
  Write|Edit)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    [ -n "$CMD" ] || exit 0
    # Mention-stripped view: a heredoc or echo that merely quotes the file name
    # is not a write to it. Fail-open to the raw command if the helper is gone.
    CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
    # 'all' mode, then keep the first target the table claims: one command can
    # write an ungated file and a gated one, and stopping at the command's first
    # write would clear it on the strength of the ungated path.
    for probe in $PROBES; do
      HITS=$(bash_write_target "$CMD_M" "$CWD" "$probe" "$CMD" all)
      # Inline interpreter writes hide the path in the script body (see
      # md-write-target.sh); retry on the raw command for that vector only.
      if [ -z "$HITS" ] && printf '%s' "$CMD_M" | grep -qE "(^|[[:space:]|;&(])(python3?|node)[[:space:]]+(-[[:space:]]*<<|-c[[:space:]]|-e[[:space:]])"; then
        HITS=$(bash_write_target "$CMD" "$CWD" "$probe" "$CMD" all)
      fi
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        if match_row "$hit"; then TARGET="$hit"; break; fi
      done <<< "$HITS"
      [ -n "$TARGET" ] && break
    done
    ;;
esac
[ -n "$TARGET" ] || exit 0

SKILL="" SCOPE=""
match_row "$TARGET" || exit 0

if [ -n "${AGENT_TASK_GID:-}" ]; then
  export SKILL_READ_KEY="$AGENT_TASK_GID"
elif [ "$SCOPE" = "all" ]; then
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  [ -n "$SID" ] || exit 0
  export SKILL_READ_KEY="sess-$SID"
else
  exit 0
fi

[ -n "$(skill_read_missing "$SKILL")" ] || exit 0
skill_read_credit_from_transcript "$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)" "$SKILL"
[ -n "$(skill_read_missing "$SKILL")" ] || exit 0
{
  echo "BLOCKED: $TARGET is owned by the \`$SKILL\` skill and its contract has not entered this session's context yet. The full skill is below; it now counts as read. Apply it, then retry the write (the retry passes this gate)."
  skill_read_deliver "$SKILL"
} >&2
exit 2
