// frame.js — paint a full-screen TUI frame by rewriting only the rows that
// changed since the last paint. Never clear-and-redraw the whole screen on a
// refresh tick: Terminal.app leaks heap on that churn over a long-lived
// session, while unchanged rows cost nothing when they are not re-sent.
//
// paint(rows): rows[i] is screen row i+1 (holes and undefined paint blank).
// invalidate(): forget the last frame and clear, so the next paint is full.
// Call it on resize and whenever the alt screen was left and re-entered.
'use strict'
const ESC = '\x1b['
let prev = []

function paint (rows) {
  let out = ''
  const n = Math.max(rows.length, prev.length)
  for (let i = 0; i < n; i++) {
    const r = rows[i] || ''
    if (r === (prev[i] || '')) continue
    out += `${ESC}${i + 1};1H${r}${ESC}0m${ESC}K`
  }
  prev = Array.from(rows, (r) => r || '')
  if (out) process.stdout.write(out)
}

function invalidate () {
  prev = []
  process.stdout.write(`${ESC}H${ESC}2J`)
}

module.exports = { paint, invalidate }
