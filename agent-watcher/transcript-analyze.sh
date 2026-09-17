#!/usr/bin/env node
// transcript-analyze.sh — read Claude Code transcripts without putting them in
// a model's context.
//
// Two subcommands, one parser:
//
//   cost <target> [--since <ISO>]
//       Where a session's tokens went: call count, context curve, compaction
//       count, image-Read positions, and the weighted cost of holding those
//       images vs checking them in a subagent. Output is ~20 lines, so it is
//       safe to run inline with `!` in any session.
//
//   compact-windows <target> [--before N] [--after N] [--out DIR]
//       The slice around every compaction, rendered as readable markdown: the
//       last N turns before the boundary, the summary itself, whatever the
//       SessionStart:compact hook injected, and the first N turns after. This is
//       the input for judging whether a run came back from a compaction with
//       stale or flattened beliefs — a question that needs a model to READ the
//       conversation, which is why this emits files to hand to one rather than
//       printing into the caller's context.
//
// <target> is `--self` (the CALLING session's own transcript, via
// CLAUDE_CODE_SESSION_ID — no lookup, and the only form that works from inside
// the run being analyzed), a session uuid, a transcript path, or --gid
// <task-gid> (resolved through resolve-run.sh).
//
// Cost model: weighted = input-token equivalents, cache read 0.1x, cache write
// 1.25x, output 5x. An image held in context is re-sent as a cache read on every
// later call, so its true cost is its size times the calls REMAINING after it is
// read, which is why `cost` reports position and not just count.
//
// Exit: 0 = ok, 1 = error, 2 = usage.

const fs = require("fs");
const path = require("path");
const readline = require("readline");

const PROJECTS = path.join(process.env.HOME, ".claude", "projects");
const IMG_RE = /\.(png|jpe?g|gif|webp)$/i;

// --- args ---------------------------------------------------------------
const argv = process.argv.slice(2);
const cmd = argv.shift();
if (!cmd || !["cost", "compact-windows"].includes(cmd)) {
  console.error("usage: transcript-analyze.sh <cost|compact-windows> <--self|session-uuid|path|--gid GID> [opts]");
  process.exit(2);
}
let target = "";
const opt = { before: 12, after: 25, out: "", since: "" };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--self") {
    // The run analyzing itself. mtime-guessing would pick a sibling slot's
    // transcript on a box running four at once; the env var is exact.
    target = process.env.CLAUDE_CODE_SESSION_ID || "";
    if (!target) die("--self needs CLAUDE_CODE_SESSION_ID (set inside a Claude Code session)");
  } else if (a === "--gid") target = gidToSession(argv[++i]);
  else if (a === "--before") opt.before = Number(argv[++i]);
  else if (a === "--after") opt.after = Number(argv[++i]);
  else if (a === "--out") opt.out = argv[++i];
  else if (a === "--since") opt.since = argv[++i];
  else target = a;
}
if (!target) {
  console.error("transcript-analyze.sh: no session given (--self, uuid, path, or --gid)");
  process.exit(2);
}

// gid -> transcript goes through resolve-run.sh, which owns this mapping.
// NOT through the orch version stamp: its `session_uuid` is AGENT_SESSION_UUID,
// the orch's own id, which never names a file under ~/.claude/projects.
function gidToSession(gid) {
  const r = require("child_process").spawnSync(
    path.join(process.env.HOME, ".cursor", "skills", "resolve-run", "scripts", "resolve-run.sh"),
    ["--gid", gid],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }
  );
  if (r.status !== 0) die(`resolve-run.sh --gid ${gid} failed: ${(r.stderr || "").trim().slice(0, 300)}`);
  let runs;
  try { runs = JSON.parse(r.stdout); } catch (e) { die(`resolve-run.sh returned non-JSON for gid ${gid}`); }
  const list = Array.isArray(runs) ? runs : [runs];
  // Last run wins: the latest segment is the one worth looking at.
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i] && list[i].transcript) return list[i].transcript;
  }
  die(`no transcript recorded for gid ${gid}`);
}

function die(msg) {
  console.error(`transcript-analyze.sh: ${msg}`);
  process.exit(1);
}

