#!/usr/bin/env node
// fleet-page.js — render the Fleet artifact page from lib/fleet-model.js (the
// same model as orch-tui): a health strip, the request ledger, resumable
// transcripts with a Resume control, and the live sessions grouped by kind.
//
// Tap contract: the page declares the `artifact` capability. A tap (Resume or
// Refresh) publishes a SMALL placeholder document that carries only the state
// (requests + the transcript uuids this page listed) and a "queued" notice.
// That wakes the fleet anchor through its watch; fleet-panel.sh apply reads
// the state, executes, and this renderer republishes the full page. Keeping
// the tap payload small keeps the anchor's read (and its token cost) small,
// and the full page never has to serialize itself.
//
// Usage: fleet-page.js [--state <fleet-state.json>] [--out <file>] [--dump <model.json>]
'use strict'
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const DIR = path.join(os.homedir(), '.config/agent-watcher')
const model = require(path.join(DIR, 'lib/fleet-model.js'))
const args = process.argv.slice(2)
const arg = (k, d) => { const i = args.indexOf(k); return i >= 0 && args[i + 1] ? args[i + 1] : d }
const STATE_PATH = arg('--state', path.join(DIR, 'fleet-state.json'))
const OUT = arg('--out', '')
const DUMP = arg('--dump', '')

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
const jsonScript = (id, obj) => `<script type="application/json" id="${id}">${JSON.stringify(obj).replace(/<\//g, '<\\/')}</script>`
const strip = t => String(t || '').replace(/^Asana:\s*/, '')
const now = Math.floor(Date.now() / 1000)
function ago (ts) {
  if (!ts) return ''
  const d = Math.max(0, now - ts)
  if (d < 90) return `${d}s`
  if (d < 5400) return `${Math.round(d / 60)}m`
  if (d < 172800) return `${Math.round(d / 3600)}h`
  return `${Math.round(d / 86400)}d`
}
const hhmm = iso => (iso || '').replace('T', ' ').slice(5, 16)

