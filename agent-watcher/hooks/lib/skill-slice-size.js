// skill-slice-size.js -- the size cap on split skills' rule-bearing files, read
// from a hook payload on stdin. cap-skill-slice-size.sh is the only caller; its
// header owns the why and the vectors.
//
// Capped files (the same set the *-slices.test.py contract tests check):
//   one-shot, pr-land        SKILL.md and every references/*.md
//   build-and-test           SKILL.md and references/{build,drive,evidence,funding}.md
// sim-testing-playbook.md and throwaway-accounts.md are working knowledge, not
// rule slices, and stay uncapped.
//
// Size is counted in characters (code points), as the slice tests count it.
// Exit 0 allow, 2 deny with the reason on stderr.
const fs = require('fs')
const path = require('path')
const os = require('os')

const LIMIT = Number(process.env.SKILL_SLICE_LIMIT || 20000)
const SKILLS_RAW = path.join(os.homedir(), '.cursor', 'skills')
let SKILLS = SKILLS_RAW
try { SKILLS = fs.realpathSync(SKILLS_RAW) } catch (e) {}
const BT_SLICES = ['build', 'drive', 'evidence', 'funding']

// A path rule, not a listing, so a slice the write is creating is capped too.
function isCapped(file) {
  const rel = path.relative(SKILLS, file).split(path.sep)
  if (rel[0] === '..' || rel.length < 2) return false
  const [skill, a, b] = rel
  if (!['one-shot', 'pr-land', 'build-and-test'].includes(skill)) return false
  if (rel.length === 2) return a === 'SKILL.md'
  if (rel.length !== 3 || a !== 'references' || !b.endsWith('.md')) return false
  return skill !== 'build-and-test' || BT_SLICES.includes(b.replace(/\.md$/, ''))
}

function cappedFiles() {
  const out = []
  for (const skill of ['one-shot', 'pr-land', 'build-and-test']) {
    const dir = path.join(SKILLS, skill)
    out.push(path.join(dir, 'SKILL.md'))
    let names = []
    try { names = fs.readdirSync(path.join(dir, 'references')) } catch (e) {}
    for (const f of names) out.push(path.join(dir, 'references', f))
  }
  return out.filter(isCapped)
}

// ~/.claude/skills is a symlink to ~/.cursor/skills, so resolve the directory
// (the file itself may not exist yet) before comparing.
function canonical(p) {
  if (!p) return ''
  p = p.replace(/^~(?=\/)/, os.homedir())
  try { return path.join(fs.realpathSync(path.dirname(p)), path.basename(p)) } catch (e) { return path.resolve(p) }
}

const chars = s => [...s].length
const read = p => { try { return fs.readFileSync(p, 'utf8') } catch (e) { return null } }
const short = p => p.replace(SKILLS + '/', '')

function deny(file, after, before) {
  const grew = before == null ? '' : ` (it is ${before} now)`
  process.stderr.write(
    `BLOCKED by cap-skill-slice-size.sh: ${short(file)} would be ${after} characters${grew}, ` +
    `and a split skill's core and rule slices must stay under ${LIMIT}. Claude Code re-attaches an ` +
    `invoked skill after compaction cut at ${LIMIT} characters, so rules past that point drop out of a run. ` +
    `Make room in the same change: move a rule to the slice that owns its phase (the core step map ` +
    `lists which slice owns what), or cut text that restates another rule. Then retry.\n`)
  process.exit(2)
}

let input
try { input = JSON.parse(fs.readFileSync(0, 'utf8')) } catch (e) { process.exit(0) }
const event = input.hook_event_name || ''
const tool = input.tool_name || ''
const ti = input.tool_input || {}

if (event === 'PreToolUse' && (tool === 'Write' || tool === 'Edit')) {
  const file = canonical(ti.file_path)
  if (!isCapped(file)) process.exit(0)
  const old = read(file)
  let next
  if (tool === 'Write') next = ti.content == null ? null : String(ti.content)
  else {
    if (old == null || ti.old_string == null || !old.includes(ti.old_string)) process.exit(0)
    const ns = String(ti.new_string == null ? '' : ti.new_string)
    next = ti.replace_all ? old.split(ti.old_string).join(ns) : old.replace(ti.old_string, () => ns)
  }
  if (next == null) process.exit(0)
  const after = chars(next)
  const before = old == null ? null : chars(old)
  // A write that shrinks a file already over the cap is the fix, never blocked.
  if (after >= LIMIT && (before == null || after > before)) deny(file, after, before)
  process.exit(0)
}

if (event === 'PostToolUse' && tool === 'Bash') {
  // The result of a shell write is not knowable before it runs, so the check
  // runs after it: a capped file the command names that is now over the cap.
  // Naming the file keeps an over-cap file some other session left from
  // flagging every unrelated command.
  const cmd = String(ti.command || '')
  const over = []
  for (const file of cappedFiles()) {
    const rel = short(file)
    const skill = rel.split('/')[0]
    if (!cmd.includes(skill) || !cmd.includes(path.basename(file))) continue
    const t = read(file)
    if (t != null && chars(t) >= LIMIT) over.push(`${rel} (${chars(t)})`)
  }
  if (over.length) {
    process.stderr.write(
      `cap-skill-slice-size.sh: this command left ${over.join(', ')} over the ${LIMIT}-character cap on a ` +
      `split skill's core and rule slices. Claude Code re-attaches an invoked skill after compaction cut at ` +
      `${LIMIT} characters, so rules past that point drop out of a run. Bring the file back under the cap now: ` +
      `move a rule to the slice that owns its phase, or cut text that restates another rule.\n`)
    process.exit(2)
  }
}
process.exit(0)
