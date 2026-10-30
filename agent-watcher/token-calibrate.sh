#!/usr/bin/env node
// token-calibrate.sh: price Claude tokens in percent of the weekly (7d) usage limit.
//
// Inputs:
//   usage-samples.jsonl   7d/5h pct readings, one line per change (usage-hold.sh writes it
//                         every watcher tick)
//   ~/.claude/projects    every transcript on this machine, main and subagent files. All
//                         sessions draw from the same limit, chat and orch alike, so all count.
//
// A weekly window is the run of samples between two drops of the 7d pct. Inside a window the
// tokens spent between the first sample at pct A and the first sample at pct B cost B-A
// percent (pct is an integer, so each end is quantized by under 1%). Tokens are priced as
// weighted tokens, input + 0.1 cache read + 1.25 cache write + 5 output (the API price ratios,
// the same weights as transcript-analyze.sh cost), because the four classes move together too
// closely for a per-class fit. Each window yields weighted tokens per 1%, plus the median and
// quartiles over its 5%-or-more intervals so drift inside a week is visible. The headline rate
// (per_pct, read by token-ledger.sh) is the latest window that reached 10%.
//
// Usage not visible here (claude.ai web or mobile, another machine on the same account) shows
// up as extra pct and lowers tokens per 1%. A limit change shows up as a step between windows.
//
// Per-file usage is cached in token-index.json (10-minute buckets per model, keyed by path,
// size and mtime), so a rerun reads only transcripts that changed.
//
// Usage: token-calibrate.sh [--days N] [--json]
//   --days N   windows that ended within N days (default 35)
//   --json     print the calibration JSON instead of the table
// Writes token-calibration.json (read by token-ledger.sh report). Exit 0 ok, 1 error, 2 usage.

const fs = require("fs");
const path = require("path");
const readline = require("readline");

const STATE = path.join(process.env.XDG_STATE_HOME || path.join(process.env.HOME, ".local", "state"), "agent-watcher");
const SAMPLES = path.join(STATE, "usage-samples.jsonl");
const INDEX = path.join(STATE, "token-index.json");
const OUT = path.join(STATE, "token-calibration.json");
const PROJECTS = path.join(process.env.HOME, ".claude", "projects");
const BUCKET_MS = 10 * 60 * 1000;
const CLASSES = ["input", "cache_read", "cache_write", "output"];

let days = 35, json = false;
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--days") days = Number(argv[++i]);
  else if (argv[i] === "--json") json = true;
  else { console.error("usage: token-calibrate.sh [--days N] [--json]"); process.exit(2); }
}
const die = (m) => { console.error(`token-calibrate.sh: ${m}`); process.exit(1); };

// --- weekly windows from the samples ---------------------------------------
function windows() {
  if (!fs.existsSync(SAMPLES)) die(`no ${SAMPLES}; usage-hold.sh writes it each watcher tick`);
  const s = fs.readFileSync(SAMPLES, "utf8").trim().split("\n").map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
    .filter((o) => o && o.seven_day != null).map((o) => ({ ts: Date.parse(o.ts), pct: o.seven_day })).sort((a, b) => a.ts - b.ts);
  const wins = [];
  let cur = [];
  for (const x of s) {
    if (cur.length && x.pct < cur[cur.length - 1].pct) { wins.push(cur); cur = []; }
    cur.push(x);
  }
  if (cur.length) wins.push(cur);
  // First-seen time of each pct value: the moment the counter reached it.
  return wins.map((w) => {
    const first = [];
    for (const x of w) if (!first.length || x.pct > first[first.length - 1].pct) first.push(x);
    return first;
  }).filter((f) => f.length >= 2);
}

// --- per-file usage index ----------------------------------------------------
function listTranscripts(sinceMs) {
  const out = [];
  const walk = (d, depth) => {
    let ents;
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && depth < 3) walk(p, depth + 1);
      else if (e.isFile() && e.name.endsWith(".jsonl")) {
        const st = fs.statSync(p);
        if (st.mtimeMs >= sinceMs) out.push({ p, size: st.size, mtime: st.mtimeMs });
      }
    }
  };
  walk(PROJECTS, 0);
  return out;
}

async function indexFile(p) {
  const buckets = {};
  const seen = new Set();
  const rl = readline.createInterface({ input: fs.createReadStream(p), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.includes('"usage"')) continue;
    let j;
    try { j = JSON.parse(line); } catch (e) { continue; }
    if (j.type !== "assistant" || !j.message || !j.message.usage || seen.has(j.message.id)) continue;
    seen.add(j.message.id);
    const ts = Date.parse(j.timestamp);
    if (isNaN(ts)) continue;
    const b = String(Math.floor(ts / BUCKET_MS));
    const m = j.message.model || "?";
    if (m === "<synthetic>") continue;
    const u = j.message.usage;
    const row = ((buckets[b] = buckets[b] || {})[m] = buckets[b][m] || [0, 0, 0, 0, 0]);
    row[0]++;
    row[1] += u.input_tokens || 0;
    row[2] += u.cache_read_input_tokens || 0;
    row[3] += u.cache_creation_input_tokens || 0;
    row[4] += u.output_tokens || 0;
  }
  return buckets;
}

