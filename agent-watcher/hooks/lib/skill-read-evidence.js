#!/usr/bin/env node
// skill-read-evidence.js: content-based proof that a skill's CURRENT SKILL.md
// body is in an agent's context. Shared by the skill-read gates (via
// lib/skill-read-gate.sh) and mark-skill-read.sh. Every mode compares what was
// delivered against the file on disk NOW, so a skill edited since delivery
// never counts, and a delivery cut short (Read token cap, compaction's 20k
// invoked_skills cut, a redirected or persisted Bash output) never counts.
//
// The canonical file is ~/.cursor/skills/<name>/SKILL.md (falls back to the
// path actually read when the canonical copy is absent). "Body" is the file
// with its YAML frontmatter removed, trimmed; Claude Code strips frontmatter
// when it injects a skill and substitutes placeholders (see containsBody).
//
// Modes:
//   scan <transcript.jsonl> <skill>...
//     Prints the subset of <skill> whose complete current body is in context,
//     space-separated. Context = the transcript from the LAST top-level
//     compact_boundary line to EOF (whole file when none). Evidence, any of:
//       - a meta user message "Base directory for this skill: .../skills/<name>"
//         (Skill tool delivery and slash-command delivery share this shape)
//         containing the body
//       - an invoked_skills attachment entry for <name> containing the body
//       - a `file` attachment of the SKILL.md containing the body
//       - Read results of the SKILL.md whose lines, checked line by line
//         against disk, together cover every line
//     Exit 0 with the credited list (possibly empty). Exit 3 on any failure
//     that could widen credit (unreadable transcript, an unparsable
//     compact_boundary candidate): callers treat non-zero as "no credit".
//
//   post <key>
//     stdin: a PostToolUse payload (Read or Bash). Prints skills to credit.
//       Read: records the lines this result proved (verified against disk) in
//             /tmp/agent-skill-read-<key>-<skill>.ranges, keyed by a hash of
//             the current file; credits once every line is covered. The state
//             file shares the marker glob, so inject-run-context.sh expires it
//             with the markers at segment and compaction boundaries.
//       Bash: credits a `cat` of the SKILL.md only when the command does not
//             redirect or pipe that output and the tool's stdout (not
//             persisted to a side file) contains the body.
"use strict";
const fs = require("fs");
const os = require("os");
const crypto = require("crypto");

const SKILL_PATH_RE = /(?:^|\/)skills\/([a-z0-9-]+)\/SKILL\.md$/;

function canonicalPath(name) {
  return `${os.homedir()}/.cursor/skills/${name}/SKILL.md`;
}

const diskCache = new Map();
function disk(name, fallbackPath) {
  const key = `${name}\0${fallbackPath || ""}`;
  if (diskCache.has(key)) return diskCache.get(key);
  let p = canonicalPath(name);
  if (!fs.existsSync(p) && fallbackPath && fs.existsSync(fallbackPath)) p = fallbackPath;
  let out = null;
  try {
    const text = fs.readFileSync(p, "utf8");
    const lines = text.split("\n");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    const body = text.replace(/^---\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/, "").trim();
    const hash = crypto.createHash("sha1").update(text).digest("hex");
    // Claude Code substitutes argument and session placeholders ($ARGUMENTS,
    // $ARGUMENTS[N], $N, ${CLAUDE_*}) when it injects a skill, so the body is
    // matched as its literal chunks between placeholders, in order.
    const chunks = body.split(/\$ARGUMENTS(?:\[\d+\])?|\$\d+|\$\{CLAUDE_[A-Z_]+\}/).filter((c) => c.length);
    if (body) out = { path: p, text, lines, body, chunks, hash };
  } catch (e) {
    out = null;
  }
  diskCache.set(key, out);
  return out;
}