// Session uuids appear upper-cased in some orch state, lower-cased in transcript
// filenames, so match case-insensitively.
function resolveTranscript(t) {
  if (t.includes("/") || t.endsWith(".jsonl")) {
    if (!fs.existsSync(t)) die(`no such transcript: ${t}`);
    return t;
  }
  const want = `${t.toLowerCase()}.jsonl`;
  for (const proj of fs.readdirSync(PROJECTS)) {
    const dir = path.join(PROJECTS, proj);
    if (!fs.statSync(dir).isDirectory()) continue;
    for (const f of fs.readdirSync(dir)) {
      if (f.toLowerCase() === want) return path.join(dir, f);
    }
  }
  die(`no transcript for session ${t} under ${PROJECTS}`);
}

// --- shared parse -------------------------------------------------------
// Assistant rows repeat per content block, so dedupe by message.id: one id is
// one model call, which is the unit both subcommands count.
async function parse(file) {
  const rows = [];
  const seen = new Set();
  let call = 0;
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    let j;
    try { j = JSON.parse(line); } catch (e) { continue; }
    if (j.type === "assistant" && j.message) {
      if (seen.has(j.message.id)) continue;
      seen.add(j.message.id);
      call++;
    }
    rows.push({ call, j });
  }
  return { rows, calls: call };
}

const isCompact = (j) =>
  (j.type === "system" && /compact/i.test(j.subtype || "")) ||
  j.type === "compact_boundary" ||
  /compact_boundary/.test(j.subtype || "");

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const out = [];
  for (const c of content) {
    if (c.type === "text") out.push(c.text || "");
    else if (c.type === "thinking") out.push(`[thinking] ${(c.thinking || "").slice(0, 1200)}`);
    else if (c.type === "tool_use") {
      const inp = JSON.stringify(c.input || {});
      out.push(`-> ${c.name}(${inp.length > 300 ? inp.slice(0, 300) + "..." : inp})`);
    } else if (c.type === "tool_result") {
      out.push(`<- result: ${clip(textOf(c.content) || String(c.content || ""))}`);
    }
  }
  return out.join("\n");
}

// Keep both ends: a build log's failure is at the tail, its command at the head.
function clip(s, head = 500, tail = 250) {
  s = String(s || "");
  if (s.length <= head + tail) return s;
  return `${s.slice(0, head)}\n   ...[${s.length - head - tail} chars omitted]...\n${s.slice(-tail)}`;
}

// --- cost ---------------------------------------------------------------
async function cost(file) {
  const { rows, calls } = await parse(file);
  let maxCtx = 0, compacts = 0, model = "?";
  let wIn = 0, wRead = 0, wWrite = 0, wOut = 0;
  const imgs = [];
  for (const { call, j } of rows) {
    if (isCompact(j)) compacts++;
    if (j.type !== "assistant" || !j.message) continue;
    if (j.message.model) model = j.message.model;
    const u = j.message.usage || {};
    const ctx = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
    if (ctx > maxCtx) maxCtx = ctx;
    wIn += u.input_tokens || 0;
    wRead += (u.cache_read_input_tokens || 0) * 0.1;
    wWrite += (u.cache_creation_input_tokens || 0) * 1.25;
    wOut += (u.output_tokens || 0) * 5;
    for (const c of j.message.content || []) {
      if (c.type === "tool_use" && c.name === "Read" && IMG_RE.test(String(c.input?.file_path || ""))) {
        imgs.push(call);
      }
    }
  }
  const k = (n) => `${Math.round(n / 1000)}k`;
  console.log(`transcript:   ${file}`);
  console.log(`model:        ${model}`);
  console.log(`model calls:  ${calls}`);
  console.log(`max context:  ${k(maxCtx)}`);
  console.log(`compactions:  ${compacts}${compacts === 0 && maxCtx > 250000 ? "   <- never compacted above 250k" : ""}`);
  console.log(`weighted:     ${k(wIn + wRead + wWrite + wOut)}  (in ${k(wIn)} / cacheRead ${k(wRead)} / cacheWrite ${k(wWrite)} / out ${k(wOut)})`);
  if (!imgs.length) { console.log(`image Reads:  0`); return; }
  console.log(`image Reads:  ${imgs.length}`);
  const dec = {};
  for (const at of imgs) dec[Math.min(9, Math.floor((at / calls) * 10))] = (dec[Math.min(9, Math.floor((at / calls) * 10))] || 0) + 1;
  console.log(`position decile (0=start, 9=end):`);
  for (let d = 0; d < 10; d++) {
    const n = dec[d] || 0;
    if (n) console.log(`  ${String(d * 10).padStart(3)}-${d * 10 + 10}%: ${"#".repeat(Math.min(n, 40))} ${n}`);
  }
  // An image read at call N is re-sent on every later call, as a cache read.
  const remaining = imgs.reduce((s, at) => s + (calls - at), 0);
  console.log(`held-in-context cost: ${k(remaining * 2500 * 0.1)} weighted  (${remaining} re-sends x 2500tok x 0.1)`);
  console.log(`per-image subagent:   ${k(imgs.length * 35000)} weighted  (~35k each, ESTIMATE — the sensitive number)`);
  console.log(`one batched subagent: ~${k(15000 * 1.25 + imgs.length * 2500 * 1.25 + imgs.length * imgs.length * 125)} weighted`);
}