async function main () {
  const state = (() => { try { return JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')) } catch { return { requests: [] } } })()
  const m = DUMP ? JSON.parse(fs.readFileSync(DUMP, 'utf8')) : await model.dump()
  const v = m.vitals
  const live = (m.fleet.live || []).slice().sort((a, b) => (b.activity || 0) - (a.activity || 0))
  const dead = (m.fleet.dead || []).slice().sort((a, b) => (b.mtime || 0) - (a.mtime || 0))
  const asanaTally = m.asana && m.asana.tally ? new Map(m.asana.tally) : null
  const pendingN = asanaTally ? (m.asana.pending || []).filter(p => /^pending$/i.test(p.status)).length : null

  // ── health strip ──
  const runs = live.filter(r => r.kind === 'run' && r.state === 'running').length
  const freeSims = (m.pool || []).filter(p => p.state === 'free').length
  const verdict = model.spawnVerdict(v, runs, freeSims, pendingN ?? 0)
  const drift = (v.jobs || []).filter(j => j.rc !== 0).map(j => j.name === 'config-watch' && j.rc === 1 ? 'config DRIFT' : `${j.name} rc${j.rc}`)
  const loadCls = v.load > v.maxLoad ? 'bad' : v.load > v.maxLoad * 0.75 ? 'warn' : 'ok'
  const ramCls = v.freeGb < v.minFree ? 'bad' : 'ok'
  const tick = v.watcherTickAge == null ? '?' : `${Math.round(v.watcherTickAge / 60)}m ago`
  const health = `
  <section class="health">
    <div class="verdict ${verdict.ok ? 'ok' : 'bad'}"><b>${verdict.ok ? 'SPAWN OPEN' : 'SPAWN GATED'}</b><span>${esc(verdict.why)}</span></div>
    <div class="gauges">
      <span class="g ${loadCls}"><i>load</i>${v.load.toFixed(1)}<small>/${v.maxLoad}</small></span>
      <span class="g ${ramCls}"><i>ram</i>${v.freeGb.toFixed(0)}G<small>free</small></span>
      <span class="g"><i>runs</i>${runs}<small>/${v.maxConcurrent}</small></span>
      <span class="g"><i>sims</i>${freeSims}<small>/${(m.pool || []).length} free</small></span>
      <span class="g"><i>pending</i>${pendingN ?? '?'}</span>
      <span class="g"><i>watcher</i>${esc(tick)}</span>
      ${drift.length ? `<span class="g bad"><i>jobs</i>${esc(drift.join(', '))}</span>` : ''}
    </div>
    ${v.hogs && v.hogs.length ? `<div class="hogs">pinned by ${esc(v.hogs.slice(0, 3).join(', '))}</div>` : ''}
  </section>`

  // ── requests ──
  const pendingByUuid = new Map((state.requests || []).filter(r => r.status === 'pending' || r.status === 'running').map(r => [r.uuid, r]))
  // Finished taps age out after an hour (the ledger keeps them); open ones always show.
  const REQ_TTL_MS = 60 * 60 * 1000
  const reqs = (state.requests || []).filter(r => !(r.status === 'done' && Date.now() - Date.parse(r.doneAt || r.at || 0) > REQ_TTL_MS))
    .sort((a, b) => (b.at || '').localeCompare(a.at || '')).slice(0, 8)
  const reqRows = reqs.map(r => {
    const cls = r.status === 'done' ? 'ok' : r.status === 'error' ? 'bad' : 'warn'
    const isRefresh = r.kind === 'refresh' || !r.uuid
    const title = isRefresh ? 'Page refresh (your tap)' : `Resume: ${strip(r.title) || r.uuid}`
    const what = r.status === 'done' ? (isRefresh ? 're-rendered' : `chat started as <code>${esc(r.rc || '?')}</code>, open it in Remote Control`)
      : r.status === 'error' ? esc(r.note || 'failed') : r.status === 'running' ? (isRefresh ? 'rendering' : 'resuming now') : 'queued for eddy'
    return `<li class="row"><span class="pill ${cls}">${esc(r.status)}</span><span class="main"><span class="t">${esc(title)}</span><span class="m">${what} · ${esc(hhmm(r.at))}</span></span></li>`
  }).join('')

  // ── transcripts ──
  const snapshotUuids = dead.map(d => d.uuid)
  const deadRows = dead.map(d => {
    const req = pendingByUuid.get(d.uuid)
    const btn = req ? `<button class="act" disabled>${req.status === 'running' ? 'resuming' : 'queued'}</button>`
      : `<button class="act" data-uuid="${esc(d.uuid)}" data-title="${esc(strip(d.title))}">Resume</button>`
    const flags = [d.isForkOfLive ? 'has fork' : '', d.forkChild ? '' : ''].filter(Boolean).join(' · ')
    return `<li class="row tr" data-q="${esc(strip(d.title).toLowerCase())} ${esc(d.uuid.slice(0, 8))}"><span class="main"><span class="t">${esc(strip(d.title) || d.uuid)}</span><span class="m">${esc(ago(d.mtime))} ago · <code>${esc(d.uuid.slice(0, 8))}</code>${flags ? ' · ' + esc(flags) : ''}</span></span>${btn}</li>`
  }).join('')

  // ── live sessions, grouped ──
  const anchors = live.filter(r => r.kind === 'anchor' || r.kind === 'adhoc')
  const chats = live.filter(r => r.kind === 'chat')
  const running = live.filter(r => r.kind === 'run' && r.state === 'running')
  const retired = live.filter(r => r.kind === 'run' && r.state === 'retired')
  const deadLive = live.filter(r => r.state === 'dead')
  const chip = r => `<span class="chip ${r.state === 'dead' ? 'bad' : ''}"><b>${esc(r.rc || r.slug || r.name)}</b><small>${esc(ago(r.activity))}</small></span>`
  const liveRow = r => {
    const title = strip(r.title) || r.name
    const rcPart = !r.rc ? 'no remote control' : r.rc === title ? 'remote control' : `<code>${esc(r.rc)}</code>`
    return `<li class="row"><span class="main"><span class="t">${esc(title)}</span><span class="m">${rcPart} · ${esc(ago(r.activity))} idle${r.reap ? ` · <em class="warn">${esc(r.reap)}</em>` : ''}${r.state === 'dead' ? ' · <em class="bad">claude dead</em>' : ''}</span></span></li>`
  }
  const sessions = `
  <section>
    <h2>Anchors <span class="n">${anchors.length}</span></h2>
    <div class="chips">${anchors.map(chip).join('') || '<span class="empty">none</span>'}</div>
  </section>
  <section>
    <h2>Running tasks <span class="n">${running.length}</span></h2>
    <ul>${running.map(liveRow).join('') || '<li class="empty">none</li>'}</ul>
  </section>
  <section>
    <h2>Chats <span class="n">${chats.length}</span></h2>
    <ul>${chats.map(liveRow).join('') || '<li class="empty">none</li>'}</ul>
  </section>
  ${deadLive.length ? `<section><h2>Dead panes <span class="n">${deadLive.length}</span></h2><ul>${deadLive.map(liveRow).join('')}</ul></section>` : ''}
  <section>
    <details><summary><h2>Retired runs <span class="n">${retired.length}</span></h2></summary>
    <ul>${retired.map(liveRow).join('') || '<li class="empty">none</li>'}</ul></details>
  </section>`

  const stamp = new Date().toISOString().replace('T', ' ').slice(0, 16) + ' UTC'
  const embedded = { requests: (state.requests || []).slice(-30), snapshotUuids, generatedAt: stamp }

  const page = `<title>Fleet</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>
  :root { --bg:#f3f2ee; --panel:#ffffff; --ink:#1b1f24; --muted:#697079; --line:#dcd9d1; --accent:#1e7a68; --accent-ink:#ffffff;
          --ok:#2f8a58; --warn:#b07a12; --bad:#b3372c; --pillbg:#eeece6; --okbg:#e4f2ea; --badbg:#f6e3e0; --warnbg:#f5ecd6; }
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#14171b; --panel:#1b1f25; --ink:#e7e5df; --muted:#9aa1a9; --line:#2b3037; --accent:#3fb39a; --accent-ink:#0e1513;
          --ok:#5cc48a; --warn:#e0a83a; --bad:#e8705f; --pillbg:#262b32; --okbg:#1c2f26; --badbg:#3a2220; --warnbg:#3a2e17; } }
  :root[data-theme="dark"] { --bg:#14171b; --panel:#1b1f25; --ink:#e7e5df; --muted:#9aa1a9; --line:#2b3037; --accent:#3fb39a; --accent-ink:#0e1513;
          --ok:#5cc48a; --warn:#e0a83a; --bad:#e8705f; --pillbg:#262b32; --okbg:#1c2f26; --badbg:#3a2220; --warnbg:#3a2e17; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.4 "IBM Plex Sans","Helvetica Neue",Arial,sans-serif; }
  header { position:sticky; top:0; z-index:2; background:var(--bg); border-bottom:1px solid var(--line); padding:.6rem .9rem; display:flex; align-items:center; gap:.7rem; }
  header h1 { font:600 1.05rem/1 "IBM Plex Sans",sans-serif; margin:0; }
  header .stamp { color:var(--muted); font:400 .72rem/1.2 "IBM Plex Mono",ui-monospace,Menlo,monospace; }
  header .grow { flex:1; }
  main { max-width:44rem; margin:0 auto; padding:0 0 3rem; }
  section { padding:.8rem .9rem 0; }
  h2 { margin:0 0 .35rem; font:500 .7rem/1 "IBM Plex Sans",sans-serif; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); display:inline-flex; gap:.4rem; align-items:baseline; }
  h2 .n { font-family:"IBM Plex Mono",ui-monospace,monospace; font-variant-numeric:tabular-nums; }
  summary { cursor:pointer; list-style:none; } summary::-webkit-details-marker { display:none; } summary h2::after { content:" ▸"; } details[open] summary h2::after { content:" ▾"; }
  ul { list-style:none; margin:0; padding:0; background:var(--panel); border:1px solid var(--line); border-radius:6px; }
  .row { display:flex; align-items:center; gap:.6rem; padding:.45rem .65rem; border-top:1px solid var(--line); min-height:2.6rem; }
  .row:first-child { border-top:0; }
  .main { flex:1; min-width:0; display:grid; gap:.05rem; }
  .t { font-weight:500; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .m { color:var(--muted); font-size:.76rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  code { font:500 .74rem "IBM Plex Mono",ui-monospace,Menlo,monospace; background:var(--pillbg); padding:.02rem .28rem; border-radius:3px; color:var(--ink); }
  em { font-style:normal; } .warn { color:var(--warn); } .bad { color:var(--bad); } .ok { color:var(--ok); }
  .pill { flex:none; font:500 .64rem/1 "IBM Plex Mono",ui-monospace,monospace; text-transform:uppercase; letter-spacing:.05em; padding:.28rem .4rem; border-radius:3px; background:var(--pillbg); color:var(--muted); min-width:3.6rem; text-align:center; }
  .pill.ok { color:var(--ok); background:var(--okbg); } .pill.bad { color:var(--bad); background:var(--badbg); } .pill.warn { color:var(--warn); background:var(--warnbg); }
  button { font:600 .8rem/1 "IBM Plex Sans",sans-serif; border:0; border-radius:5px; padding:.55rem .75rem; cursor:pointer; min-height:2.2rem; }
  button.act { background:var(--accent); color:var(--accent-ink); flex:none; }
  button.ghost { background:var(--pillbg); color:var(--ink); }
  button[disabled] { opacity:.5; cursor:default; }
  button:focus-visible, input:focus-visible { outline:3px solid var(--warn); outline-offset:2px; }
  .empty { padding:.6rem .65rem; color:var(--muted); font-size:.8rem; }
  #msg { padding:.5rem .9rem 0; font:400 .76rem "IBM Plex Mono",ui-monospace,monospace; color:var(--muted); min-height:1.2rem; }
  .health { display:grid; gap:.45rem; }
  .verdict { display:flex; gap:.6rem; align-items:baseline; padding:.55rem .7rem; border-radius:6px; background:var(--okbg); color:var(--ok); }
  .verdict.bad { background:var(--badbg); color:var(--bad); }
  .verdict b { font:600 .72rem/1 "IBM Plex Mono",ui-monospace,monospace; letter-spacing:.06em; white-space:nowrap; }
  .verdict span { font-size:.82rem; color:var(--ink); min-width:0; overflow-wrap:anywhere; }
  .gauges { display:flex; flex-wrap:wrap; gap:.35rem; }
  .g { display:inline-flex; align-items:baseline; gap:.3rem; padding:.3rem .5rem; border-radius:5px; background:var(--panel); border:1px solid var(--line); font:500 .9rem/1 "IBM Plex Mono",ui-monospace,monospace; font-variant-numeric:tabular-nums; }
  .g i { font:500 .62rem/1 "IBM Plex Sans",sans-serif; font-style:normal; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
  .g small { font-size:.7rem; color:var(--muted); } .g.bad { color:var(--bad); border-color:var(--bad); } .g.warn { color:var(--warn); }
  .hogs { color:var(--muted); font-size:.74rem; }
  .chips { display:flex; flex-wrap:wrap; gap:.35rem; }
  .chip { display:inline-flex; gap:.35rem; align-items:baseline; padding:.3rem .5rem; border-radius:5px; background:var(--panel); border:1px solid var(--line); font:500 .78rem "IBM Plex Mono",ui-monospace,monospace; }
  .chip small { color:var(--muted); font-size:.68rem; } .chip.bad b { color:var(--bad); }
  .filter { width:100%; margin:0 0 .4rem; padding:.5rem .65rem; border:1px solid var(--line); border-radius:6px; background:var(--panel); color:var(--ink); font:400 .9rem "IBM Plex Sans",sans-serif; }
  .tr.hide { display:none; }
</style>
<header>
  <h1>Fleet</h1>
  <span class="stamp">eddy · ${esc(stamp)}</span>
  <span class="grow"></span>
  <button id="refresh" class="ghost" disabled>Refresh</button>
</header>
<div id="msg"></div>
<main>
  ${health}
  ${reqRows ? `<section><h2>Requests <span class="n">${reqs.length}</span></h2><ul>${reqRows}</ul></section>` : ''}
  <section>
    <h2>Resumable transcripts <span class="n">${dead.length}</span></h2>
    <input id="filter" class="filter" type="search" placeholder="filter by name or id" autocomplete="off">
    <ul id="dead">${deadRows || '<li class="empty">Every transcript has a live session.</li>'}</ul>
  </section>
  ${sessions}
</main>
${jsonScript('state', embedded)}
<script>
(function () {
  var state = JSON.parse(document.getElementById('state').textContent);
  var msg = document.getElementById('msg');
  var refresh = document.getElementById('refresh');
  var filter = document.getElementById('filter');
  filter.addEventListener('input', function () {
    var q = filter.value.trim().toLowerCase();
    document.querySelectorAll('li.tr').forEach(function (li) { li.classList.toggle('hide', q && li.dataset.q.indexOf(q) < 0); });
  });
  function stateScript(s) { return '<script type="application/json" id="state">' + JSON.stringify(s).replace(/<\\//g, '<\\\\/') + '<\\/script>'; }
  // The tap payload: a small placeholder page carrying the state. The fleet
  // anchor reads it, applies the requests, and republishes the full page.
  function queuedPage(s, label) {
    return '<!doctype html>\\n<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Fleet</title>'
      + '<style>body{margin:0;padding:1.2rem;font:15px/1.5 -apple-system,"IBM Plex Sans",sans-serif;background:#f3f2ee;color:#1b1f24}@media(prefers-color-scheme:dark){body{background:#14171b;color:#e7e5df}}h1{font-size:1.05rem;margin:0 0 .6rem}p{margin:.3rem 0;max-width:40rem}small{opacity:.7}</style></head><body>'
      + '<h1>Fleet: ' + label.replace(/</g, '&lt;') + '</h1>'
      + '<p>Queued at ' + new Date().toISOString().replace('T', ' ').slice(0, 19) + ' UTC. The fleet anchor on eddy picks this up on its next wake and republishes the full page; this view reloads by itself, usually within a minute.</p>'
      + '<p><small>If this page has not changed in three minutes, the fleet anchor is down: open any anchor in Remote Control and ask it to resume fleet.</small></p>'
      + stateScript(s) + '</body></html>';
  }
  var artifactP = (window.claude && window.claude.use) ? window.claude.use('artifact') : Promise.resolve(null);
  artifactP.then(function (artifact) {
    if (!artifact) { msg.textContent = 'read-only view: publishing is not available here'; return; }
    refresh.disabled = false;
    function publish(next, label) {
      document.querySelectorAll('button').forEach(function (b) { b.disabled = true; });
      msg.textContent = label + '…';
      artifact.publish(queuedPage(next, label)).catch(function (e) {
        var code = (e && e.code) || 'error';
        if (code === 'conflict') { msg.textContent = 'a newer version arrived; reloading'; return; }
        msg.textContent = code === 'rate_limited' ? 'publishing too often right now; wait a minute and tap again' : 'could not publish: ' + code;
        document.querySelectorAll('button').forEach(function (b) { b.disabled = false; });
      });
    }
    refresh.addEventListener('click', function () {
      var next = JSON.parse(JSON.stringify(state));
      next.requests.push({ id: 'r' + Date.now().toString(36), kind: 'refresh', title: 'Refresh', at: new Date().toISOString(), status: 'pending' });
      publish(next, 'refreshing');
    });
    document.querySelectorAll('button.act[data-uuid]').forEach(function (b) {
      b.addEventListener('click', function () {
        var next = JSON.parse(JSON.stringify(state));
        next.requests.push({ id: 'r' + Date.now().toString(36), kind: 'resume', uuid: b.dataset.uuid, title: b.dataset.title, at: new Date().toISOString(), status: 'pending' });
        publish(next, 'resuming ' + b.dataset.title);
      });
    });
  });
})();
</script>
`
  if (OUT) fs.writeFileSync(OUT, page)
  else process.stdout.write(page)
}

main().catch(e => { console.error('fleet-page:', e.message || e); process.exit(1) })