// Lines of the current file proven by one Read result object
// ({content, startLine}), as a list of 1-based line numbers.
function provenLines(d, file) {
  if (!file || typeof file.content !== "string") return [];
  const start = Number.isInteger(file.startLine) && file.startLine > 0 ? file.startLine : 1;
  const got = file.content.split("\n");
  const n = Number.isInteger(file.numLines) && file.numLines >= 0 ? Math.min(file.numLines, got.length) : got.length;
  const out = [];
  for (let i = 0; i < n; i++) {
    const ln = start + i;
    if (ln > d.lines.length) break;
    if (got[i] === d.lines[ln - 1]) out.push(ln);
  }
  return out;
}

function containsBody(text, d) {
  if (typeof text !== "string") return false;
  let pos = 0;
  for (const c of d.chunks) {
    const i = text.indexOf(c, pos);
    if (i < 0) return false;
    pos = i + c.length;
  }
  return d.chunks.length > 0;
}

function textOf(message) {
  if (!message) return "";
  const c = message.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter((x) => x && x.type === "text" && typeof x.text === "string").map((x) => x.text).join("\n");
  return "";
}

function scan(transcript, names) {
  const buf = fs.readFileSync(transcript);
  const NL = 10;
  const lineAt = (idx) => {
    const s = buf.lastIndexOf(NL, idx) + 1;
    let e = buf.indexOf(NL, idx);
    if (e < 0) e = buf.length;
    return [s, e];
  };

  // Last top-level compact_boundary. The needle cannot match inside a JSON
  // string value (the quotes would be escaped), but it can match a nested
  // object, so each candidate is parsed and checked at the top level.
  let from = 0;
  const needle = Buffer.from('"compact_boundary"');
  let pos = buf.length;
  while (pos > 0) {
    const hit = buf.lastIndexOf(needle, pos - 1);
    if (hit < 0) break;
    const [s, e] = lineAt(hit);
    let o;
    try {
      o = JSON.parse(buf.toString("utf8", s, e));
    } catch (err) {
      throw new Error(`unparsable compact_boundary candidate at byte ${s}`);
    }
    if (o && o.type === "system" && o.subtype === "compact_boundary") {
      from = e;
      break;
    }
    pos = s;
  }

  const wanted = new Map();
  for (const name of names) {
    const d = disk(name);
    if (d) wanted.set(name, { d, covered: new Set(), ok: false });
  }
  if (!wanted.size) return [];

  // Only lines mentioning skills/<name> (delivery headers, file paths) or an
  // invoked_skills attachment (entries keyed by name) can carry evidence.
  // Collect their offsets, then parse just those lines.
  const starts = new Set();
  for (const needleText of [...[...wanted.keys()].map((n) => `skills/${n}`), '"invoked_skills"']) {
    const nb = Buffer.from(needleText);
    let i = buf.indexOf(nb, from);
    while (i >= 0) {
      const [s, e] = lineAt(i);
      starts.add(s);
      i = buf.indexOf(nb, e);
    }
  }

  for (const s of [...starts].sort((a, b) => a - b)) {
    let e = buf.indexOf(NL, s);
    if (e < 0) e = buf.length;
    let o;
    try {
      o = JSON.parse(buf.toString("utf8", s, e));
    } catch (err) {
      continue; // a partial trailing line can only withhold credit
    }
    if (!o || o.isSidechain === true) continue;

    if (o.type === "user" && o.isMeta === true) {
      const t = textOf(o.message);
      const m = t.match(/^Base directory for this skill: (\S+?)\/?\s*\n/);
      if (m) {
        const name = m[1].split("/").pop();
        const w = wanted.get(name);
        if (w && containsBody(t, w.d)) w.ok = true;
      }
    }

    const att = o.attachment;
    if (o.type === "attachment" && att) {
      if (att.type === "invoked_skills" && Array.isArray(att.skills)) {
        for (const sk of att.skills) {
          if (!sk || typeof sk.content !== "string" || typeof sk.name !== "string") continue;
          const w = wanted.get(sk.name.split(":").pop());
          if (w && containsBody(sk.content, w.d)) w.ok = true;
        }
      } else if (att.type === "file") {
        const f = att.content && att.content.file;
        const fp = (f && f.filePath) || att.filename || "";
        const m = fp.match(SKILL_PATH_RE);
        const w = m && wanted.get(m[1]);
        if (w && f && typeof f.content === "string" && containsBody(f.content, w.d)) w.ok = true;
      }
    }

    const r = o.toolUseResult;
    if (o.type === "user" && r && typeof r === "object" && r.file && typeof r.file.filePath === "string") {
      const m = r.file.filePath.match(SKILL_PATH_RE);
      const w = m && wanted.get(m[1]);
      if (w) for (const ln of provenLines(w.d, r.file)) w.covered.add(ln);
    }
  }

  const out = [];
  for (const [name, w] of wanted) {
    if (w.ok || (w.d.lines.length > 0 && w.covered.size === w.d.lines.length)) out.push(name);
  }
  return out;
}

