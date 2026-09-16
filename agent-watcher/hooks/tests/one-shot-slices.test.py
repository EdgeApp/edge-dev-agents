#!/usr/bin/env python3
"""Contract test for the /one-shot core + references split.

Run: python3 ~/.config/agent-watcher/hooks/tests/one-shot-slices.test.py
     ONE_SHOT_DIR=<dir> python3 .../one-shot-slices.test.py   # test a staged tree

Claude Code truncates each re-attached skill body at 20,000 characters after a
compaction, so the core SKILL.md must stay under that and the phase rules must
live in reference files the core step map points at. The pre-split file is the
baseline: every rule id it carried must survive, exactly once, with a
byte-identical body.

Baseline source: fixtures/one-shot-pre-split.SKILL.md, a pinned copy of the
file the split was actually taken from. The scratchpad backup tarball is the
fallback; it predates the last live edits to SKILL.md, so it is not authoritative.
"""
import os, re, sys, tarfile

LIMIT = 20000
ONE_SHOT = os.environ.get('ONE_SHOT_DIR',
                          os.path.expanduser('~/.cursor/skills/one-shot'))
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'fixtures', 'one-shot-pre-split.SKILL.md')
BACKUP = os.environ.get(
    'ONE_SHOT_BACKUP',
    '/private/tmp/claude-501/-Users-eddy-git/'
    '4da88c80-1f1a-4ec1-8fda-10760f25f88f/scratchpad/pre-author-backup.tgz')
BACKUP_MEMBER = '.cursor/skills/one-shot/SKILL.md'

RULE_RE = re.compile(r'<rule id="([^"]+)">(.*?)</rule>', re.S)
fails = []


def rules_of(text):
    """{id: body} for every <rule> in text."""
    return {m.group(1): m.group(2) for m in RULE_RE.finditer(text)}


def read(path):
    return open(path, encoding='utf-8').read()


# --- baseline: the pre-split SKILL.md ----------------------------------------
if os.path.exists(FIXTURE):
    pre, baseline = read(FIXTURE), 'fixtures/one-shot-pre-split.SKILL.md'
elif os.path.exists(BACKUP):
    with tarfile.open(BACKUP) as tf:
        pre = tf.extractfile(BACKUP_MEMBER).read().decode('utf-8')
    baseline = BACKUP
else:
    print('SKIP: no pre-split baseline (fixture and backup tarball both absent)')
    sys.exit(0)
pre_rules = rules_of(pre)
if len(pre_rules) != len(RULE_RE.findall(pre)):
    fails.append('baseline has duplicate rule ids')

core_path = os.path.join(ONE_SHOT, 'SKILL.md')
refs_dir = os.path.join(ONE_SHOT, 'references')
core = read(core_path)
ref_files = sorted(f for f in os.listdir(refs_dir) if f.endswith('.md'))

# --- 1. core fits the re-attach budget ---------------------------------------
if len(core) >= LIMIT:
    fails.append('core SKILL.md is %d chars, must be under %d' % (len(core), LIMIT))

# --- 2 + 3. every rule survives, exactly once, byte for byte -----------------
seen = {}
for name, text in [('SKILL.md', core)] + [(f, read(os.path.join(refs_dir, f)))
                                          for f in ref_files]:
    for m in RULE_RE.finditer(text):
        rid = m.group(1)
        if rid in seen:
            fails.append('rule %s appears in both %s and %s' % (rid, seen[rid][0], name))
        seen[rid] = (name, m.group(2))

for rid, body in sorted(pre_rules.items()):
    if rid not in seen:
        fails.append('rule %s was lost in the split' % rid)
    elif seen[rid][1] != body:
        fails.append('rule %s body changed (was %d chars, now %d) in %s'
                     % (rid, len(body), len(seen[rid][1]), seen[rid][0]))
for rid in sorted(set(seen) - set(pre_rules)):
    fails.append('rule %s is new; the split may only move rules' % rid)

# --- 3b. no prose was lost either: the split moves text, never rewrites it ----
# Two lines are allowed to differ: the generic <rules> opener (each file carries its
# own), and the worktree-provisioning line, whose "per Per-task worktrees above" pointed
# at text that now lives in another file and was repointed to references/intake.md.
ALLOW_DROPPED = {
    '<rules description="Non-negotiable constraints.">',
    'First provision the workspace (per **Per-task worktrees** above): from the plan, create a co-located worktree for the target repo — plus any gui-dependency repos the task modifies, then `updot`-link them into the gui worktree — and `cd` into the primary repo\'s worktree. (Skip on manual non-watcher runs already inside a normal checkout.) Before setting agent_status=Developing, the plan file `plan-<gid>-<short-slug>.md` (asana-plan `create-plan-required`) must already exist and be attached via `asana-task-update.sh --attach-file`; a followup segment skips this. Then set agent_status=Developing and run `/im` using the approved `/asana-plan` output.',
}
split_lines = set()
for name, text in [('SKILL.md', core)] + [(f, read(os.path.join(refs_dir, f)))
                                          for f in ref_files]:
    split_lines |= {ln for ln in text.split('\n') if ln.strip()}
for ln in pre.split('\n'):
    if ln.strip() and ln not in split_lines and ln not in ALLOW_DROPPED:
        fails.append('line dropped in the split: %s' % ln[:120])

STEP_RE = re.compile(r'^<step id="([^"]+)"', re.M)
for sid in STEP_RE.findall(pre):
    hits = [n for n, t in [('SKILL.md', core)] +
            [(f, read(os.path.join(refs_dir, f))) for f in ref_files]
            if ('<step id="%s"' % sid) in t]
    if len(hits) != 1:
        fails.append('step %s appears in %d files (%s), expected 1'
                     % (sid, len(hits), ', '.join(hits) or 'none'))

# --- 4. the step map and the references agree --------------------------------
cited = set(re.findall(r'references/([A-Za-z0-9._-]+\.md)', core))
for f in sorted(set(ref_files) - cited):
    fails.append('references/%s exists but the core step map never names it' % f)
for f in sorted(cited - set(ref_files)):
    fails.append('core step map points at references/%s, which does not exist' % f)

# --- 5. each slice fits the same budget --------------------------------------
for f in ref_files:
    n = len(read(os.path.join(refs_dir, f)))
    if n >= LIMIT:
        fails.append('references/%s is %d chars, must be under %d' % (f, n, LIMIT))

# --- report ------------------------------------------------------------------
print('core SKILL.md: %d chars' % len(core))
for f in ref_files:
    print('  references/%-20s %d chars  %d bytes'
          % (f, len(read(os.path.join(refs_dir, f))),
             os.path.getsize(os.path.join(refs_dir, f))))
print('rules: %d baseline, %d placed (baseline: %s)'
      % (len(pre_rules), len(seen), baseline))

if fails:
    print('\nFAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('\nPASS')
