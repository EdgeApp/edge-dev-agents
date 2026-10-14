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
// The reading of the command line is lib/shell-commands.js, the same one
// cmd-parse.sh prints, so this helper and the gates that read commands
// directly cannot disagree about what a line runs.
//
// Exit 1 means "not established as executing", including every parse failure.
// Callers choose which direction that is safe in: a gate that FIRES on exit 0
// stays quiet, an exemption that is GRANTED on exit 0 is withheld and the gate
// still runs. Nothing here decides that for them.
//
// The text handed to `bash -c "..."` or `sh -c '...'` is read as commands
// when it is written in the line; `eval` text is not.

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

const HOME = process.env.HOME || "";
let cmds;
try {
  cmds = require(path.join(__dirname, "lib", "shell-commands.js")).parse(raw);
} catch (e) {
  process.exit(1);
}

for (const c of cmds) {
  if (c.opaque) continue;
  // An unassigned $HOME is expanded from the environment by the parser; the
  // replace covers a line that reassigns it.
  const p = c.path.replace(/\$\{HOME\}/g, HOME).replace(/\$HOME/g, HOME);
  if (NAMES.length && NAMES.includes(p.split("/").pop())) process.exit(0);
  if (DIRS.some((d) => p.includes(d))) process.exit(0);
}

process.exit(1);
