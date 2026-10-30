#!/usr/bin/env node
// transcript-analyze.sh — read Claude Code transcripts without putting them in
// a model's context.
//
// Three subcommands, one parser:
//
//   cost <target>
//       Where a session's tokens went: call count, context curve, compaction
//       count, image-Read positions, and the weighted cost of holding those
//       images vs checking them in a subagent. Output is ~20 lines, so it is
//       safe to run inline with `!` in any session.
//
//   phases <target> [--since ISO] [--until ISO] [--initial NAME] [--mark NAME=ISO]... [--json]
//       Raw token totals (calls, input, cache read, cache write, output) split by
//       the phase in effect at each call, main transcript plus its subagents
//       (<uuid>/subagents/*.jsonl). Phase boundaries are the session's own
//       `update-status.sh <gid> <Status>` calls; --mark adds a boundary the
//       transcript cannot show (a QA pass's `approved` file), --initial names the
//       phase before the first boundary (default Startup). --since/--until keep
//       only calls in that window, so a resumed session is not counted twice.
//       token-ledger.sh is the caller; --json is its input.
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
if (!cmd || !["cost", "phases", "compact-windows"].includes(cmd)) {
  console.error("usage: transcript-analyze.sh <cost|phases|compact-windows> <--self|session-uuid|path|--gid GID> [opts]");
  process.exit(2);
}
let target = "";
const opt = { before: 12, after: 25, out: "", since: "", until: "", initial: "Startup", marks: [], json: false };
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
  // --since/--until filter `phases` only.
  else if (a === "--since") opt.since = argv[++i];
  else if (a === "--until") opt.until = argv[++i];
  else if (a === "--initial") opt.initial = argv[++i];
  else if (a === "--mark") {
    const m = /^([^=]+)=(.+)$/.exec(argv[++i] || "");
    if (!m || isNaN(Date.parse(m[2]))) die(`--mark wants NAME=ISO-time, got ${argv[i]}`);
    opt.marks.push({ ts: Date.parse(m[2]), phase: m[1] });
  }
  else if (a === "--json") opt.json = true;
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

// --- phases -------------------------------------------------------------
const STATUS_RE = /update-status\.sh\s+\S+\s+(Pending|Planning|Developing|Reviewing|Testing|Complete)\b/;
const zero = () => ({ calls: 0, input: 0, cache_read: 0, cache_write: 0, output: 0 });
function addUsage(b, u) {
  b.calls++;
  b.input += u.input_tokens || 0;
  b.cache_read += u.cache_read_input_tokens || 0;
  b.cache_write += u.cache_creation_input_tokens || 0;
  b.output += u.output_tokens || 0;
}

// One entry per model call, deduped by message.id across the main transcript
// and every subagent file.
async function usageRows(file, seen) {
  const out = [];
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.includes('"assistant"')) continue;
    let j;
    try { j = JSON.parse(line); } catch (e) { continue; }
    if (j.type !== "assistant" || !j.message) continue;
    let status = null;
    for (const c of j.message.content || []) {
      if (c.type === "tool_use" && c.name === "Bash") {
        const m = STATUS_RE.exec(String(c.input?.command || ""));
        if (m) status = m[1];
      }
    }
    const id = j.message.id;
    // A status write can sit in a later content-block row of the same call.
    if (seen.has(id)) { if (status) out.push({ ts: Date.parse(j.timestamp), status, dup: true }); continue; }
    seen.add(id);
    out.push({ ts: Date.parse(j.timestamp), model: j.message.model || "?", u: j.message.usage || {}, status });
  }
  return out;
}

async function phases(file) {
  const seen = new Set();
  const main = await usageRows(file, seen);
  const subDir = path.join(path.dirname(file), path.basename(file, ".jsonl"), "subagents");
  let sub = [];
  if (fs.existsSync(subDir)) {
    for (const f of fs.readdirSync(subDir).filter((f) => f.endsWith(".jsonl"))) {
      sub = sub.concat(await usageRows(path.join(subDir, f), seen));
    }
  }
  // Boundaries: a status write takes effect on the NEXT call, a --mark at its time.
  const bounds = opt.marks.slice();
  for (const r of main) if (r.status) bounds.push({ ts: r.ts + 1, phase: r.status });
  bounds.sort((a, b) => a.ts - b.ts);
  const phaseAt = (ts) => {
    let p = opt.initial;
    for (const b of bounds) { if (b.ts <= ts) p = b.phase; else break; }
    return p;
  };
  const since = opt.since ? Date.parse(opt.since) : -Infinity;
  const until = opt.until ? Date.parse(opt.until) : Infinity;
  const res = { transcript: file, since: opt.since || null, until: opt.until || null, models: {}, phases: {}, subagents: zero(), total: zero(), first: null, last: null };
  const order = [];
  for (const [rows, isSub] of [[main, false], [sub, true]]) {
    for (const r of rows) {
      if (r.dup || isNaN(r.ts) || r.ts <= since || r.ts > until) continue;
      const p = phaseAt(r.ts);
      if (!res.phases[p]) { res.phases[p] = zero(); order.push(p); }
      addUsage(res.phases[p], r.u);
      addUsage(res.total, r.u);
      if (isSub) addUsage(res.subagents, r.u);
      res.models[r.model] = (res.models[r.model] || 0) + 1;
      if (res.first === null || r.ts < res.first) res.first = r.ts;
      if (res.last === null || r.ts > res.last) res.last = r.ts;
    }
  }
  res.first = res.first && new Date(res.first).toISOString();
  res.last = res.last && new Date(res.last).toISOString();
  if (opt.json) { console.log(JSON.stringify(res)); return; }
  const k = (n) => `${Math.round(n / 1000)}k`.padStart(8);
  console.log(`transcript: ${file}`);
  console.log(`window:     ${res.first || "-"} .. ${res.last || "-"}`);
  console.log(`models:     ${Object.entries(res.models).map(([m, n]) => `${m} (${n})`).join(", ") || "-"}`);
  console.log(`${"phase".padEnd(12)}${"calls".padStart(7)}${"input".padStart(8)}${"cRead".padStart(8)}${"cWrite".padStart(8)}${"output".padStart(8)}`);
  for (const [name, b] of [...order.map((p) => [p, res.phases[p]]), ["(subagents)", res.subagents], ["TOTAL", res.total]]) {
    console.log(`${name.padEnd(12)}${String(b.calls).padStart(7)}${k(b.input)}${k(b.cache_read)}${k(b.cache_write)}${k(b.output)}`);
  }
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
  else if (cmd === "phases") await phases(file);
  else await compactWindows(file);
})().catch((e) => die(e.message));
