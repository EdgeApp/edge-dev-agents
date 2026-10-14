// shell-commands.js: one reading of a Bash tool command string into the
// commands it runs. Every hook that asks "does this command line run X" reads
// the answer from here (through cmd-parse.sh or cmd-executes.sh), so two hooks
// cannot disagree about the same line.
//
//   const { parse } = require("./lib/shell-commands.js")
//   parse(raw, { env, cwd }) -> [ command, ... ]   in the order they appear
//
// A command is one simple command with its prefix removed:
//   name    basename of the program word, e.g. "git"
//   path    the program word itself, with ~ and known variables expanded
//   argv    the words from the program word on, quotes removed, known
//           variables expanded (an unknown $NAME stays as written)
//   words   the same words before expansion
//   redirs  [{ op, target }] the redirections written on the command
//   cwd     the directory in force from an earlier `cd`, or null when none
//           was written or it cannot be read
//   start, end   the span of the command in the input, prefix included;
//           -1 for a command read out of a `bash -c` string
//   nested  true for a command read out of a `bash -c` string
//   opaque  true for a shell whose -c string is not literal text
//   git     for git: { sub, args, dir, noVerify, amend, autosquash }. sub is
//           the real subcommand after the global options (-C <dir>, -c k=v,
//           --git-dir, ...); dir is the -C directory resolved against cwd
//   gh      for gh: { sub, args }, sub being "<group> <verb>" ("pr merge")
//
// The prefix removed ahead of the program word: VAR=value assignments, the
// reserved words that leave the next word in command position (if, then, do,
// !, {, ...), and the wrappers that still run their argument (env, timeout,
// nice, time, command, exec, sudo, nohup, xargs, xcrun, bash <script>, ...).
// `command -v` and `xcrun --find` only print a path, so they yield no command.
//
// What counts as run: a command at the top level, in a chain or pipeline, in a
// subshell or brace group, in $( ), backticks or <( ) even inside double
// quotes, and the text handed to `bash -c` or `sh -c` (zsh, dash, ksh too)
// when that text is written in the command. What does not: text in single
// quotes, in a heredoc body, in a comment, or passed to `eval`.
//
// Known gaps, deliberate: `eval`, a script fed to a shell on stdin, a
// substitution inside a heredoc body, `find -exec`, an alias or function
// defined in the same line, and a program name held in a variable this line
// does not assign.

"use strict";

const path = require("path");

const RESERVED = new Set(["if", "then", "elif", "else", "fi", "while", "until", "do", "done",
                          "!", "{", "}", "coproc"]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
// Wrapper -> { flags taking a separate value }. A wrapper's own options are
// skipped; the first word that is not one of them is the program.
const WRAPPERS = {
  env: { value: ["-u", "-C", "-S", "--unset", "--chdir", "--split-string"], assigns: true },
  timeout: { value: ["-s", "-k", "--signal", "--kill-after"], duration: true },
  gtimeout: { value: ["-s", "-k", "--signal", "--kill-after"], duration: true },
  nice: { value: ["-n", "--adjustment"] },
  ionice: { value: ["-c", "-n", "-p", "--class", "--classdata"] },
  time: { value: ["-o", "-f"] },
  command: { value: [], lookup: ["-v", "-V"] },
  exec: { value: ["-a"] },
  builtin: { value: [] },
  nohup: { value: [] },
  setsid: { value: [] },
  noglob: { value: [] },
  nocorrect: { value: [] },
  unbuffer: { value: [] },
  stdbuf: { value: ["-i", "-o", "-e", "--input", "--output", "--error"] },
  caffeinate: { value: ["-t", "-w"] },
  sudo: { value: ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "--user", "--group"] },
  doas: { value: ["-u", "-C"] },
  arch: { value: ["-e", "-arch"] },
  xargs: { value: ["-n", "-I", "-P", "-L", "-J", "-R", "-S", "-s", "-E", "-d", "-a",
                   "--max-args", "--max-procs", "--replace", "--delimiter", "--arg-file"] },
  xcrun: { value: ["--sdk", "-sdk", "--toolchain", "-toolchain"],
           lookup: ["-f", "--find", "-find", "--show-sdk-path", "--show-sdk-version", "--show-toolchain-path"] },
  source: { plain: true },
  ".": { plain: true },
};
const SHELL_VALUE_OPTS = new Set(["-o", "+o", "-O", "+O", "--rcfile", "--init-file"]);

