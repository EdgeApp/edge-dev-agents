'use strict'
// lib/collect-worker.js — runs lib/fleet-model.js collect() on a worker thread
// for orch-tui.js. collect() shells out synchronously (tmux, ps, lsof, log
// tails); here those calls block only this thread, so the TUI keeps answering
// keys while a refresh runs.
//
// Protocol: the parent posts any message to request a collect; the worker
// replies {model} or {error}. After each reply it warms the task-name cache, so
// a name Asana had to be asked for shows on the next collect.
const { parentPort } = require('worker_threads')
const M0 = require('./fleet-model.js')

parentPort.on('message', async () => {
  try { parentPort.postMessage({ model: M0.collect() }) } catch (e) { parentPort.postMessage({ error: String(e.message || e) }) }
  try { await M0.warmNames() } catch { /* names stay as cached */ }
})
