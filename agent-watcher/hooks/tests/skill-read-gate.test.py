#!/usr/bin/env python3
"""Contract tests for the skill-read gate: marker crediting and lazy
transcript-evidence credit.

Run: python3 ~/.config/agent-watcher/hooks/tests/skill-read-gate.test.py
     (SKILL_READ_HOOKS_DIR=<dir> tests a staged copy of the hooks tree)

Hooks run with HOME pointed at a temp dir holding synthetic skills, so the
real ~/.cursor/skills and live markers are never touched.

  1. require-skill-read-for-scripts.sh transcript evidence: pre-compact body
     only blocks; post-compact invoked_skills full allows, cut at 20000 blocks;
     an edited skill blocks; a slash-command meta body (with placeholder
     substitution) allows; a token-capped Read blocks; paged Reads covering
     every line allow, partial pages block; a nested compact_boundary does not
     cut the scan; an unparsable boundary candidate fails closed.
  2. Gate shape: --help/-h only invocations are exempt; the deny message says
     the whole command was cancelled; over-cap skills get the paging pointer
     and no marker; no AGENT_TASK_GID is a no-op.
  3. mark-skill-read.sh: full Read credits, token-capped Read does not, paged
     Reads credit once covered, an edit between pages resets coverage; cat
     credits only when its stdout reaches the transcript; Skill tool credits.
  4. The other skill-read gates (lint-md-on-write.sh no-slop on Write,
     slack-prose-gate.sh no-slop on Slack sends, require-skill-for-file.sh
     agents-md on AGENTS.md, orch and interactive keys) try transcript credit
     on the would-block path: post-compact invoked_skills full allows, cut at
     20000 or an edited skill blocks with the body delivered.
"""
import glob, json, os, shutil, subprocess, sys, tempfile, time

HOOKS = os.path.expanduser(os.environ.get('SKILL_READ_HOOKS_DIR', '~/.config/agent-watcher/hooks'))
GATE = f'{HOOKS}/require-skill-read-for-scripts.sh'
MARK = f'{HOOKS}/mark-skill-read.sh'
GID = f'SRGTEST{os.getpid()}'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


home = tempfile.mkdtemp(prefix='srg-home-')
os.makedirs(f'{home}/.config/agent-watcher')
os.symlink(HOOKS, f'{home}/.config/agent-watcher/hooks')
SK = f'{home}/.cursor/skills'
BASE_ENV = {**os.environ, 'HOME': home}


def write_skill(name, body):
    os.makedirs(f'{SK}/{name}/scripts', exist_ok=True)
    text = f'---\nname: {name}\ndescription: test skill\n---\n\n{body}'
    open(f'{SK}/{name}/SKILL.md', 'w').write(text)
    return text


SMALL = write_skill('alpha', '<goal>Alpha goal.</goal>\n<rule id="a">Pass $ARGUMENTS through.</rule>\n' + ''.join(f'<step id="{i}">alpha step {i}</step>\n' for i in range(40)))
BIG_BODY = ''.join(f'<rule id="r{i}">{"big rule text " * 30}</rule>\n' for i in range(200))  # ~88KB, 200+ lines, over the 50KB cap
BIG = write_skill('bravo', BIG_BODY)


def body_of(text):
    return text.split('\n---\n', 1)[1].strip()


def lines_of(text):
    ls = text.split('\n')
    return ls[:-1] if ls and ls[-1] == '' else ls


SID = f'SRGSESS{os.getpid()}'


def clear():
    for f in glob.glob(f'/tmp/agent-skill-read-{GID}-*') + glob.glob(f'/tmp/agent-skill-read-sess-{SID}-*'):
        os.remove(f)


def marker(sk):
    return os.path.exists(f'/tmp/agent-skill-read-{GID}-{sk}')


def run(script, payload, gid=True):
    env = dict(BASE_ENV)
    if gid:
        env['AGENT_TASK_GID'] = GID
    else:
        env.pop('AGENT_TASK_GID', None)
    return subprocess.run([script], input=json.dumps(payload), capture_output=True, text=True, env=env)


# ---- transcript builders ----
def meta(name, text, args=None):
    content = f'Base directory for this skill: /Users/x/.claude/skills/{name}\n\n{text}'
    if args:
        content += f'\n\n\nARGUMENTS: {args}'
    return {'type': 'user', 'isMeta': True, 'isSidechain': False, 'message': {'role': 'user', 'content': [{'type': 'text', 'text': content}]}}


