#!/usr/bin/env bash
# shell-word-resolve.sh -- shared static expansion of one shell WORD taken from
# a Bash tool command string. Source this; do not execute it.
#
# Hooks read argument values out of the command text (maestro --device, the
# target of a '> file.md' redirect). Agents routinely write those values as
# variables: 'U=<udid>' on one line and 'maestro --device $U test' on the next,
# or "$AGENT_SIM_UDID". A hook that takes the literal '$U' misclassifies it (an
# iOS UDID read as an Android serial; a memory-dir path read as a worktree path).
#
# Resolution order for each $VAR / ${VAR} in the word:
#   1. the LAST 'VAR=value' assignment that appears in the command BEFORE the
#      word (plain, export, local, declare; the value itself is resolved the
#      same way, recursively, against the text before ITS assignment)
#   2. the hook's own environment (orch sessions export AGENT_SIM_UDID,
#      AGENT_METRO_PORT, ... to hooks)
# Quoting follows the shell: single quotes are literal, double quotes and bare
# text expand, a leading '~' on bare text becomes $HOME. Nothing is evaluated:
# command substitution, arithmetic, parameter operators (${X:-y}), positional
# and special parameters are UNRESOLVABLE, as is a variable found in neither
# place. Callers decide what unresolvable means (block, or keep the literal).
#
# Assignment positions are found in the mention-stripped view (so a 'U=...'
# line inside a heredoc body is not an assignment) and their values are read
# from the raw command at the same offset (strip-cmd-mentions.sh preserves
# length, so a quoted value blanked in the stripped view is still readable).
#
# resolve_shell_word <word> <raw-cmd> [stripped-cmd] [pos]
#   <pos>: offset of the word in the command; empty = first occurrence of the
#   word in the stripped view (else the raw command), falling back to the end.
#   Prints the expanded word and returns 0; prints nothing and returns 1 when
#   unresolvable.

resolve_shell_word() {
  node -e '
const [word, raw, strippedArg, posArg] = process.argv.slice(1);
const stripped = strippedArg && strippedArg.length === raw.length ? strippedArg : raw;
let pos = posArg === undefined || posArg === "" ? -1 : Number(posArg);
if (pos < 0) { pos = stripped.indexOf(word); if (pos < 0) pos = raw.indexOf(word); if (pos < 0) pos = raw.length; }
const HOME = process.env.HOME || "";
const REF = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;
function expandText(s, end, depth) {
  if (depth > 8) return null;
  if (s.replace(REF, "").includes("$") || s.includes("`")) return null;
  let ok = true;
  const out = s.replace(REF, (_, a, b) => { const v = lookup(a || b, end, depth + 1); if (v === null) ok = false; return v === null ? "" : v; });
  return ok ? out : null;
}
function expandWord(w, end, depth) {
  let out = "", i = 0;
  while (i < w.length) {
    const c = w[i];
    if (c === "\x27") { const j = w.indexOf("\x27", i + 1); if (j < 0) return null; out += w.slice(i + 1, j); i = j + 1; continue; }
    if (c === "\"") { const j = w.indexOf("\"", i + 1); if (j < 0) return null; const e = expandText(w.slice(i + 1, j), end, depth); if (e === null) return null; out += e; i = j + 1; continue; }
    let j = i; while (j < w.length && w[j] !== "\x27" && w[j] !== "\"") j++;
    let bare = w.slice(i, j);
    if (i === 0 && (bare === "~" || bare.startsWith("~/"))) bare = HOME + bare.slice(1);
    const e = expandText(bare, end, depth); if (e === null) return null; out += e; i = j;
  }
  return out;
}
function lookup(name, end, depth) {
  const re = new RegExp("(?:^|[\\s;&|(])(?:(?:export|local|declare(?:\\s+-[A-Za-z]+)?)\\s+)?" + name + "=", "g");
  const hay = stripped.slice(0, end);
  let m, last = null, at = 0;
  while ((m = re.exec(hay))) { at = m.index; last = m.index + m[0].length; }
  if (last !== null) {
    const vm = /^("[^"]*"|\x27[^\x27]*\x27|[^\s;&|)]*)/.exec(raw.slice(last));
    return expandWord(vm ? vm[1] : "", at, depth);
  }
  return Object.prototype.hasOwnProperty.call(process.env, name) ? process.env[name] : null;
}
const r = expandWord(word, pos, 0);
if (r === null) process.exit(1);
process.stdout.write(r);
' "$1" "$2" "${3:-}" "${4:-}"
}
