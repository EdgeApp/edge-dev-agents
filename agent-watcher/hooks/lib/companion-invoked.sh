#!/usr/bin/env node
// companion-invoked.sh — stdin: a Bash tool command string.
// Exit 0 = the command INVOKES a sanctioned companion script (the caller should
// exempt it). Exit 1 = it does not. No stdout.
//
// Why this exists: the gate hooks exempt companion scripts by DIRECTORY, because
// every sanctioned path lives under ~/.cursor/skills or ~/.config/agent-watcher
// and a name list stops covering the next script added there. Matching that
// directory against the WHOLE command string is what this replaces: it exempted
// any command that merely MENTIONED such a path, so `git add .cursor/skills/x &&
// git commit`, and even `git commit --no-verify -m "see ~/.cursor/skills/y"`,
// walked straight through every gate. An exemption that fires on a substring
// anywhere is not an exemption, it is an off switch the model can type by
// accident.
//
// So the path must sit in COMMAND POSITION: first word of a segment, after
// optional VAR=value assignments and wrapper words (env/timeout/nice/time/
// command/exec/bash/sh/sudo). A path in ARGUMENT position (git add <path>,
// cat <path>, a commit message quoting it) is not an invocation and never
// exempts. Same discipline guard-piped-watcher-scripts.sh applies to its own
// matching.
//
// Segment boundaries come from the MENTION-STRIPPED view (strip-cmd-mentions.sh,
// which blanks heredoc bodies and quoted spans while preserving length), so a
// `;` inside a commit message cannot fabricate a segment. The candidate word is
// then read from the RAW text at the same offset, because a legitimate
// invocation is often quoted ("$HOME/.cursor/skills/lint-commit.sh") and the
// stripped view has blanked exactly those characters.
//
// Fail CLOSED: anything unparseable exits 1 (no exemption, the gate still runs).
// A wrongly-withheld exemption costs one blocked call with a message naming the
// sanctioned path; a wrongly-granted one disables the gate silently.

const { spawnSync } = require("child_process");
const path = require("path");

const EXEMPT_DIRS = ["/.cursor/skills/", "/.config/agent-watcher/"];
// Words that precede the real command without being it.
const WRAPPERS = new Set(["env", "timeout", "nice", "time", "command", "exec", "bash", "sh", "sudo", "builtin"]);
// Characters that END a segment in the stripped view. `&&`/`||` fall out of the
// single-character forms; `>`/`<` are redirects and start nothing.
const SEPARATORS = new Set([";", "&", "|", "\n", "(", "{"]);

let raw = "";
try {
  raw = require("fs").readFileSync(0, "utf8");
} catch (e) {
  process.exit(1);
}
if (!raw.trim()) process.exit(1);

// Stripped view, same length as raw. Fail closed if the helper is unavailable:
// without it a quoted mention could pass as a segment start.
let stripped;
try {
  const r = spawnSync(path.join(__dirname, "..", "strip-cmd-mentions.sh"), {
    input: raw,
    encoding: "utf8",
  });
  if (r.status !== 0 || typeof r.stdout !== "string") process.exit(1);
  stripped = r.stdout.replace(/\n$/, "");
} catch (e) {
  process.exit(1);
}
if (stripped.length !== raw.length) {
  // Length skew means the offsets no longer line up and every read below would
  // be from the wrong place.
  process.exit(1);
}

// Segment starts: offset 0, plus every offset following a separator run.
const starts = [0];
for (let i = 0; i < stripped.length; i++) {
  if (SEPARATORS.has(stripped[i])) starts.push(i + 1);
}

const HOME = process.env.HOME || "";

// Read one shell word from raw at `i`, honoring quotes. Returns {word, next}.
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
  s = s.replace(/\$\{HOME\}/g, HOME).replace(/\$HOME/g, HOME);
  return s;
}

for (const start of starts) {
  let i = start;
  // Bounded: a segment cannot be all prefix. Assignments and wrappers are few.
  for (let guard = 0; guard < 12; guard++) {
    const { word, next, empty } = readWord(raw, i);
    if (empty) break;
    // VAR=value prefix -> keep scanning.
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(word)) { i = next; continue; }
    const base = word.split("/").pop();
    if (WRAPPERS.has(base)) {
      i = next;
      // `timeout 60` / `timeout 1m`: the duration is not the command.
      if (base === "timeout") {
        const peek = readWord(raw, i);
        if (/^\d+[smhd]?$/.test(peek.word)) i = peek.next;
      }
      continue;
    }
    const norm = normalize(word);
    if (EXEMPT_DIRS.some((d) => norm.includes(d))) process.exit(0);
    break; // first real command word decided this segment
  }
}

process.exit(1);
