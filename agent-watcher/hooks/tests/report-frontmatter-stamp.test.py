#!/usr/bin/env python3
"""Contract tests for the run-report frontmatter and friction stamp in
require-clean-run-report.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/report-frontmatter-stamp.test.py
     (STAMP_SRC=<dir> tests a staged copy of the hook from one flat directory)

Covers:
  S1. generated / ended are overwritten with the attach time, started with the
      segment's version-stamp ts, whatever the report said.
  S2. repo / branch come from the task's worktree checkout (comma-joined for
      several repos); a task with no worktree keeps them blank.
  S3. slot_index from the slot record, metro_port / sim_udid from the spawn env
      (slot record when the env is unset); wrong hand values are replaced.
  S4. Orchestration Issues gets one machine-count line (hook blocks with the top
      hooks, tool errors, compactions) right after the section's comment, and a
      re-attach replaces it instead of adding a second.
  S5. A clean transcript (no blocks, no errors) adds no line; a missing
      transcript adds none and does not fail the hook.
  S6. Lines outside the frontmatter that look like keys are left alone.
"""
import json, os, re, shutil, subprocess, sys, tempfile

REAL = os.path.expanduser('~')
SRC = os.environ.get('STAMP_SRC')
GID = '998' + str(os.getpid()).zfill(10)
DOCMARK = f'/tmp/agent-report-doc-{GID}'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


TMP = tempfile.mkdtemp(prefix='fm-stamp-test-')
HOME = os.path.join(TMP, 'home')
STATE = os.path.join(TMP, 'state')
WTROOT = os.path.join(TMP, 'worktrees')
os.makedirs(os.path.join(STATE, 'agent-watcher/versions'))