async function loadIndex(sinceMs) {
  let idx = {};
  try { idx = JSON.parse(fs.readFileSync(INDEX, "utf8")); } catch (e) {}
  const files = listTranscripts(sinceMs);
  const live = new Set();
  let reread = 0;
  for (const f of files) {
    live.add(f.p);
    const c = idx[f.p];
    if (c && c.size === f.size && c.mtime === f.mtime) continue;
    idx[f.p] = { size: f.size, mtime: f.mtime, buckets: await indexFile(f.p) };
    reread++;
  }
  for (const k of Object.keys(idx)) if (!live.has(k) && idx[k].mtime < sinceMs) delete idx[k];
  const tmp = `${INDEX}.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(idx));
  fs.renameSync(tmp, INDEX);
  // Merge into one bucket -> model -> totals map.
  const all = new Map();
  for (const { buckets } of Object.values(idx)) {
    for (const [b, models] of Object.entries(buckets)) {
      const tgt = all.get(+b) || {};
      for (const [m, r] of Object.entries(models)) {
        const t = (tgt[m] = tgt[m] || [0, 0, 0, 0, 0]);
        for (let i = 0; i < 5; i++) t[i] += r[i];
      }
      all.set(+b, tgt);
    }
  }
  return { all, files: files.length, reread };
}

const weighted = (t) => t.input + 0.1 * t.cache_read + 1.25 * t.cache_write + 5 * t.output;
const quant = (a, q) => { const v = [...a].sort((x, y) => x - y); return v.length ? v[Math.min(v.length - 1, Math.floor(q * v.length))] : null; };
const family = (m) => (/opus/i.test(m) ? "opus" : /sonnet/i.test(m) ? "sonnet" : /haiku/i.test(m) ? "haiku" : /fable/i.test(m) ? "fable" : "other");
function sumRange(all, t0, t1) {
  const tot = { calls: 0, input: 0, cache_read: 0, cache_write: 0, output: 0, by_family: {} };
  for (let b = Math.floor(t0 / BUCKET_MS); b < Math.floor(t1 / BUCKET_MS); b++) {
    const models = all.get(b);
    if (!models) continue;
    for (const [m, r] of Object.entries(models)) {
      tot.calls += r[0]; tot.input += r[1]; tot.cache_read += r[2]; tot.cache_write += r[3]; tot.output += r[4];
      const f = (tot.by_family[family(m)] = tot.by_family[family(m)] || { calls: 0, input: 0, cache_read: 0, cache_write: 0, output: 0 });
      f.calls += r[0]; f.input += r[1]; f.cache_read += r[2]; f.cache_write += r[3]; f.output += r[4];
    }
  }
  return tot;
}


(async () => {
  const cutoff = Date.now() - days * 86400000;
  const wins = windows().filter((w) => w[w.length - 1].ts >= cutoff);
  if (!wins.length) die(`no weekly window with two or more pct readings in the last ${days} days`);
  const { all, files, reread } = await loadIndex(wins[0][0].ts - 86400000);

  const result = { computed_at: new Date().toISOString(), transcripts: files, weights: { input: 1, cache_read: 0.1, cache_write: 1.25, output: 5 }, windows: [], per_pct: null };
  for (const w of wins) {
    const a = w[0], z = w[w.length - 1];
    const tot = sumRange(all, a.ts, z.ts);
    const d = z.pct - a.pct;
    // Intervals of 5% or more: shorter ones are mostly quantization noise.
    const rates = [];
    let s = a;
    for (const x of w.slice(1)) {
      if (x.pct - s.pct < 5) continue;
      rates.push(weighted(sumRange(all, s.ts, x.ts)) / (x.pct - s.pct));
      s = x;
    }
    result.windows.push({
      from: new Date(a.ts).toISOString(), to: new Date(z.ts).toISOString(), pct_from: a.pct, pct_to: z.pct, pct: d,
      tokens: tot,
      per_pct: { weighted: Math.round(weighted(tot) / d), ...Object.fromEntries(CLASSES.map((c) => [c, Math.round(tot[c] / d)])) },
      intervals: { n: rates.length, p25: quant(rates, 0.25), median: quant(rates, 0.5), p75: quant(rates, 0.75) },
    });
  }
  const ref = result.windows.filter((w) => w.pct >= 10).pop() || result.windows[result.windows.length - 1];
  result.per_pct = { window: ref.from, ...ref.per_pct };
  const tmp = `${OUT}.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(result, null, 2));
  fs.renameSync(tmp, OUT);

  if (json) { console.log(JSON.stringify(result)); return; }
  const M = (n) => (n == null ? "-" : `${(n / 1e6).toFixed(2)}M`);
  console.log(`transcripts: ${files} (${reread} re-read)   weighted = input + 0.1 cRead + 1.25 cWrite + 5 out`);
  console.log(`${"window".padEnd(18)}${"pct".padStart(8)}${"calls".padStart(8)}${"wtd/1%".padStart(9)}${"p25".padStart(8)}${"median".padStart(8)}${"p75".padStart(8)}${"cRead/1%".padStart(10)}${"out/1%".padStart(8)}  families`);
  for (const w of result.windows) {
    const fam = Object.entries(w.tokens.by_family).map(([k, v]) => `${k} ${Math.round((100 * v.calls) / Math.max(1, w.tokens.calls))}%`).join(" ");
    const iv = w.intervals;
    console.log(`${w.from.slice(0, 16).padEnd(18)}${`${w.pct_from}->${w.pct_to}`.padStart(8)}${String(w.tokens.calls).padStart(8)}${M(w.per_pct.weighted).padStart(9)}${M(iv.p25).padStart(8)}${M(iv.median).padStart(8)}${M(iv.p75).padStart(8)}${M(w.per_pct.cache_read).padStart(10)}${M(w.per_pct.output).padStart(8)}  ${fam}`);
  }
  console.log(`headline: ${M(result.per_pct.weighted)} weighted tokens per 1% of the weekly limit (window from ${result.per_pct.window.slice(0, 10)})`);
  console.log(`wrote ${OUT}`);
})().catch((e) => die(e.stack || e.message));