// git's own options that take a separate value word. --git-dir=<p> and the
// other = forms are one word and fall under "starts with a dash".
const GIT_VALUE_OPTS = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace",
                                "--super-prefix", "--config-env", "--attr-source", "--exec-path"]);
// `git --exec-path` with no = prints a path and takes no value.
const GIT_NO_VALUE = new Set(["--exec-path"]);
// commit options whose value is the next word, so that word is never a flag.
const COMMIT_VALUE_OPTS = new Set(["-m", "-F", "-C", "-c", "-t", "--message", "--file", "--reuse-message",
                                   "--reedit-message", "--template", "--author", "--date", "--fixup",
                                   "--squash", "--cleanup", "--trailer", "--pathspec-from-file"]);
const GH_VALUE_OPTS = new Set(["-R", "--repo", "--hostname"]);

function isName(c) { return c !== undefined && /[A-Za-z0-9_]/.test(c); }

function parse(raw, opts) {
  const o = opts || {};
  const ctx = {
    out: [],
    vars: Object.create(null),
    env: o.env || process.env,
    home: (o.env || process.env).HOME || "",
    depth: 0,
  };
  if (typeof raw !== "string" || !raw) return ctx.out;
  region(raw, 0, raw.length, ctx, { term: null, cwd: o.cwd || null, nested: false });
  return ctx.out;
}

function lookup(ctx, name) {
  if (name in ctx.vars) return ctx.vars[name];
  if (Object.prototype.hasOwnProperty.call(ctx.env, name)) return ctx.env[name];
  return undefined;
}

// Index just past the bracket that closes the one at `i`, quotes honored.
function matching(s, i, stop, open, close) {
  let depth = 0;
  for (let j = i; j < stop; j++) {
    const c = s[j];
    if (c === "\\") { j++; continue; }
    if (c === "'") { const k = s.indexOf("'", j + 1); if (k === -1 || k >= stop) return stop; j = k; continue; }
    if (c === '"') {
      let k = j + 1;
      while (k < stop && s[k] !== '"') { if (s[k] === "\\") k++; k++; }
      j = k; continue;
    }
    if (c === open) depth++;
    else if (c === close) { depth--; if (depth === 0) return j + 1; }
  }
  return stop;
}