def boundary():
    return {'type': 'system', 'subtype': 'compact_boundary', 'content': 'Conversation compacted', 'isSidechain': False}


def invoked(name, content):
    return {'type': 'attachment', 'isSidechain': False, 'attachment': {'type': 'invoked_skills', 'skills': [{'name': name, 'path': f'userSettings:{name}', 'content': content}]}}


def read_result(name, text, start, count, capped=False):
    ls = lines_of(text)
    page = ls[start - 1:start - 1 + count]
    f = {'filePath': f'/Users/x/.cursor/skills/{name}/SKILL.md', 'content': '\n'.join(page), 'numLines': len(page), 'startLine': start, 'totalLines': len(ls)}
    if capped:
        f['truncatedByTokenCap'] = True
    return f


def read_line(name, text, start, count, capped=False):
    f = read_result(name, text, start, count, capped)
    shown = '\n'.join(f'{start + i}\t{l}' for i, l in enumerate(f['content'].split('\n')))
    return {'type': 'user', 'isSidechain': False, 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't', 'content': shown}]}, 'toolUseResult': {'type': 'text', 'file': f}}


def transcript(rows, raw_tail=''):
    fd, p = tempfile.mkstemp(prefix='srg-transcript-', suffix='.jsonl', dir=home)
    with os.fdopen(fd, 'w') as fh:
        for r in rows:
            fh.write(json.dumps(r) + '\n')
        fh.write(raw_tail)
    return p


def gate(cmd, tp=None, gid=True):
    payload = {'tool_name': 'Bash', 'tool_input': {'command': cmd}}
    if tp:
        payload['transcript_path'] = tp
    return run(GATE, payload, gid)


A_CMD = f'{SK}/alpha/scripts/run.sh --go'
B_CMD = f'{SK}/bravo/scripts/run.sh --go'
A_DELIVERED = body_of(SMALL).replace('$ARGUMENTS', 'the args')