function post(key) {
  const input = JSON.parse(fs.readFileSync(0, "utf8"));
  const tool = input.tool_name;
  const ti = input.tool_input || {};
  const tr = input.tool_response;
  const out = [];

  if (tool === "Read") {
    const fp = String(ti.file_path || "");
    const m = fp.match(SKILL_PATH_RE);
    if (!m || !tr || typeof tr !== "object" || !tr.file) return out;
    const name = m[1];
    const d = disk(name, fp);
    if (!d) return out;
    const proven = provenLines(d, tr.file);
    if (!proven.length) return out;
    const stateFile = `/tmp/agent-skill-read-${key}-${name}.ranges`;
    let covered = new Set();
    try {
      const st = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      if (st && st.hash === d.hash && Array.isArray(st.lines)) covered = new Set(st.lines);
    } catch (e) {
      // no state yet, or unreadable: start fresh
    }
    for (const ln of proven) covered.add(ln);
    if (covered.size === d.lines.length) out.push(name);
    try {
      fs.writeFileSync(stateFile, JSON.stringify({ hash: d.hash, total: d.lines.length, lines: [...covered].sort((a, b) => a - b) }));
    } catch (e) {
      // state is an optimization; the gate's transcript scan still backfills
    }
    return out;
  }

  if (tool === "Bash") {
    const cmd = String(ti.command || "");
    if (!tr || typeof tr !== "object" || typeof tr.stdout !== "string" || tr.persistedOutputPath) return out;
    // Each command segment (split on ; && || newline) that is a cat of a
    // SKILL.md must leave stdout alone: no pipe, no stdout redirect, no
    // $( ) capture around it.
    for (const seg of cmd.split(/;|&&|\|\||\n/)) {
      const cm = seg.match(/(^|\$\(|\()\s*cat\s[^|]*/);
      if (!cm) continue;
      const names = [...seg.matchAll(/skills\/([a-z0-9-]+)\/SKILL\.md/g)].map((x) => x[1]);
      if (!names.length) continue;
      if (cm[1] === "$(" || /\|/.test(seg) || /(^|[^0-9&<>])>|\b1>|&>/.test(seg.replace(/\b2>(&1|\s*\/dev\/null)/g, ""))) continue;
      for (const name of new Set(names)) {
        const d = disk(name, (seg.match(new RegExp(`\\S*skills/${name}/SKILL\\.md`)) || [])[0]);
        if (d && tr.stdout.includes(d.body)) out.push(name); // cat output is verbatim: no placeholder tolerance
      }
    }
    return [...new Set(out)];
  }
  return out;
}

function main() {
  const [mode, ...args] = process.argv.slice(2);
  if (mode === "scan") {
    const [transcript, ...names] = args;
    if (!transcript || !names.length) process.exit(2);
    process.stdout.write(scan(transcript, names).join(" "));
    return;
  }
  if (mode === "post") {
    if (!args[0]) process.exit(2);
    process.stdout.write(post(args[0]).join(" "));
    return;
  }
  process.exit(2);
}

try {
  main();
} catch (e) {
  process.stderr.write(`skill-read-evidence: ${e.message}\n`);
  process.exit(3);
}
