#!/usr/bin/env bash
# maestro-cmd.sh -- shared detection of maestro DRIVES in a Bash tool command.
# Source this; do not execute it.
#
# One parser for every hook that gates on "this command drives a device through
# maestro" (require-maestro-device.sh, require-playbook-before-drive.sh), so the
# two gates agree on what a drive is.
#
# A drive is a command SEGMENT (split at ; && || | & and newlines in the
# mention-stripped view) whose command word, after optional VAR=x prefixes and
# timeout/env/nice/time/command/exec/caffeinate wrappers, is:
#   drive     a `maestro` binary (bare or by path) with a driving subcommand
#             (test|record|studio|hierarchy), or a `maestro-runner` binary
#             with one of its driving subcommands (test|hierarchy|screenshot|
#             wda), in the same segment. Global flags may sit between the
#             binary and the subcommand. `maestro --version`, `maestro mcp`,
#             `maestro-runner lint|devices|doctor`, and any command that merely
#             names a maestro path in argument position (ls, cat, grep) are
#             not drives.
#   wrapper   capture-buy-quote.sh, maestro-bench.sh or maestro-mcp-wrapper.sh,
#             which drive the sim themselves.
#
# maestro_cmd_segments <raw-cmd> [stripped-cmd]
#   Prints one line per drive:
#     <kind><TAB><segment-offset><TAB><engine><TAB><platform><TAB><device-word>
#   <engine> is maestro or maestro-runner (maestro for wrappers). <platform> is
#   the raw --platform value, or - when absent (maestro-runner defaults to
#   android without it). <device-word> is the raw text of the first
#   --device/--udid value (quotes kept, for lib/shell-word-resolve.sh), empty
#   when absent or for wrappers; it is LAST so an empty value survives
#   tab-split `read`. Prints nothing when the command drives nothing.

maestro_cmd_segments() {
  node -e '
const [raw, strippedArg] = process.argv.slice(1);
const m = strippedArg && strippedArg.length === raw.length ? strippedArg : raw;
const PREFIX = "^\\s*[({]?\\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*=\\S*|timeout(?:\\s+-\\S+)*\\s+[0-9.]+[smhd]?|env|nice|time|command|exec|caffeinate(?:\\s+-[A-Za-z]+)*)\\s+)*";
const DRIVE = new RegExp(PREFIX + "(?:\\S*/)?(maestro(?:-runner)?)(?=\\s|$)");
const WRAP = new RegExp(PREFIX + "(?:\\S*/)?(?:capture-buy-quote|maestro-bench|maestro-mcp-wrapper)\\.sh(?=\\s|$)");
const SUB = {
  "maestro": /\s(?:test|record|studio|hierarchy)(?:\s|$)/,
  "maestro-runner": /\s(?:test|hierarchy|screenshot|wda)(?:\s|$)/,
};
function topLevel(str, re) {
  // Separators inside $(...) / $((...)) belong to the substitution; a bare
  // ( ... ) subshell group is transparent, so its inner commands still split.
  const hits = [], stack = [];
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    if (c === "(") { stack.push(str[i - 1] === "$" || (stack.length > 0 && stack[stack.length - 1] && str[i - 1] === "(")); continue; }
    if (c === ")") { stack.pop(); continue; }
    if (stack.includes(true)) continue;
    re.lastIndex = i;
    const x = re.exec(str);
    if (x && x.index === i) { hits.push({ index: i, len: x[0].length }); i += x[0].length - 1; }
  }
  return hits;
}
const seps = topLevel(m, /&&|\|\||;|\n|\|&?|(?<![<>])&(?![>&])/y);
let s = 0;
const bounds = [];
for (const x of seps) { bounds.push([s, x.index]); s = x.index + x.len; }
bounds.push([s, m.length]);
for (const [a, b] of bounds) {
  const rawSeg = raw.slice(a, b);
  const head = DRIVE.exec(rawSeg);
  if (head && SUB[head[1]].test(m.slice(a + head[0].length, b))) {
    const dm = /\s--(?:device|udid)(?:=|\s+)("[^"]*"|\x27[^\x27]*\x27|[^\s;&|]+)/.exec(rawSeg);
    const pm = /\s--platform(?:=|\s+)("[^"]*"|\x27[^\x27]*\x27|[^\s;&|]+)/.exec(rawSeg);
    console.log(["drive", a, head[1], pm ? pm[1] : "-", dm ? dm[1] : ""].join("\t"));
  } else if (WRAP.test(rawSeg)) {
    console.log(["wrapper", a, "maestro", "-", ""].join("\t"));
  }
}
' "$1" "${2:-}"
}
