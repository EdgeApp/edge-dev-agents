#!/usr/bin/env node
// transcript-friction.js: mechanical friction counts for one session transcript
// (Claude Code JSONL): hook blocks (total and per hook script), tool errors, and
// compaction boundaries. The run report's Orchestration Issues stamp
// (hooks/require-clean-run-report.sh) reads these, so a report can no longer say
// "None observed" over a session that hit dozens of gate blocks.
//
// The patterns match resolve-run.sh's friction block line for line, so the
// report stamp and the eval read the same numbers; resolve-run.sh should import
// HOOK_BLOCK / TOOL_ERROR / COMPACT from here instead of carrying its own copy.
//
// Usage: node transcript-friction.js <transcript.jsonl>
// Prints one JSON line: {"hook_blocks":{"total":N,"by_hook":{...}},"tool_errors":N,"compact_boundaries":N}
// A missing or unreadable transcript prints {} and exits 0 (callers skip the stamp).
const fs = require('fs')
const rl = require('readline')

const HOOK_BLOCK = /PreToolUse:\w+ hook error: \[[^\]]*\/([a-z0-9-]+\.sh)\]/
const TOOL_ERROR = /"is_error":\s*true/
const COMPACT = /"subtype":"compact_boundary"/

async function count(path) {
  const fr = { hook_blocks: { total: 0, by_hook: {} }, tool_errors: 0, compact_boundaries: 0 }
  const r = rl.createInterface({ input: fs.createReadStream(path), crlfDelay: Infinity })
  for await (const line of r) {
    const hb = line.match(HOOK_BLOCK)
    if (hb) {
      fr.hook_blocks.total++
      fr.hook_blocks.by_hook[hb[1]] = (fr.hook_blocks.by_hook[hb[1]] || 0) + 1
    }
    if (TOOL_ERROR.test(line)) fr.tool_errors++
    if (COMPACT.test(line)) fr.compact_boundaries++
  }
  return fr
}

module.exports = { HOOK_BLOCK, TOOL_ERROR, COMPACT, count }

if (require.main === module) {
  const p = process.argv[2]
  if (!p || !fs.existsSync(p)) { console.log('{}'); process.exit(0) }
  count(p).then(fr => console.log(JSON.stringify(fr))).catch(() => console.log('{}'))
}
