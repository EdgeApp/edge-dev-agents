#!/usr/bin/env bash
# guard-piped-watcher-scripts.sh — PreToolUse(Bash).
# The agent-watcher helper scripts (update-status.sh, set-tested.sh, log-attempt.sh,
# release-pool-entry.sh, ...) MUST be called BARE. Wrapping one in a `| tail`/`| head`
# pipeline runs it in a subshell that fails its setgid with
# "failed to change group ID: operation not permitted" (exit 1) on this host, so the
# status write silently does not happen and the agent burns retries. The one-shot rule
# `agent-status-on-pending-task` forbids this in prose; this hook enforces it.
#
# REWRITE, don't block (a block costs a full bounce). Per command segment:
#   1. Split the mention-stripped view (heredoc bodies and quoted spans blanked,
#      same length as the raw command) at `;`, `&&`, `||`, and newlines.
#   2. A segment is gated only when an agent-watcher helper *.sh sits in COMMAND
#      position (optionally behind `(`, VAR=x prefixes, timeout/env/nice/time/
#      command/exec, or bash/sh). A reader that merely names the path (cat, sed,
#      grep, ls) is argument position and never fires.
#   3. In a gated segment with a pipe, drop the trailing pipe stages when EVERY
#      downstream stage is head or tail with plain args (watcher stdout is small;
#      the truncation was pointless). Any other downstream stage keeps the block.
#   4. Cuts are made on the RAW command at the stripped view's offsets, so quoted
#      args and heredoc bodies survive byte for byte; the operator that ended the
#      segment is rejoined behind one space (`2>&1 | tail -2 && x` -> `2>&1 && x`).
# The rewrite is idempotent: its output has no piped watcher segment.
#
# SUBSTITUTIONS BLOCK, never rewrite: a watcher helper in any pipe stage inside
# $(...), backticks, or <(...)/>(...) (`X=$(update-status.sh 1 Testing | tail -1)`)
# is found by a small lexer over the RAW command (single quotes and heredoc
# bodies are inert; $(...) and backticks inside double quotes are live, as in
# the shell). The per-segment rewriter above only sees command position at the
# top level, and cutting inside a substitution would change what the outer
# command captures, so the agent gets the block and runs the helper bare.
#
# Gated completion shapes (Complete / --blocked / pr-create) are rewritten like any
# other: parallel PreToolUse decisions merge deny > defer > ask > allow, and every
# hook evaluates the ORIGINAL input, so a completion-judgment deny still wins over
# this hook's allow.
#
# EXCEPTION: a command carrying `--attach-name` keeps the hard block.
# require-clean-run-report.sh also emits updatedInput for attach calls, and two
# rewriters on one call collide (the last one wins, silently dropping the other's
# edit).
#
# No systemMessage: rewrites are silent to the operator (operator ruling
# 2026-08-17: fires per session made this the top chat-noise source). The model
# still gets permissionDecisionReason on every fire.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Cheap prefilter before spawning node.
case "$CMD" in *.config/agent-watcher/*) ;; *) exit 0 ;; esac
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

BLOCK_MSG="BLOCKED: do not pipe an agent-watcher helper script through '| tail' or '| head'. The pipe runs it in a subshell that fails setgid ('failed to change group ID: operation not permitted') and exit-1s, so the write does not happen. Call the script BARE and read its stdout/exit code directly (one-shot rule agent-status-on-pending-task)."

SUBST_MSG="BLOCKED: an agent-watcher helper script is piped inside a command substitution (\$(...), backticks, or <(...)). The pipe runs it in a subshell that fails setgid ('failed to change group ID: operation not permitted') and exit-1s, so the write does not happen. Run the helper bare as its own command (not inside a substitution, no pipe) and read its stdout/exit code directly (one-shot rule agent-status-on-pending-task)."

# Exit 0 + rewritten command on stdout: rewrite applies. Exit 1: nothing piped.
# Exit 3: a piped watcher segment the rewrite cannot make safe.
# Exit 4: a watcher helper piped inside a substitution.
set +e
REWRITTEN=$(node -e '
const [raw, strippedArg] = process.argv.slice(1);
const m = strippedArg.length === raw.length ? strippedArg : raw;
const HEAD = /^\s*[({]?\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|timeout(?:\s+-\S+)*\s+[0-9.]+[smhd]?|env|nice|time|command|exec|bash|sh)\s+)*["\x27]?\S*\.config\/agent-watcher\/(?:hooks\/)?[A-Za-z0-9_.-]+\.sh(?=["\x27\s|;&)]|$)/;
const DOWN = /^\s*(?:head|tail)(?:\s+(?:-[A-Za-z0-9]+|--[a-z-]+(?:=\S+)?|[0-9]+))*\s*\)*\s*$/;
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
// Body spans of every $(...), <(...), >(...) and backtick substitution in the
// raw command, nested ones included: [open, bodyStart, bodyEnd].
function substitutions(str) {
  const subs = [], st = [{ t: "top" }], pending = [];
  for (let i = 0; i < str.length; i++) {
    const f = st[st.length - 1], c = str[i];
    if (c === "\\") { i++; continue; }
    if (f.t === "dq") {
      if (c === "\"") st.pop();
      else if (c === "$" && str[i + 1] === "(") { st.push({ t: "paren", open: i, start: i + 2, depth: 0 }); i++; }
      else if (c === "`") st.push({ t: "bt", open: i, start: i + 1 });
      continue;
    }
    if (f.t === "bt" && c === "`") { subs.push([f.open, f.start, i]); st.pop(); continue; }
    if (c === "\x27") { const j = str.indexOf("\x27", i + 1); if (j < 0) break; i = j; continue; }
    if (c === "\"") { st.push({ t: "dq" }); continue; }
    if (c === "`") { st.push({ t: "bt", open: i, start: i + 1 }); continue; }
    if ((c === "$" || c === "<" || c === ">") && str[i + 1] === "(") { st.push({ t: "paren", open: i, start: i + 2, depth: 0 }); i++; continue; }
    if (c === "<" && str[i + 1] === "<" && str[i + 2] !== "<") {
      const h = /^<<-?\s*(["\x27]?)(\w+)\1/.exec(str.slice(i));
      if (h) { pending.push(h[2]); i += h[0].length - 1; continue; }
    }
    if (c === "\n" && pending.length) {
      let k = i + 1;
      for (const tag of pending) {
        const e = new RegExp("^[ \\t]*" + tag + "[ \\t]*$", "m").exec(str.slice(k));
        k = e ? k + e.index + e[0].length : str.length;
      }
      pending.length = 0;
      i = k - 1;
      continue;
    }
    if (f.t === "paren") {
      if (c === "(") f.depth++;
      else if (c === ")") { if (f.depth) f.depth--; else { subs.push([f.open, f.start, i]); st.pop(); } }
    }
  }
  return subs;
}
for (const [, a, b] of substitutions(raw)) {
  // Blank quoted spans and nested substitutions so their pipes and separators
  // do not count for this body; keep offsets so stages map back onto raw.
  const chars = raw.slice(a, b).split("");
  for (const [o, , e] of substitutions(raw)) {
    if (o >= a && e < b) for (let k = o; k <= e; k++) chars[k - a] = " ";
  }
  const bm = chars.join("").replace(/\x27[^\x27]*\x27|"[^"]*"/g, (q) => " ".repeat(q.length));
  let s0 = 0;
  const segs = [];
  for (const x of bm.matchAll(/&&|\|\||;|\n/g)) { segs.push([s0, x.index]); s0 = x.index + x[0].length; }
  segs.push([s0, bm.length]);
  for (const [sa, sb] of segs) {
    const cuts = [...bm.slice(sa, sb).matchAll(/(?<![>|])\|&?/g)];
    if (!cuts.length) continue;
    let from = sa;
    for (const x of [...cuts.map((y) => ({ at: sa + y.index, len: y[0].length })), { at: sb, len: 0 }]) {
      if (HEAD.test(raw.slice(a + from, a + x.at))) process.exit(4);
      from = x.at + x.len;
    }
  }
}
const seps = topLevel(m, /&&|\|\||;|\n/y);
const bounds = [];
let s = 0;
for (const x of seps) { bounds.push([s, x.index]); s = x.index + x.len; }
bounds.push([s, m.length]);
let out = raw, changed = false;
for (let k = bounds.length - 1; k >= 0; k--) {
  const [a, b] = bounds[k];
  if (!HEAD.test(raw.slice(a, b))) continue;
  const seg = m.slice(a, b);
  const pipes = topLevel(seg, /(?<![>|])\|&?/y).map((x) => ({ index: x.index, 0: seg.substr(x.index, x.len) }));
  if (!pipes.length) continue;
  const stages = [];
  for (let i = 0; i < pipes.length; i++) {
    const from = pipes[i].index + pipes[i][0].length;
    stages.push(seg.slice(from, i + 1 < pipes.length ? pipes[i + 1].index : seg.length));
  }
  if (!stages.every((st) => DOWN.test(st))) process.exit(3);
  const cut = a + pipes[0].index;
  const rest = out.slice(b);
  const glue = rest.length && rest[0] !== "\n" ? " " : "";
  // Keep the closing parens of a ( ... | tail ) subshell group.
  const closers = (stages[stages.length - 1].match(/\)[\s)]*$/) || [""])[0].replace(/\s/g, "");
  out = out.slice(0, cut).replace(/[ \t]+$/, "") + closers + glue + rest;
  changed = true;
}
if (!changed) process.exit(1);
process.stdout.write(out);
' "$CMD" "$CMD_M")
RC=$?
set -e

case "$RC" in
  1) exit 0 ;;
  0)
    if [ -z "$REWRITTEN" ] || [ "$REWRITTEN" = "$CMD" ]; then
      echo "$BLOCK_MSG" >&2
      exit 2
    fi
    case "$CMD" in
      *--attach-name*)
        echo "$BLOCK_MSG (Not auto-rewritten: this command carries --attach-name, whose report gate rewrites the same call.)" >&2
        exit 2
        ;;
    esac
    jq -nc --arg cmd "$REWRITTEN" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: "auto-rewrote piped agent-watcher call to bare (pipe breaks setgid on this host)",
        updatedInput: { command: $cmd }
      }
    }'
    exit 0
    ;;
  3)
    echo "$BLOCK_MSG" >&2
    exit 2
    ;;
  4)
    echo "$SUBST_MSG" >&2
    exit 2
    ;;
  *)
    # node missing or crashed: fail open, as every other infra error in these hooks.
    exit 0
    ;;
esac