// --- compact-windows ----------------------------------------------------
async function compactWindows(file) {
  const { rows, calls } = await parse(file);
  const marks = [];
  rows.forEach((r, i) => { if (isCompact(r.j)) marks.push(i); });
  if (!marks.length) {
    console.log(`no compaction boundaries in ${file} (${calls} calls) — nothing to review`);
    return;
  }
  const outDir = opt.out || path.join(process.env.TMPDIR || "/tmp", `compact-windows-${path.basename(file, ".jsonl").slice(0, 8)}`);
  fs.mkdirSync(outDir, { recursive: true });

  marks.forEach((mi, n) => {
    // Window by MODEL CALLS, not raw rows: rows include tool results and system
    // noise, so a row-count window would land arbitrarily far from the boundary.
    const atCall = rows[mi].call;
    const lo = atCall - opt.before;
    const hi = atCall + opt.after;
    const lines = [];
    lines.push(`# Compaction ${n + 1} of ${marks.length}`);
    lines.push(``);
    lines.push(`Session: ${file}`);
    lines.push(`Boundary at model call ${atCall} of ${calls}. Window: calls ${Math.max(1, lo)} to ${Math.min(calls, hi)}.`);
    lines.push(``);
    lines.push(`Read this asking: after the boundary, does the agent act on anything the`);
    lines.push(`summary flattened or dropped? Tells are a re-stated belief with no fresh`);
    lines.push(`verification, a re-done step that already succeeded, a lost negative`);
    lines.push(`instruction ("do NOT ..."), or an identifier (gid, sha, PR number) that`);
    lines.push(`changes value across the boundary.`);
    lines.push(``);
    for (let i = 0; i < rows.length; i++) {
      const { call, j } = rows[i];
      if (call < lo || call > hi) continue;
      if (i === mi) {
        lines.push(`\n---\n\n## >>> COMPACTION BOUNDARY (call ${call}) <<<\n`);
        lines.push("```");
        lines.push(clip(JSON.stringify(j, null, 1), 4000, 1000));
        lines.push("```\n");
        continue;
      }
      if (j.type === "assistant" && j.message) {
        const t = textOf(j.message.content);
        if (t.trim()) lines.push(`### [call ${call}] assistant\n\n${clip(t, 2500, 500)}\n`);
      } else if (j.type === "user" && j.message) {
        const t = textOf(j.message.content);
        if (t.trim()) lines.push(`### [call ${call}] user / tool results\n\n${clip(t, 1800, 400)}\n`);
      } else if (j.type === "system") {
        // SessionStart:compact ground-truth injection lands here. It is the
        // thing most worth checking, so it is never clipped as hard.
        const t = clip(JSON.stringify(j.content || j.message || j, null, 1), 3000, 500);
        lines.push(`### [call ${call}] SYSTEM (${j.subtype || j.type})\n\n\`\`\`\n${t}\n\`\`\`\n`);
      }
    }
    const f = path.join(outDir, `compaction-${String(n + 1).padStart(2, "0")}.md`);
    fs.writeFileSync(f, lines.join("\n"));
    const kb = Math.round(fs.statSync(f).size / 1024);
    console.log(`${f}  (call ${atCall}/${calls}, ${kb}KB)`);
  });
  console.log(``);
  console.log(`${marks.length} window(s) in ${outDir}`);
  console.log(`Hand these to a model to read. They are markdown, not jsonl, and`);
  console.log(`carry only the turns around each boundary.`);
}

(async () => {
  const file = resolveTranscript(target);
  if (cmd === "cost") await cost(file);
  else await compactWindows(file);
})().catch((e) => die(e.message));
