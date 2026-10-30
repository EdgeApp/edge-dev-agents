#!/usr/bin/env node
// token-ledger.sh: one line of token spend per orch run segment, priced in percent of the
// weekly usage limit.
//
//   record --gid G --kind dev|qa [--session UUID]
//       Splits the session's tokens by phase (transcript-analyze.sh phases) and appends
//       {ts,gid,kind,session,transcript,since,until,models,phases,subagents,total,weighted,pct_est}
//       to token-ledger.jsonl. The session defaults to CLAUDE_CODE_SESSION_ID; with neither,
//       it prints a skip note and exits 0 (a watcher-side QA abandon has no session).
//       A dev record for a gid that already has a dev or followup line is kind followup.
//       Calls already counted by an earlier line for the same transcript are excluded
//       (--since is that line's last call), so a resumed session is not counted twice.
//       qa records split at the pass's `approved` file: Planning before it, Running after.
//       Callers: update-status.sh on Complete (dev, followup) and qa-verdict.sh before POSTED.
//       Both run it detached and best-effort; failures land in token-ledger.log.
//
//   report [--since YYYY-MM-DD] [--gid G] [--json]
//       One row per ledger line: tokens by phase and the estimated share of the weekly limit,
//       repriced with the current token-calibration.json (token-calibrate.sh writes it).
//
// weighted = input + 0.1 cache read + 1.25 cache write + 5 output, matching token-calibrate.sh.
// Exit 0 ok (including a skipped record), 1 error, 2 usage.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const STATE = path.join(process.env.XDG_STATE_HOME || path.join(process.env.HOME, ".local", "state"), "agent-watcher");
const LEDGER = path.join(STATE, "token-ledger.jsonl");
const CALIB = path.join(STATE, "token-calibration.json");
const ANALYZE = path.join(__dirname, "transcript-analyze.sh");

const argv = process.argv.slice(2);
const cmd = argv.shift();
const opt = { gid: "", kind: "", session: process.env.CLAUDE_CODE_SESSION_ID || "", since: "", json: false };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--gid") opt.gid = argv[++i];
  else if (a === "--kind") opt.kind = argv[++i];
  else if (a === "--session") opt.session = argv[++i];
  else if (a === "--since") opt.since = argv[++i];
  else if (a === "--json") opt.json = true;
  else usage();
}
function usage() {
  console.error("usage: token-ledger.sh record --gid G --kind dev|qa [--session UUID]\n       token-ledger.sh report [--since YYYY-MM-DD] [--gid G] [--json]");
  process.exit(2);
}
const die = (m) => { console.error(`token-ledger.sh: ${m}`); process.exit(1); };
const weighted = (t) => t.input + 0.1 * t.cache_read + 1.25 * t.cache_write + 5 * t.output;
const readLedger = () => {
  try { return fs.readFileSync(LEDGER, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch (e) { return []; }
};
const perPct = () => {
  try { return JSON.parse(fs.readFileSync(CALIB, "utf8")).per_pct.weighted || null; } catch (e) { return null; }
};

function record() {
  if (!opt.gid || !["dev", "qa"].includes(opt.kind)) usage();
  if (!opt.session) { console.log(`token-ledger: skipped ${opt.gid} ${opt.kind}: no session id`); return; }
  const prior = readLedger().filter((r) => r.gid === opt.gid);
  const kind = opt.kind === "dev" && prior.some((r) => r.kind === "dev" || r.kind === "followup") ? "followup" : opt.kind;
  const args = ["phases", opt.session, "--json"];
  if (opt.kind === "qa") {
    args.push("--initial", "Planning");
    try {
      const approved = path.join(STATE, "qa", opt.gid, "approved");
      args.push("--mark", `Running=${fs.statSync(approved).mtime.toISOString()}`);
    } catch (e) {}
  }
  let out;
  try { out = JSON.parse(execFileSync(ANALYZE, args, { encoding: "utf8", maxBuffer: 1 << 24 })); } catch (e) { die(`transcript-analyze.sh phases failed: ${e.message.split("\n")[0]}`); }
  // A later segment of the same transcript (a resumed followup) starts after the last counted call.
  const prev = readLedger().filter((r) => r.transcript === out.transcript && r.last).pop();
  if (prev) {
    try { out = JSON.parse(execFileSync(ANALYZE, [...args, "--since", prev.last], { encoding: "utf8", maxBuffer: 1 << 24 })); } catch (e) { die(`transcript-analyze.sh phases --since failed: ${e.message.split("\n")[0]}`); }
  }
  if (!out.total || !out.total.calls) { console.log(`token-ledger: skipped ${opt.gid} ${kind}: no new calls`); return; }
  const w = weighted(out.total), p = perPct();
  const rec = {
    ts: new Date().toISOString(), gid: opt.gid, kind, session: opt.session, transcript: out.transcript,
    since: prev ? prev.last : null, first: out.first, last: out.last, models: out.models,
    phases: out.phases, subagents: out.subagents, total: out.total, weighted: Math.round(w),
    pct_est: p ? +(w / p).toFixed(2) : null,
  };
  fs.appendFileSync(LEDGER, JSON.stringify(rec) + "\n");
  console.log(`token-ledger: ${opt.gid} ${kind} ${out.total.calls} calls, ${(w / 1e6).toFixed(2)}M weighted${rec.pct_est != null ? `, ~${rec.pct_est}% of the weekly limit` : ""}`);
}

function report() {
  const p = perPct();
  let rows = readLedger();
  if (opt.since) rows = rows.filter((r) => r.ts >= opt.since);
  if (opt.gid) rows = rows.filter((r) => r.gid === opt.gid);
  rows = rows.map((r) => ({ ...r, pct_now: p ? +(weighted(r.total) / p).toFixed(2) : null }));
  if (opt.json) { console.log(JSON.stringify({ per_pct: p, rows })); return; }
  if (!rows.length) { console.log("no ledger rows"); return; }
  const M = (n) => `${(n / 1e6).toFixed(2)}M`;
  console.log(`${"ts".padEnd(17)}${"gid".padEnd(18)}${"kind".padEnd(9)}${"calls".padStart(6)}${"weighted".padStart(10)}${"pct".padStart(7)}  phases (weighted)`);
  let sum = 0;
  for (const r of rows) {
    sum += r.pct_now || 0;
    const ph = Object.entries(r.phases).map(([k, v]) => `${k} ${M(weighted(v))}`).join(", ");
    console.log(`${r.ts.slice(0, 16).padEnd(17)}${r.gid.padEnd(18)}${r.kind.padEnd(9)}${String(r.total.calls).padStart(6)}${M(weighted(r.total)).padStart(10)}${(r.pct_now != null ? `${r.pct_now}%` : "-").padStart(7)}  ${ph}${r.subagents.calls ? `; subagents ${M(weighted(r.subagents))}` : ""}`);
  }
  console.log(p ? `total ~${sum.toFixed(1)}% of the weekly limit at ${M(p)} weighted per 1%` : "no token-calibration.json: run token-calibrate.sh for pct");
}

if (cmd === "record") record();
else if (cmd === "report") report();
else usage();