try:
    # ---- 1. transcript evidence ----
    clear()
    tp = transcript([meta('alpha', A_DELIVERED), boundary()])
    r = gate(A_CMD, tp)
    check('pre-compact body only: block', r.returncode == 2, r.stderr[:200])

    clear()
    tp = transcript([meta('bravo', body_of(BIG)), boundary(), invoked('bravo', 'Base directory for this skill: /Users/x/.claude/skills/bravo\n\n' + body_of(BIG))])
    r = gate(B_CMD, tp)
    check('post-compact invoked_skills full: allow and marker written', r.returncode == 0 and marker('bravo'), r.stderr[:200])

    clear()
    tp = transcript([boundary(), invoked('bravo', body_of(BIG))])
    r = gate(B_CMD, tp)
    check('invoked_skills entry without a path header still credits by name', r.returncode == 0 and marker('bravo'), r.stderr[:200])

    clear()
    cut = ('Base directory for this skill: /Users/x/.claude/skills/bravo\n\n' + body_of(BIG))[:20000]
    tp = transcript([boundary(), invoked('bravo', cut + '\n\n[... skill content truncated for compaction; use Read on the skill path if you need the full text]')])
    r = gate(B_CMD, tp)
    check('invoked_skills cut at 20000: block, no marker', r.returncode == 2 and not marker('bravo'), r.stderr[:200])

    clear()
    tp = transcript([meta('alpha', A_DELIVERED, 'the args')])
    saved = open(f'{SK}/alpha/SKILL.md').read()
    open(f'{SK}/alpha/SKILL.md', 'w').write(saved.replace('alpha step 7', 'alpha step 7 (edited)'))
    r = gate(A_CMD, tp)
    check('skill edited since delivery: block', r.returncode == 2, r.stderr[:200])
    open(f'{SK}/alpha/SKILL.md', 'w').write(saved)

    clear()
    r = gate(A_CMD, tp)
    check('slash-command meta body with substituted $ARGUMENTS: allow', r.returncode == 0 and marker('alpha'), r.stderr[:200])

    clear()
    n = len(lines_of(BIG))
    tp = transcript([read_line('bravo', BIG, 1, n // 2, capped=True)])
    r = gate(B_CMD, tp)
    check('token-capped Read only: block', r.returncode == 2 and not marker('bravo'), r.stderr[:200])

    clear()
    tp = transcript([read_line('bravo', BIG, 1, n // 2, capped=True), read_line('bravo', BIG, n // 2 + 1, n)])
    r = gate(B_CMD, tp)
    check('paged Reads covering every line: allow', r.returncode == 0 and marker('bravo'), r.stderr[:200])

    clear()
    tp = transcript([read_line('bravo', BIG, 1, n // 2, capped=True), read_line('bravo', BIG, n // 2 + 2, n)])
    r = gate(B_CMD, tp)
    check('partial pages (one line missing): block', r.returncode == 2 and not marker('bravo'), r.stderr[:200])

    clear()
    tp = transcript([read_line('bravo', BIG, 1, n // 2), boundary(), read_line('bravo', BIG, n // 2 + 1, n)])
    r = gate(B_CMD, tp)
    check('pages split by compaction: block', r.returncode == 2, r.stderr[:200])

    clear()
    nested = {'type': 'user', 'isSidechain': False, 'message': {'role': 'user', 'content': 'x'}, 'toolUseResult': {'parsed': {'type': 'system', 'subtype': 'compact_boundary'}, 'note': 'skills/alpha'}}
    tp = transcript([meta('alpha', A_DELIVERED), nested])
    r = gate(A_CMD, tp)
    check('nested compact_boundary object does not cut the scan: allow', r.returncode == 0, r.stderr[:200])

    clear()
    tp = transcript([meta('alpha', A_DELIVERED)], raw_tail='{"type":"system","subtype":"compact_boundary","content":"trunc')
    r = gate(A_CMD, tp)
    check('unparsable compact_boundary candidate: fail closed (block)', r.returncode == 2, r.stderr[:200])

    clear()
    side = meta('alpha', A_DELIVERED)
    side['isSidechain'] = True
    r = gate(A_CMD, transcript([side]))
    check('sidechain delivery does not credit: block', r.returncode == 2, r.stderr[:200])

    clear()
    r = gate(A_CMD, '/nonexistent/transcript.jsonl')
    check('missing transcript: block (deny-with-body as before)', r.returncode == 2 and marker('alpha'), r.stderr[:200])

    # ---- 2. gate shape ----
    clear()
    r = gate(A_CMD)
    check('deny message: whole command cancelled, re-run all of it', r.returncode == 2 and 'NOTHING in it ran' in r.stderr and 'ENTIRE command' in r.stderr, r.stderr[:300])
    check('under-cap skill delivered in full with marker', 'delivered in full' in r.stderr and marker('alpha'))

    clear()
    r = gate(B_CMD)
    check('over-cap skill: paging pointer, no marker', r.returncode == 2 and 'in pages (offset/limit)' in r.stderr and f'every line 1-{n}' in r.stderr and not marker('bravo'), r.stderr[-400:])

    clear()
    for cmd in (f'{SK}/alpha/scripts/run.sh --help', f'{SK}/alpha/scripts/run.sh -h 2>&1 | head -20', f'bash {SK}/alpha/scripts/run.sh --help'):
        r = gate(cmd)
        check(f'help-only exempt: {cmd.replace(SK, "SK")}', r.returncode == 0 and not marker('alpha'), r.stderr[:200])
    r = gate(f'{SK}/alpha/scripts/run.sh --help && {SK}/alpha/scripts/run.sh --go')
    check('help plus a real invocation: block', r.returncode == 2)
    clear()
    r = gate(f'{SK}/alpha/scripts/run.sh --help-me')
    check('--help-me is not help-only: block', r.returncode == 2)

    write_skill('task-review', '<goal>Task review.</goal>\n')
    write_skill('im', '<goal>Implement.</goal>\n')
    clear()
    r = gate('~/.cursor/asana-get-context.sh 12345')
    check('shared asana-get-context.sh needs task-review', r.returncode == 2 and '/task-review contract' in r.stderr, r.stderr[:200])
    r = gate('cd /x && ~/.cursor/lint-commit.sh -m "msg"')
    check('shared lint-commit.sh needs im', r.returncode == 2 and '/im contract' in r.stderr, r.stderr[:200])
    clear()
    r = gate('~/.cursor/lint-commit.sh --help')
    check('shared script help-only exempt', r.returncode == 0 and not marker('im'), r.stderr[:200])
    r = gate(f"cat > /tmp/r.md <<'EOF'\nran {SK}/alpha/scripts/run.sh --go\nEOF")
    check('heredoc merely quoting a script path does not fire', r.returncode == 0, r.stderr[:200])

    clear()
    r = gate(A_CMD, gid=False)
    check('no AGENT_TASK_GID: gate no-op', r.returncode == 0 and not r.stderr and not marker('alpha'))
    r = run(MARK, {'tool_name': 'Skill', 'tool_input': {'skill': 'alpha'}}, gid=False)
    check('no AGENT_TASK_GID and no session_id: mark no-op', r.returncode == 0 and not os.path.exists('/tmp/agent-skill-read--alpha') and not os.path.exists('/tmp/agent-skill-read-sess--alpha'))

    # ---- 3. mark-skill-read.sh ----
    def mread(name, text, start=None, count=None, capped=False, fp=None):
        ls = lines_of(text)
        s, c = start or 1, count or len(ls)
        ti = {'file_path': fp or f'/Users/x/.cursor/skills/{name}/SKILL.md'}
        if start is not None:
            ti['offset'], ti['limit'] = start, count
        return run(MARK, {'tool_name': 'Read', 'session_id': 'S', 'tool_input': ti, 'tool_response': {'type': 'text', 'file': read_result(name, text, s, c, capped)}})

    clear()
    mread('alpha', SMALL)
    check('mark: full uncapped Read credits', marker('alpha'))

    clear()
    mread('bravo', BIG, None, n // 2, capped=True)
    check('mark: token-capped no-offset Read does not credit', not marker('bravo'))
    mread('bravo', BIG, n // 2 + 1, n - n // 2 - 1)
    check('mark: pages short of the last line do not credit', not marker('bravo'))
    mread('bravo', BIG, n, 1)
    check('mark: paged Reads credit once every line is covered', marker('bravo'))

    clear()
    mread('bravo', BIG, None, n // 2, capped=True)
    saved = open(f'{SK}/bravo/SKILL.md').read()
    edited = saved.replace('<rule id="r150">', '<rule id="r150" edited="1">')
    open(f'{SK}/bravo/SKILL.md', 'w').write(edited)
    mread('bravo', edited, n // 2 + 1, n)
    check('mark: an edit between pages resets coverage', not marker('bravo'))
    open(f'{SK}/bravo/SKILL.md', 'w').write(saved)

    def mcat(cmd, stdout, **extra):
        return run(MARK, {'tool_name': 'Bash', 'session_id': 'S', 'tool_input': {'command': cmd}, 'tool_response': {'stdout': stdout, 'stderr': '', 'interrupted': False, **extra}})

    AP = f'{SK}/alpha/SKILL.md'
    clear(); mcat(f'cat {AP}', SMALL)
    check('mark: plain cat whose stdout holds the body credits', marker('alpha'))
    clear(); mcat(f'cat {AP} > /tmp/copy.md', '')
    check('mark: cat redirected to a file does not credit', not marker('alpha'))
    clear(); mcat(f'cat {AP} >> /tmp/copy.md', SMALL)
    check('mark: cat appended to a file does not credit (even with stdout)', not marker('alpha'))
    clear(); mcat(f'X=$(cat {AP}); echo ok', 'ok')
    check('mark: cat captured by $( ) does not credit', not marker('alpha'))
    clear(); mcat(f'cat {AP} | grep rule', 'rule')
    check('mark: cat piped onward does not credit', not marker('alpha'))
    clear(); mcat(f'cat {AP} 2>/dev/null', SMALL)
    check('mark: cat with stderr silenced credits', marker('alpha'))
    clear(); mcat(f'cat {SK}/bravo/SKILL.md', BIG[:30000], persistedOutputPath='/tmp/x.txt', persistedOutputSize=len(BIG))
    check('mark: cat persisted to a side file does not credit', not marker('bravo'))
    clear(); mcat(f"cat > /tmp/note.md <<'EOF'\nsee {AP}\nEOF", '')
    check('mark: heredoc write mentioning a SKILL.md does not credit', not marker('alpha'))

    clear(); run(MARK, {'tool_name': 'Skill', 'tool_input': {'skill': 'plugin:alpha'}})
    check('mark: Skill tool credits (prefix stripped)', marker('alpha'))

    # ---- 4. transcript credit on the other skill-read gates ----
    lint_stub = f'{SK}/no-slop/scripts/no-slop-lint.sh'
    NOSLOP = write_skill('no-slop', ''.join(f'<rule id="n{i}">{"no slop rule text " * 15}</rule>\n' for i in range(100)))  # ~27KB: over the 20000 cut, under the 50KB cap
    open(lint_stub, 'w').write('#!/bin/sh\nexit 0\n')
    os.chmod(lint_stub, 0o755)
    AGENTSMD = write_skill('agents-md', ''.join(f'<rule id="g{i}">{"agents md rule text " * 15}</rule>\n' for i in range(100)))
    os.makedirs(f'{home}/work', exist_ok=True)

    def with_tp(payload, tp):
        return {**payload, 'transcript_path': tp}

    def lintmd(tp, gid=True):
        return run(f'{HOOKS}/lint-md-on-write.sh', with_tp({'tool_name': 'Write', 'tool_input': {'file_path': f'{home}/work/doc.md', 'content': 'Plain text.\n'}}, tp), gid)

    def slack(tp, gid=True):
        return run(f'{HOOKS}/slack-prose-gate.sh', with_tp({'tool_name': 'mcp__claude_ai_Slack__slack_send_message', 'tool_input': {'channel_id': 'C1', 'message': 'Plain text.'}}, tp), gid)

    def skillfile(tp, gid=True):
        return run(f'{HOOKS}/require-skill-for-file.sh', with_tp({'tool_name': 'Write', 'session_id': SID, 'tool_input': {'file_path': f'{home}/work/AGENTS.md', 'content': 'x\n'}}, tp), gid)

    def slack_denied(r):
        return r.returncode == 0 and '"permissionDecision":"deny"' in r.stdout and 'no-slop contract' in r.stdout

    GATES = [
        ('lint-md-on-write', 'no-slop', NOSLOP, lintmd, lambda r: r.returncode == 2 and 'no-slop contract' in r.stderr, lambda r: r.returncode == 0 and not r.stderr, True),
        ('slack-prose-gate', 'no-slop', NOSLOP, slack, slack_denied, lambda r: r.returncode == 0 and 'deny' not in r.stdout, True),
        ('require-skill-for-file', 'agents-md', AGENTSMD, skillfile, lambda r: r.returncode == 2 and '`agents-md` skill' in r.stderr, lambda r: r.returncode == 0 and not r.stderr, True),
        ('require-skill-for-file interactive', 'agents-md', AGENTSMD, skillfile, lambda r: r.returncode == 2 and '`agents-md` skill' in r.stderr, lambda r: r.returncode == 0 and not r.stderr, False),
    ]
    for label, sk, text, hook, blocked, allowed, orch in GATES:
        mk = (lambda: marker(sk)) if orch else (lambda: os.path.exists(f'/tmp/agent-skill-read-sess-{SID}-{sk}'))
        header = f'Base directory for this skill: /Users/x/.claude/skills/{sk}\n\n'
        full = transcript([meta(sk, body_of(text)), boundary(), invoked(sk, header + body_of(text))])

        clear()
        r = hook(full, gid=orch)
        check(f'{label}: post-compact invoked_skills full: allow and marker written', allowed(r) and mk(), (r.stdout + r.stderr)[:200])

        clear()
        cut = (header + body_of(text))[:20000]
        r = hook(transcript([boundary(), invoked(sk, cut + '\n\n[... skill content truncated for compaction; use Read on the skill path if you need the full text]')]), gid=orch)
        check(f'{label}: invoked_skills cut at 20000: block with body', blocked(r) and 'delivered in full' in (r.stdout + r.stderr), (r.stdout + r.stderr)[:200])

        clear()
        saved = open(f'{SK}/{sk}/SKILL.md').read()
        open(f'{SK}/{sk}/SKILL.md', 'w').write(saved.replace('id="n7"', 'id="n7" edited="1"').replace('id="g7"', 'id="g7" edited="1"'))
        r = hook(full, gid=orch)
        open(f'{SK}/{sk}/SKILL.md', 'w').write(saved)
        check(f'{label}: skill edited since delivery: block', blocked(r), (r.stdout + r.stderr)[:200])

        clear()
        r = hook('/nonexistent/transcript.jsonl', gid=orch)
        check(f'{label}: missing transcript: block (deny-with-body as before)', blocked(r) and mk(), (r.stdout + r.stderr)[:200])

    # ---- timing (informational): scan cost on a synthetic 30MB transcript ----
    clear()
    filler = {'type': 'user', 'isSidechain': False, 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't', 'content': 'x' * 3000}]}}
    big_rows = [meta('alpha', A_DELIVERED)] + [filler] * 10000
    tp = transcript(big_rows)
    t0 = time.time(); r = gate(A_CMD, tp); dt = time.time() - t0
    check(f'30MB transcript scan allows in under 2s ({dt:.2f}s, {os.path.getsize(tp) // 1048576}MB)', r.returncode == 0 and dt < 2.0, r.stderr[:200])
finally:
    clear()
    shutil.rmtree(home, ignore_errors=True)

print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