HOOK_REL = '.config/agent-watcher/hooks/require-clean-run-report.sh'
staged = os.path.join(SRC, os.path.basename(HOOK_REL)) if SRC else ''
hook_src = staged if staged and os.path.exists(staged) else os.path.join(REAL, HOOK_REL)
HOOK = os.path.join(HOME, HOOK_REL)
os.makedirs(os.path.dirname(HOOK)); shutil.copy(hook_src, HOOK); os.chmod(HOOK, 0o755)
for rel in ['.config/agent-watcher/lib/attach-names.sh',
            '.config/agent-watcher/lib/worktree-root.sh',
            '.config/agent-watcher/lib/slots.js',
            '.config/agent-watcher/lib/transcript-friction.js',
            '.config/agent-watcher/hooks/lib/shell-word-resolve.sh',
            '.config/agent-watcher/hooks/lib/splice-judge-section.sh',
            '.config/agent-watcher/judge-report-section.sh',
            '.config/agent-watcher/lib/judge-log.sh',
            '.config/agent-watcher/hooks/strip-cmd-mentions.sh',
            '.config/agent-watcher/hooks/lib/reviewer-outage-noise.sh',
            '.config/agent-watcher/asana-config.json']:  # no template: the section-set lint is report-reattach's concern
    dst = os.path.join(HOME, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(os.path.join(REAL, rel)) and not os.path.exists(dst):
        os.symlink(os.path.join(REAL, rel), dst)

json.dump({}, open(os.path.join(HOME, '.config/agent-watcher/credentials.json'), 'w'))  # no token: no Asana calls
open(os.path.join(STATE, f'agent-watcher/versions/{GID}.jsonl'), 'w').write(
    json.dumps({'ts': '2026-10-20T09:00:00Z', 'model': 'opus', 'effort': 'high'}) + '\n')
json.dump({'slots': [{'slot_index': 4, 'task_gid': GID, 'sim_udid': 'SLOT-UDID', 'metro_port': 8184}]},
          open(os.path.join(STATE, 'agent-watcher/slots.json'), 'w'))


def mkrepo(name, branch):
    d = os.path.join(WTROOT, GID, name)
    os.makedirs(d)
    for c in (['git', 'init', '-q', '-b', branch], ['git', 'commit', '-q', '--allow-empty', '-m', 'x']):
        subprocess.run(c, cwd=d, check=True, capture_output=True,
                       env={**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t',
                            'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'})


BLOCK = '{"type":"user","content":"PreToolUse:Bash hook error: [~/.config/agent-watcher/hooks/%s.sh]: BLOCKED"}'
ERR = '{"type":"user","tool_result":{"is_error": true}}'


def transcript(name, blocks, errors, compacts):
    p = os.path.join(TMP, name)
    lines = []
    for hook, n in blocks.items():
        lines += [BLOCK % hook] * n
    lines += [ERR] * errors + ['{"subtype":"compact_boundary"}'] * compacts + ['{"type":"assistant"}']
    open(p, 'w').write('\n'.join(lines) + '\n')
    return p


REPORT = os.path.join(TMP, f'agent-run-report-{GID}-x.md')


def report():
    open(REPORT, 'w').write(
        '---\niteration: "1"\ngenerated: "2020-01-01T00:00:00Z"\nrepo: ""\nbranch: ""\npr: none\n'
        'started: "2030-01-01T00:00:00Z"\nended: "2030-01-01T00:00:00Z"\n'
        'slot_index: null         # from slots.js\nmetro_port: null\nsim_udid: "WRONG"\n---\n\n'
        '# Run report 1: x\n\n_iteration 1 · opus@high · generated 2020-01-01T00:00:00Z · session abc_\n\n'
        '## Summary\n\nrepo: not-frontmatter\n\n## Orchestration Issues\n<!-- cat: orchestration -->\n'
        '<!-- Friction with the harness\n     second comment line. -->\n_None observed._\n\n## Skill Gaps\n\n_None observed._\n')


def run(transcript_path, **extra):
    os.path.exists(DOCMARK) and os.remove(DOCMARK)
    e = {k: v for k, v in os.environ.items() if k not in ('AGENT_SIM_UDID', 'AGENT_METRO_PORT', 'ASANA_TOKEN')}
    e.update(HOME=HOME, XDG_STATE_HOME=STATE, AGENT_TASK_GID=GID, AGENT_WORKTREE_ROOT=WTROOT, ASANA_TOKEN='')
    e.update({k: str(v) for k, v in extra.items()})
    cmd = f'~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task {GID} --attach-file {REPORT} --attach-name agent-run-report.md'
    payload = {'session_id': 'sess-1', 'tool_input': {'command': cmd}}
    if transcript_path is not None:
        payload['transcript_path'] = transcript_path
    return subprocess.run([HOOK], input=json.dumps(payload), capture_output=True, text=True, env=e, timeout=120)


def fm(key):
    body = open(REPORT).read().split('---', 2)[1]
    m = re.search(rf'^{key}: *"?([^"\n]*?)"?\s*$', body, re.M)
    return m.group(1) if m else None


# S1-S3: one repo worktree, env sim + port, noisy transcript.
mkrepo('edge-react-gui', 'jon/feature-x')
T1 = transcript('t1.jsonl', {'require-skill-read-for-scripts': 22, 'require-clean-run-report': 3,
                             'require-subtasks-for-multi-repo-pr': 2, 'other-hook': 1}, 42, 3)
report()
p = run(T1, AGENT_SIM_UDID='ENV-UDID', AGENT_METRO_PORT='8190')
check('S0 hook passes', p.returncode == 0, p.stderr[-800:])
gen = fm('generated')
check('S1 generated overwritten with attach time', gen and gen != '2020-01-01T00:00:00Z' and gen.startswith('20'), gen)
check('S1 ended equals generated (attach time)', fm('ended') == gen, fm('ended'))
check('S1 started from the segment version stamp', fm('started') == '2026-10-20T09:00:00Z', fm('started'))
check('S1 visible stamp line carries the new generated time', f'generated {gen}' in open(REPORT).read(), open(REPORT).read()[:400])
check('S2 repo from worktree', fm('repo') == 'edge-react-gui', fm('repo'))
check('S2 branch from worktree', fm('branch') == 'jon/feature-x', fm('branch'))
check('S3 slot_index from slot record, unquoted', re.search(r'^slot_index: 4$', open(REPORT).read(), re.M) is not None, fm('slot_index'))
check('S3 metro_port from env', fm('metro_port') == '8190', fm('metro_port'))
check('S3 wrong sim_udid replaced from env', fm('sim_udid') == 'ENV-UDID', fm('sim_udid'))
check('S6 body line that looks like a key untouched', 'repo: not-frontmatter' in open(REPORT).read())
txt = open(REPORT).read()
sec = txt.split('## Orchestration Issues', 1)[1].split('## Skill Gaps', 1)[0]
lines = [l for l in sec.split('\n') if l.strip()]
want = ('- Machine count, this session: 28 hook blocks (require-skill-read-for-scripts.sh 22, '
        'require-clean-run-report.sh 3, require-subtasks-for-multi-repo-pr.sh 2), 42 tool errors, 3 compactions. <!-- friction-stamp -->')
check('S4 friction line placed after the section comment, before the agent text',
      len(lines) >= 4 and lines[3] == want and lines[4] == '_None observed._', '\n'.join(lines))

# S4 re-attach: replaced, not duplicated; S3 slot fallback when env unset.
T2 = transcript('t2.jsonl', {'require-clean-run-report': 5}, 0, 0)
p = run(T2)
txt = open(REPORT).read()
check('S4 re-attach keeps exactly one friction line', txt.count('<!-- friction-stamp -->') == 1, txt)
check('S4 re-attach line has the new counts', '5 hook blocks (require-clean-run-report.sh 5), 0 tool errors' in txt, txt)
check('S3 sim_udid and metro_port fall back to the slot record', fm('sim_udid') == 'SLOT-UDID' and fm('metro_port') == '8184',
      f"{fm('sim_udid')} {fm('metro_port')}")

# S5: clean transcript removes the line; missing transcript adds none.
T3 = transcript('t3.jsonl', {}, 0, 0)
p = run(T3)
check('S5 clean transcript: no friction line', p.returncode == 0 and '<!-- friction-stamp -->' not in open(REPORT).read(), p.stderr[-400:])
p = run(None)
check('S5 missing transcript: hook passes, no line', p.returncode == 0 and '<!-- friction-stamp -->' not in open(REPORT).read(), p.stderr[-400:])

# S2 several repos comma-join; none keeps blank.
mkrepo('edge-core-js', 'jon/feature-y')
report(); run(T3)
check('S2 two worktree repos comma-joined in order', fm('repo') == 'edge-core-js,edge-react-gui' and fm('branch') == 'jon/feature-y,jon/feature-x',
      f"{fm('repo')} {fm('branch')}")
shutil.rmtree(os.path.join(WTROOT, GID))
report(); run(T3)
check('S2 no worktree (Task deliverable): repo and branch stay blank', fm('repo') == '' and fm('branch') == '', f"{fm('repo')!r} {fm('branch')!r}")

os.path.exists(DOCMARK) and os.remove(DOCMARK)
shutil.rmtree(TMP)
print('\nall passed' if not fails else f'\n{len(fails)} FAILED: {", ".join(fails)}')
sys.exit(1 if fails else 0)
