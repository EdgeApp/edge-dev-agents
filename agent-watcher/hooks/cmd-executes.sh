#!/usr/bin/env node
// cmd-executes.sh — shared trigger-precision helper for PreToolUse(Bash) hooks.
// stdin: the RAW Bash tool command string. Exit 0 iff the command EXECUTES
// something the caller named; exit 1 iff it does not; exit 2 on usage error.
//
//   cmd-executes.sh <script-basename>...   any of these scripts is executed
//   cmd-executes.sh --under <dir>...       a script under any of these path
//                                          fragments is executed (a whole
//                                          sanctioned tree, so the next script
//                                          added to it is covered on arrival)
//
// EXECUTED means the path sits in COMMAND POSITION: first word of a segment,
// after optional VAR=value assignments and wrapper words that still run the
// program (env, timeout/gtimeout, nice, time, command, exec, bash, sh, sudo,
// builtin, nohup, caffeinate, source, .). `command -v` only prints a path, so
// it is not a wrapper.
//
// A command that merely NAMES the path in ARGUMENT position never counts, and
// both directions of that mistake are expensive:
//   - a gate that fires on a mention blocks read-only work (a grep or sed
//     against the script), which is what a substring match produced across
//     three eval cohorts;
//   - an exemption that fires on a mention is not an exemption but an off
//     switch, since `git add <path> && git commit` then walks through the gate
//     it was meant to face.
// One implementation answers both, so the two cannot drift apart.
//
// Segment boundaries come from the MENTION-STRIPPED view (strip-cmd-mentions.sh
// blanks heredoc bodies and quoted spans while preserving length), so a `;` in
// a commit message cannot fabricate a segment. The candidate word is read from
// the RAW text at the same offset, because a legitimate invocation is often
// quoted ("$HOME/.cursor/skills/lint-commit.sh") and the stripped view has
// blanked exactly those characters.
//
// Exit 1 means "not established as executing", including every parse failure.
// Callers choose which direction that is safe in: a gate that FIRES on exit 0
// stays quiet, an exemption that is GRANTED on exit 0 is withheld and the gate
// still runs. Nothing here decides that for them.
//
// A command hidden inside `bash -c "..."` is not seen: the stripped view blanks
// the quoted program text, which is also why the calling gates cannot match it.

const { spawnSync } = require("child_process");
const path = require("path");

const NAMES = [];
const DIRS = [];
{
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--under") {
      const d = argv[++i];
      if (!d) { process.stderr.write("cmd-executes.sh: --under needs a path fragment\n"); process.exit(2); }
      DIRS.push(d);
    } else {
      NAMES.push(argv[i]);
    }
  }
  if (!NAMES.length && !DIRS.length) {
    process.stderr.write("usage: cmd-executes.sh <script-basename>... | --under <dir>...\n");
    process.exit(2);
  }
}

let raw = "";
try {
  raw = require("fs").readFileSync(0, "utf8");
} catch (e) {
  process.exit(1);
}
if (!raw.trim()) process.exit(1);

// Same length as raw, or the offsets below would read from the wrong place.
let stripped;
try {
  const r = spawnSync(path.join(__dirname, "strip-cmd-mentions.sh"), { input: raw, encoding: "utf8" });
  if (r.status !== 0 || typeof r.stdout !== "string") process.exit(1);
  stripped = r.stdout.replace(/\n$/, "");
} catch (e) {
  process.exit(1);
}
if (stripped.length !== raw.length) process.exit(1);

// `&&` / `||` fall out of the single-character forms; `>` and `<` are redirects
// and start no command.
const SEPARATORS = new Set([";", "&", "|", "\n", "(", "{"]);
const WRAPPERS = new Set(["env", "timeout", "gtimeout", "nice", "time", "command", "exec",
                          "bash", "sh", "sudo", "builtin", "nohup", "caffeinate", "source", "."]);
const HOME = process.env.HOME || "";

const starts = [0];
for (let i = 0; i < stripped.length; i++) {
  if (SEPARATORS.has(stripped[i])) starts.push(i + 1);
}

// One shell word from raw at `i`, honoring quotes.
function readWord(s, i) {
  let out = "";
  while (i < s.length && /\s/.test(s[i])) i++;
  const start = i;
  while (i < s.length && !/\s/.test(s[i])) {
    const c = s[i];
    if (c === '"' || c === "'") {
      const close = s.indexOf(c, i + 1);
      if (close === -1) { out += s.slice(i + 1); i = s.length; break; }
      out += s.slice(i + 1, close);
      i = close + 1;
    } else {
      out += c;
      i++;
    }
  }
  return { word: out, next: i, empty: i === start };
}

function normalize(w) {
  let s = w;
  if (s.startsWith("~/")) s = HOME + s.slice(1);
  return s.replace(/\$\{HOME\}/g, HOME).replace(/\$HOME/g, HOME);
}

function hit(word) {
  const norm = normalize(word);
  if (NAMES.length && NAMES.includes(norm.split("/").pop())) return true;
  return DIRS.some((d) => norm.includes(d));
}

for (const start of starts) {
  let i = start;
  // Bounded: a segment cannot be all prefix. Assignments and wrappers are few.
  for (let guard = 0; guard < 16; guard++) {
    const w = readWord(raw, i);
    if (w.empty) break;
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w.word)) { i = w.next; continue; }

    const base = w.word.split("/").pop();
    if (WRAPPERS.has(base)) {
      i = w.next;
      const peek = readWord(raw, i);
      if (base === "command") {
        if (/^-[vV]$/.test(peek.word)) break;      // a lookup, not a run
        if (peek.word === "-p") i = peek.next;
      } else if (base === "timeout" || base === "gtimeout") {
        let p = peek;
        while (!p.empty && /^-/.test(p.word)) {     // -s SIG, -k DUR, --foreground
          i = p.next;
          if (/^-[sk]$/.test(p.word)) { const a = readWord(raw, i); if (!a.empty) i = a.next; }
          p = readWord(raw, i);
        }
        if (/^[0-9.]+[smhd]?$/.test(p.word)) i = p.next;   // the duration is not the command
      } else if (base === "nice") {
        if (/^-n$/.test(peek.word)) { i = peek.next; const a = readWord(raw, i); if (!a.empty) i = a.next; }
        else if (/^-\d+$/.test(peek.word)) i = peek.next;
      } else if (base === "env") {
        let p = peek;
        while (!p.empty && (/^-/.test(p.word) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(p.word))) {
          i = p.next;
          if (/^-u$/.test(p.word)) { const a = readWord(raw, i); if (!a.empty) i = a.next; }
          p = readWord(raw, i);
        }
      } else if (base === "time") {
        if (peek.word === "-p") i = peek.next;
      }
      continue;
    }

    if (hit(w.word)) process.exit(0);
    break;   // the first real command word decided this segment
  }
}

process.exit(1);
