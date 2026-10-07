#!/usr/bin/env bash
# redirect-settings-writes.sh -- PreToolUse(Write | Edit | Bash).
# Blocks a write to ~/.claude/settings.json that changes a PINNED key (a
# top-level key of ~/.claude/settings.canonical.json: hooks, env, attribution)
# and names the canonical file instead. settings-guard.sh re-applies the
# canonical values on every settings.json change, so a direct edit to a pinned
# key would be reverted within seconds; this denial moves the edit to the file
# that sticks. Writes that leave pinned keys alone (permissions, plugins, model)
# pass.
#
# Vectors: Write (content compared), Edit (replacement applied to the current
# file, then compared), Bash writing settings.json by redirect/tee/sed -i/inline
# interpreter (lib/md-write-target.sh; the result cannot be computed, so any
# Bash write to the file is denied). Every session, orch or interactive: an
# operator edit is reverted the same way. Exit 0 allow, exit 2 block.
set -uo pipefail

SETTINGS="${SG_SETTINGS:-$HOME/.claude/settings.json}"
CANON="${SG_CANON:-$HOME/.claude/settings.canonical.json}"
[ -f "$CANON" ] || exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

deny() {
  echo "BLOCKED: $1 ~/.claude/settings.json is guarded: its pinned keys ($(jq -r 'keys | join(", ")' "$CANON")) are re-applied from ~/.claude/settings.canonical.json on every change by settings-guard.sh, so this edit would be reverted. Make the same edit in ~/.claude/settings.canonical.json; the guard copies it into settings.json within seconds and restarts long-lived sessions so they load it. Keys outside that list (permissions, plugins, model) can still be edited in settings.json directly." >&2
  exit 2
}

case "$TOOL" in
  Write|Edit)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
    FP="${FP/#\~/$HOME}"
    [ "$FP" = "$SETTINGS" ] || exit 0
    printf '%s' "$INPUT" | node -e '
const fs = require("fs")
const [settingsPath, canonPath] = process.argv.slice(1)
const inp = JSON.parse(fs.readFileSync(0, "utf8"))
const canon = JSON.parse(fs.readFileSync(canonPath, "utf8"))
let cur = ""
try { cur = fs.readFileSync(settingsPath, "utf8") } catch {}
let next
const ti = inp.tool_input || {}
if (inp.tool_name === "Write") next = ti.content ?? ""
else {
  const o = ti.old_string ?? "", n = ti.new_string ?? ""
  next = ti.replace_all ? cur.split(o).join(n) : cur.replace(o, () => n)
}
let a, b
try { a = JSON.parse(cur || "{}"); b = JSON.parse(next) } catch { process.exit(0) }
const changed = Object.keys(canon).filter((k) => JSON.stringify(a[k]) !== JSON.stringify(b[k]))
if (changed.length) { console.log(changed.join(", ")); process.exit(3) }
' "$SETTINGS" "$CANON"
    rc=$?
    [ "$rc" = 3 ] && deny "this $TOOL changes a pinned key:"
    exit 0
    ;;
  Bash)
    LIB="$HOME/.config/agent-watcher/hooks/lib"
    [ -f "$LIB/md-write-target.sh" ] || exit 0
    . "$LIB/md-write-target.sh"
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [ -n "$CMD" ] || exit 0
    case "$CMD" in *settings.json*) ;; *) exit 0 ;; esac
    CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
    HITS=$(bash_write_target "$CMD_M" "$CWD" "settings.json" "$CMD" all)
    if [ -z "$HITS" ] && printf '%s' "$CMD_M" | grep -qE "(^|[[:space:]|;&(])(python3?|node)[[:space:]]+(-[[:space:]]*<<|-c[[:space:]]|-e[[:space:]])"; then
      HITS=$(bash_write_target "$CMD" "$CWD" "settings.json" "$CMD" all)
    fi
    while IFS= read -r hit; do
      [ "$hit" = "$SETTINGS" ] && deny "a Bash write to"
    done <<< "$HITS"
    exit 0
    ;;
esac
exit 0