// Parse s[i..stop). With st.term === ")" the region ends at the unmatched ")"
// and the index past it is returned.
function region(s, i, stop, ctx, st) {
  if (ctx.depth > 12) return stop;
  ctx.depth++;
  let cwd = st.cwd;
  const cwdStack = [];
  let parenDepth = 0;
  let caseDepth = 0;
  let patPos = false;                 // inside a case, reading a pattern list
  let words = [];
  let redirs = [];
  let cur = null;
  let expectRedir = null;
  let inCond = false;
  const heredocs = [];

  const open = (at) => { if (!cur) cur = { v: "", x: "", s: at, e: at, q0: false, quoted: false, dyn: false }; };
  const add = (v, x) => { cur.v += v; cur.x += x === undefined ? v : x; };
  const endWord = (at) => {
    if (!cur) return;
    cur.e = at;
    if (expectRedir) { redirs.push({ op: expectRedir, target: cur.x, e: at }); expectRedir = null; }
    else {
      words.push(cur);
      if (!cur.quoted && cur.v === "[[" && words.slice(0, -1).every((w) => !w.quoted && RESERVED.has(w.v))) inCond = true;
      else if (inCond && !cur.quoted && cur.v === "]]") inCond = false;
    }
    cur = null;
  };
  const flush = (at) => {
    endWord(at);
    if (words.length) cwd = emit(words, redirs, ctx, cwd, st, (n) => { caseDepth = Math.max(0, caseDepth + n); patPos = n > 0; });
    words = []; redirs = []; expectRedir = null; inCond = false;
  };

  // `$...` at i, inside or outside double quotes. Appends to cur.
  const dollar = (j) => {
    const n = s[j + 1];
    if (n === "(" && s[j + 2] === "(") {
      const k = matching(s, j + 1, stop, "(", ")");
      add(s.slice(j, k)); cur.dyn = true; return k;
    }
    if (n === "(") {
      const k = region(s, j + 2, stop, ctx, { term: ")", cwd, nested: st.nested });
      add(s.slice(j, k)); cur.dyn = true; return k;
    }
    if (n === "{") {
      const k = matching(s, j + 1, stop, "{", "}");
      const inner = s.slice(j + 2, k - 1);
      const val = /^[A-Za-z_][A-Za-z0-9_]*$/.test(inner) ? lookup(ctx, inner) : undefined;
      if (val === undefined) cur.dyn = true;
      add(s.slice(j, k), val === undefined ? s.slice(j, k) : val); return k;
    }
    if (n !== undefined && /[A-Za-z_]/.test(n)) {
      let k = j + 1;
      while (k < stop && isName(s[k])) k++;
      const val = lookup(ctx, s.slice(j + 1, k));
      if (val === undefined) cur.dyn = true;
      add(s.slice(j, k), val === undefined ? s.slice(j, k) : val); return k;
    }
    if (n !== undefined && /[0-9?#@*$!-]/.test(n) && j + 1 < stop) { add(s.slice(j, j + 2)); cur.dyn = true; return j + 2; }
    add("$"); return j + 1;
  };
  const backtick = (j) => {
    let k = j + 1;
    while (k < stop && s[k] !== "`") { if (s[k] === "\\") k++; k++; }
    if (k > stop) k = stop;
    region(s, j + 1, k, ctx, { term: null, cwd, nested: st.nested });
    add(s.slice(j, Math.min(k + 1, stop))); cur.dyn = true;
    return Math.min(k + 1, stop);
  };
  const readHeredocs = (j) => {
    // j is just past a newline. Skip each pending body through its tag line.
    while (heredocs.length) {
      const h = heredocs.shift();
      for (;;) {
        if (j >= stop) return stop;
        let k = s.indexOf("\n", j);
        if (k === -1 || k > stop) k = stop;
        let line = s.slice(j, k);
        if (h.dash) line = line.replace(/^\t+/, "");
        j = Math.min(k + 1, stop);
        if (line === h.tag || line.trim() === h.tag) break;
        if (k === stop) return stop;
      }
    }
    return j;
  };

  while (i < stop) {
    const c = s[i];

    if (c === "\\") {
      if (s[i + 1] === "\n") { i += 2; continue; }
      open(i);
      if (!cur.v) cur.q0 = true;
      if (i + 1 < stop) add(s[i + 1]);
      i += 2; continue;
    }
    if (c === "'") {
      open(i); if (!cur.v) cur.q0 = true; cur.quoted = true;
      let k = s.indexOf("'", i + 1);
      if (k === -1 || k >= stop) k = stop;
      add(s.slice(i + 1, k)); i = Math.min(k + 1, stop); continue;
    }
    if (c === '"') {
      open(i); if (!cur.v) cur.q0 = true; cur.quoted = true;
      i++;
      while (i < stop && s[i] !== '"') {
        const d = s[i];
        if (d === "\\" && i + 1 < stop) {
          const e = s[i + 1];
          if (e === "\n") { i += 2; continue; }
          if (e === '"' || e === "\\" || e === "$" || e === "`") { add(e); i += 2; continue; }
          add(d); i++; continue;
        }
        if (d === "$") { i = dollar(i); continue; }
        if (d === "`") { i = backtick(i); continue; }
        add(d); i++;
      }
      i++; continue;
    }
    if (c === "$") {
      if (s[i + 1] === "'") {
        open(i); if (!cur.v) cur.q0 = true; cur.quoted = true;
        let k = i + 2;
        while (k < stop && s[k] !== "'") { if (s[k] === "\\") k++; k++; }
        add(s.slice(i + 2, Math.min(k, stop))); i = Math.min(k + 1, stop); continue;
      }
      open(i); i = dollar(i); continue;
    }
    if (c === "`") { open(i); i = backtick(i); continue; }

    if (c === " " || c === "\t" || c === "\r") { endWord(i); i++; continue; }
    if (c === "\n") { flush(i); i = readHeredocs(i + 1); continue; }
    if (c === "#" && !cur && !inCond) {
      let k = s.indexOf("\n", i);
      if (k === -1 || k > stop) k = stop;
      i = k; continue;
    }

    if (inCond && (c === "&" || c === "|" || c === "<" || c === ">" || c === "(" || c === ")")) {
      open(i); add(c); i++; continue;
    }

    if (c === "~" && !cur && (s[i + 1] === "/" || i + 1 >= stop || /[\s;&|)]/.test(s[i + 1]))) {
      open(i); add("~", ctx.home || "~"); i++; continue;
    }

    if (c === "<" || c === ">") {
      if (c === "<" && s[i + 1] === "(" || c === ">" && s[i + 1] === "(") {
        open(i);
        const k = region(s, i + 2, stop, ctx, { term: ")", cwd, nested: st.nested });
        add(s.slice(i, k)); cur.dyn = true; i = k; continue;
      }
      // A word of digits right before the operator is a file descriptor.
      if (cur && !cur.quoted && /^[0-9]+$/.test(cur.v)) cur = null; else endWord(i);
      if (c === "<" && s[i + 1] === "<" && s[i + 2] === "<") { expectRedir = "<<<"; i += 3; continue; }
      if (c === "<" && s[i + 1] === "<") {
        let k = i + 2;
        let dash = false;
        if (s[k] === "-") { dash = true; k++; }
        while (k < stop && (s[k] === " " || s[k] === "\t")) k++;
        let tag = "";
        while (k < stop && !/[\s;&|<>()]/.test(s[k])) {
          if (s[k] === "'" || s[k] === '"') {
            const q = s.indexOf(s[k], k + 1);
            if (q === -1 || q >= stop) { tag += s.slice(k + 1, stop); k = stop; break; }
            tag += s.slice(k + 1, q); k = q + 1;
          } else if (s[k] === "\\") { tag += s[k + 1] || ""; k += 2; }
          else { tag += s[k]; k++; }
        }
        if (tag) heredocs.push({ tag, dash });
        i = k; continue;
      }
      let op = c;
      let k = i + 1;
      if (s[k] === ">" && c === ">") { op += ">"; k++; }
      if (s[k] === "&") { op += "&"; k++; }
      else if (s[k] === "|" && c === ">") { op += "|"; k++; }
      else if (s[k] === ">" && c === "<") { op += ">"; k++; }
      expectRedir = op; i = k; continue;
    }
    if (c === "&" && s[i + 1] === ">") {
      endWord(i);
      let k = i + 2;
      if (s[k] === ">") k++;
      expectRedir = "&>"; i = k; continue;
    }

    if (c === "|" && patPos && caseDepth > 0 && !(words[0] && words[0].v === "case")) { endWord(i); i++; continue; }
    if (c === ";" || c === "&" || c === "|") {
      flush(i);
      if (c === ";" && caseDepth > 0 && (s[i + 1] === ";" || s[i + 1] === "&")) patPos = true;
      i++; continue;
    }

    if (c === "(") {
      if (cur) {                       // a=(x y), name(), a glob qualifier
        const k = matching(s, i, stop, "(", ")");
        add(s.slice(i, k)); i = k; continue;
      }
      if (!words.length) {
        if (patPos && caseDepth > 0) { i++; continue; }                          // (pattern)
        if (s[i + 1] === "(") { i = matching(s, i, stop, "(", ")"); continue; }   // (( arithmetic ))
        cwdStack.push(cwd); parenDepth++; i++; continue;
      }
      if (!words[0].quoted && words[0].v === "case") { caseDepth++; patPos = true; words = []; redirs = []; i++; continue; }   // case x in (pat)
      if (words.every(w => !w.quoted && RESERVED.has(w.v)) && s[i + 1] !== "(") {   // do ( ... ), then ( ... )
        words = []; redirs = []; cwdStack.push(cwd); parenDepth++; i++; continue;
      }
      const k = matching(s, i, stop, "(", ")");
      if (/^\(\s*\)$/.test(s.slice(i, k)) && words.length <= 2) { words = []; i = k; continue; }   // name () {
      open(i); add(s.slice(i, k)); cur.dyn = true; endWord(k); i = k; continue;
    }
    if (c === ")") {
      if (parenDepth > 0) { flush(i); parenDepth--; cwd = cwdStack.pop(); i++; continue; }
      endWord(i);
      const first = words[0];
      if (first && !first.quoted && first.v === "case") { caseDepth++; patPos = false; words = []; redirs = []; i++; continue; }
      if (caseDepth > 0 && patPos) { patPos = false; words = []; redirs = []; i++; continue; }     // a case pattern
      flush(i);
      if (st.term === ")") { ctx.depth--; return i + 1; }
      i++; continue;
    }

    open(i); add(c); i++;
  }
  flush(stop);
  ctx.depth--;
  return stop;
}

function isAssign(w) { return !w.q0 && /^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(w.v); }

// Turn one simple command's words into a record, or into nested records for a
// shell -c string. Returns the cwd in force after it.
function emit(words, redirs, ctx, cwd, st, caseDelta) {
  const n = words.length;
  let k = 0;
  // `do X=1`, `then X=1`: the assignment follows a reserved word.
  while (k < n && !words[k].quoted && RESERVED.has(words[k].v) && k + 1 < n && isAssign(words[k + 1])) k++;
  const env = [];
  while (k < n && isAssign(words[k])) { env.push(words[k]); k++; }
  if (k === n) {
    // Assignment only: later words in this line can expand it. An unquoted
    // leading ~ in the value is the home directory, as the shell expands it.
    for (const w of env) {
      const eq = w.v.indexOf("=");
      const name = w.v.slice(0, eq).replace(/\+$/, "");
      let val = w.x.slice(eq + 1);
      if (/^~(\/|$)/.test(w.v.slice(eq + 1)) && /^~(\/|$)/.test(val) && ctx.home) val = ctx.home + val.slice(1);
      if (w.dyn) delete ctx.vars[name]; else ctx.vars[name] = val;
    }
    return cwd;
  }

  const bare = (j) => (j < n && !words[j].quoted ? words[j].v : null);
  let opaqueShell = false;
  for (let guard = 0; guard < 32 && k < n; guard++) {
    const w = bare(k);
    if (w !== null && RESERVED.has(w)) { k++; continue; }
    if (w === "for" || w === "select") return cwd;
    if (w === "case") { caseDelta(1); return cwd; }
    if (w === "esac") { caseDelta(-1); k++; continue; }
    if (w === "function") { k += 2; continue; }
    if (w !== null && /^[A-Za-z_][\w-]*\(\)$/.test(w)) { k++; continue; }

    const base = words[k].x.split("/").pop();
    if (SHELLS.has(base)) {
      let j = k + 1;
      let script = null;
      let noexec = false;                // bash -n: a syntax check runs nothing
      while (j < n) {
        const a = words[j].v;
        if (words[j].quoted || !/^[-+]/.test(a) || a === "-" || a === "--") break;
        if (/^-[A-Za-z]*n/.test(a) && !a.startsWith("--")) noexec = true;
        if (/^-[A-Za-z]*o$/.test(a) && words[j + 1] && words[j + 1].v === "noexec") noexec = true;
        if (/^-[A-Za-z]*c[A-Za-z]*$/.test(a)) { script = words[j + 1] || null; j += 2; break; }
        j += SHELL_VALUE_OPTS.has(a) || /^[-+][A-Za-z]*[oO]$/.test(a) ? 2 : 1;      // -euo pipefail
      }
      if (noexec) break;                 // the shell itself is the command
      if (script) {
        // A literal -c string is read as a script of its own. One that is only
        // an expansion cannot be read; the shell is reported as opaque.
        const literal = script.x.replace(/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\([^)]*\)|`[^`]*`/g, "").trim();
        if (literal) {
          region(script.x, 0, script.x.length, ctx, { term: null, cwd, nested: true });
          return cwd;
        }
        opaqueShell = true;
        break;
      }
      if (j < n && words[j].v === "--") j++;
      if (j >= n) break;                 // a bare shell: itself the command
      k = j; continue;                   // bash <script>: the script is the command
    }
    const wr = Object.prototype.hasOwnProperty.call(WRAPPERS, base) ? WRAPPERS[base] : null;
    if (!wr) break;
    let j = k + 1;
    let isLookup = false;
    if (!wr.plain) {
      while (j < n) {
        const a = words[j].v;
        if (wr.assigns && isAssign(words[j])) { j++; continue; }
        if (words[j].quoted || !/^-/.test(a) || a === "-") { if (a === "-" && wr.assigns) { j++; continue; } break; }
        if (a === "--") { j++; break; }
        if (wr.lookup && wr.lookup.includes(a)) isLookup = true;
        j += wr.value.includes(a) ? 2 : 1;
      }
      if (wr.duration && j < n && /^[0-9.]+[smhd]?$/.test(words[j].v)) j++;
    }
    if (isLookup) return cwd;            // prints a path, runs nothing
    if (j >= n) break;                   // a bare wrapper: itself the command
    k = j;
  }
  if (k >= n) return cwd;

  const cmd = words.slice(k);
  const argv = cmd.map((w) => w.x);
  const rec = {
    name: argv[0].split("/").pop(),
    path: argv[0],
    argv,
    words: cmd.map((w) => w.v),
    redirs: redirs.map((r) => ({ op: r.op, target: r.target })),
    cwd,
    start: st.nested ? -1 : words[0].s,
    end: st.nested ? -1 : Math.max(words[n - 1].e, ...redirs.map((r) => r.e)),
    nested: !!st.nested,
  };
  if (opaqueShell) rec.opaque = true;
  if (rec.name === "git") rec.git = gitInfo(argv, cwd);
  if (rec.name === "gh") rec.gh = ghInfo(argv);
  ctx.out.push(rec);

  if (rec.name === "cd" || rec.name === "pushd") {
    let j = 1;
    while (j < argv.length && /^-[LPe@]+$/.test(argv[j])) j++;
    if (argv[j] === "--") j++;
    return resolveDir(cwd, argv[j] === undefined ? ctx.home : argv[j], cmd[j] && cmd[j].dyn);
  }
  return cwd;
}

// The directory a `cd <target>` or `git -C <target>` lands in, or null when it
// cannot be read from the text.
function resolveDir(cwd, target, dyn) {
  if (dyn || !target || target === "-" || /[$`*?]/.test(target)) return null;
  if (target.startsWith("/")) return path.normalize(target);
  if (!cwd) return null;
  return path.normalize(path.join(cwd, target));
}

function gitInfo(argv, cwd) {
  let i = 1;
  let dir = cwd;
  let sawC = false;
  while (i < argv.length) {
    const a = argv[i];
    if (!a.startsWith("-")) break;
    if (a === "-C") { dir = resolveDir(dir, argv[i + 1], false); sawC = true; i += 2; continue; }
    if (GIT_VALUE_OPTS.has(a) && !GIT_NO_VALUE.has(a)) { i += 2; continue; }
    i++;
  }
  const sub = argv[i] === undefined ? "" : argv[i];
  const args = argv.slice(i + 1);
  const info = { sub, args, dir: sawC ? dir : cwd };
  if (sub === "commit") {
    info.noVerify = false; info.amend = false;
    for (let j = 0; j < args.length; j++) {
      const a = args[j];
      if (a === "--") break;
      if (COMMIT_VALUE_OPTS.has(a)) { j++; continue; }
      if (a === "--no-verify") info.noVerify = true;
      else if (a === "--amend") info.amend = true;
      // A short cluster: -n is --no-verify until a letter that takes a value.
      else if (/^-[A-Za-z]/.test(a) && /^-[^mFCct]*n/.test(a)) info.noVerify = true;
    }
  }
  if (sub === "rebase" || sub === "pull") info.autosquash = args.includes("--autosquash");
  return info;
}

function ghInfo(argv) {
  const pos = [];
  const args = [];
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (pos.length < 2) {
      if (GH_VALUE_OPTS.has(a)) { args.push(a, argv[i + 1]); i++; continue; }
      if (a.startsWith("-")) { args.push(a); continue; }
      pos.push(a); continue;
    }
    args.push(a);
  }
  return { sub: pos.join(" "), args: args.filter((a) => a !== undefined) };
}

module.exports = { parse, gitInfo, ghInfo, resolveDir };
