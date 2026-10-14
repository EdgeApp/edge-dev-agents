#!/usr/bin/env node
// cmd-parse.sh: the commands a Bash tool command string runs, for the
// PreToolUse(Bash) hooks. stdin: the RAW command string. A thin front for
// lib/shell-commands.js, which documents what counts as run and the record
// fields.
//
//   cmd-parse.sh [--cwd <dir>]
//       stdout: one JSON object per command, one per line, in order.
//
//   cmd-parse.sh --rest --under <dir>...
//       stdout: the mention-stripped view of the command (same length as the
//       input, see strip-cmd-mentions.sh) with every command that runs a
//       script under one of the path fragments blanked as well. A hook that
//       must not fire on its own sanctioned wrapper matches against this view,
//       so the wrapper is ignored and the rest of the line is still judged.
//
// Exit 0 on success (no commands prints nothing), 1 when the command cannot
// be read, 2 on a usage error. A caller treats 1 as "fall back to the text
// match it had before", never as "nothing runs".

"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const { parse } = require(path.join(__dirname, "lib", "shell-commands.js"));

const argv = process.argv.slice(2);
let cwd = null;
let rest = false;
const dirs = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--cwd") cwd = argv[++i] || null;
  else if (a === "--rest") rest = true;
  else if (a === "--under") { const d = argv[++i]; if (!d) usage(); dirs.push(d); }
  else usage();
}
if (rest !== (dirs.length > 0)) usage();

function usage() {
  process.stderr.write("usage: cmd-parse.sh [--cwd <dir>] | --rest --under <dir>...\n");
  process.exit(2);
}

let raw = "";
try { raw = require("fs").readFileSync(0, "utf8"); } catch (e) { process.exit(1); }

let cmds;
try { cmds = parse(raw, { cwd }); } catch (e) { process.exit(1); }

if (!rest) {
  let out = "";
  for (const c of cmds) out += JSON.stringify(c) + "\n";
  process.stdout.write(out);
  process.exit(0);
}

const r = spawnSync(path.join(__dirname, "strip-cmd-mentions.sh"), { input: raw, encoding: "utf8" });
if (r.status !== 0 || typeof r.stdout !== "string" || r.stdout.length !== raw.length) process.exit(1);
const view = r.stdout.split("");
for (const c of cmds) {
  if (c.start < 0 || !dirs.some((d) => c.path.includes(d))) continue;
  for (let i = c.start; i < c.end && i < view.length; i++) if (view[i] !== "\n") view[i] = " ";
}
process.stdout.write(view.join(""));
