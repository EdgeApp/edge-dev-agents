#!/usr/bin/env python3
"""True-positive / false-positive vectors for the command-parsing PreToolUse gates.

Run: python3 ~/.config/agent-watcher/hooks/tests/hook-false-positives.test.py

Every vector below is the shape of a real block from an eval cohort, with
synthetic ids. Each gate must keep blocking its true positives and stop
blocking the false positives:

  guard-piped-watcher-scripts.sh  per-segment rewrite of `watcher.sh | tail`,
                                  `| sed -n <n>,<m>p`, and redirects on the
                                  dropped stage; unrelated pipes later in the
                                  command pass untouched; filter stages and
                                  --attach-name commands still block, quoting
                                  the segment at fault; a helper piped inside
                                  $(...), backticks, or <(...) blocks.
  strip-cmd-mentions.sh           output length always equals input length, so
                                  offset-mapping callers keep the stripped view.
  require-skill-read-for-scripts.sh the deny quotes the gated segment and says
                                  a preceding heredoc write was cancelled too.
  require-tdd-current.sh          a doc too large for a pipe buffer is still
                                  read as stamped; a stale stamp still blocks.
  require-maestro-device.sh       --device "$VAR" resolves (same-command
                                  assignment, then env) before the iOS/Android
                                  split; $(...) blocks; list_devices skips the
                                  booted guard; take_screenshot/inspect_screen
                                  keep it.
  require-playbook-before-drive.sh only real drives fire (not --version, ls,
                                  grep, list_devices, take_screenshot,
                                  inspect_screen).
  require-plan-before-developing.sh a plan written earlier in the same command,
                                  a scratchpad plan, or a fresh followup-scope
                                  check on a followup segment passes.
  require-subtasks-for-multi-repo-pr.sh only --asana-attach calls are gated.
  cmd-executes.sh                 timeout/gtimeout/env/nice/nohup/command/exec/
                                  time wrappers count as executing the program;
                                  `command -v` and wrapped readers do not.
  lib/md-write-target.sh          quoted redirect/tee targets are read from the
                                  raw command and resolved.
  lint-md-on-write.sh             scratchpad paths and $VAR targets that
                                  resolve into allowlisted dirs pass.

Side effects are confined to temp dirs and /tmp files named with TEST_GID.
xcrun and adb are PATH stubs, so no simulator or device is needed.
"""
import json, os, shutil, subprocess, sys, tempfile, time

HOOKS = os.path.expanduser('~/.config/agent-watcher/hooks')
AW = '~/.config/agent-watcher'
TEST_GID = '9090909090909091'
UDID = '11111111-2222-3333-4444-555555555555'
OTHER_UDID = '3789F093-696C-4EA3-95F2-23587B7364D4'
SERIAL = '314c594c53563398'
EM = chr(0x2014)
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def hook(name, cmd=None, tool='Bash', tool_input=None, env=None, cwd='/nonexistent'):
    payload = {'tool_name': tool, 'cwd': cwd,
               'tool_input': tool_input if tool_input is not None else {'command': cmd}}
    e = dict(os.environ)
    for k in ('AGENT_TASK_GID', 'AGENT_SIM_UDID', 'AGENT_METRO_PORT'):
        e.pop(k, None)
    e.update(env or {})
    p = subprocess.run([os.path.join(HOOKS, name)], input=json.dumps(payload),
                       capture_output=True, text=True, env=e, timeout=60)
    return p.returncode, p.stdout, p.stderr


# ---------------------------------------------------------------- piped watcher
def piped():
    env = {'AGENT_TASK_GID': TEST_GID}
    us = f'{AW}/update-status.sh {TEST_GID}'

    def rewrite(label, cmd, want):
        rc, out, err = hook('guard-piped-watcher-scripts.sh', cmd, env=env)
        got = json.loads(out)['hookSpecificOutput']['updatedInput']['command'] if rc == 0 and out.strip() else None
        check(f'piped rewrite: {label}', got == want, f'rc={rc} got={got!r} err={err[:120]}')
        if got is not None:
            syn = subprocess.run(['bash', '-n', '-c', got], capture_output=True, text=True)
            check(f'piped rewrite is valid bash: {label}', syn.returncode == 0, syn.stderr[:160])

    def passes(label, cmd):
        rc, out, err = hook('guard-piped-watcher-scripts.sh', cmd, env=env)
        check(f'piped passes untouched: {label}', rc == 0 and not out.strip(), f'rc={rc} out={out[:120]} err={err[:120]}')

    def blocks(label, cmd):
        rc, out, err = hook('guard-piped-watcher-scripts.sh', cmd, env=env)
        check(f'piped blocks: {label}', rc == 2 and 'BLOCKED' in err, f'rc={rc} out={out[:120]}')

    # False positive from the investigation: watcher is bare, a LATER segment pipes.
    passes('bare watcher, later grep | head',
           f"{AW}/update-status.sh 1 Reviewing 2>&1; gh pr view 6 --json body > /tmp/b.md; grep -n 'x' /tmp/b.md | head -6")
    passes('reader cat of a watcher path', f'cat {AW}/hooks/require-subtasks-for-multi-repo-pr.sh 2>/dev/null | head -60')
    passes('heredoc quoting a piped call', f"cat > /tmp/agent-state-{TEST_GID}.md <<'EOF'\nran {us} Complete 2>&1 | tail -5\nEOF")
    passes('echo quoting a piped call', f'echo "{us} Complete | tail -2"')

    rewrite('Complete | tail (completion carve-out dropped)', f'{us} Complete 2>&1 | tail -5', f'{us} Complete 2>&1')
    rewrite('Reviewing | tail; later pipes kept',
            f'{us} Reviewing 2>&1 | tail -2; echo "=== checks ==="; gh pr checks 228 2>&1 | head -20',
            f'{us} Reviewing 2>&1 ; echo "=== checks ==="; gh pr checks 228 2>&1 | head -20')
    rewrite('&& operator rejoined with a space', f'{us} Testing 2>&1 | tail -2 && echo ok', f'{us} Testing 2>&1 && echo ok')
    rewrite('quoted pipes in later jq survive',
            f"{us} Testing 2>&1 | tail -2; jq '.a | .b' env.json > /tmp/e.json && mv /tmp/e.json env.json",
            f"{us} Testing 2>&1 ; jq '.a | .b' env.json > /tmp/e.json && mv /tmp/e.json env.json")
    rewrite('check-followup-scope | head -40, then other script | head',
            f'{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | head -40; echo "=== TDD ==="; ~/.cursor/skills/asana-field-value.sh {TEST_GID} "TDD?" 2>&1 | head -5',
            f'{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 ; echo "=== TDD ==="; ~/.cursor/skills/asana-field-value.sh {TEST_GID} "TDD?" 2>&1 | head -5')
    rewrite('mid-command watcher after cd',
            f'cd ~/git && echo "=== lane ==="; {AW}/lane-release.sh --task-gid {TEST_GID} --repos r 2>&1 | tail -15; echo done',
            f'cd ~/git && echo "=== lane ==="; {AW}/lane-release.sh --task-gid {TEST_GID} --repos r 2>&1 ; echo done')
    rewrite('quoted $HOME path behind timeout, newline operator',
            f'timeout 30 "$HOME/.config/agent-watcher/update-status.sh" {TEST_GID} Testing | tail -n 3\necho next',
            f'timeout 30 "$HOME/.config/agent-watcher/update-status.sh" {TEST_GID} Testing\necho next')
    rewrite('subshell group keeps its closing paren', f'({us} Reviewing | tail -2) && echo ok', f'({us} Reviewing) && echo ok')

    # Truncation stages beyond head/tail, and redirections on the dropped stage.
    rewrite('sed -n range, quoted, later segments kept',
            f"{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | sed -n '1,14p'; cd ~/git/x && gh api graphql -f query='{{ a }}' --jq '.b | .c'",
            f"{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 ; cd ~/git/x && gh api graphql -f query='{{ a }}' --jq '.b | .c'")
    rewrite('two piped watchers, tail then unquoted sed -n range',
            f'{AW}/set-tested.sh {TEST_GID} "Unit Tests" 2>&1 | tail -1; {AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | sed -n 1,8p',
            f'{AW}/set-tested.sh {TEST_GID} "Unit Tests" 2>&1 ; {AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1')
    rewrite('sed -n range then unrelated gh segments',
            f"{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | sed -n '1,12p'; gh pr view 1088 --json state; echo \"$AGENT_ORCH_VERSION\"",
            f"{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 ; gh pr view 1088 --json state; echo \"$AGENT_ORCH_VERSION\"")
    rewrite('redirect on the dropped stage moves ahead of the 2>&1 dup',
            f'{us} Complete 2>&1 | tail -2 > /tmp/out.txt', f'{us} Complete > /tmp/out.txt 2>&1')
    rewrite('redirect on the dropped stage, no dup to reorder',
            f'{us} Complete | tail -2 > /tmp/out.txt && echo ok', f'{us} Complete > /tmp/out.txt && echo ok')

    blocks('non head/tail downstream stage', f'{us} Complete 2>&1 | grep -i error')
    # Stages are matched raw: a blanked quoted span must not read as a bare tail.
    blocks('quoted argument on a truncation stage', f'{us} Complete | tail -2 "$(echo x)"')
    blocks('--attach-name command is never rewritten',
           f'~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task {TEST_GID} --attach-file /tmp/r.md --attach-name agent-run-report.md; {us} Complete | tail -2')
    # Substitutions: never rewritten, always blocked with the run-it-bare message.
    def subst_blocks(label, cmd):
        rc, out, err = hook('guard-piped-watcher-scripts.sh', cmd, env=env)
        check(f'piped blocks in substitution: {label}', rc == 2 and 'inside a command substitution' in err, f'rc={rc} out={out[:120]}')

    subst_blocks('$(watcher 2>&1 | tail -1)', f'X=$({AW}/update-status.sh 1 Testing 2>&1 | tail -1); echo $X')
    subst_blocks('backticks', f'X=`{us} Testing 2>&1 | tail -1`; echo $X')
    subst_blocks('$(...) inside double quotes', f'echo "result: $({us} Testing 2>&1 | tail -1)"')
    subst_blocks('process substitution', f'diff <({us} Testing | head -1) /tmp/x')
    subst_blocks('nested $(...)', f'Y=$(echo $({us} Testing | tail -1))')
    subst_blocks('quoted $HOME path behind timeout, grep stage',
                 f'X=$(timeout 30 "$HOME/.config/agent-watcher/set-tested.sh" 1 2>&1 | grep -c ok)')
    subst_blocks('after an unquoted heredoc', f'cat <<EOF > /tmp/a\nx\nEOF\nX=$({us} Testing | tail -1)')
    passes('$(cat watcher | head) reader', f'X=$(cat {AW}/update-status.sh | head -3)')
    passes('$(watcher) unpiped, pipe outside', f'R=$({us} Testing 2>&1); echo "$R" | tail -1')
    passes('quoted heredoc quoting a substitution', f"cat > /tmp/agent-state-{TEST_GID}.md <<'EOF'\nran X=$({us} Testing | tail -1)\nEOF")
    passes('single-quoted substitution text', f"echo 'X=$({us} Testing | tail -1)'")
    passes('--reason "$(cat f | head)" on a bare watcher', f'{us} Testing --reason "$(cat /tmp/r | head -3)"')
    passes('quoted pipe inside $(watcher ...)', f'X=$({us} Testing --reason "a | b")')
    passes('pipe only in a nested substitution arg', f'X=$({us} Testing $(echo a | tr a b))')

    # A segment the rewrite cannot make safe blocks the call and is quoted back,
    # so the retry edits that stage instead of re-deriving the whole command.
    def blocks_naming(label, cmd, seg):
        rc, out, err = hook('guard-piped-watcher-scripts.sh', cmd, env=env)
        check(f'piped block quotes the offending segment: {label}',
              rc == 2 and 'BLOCKED' in err and seg in err, f'rc={rc} err={err[:400]}')

    blocks_naming('rewritable tail segment, grep segment at fault',
                  f'{AW}/set-tested.sh {TEST_GID} "iOS Sim" 2>&1 | tail -2; {AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | grep -E "marker" | head -6',
                  f'{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | grep -E "marker" | head -6')
    blocks_naming('grep segment after an ungated substitution',
                  f'echo "TDD: $(~/.cursor/skills/asana-field-value.sh {TEST_GID} \'TDD?\' 2>&1 | tail -1)"; {AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | grep -E "marker"',
                  f'{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1 | grep -E "marker"')

    rc, _, _ = hook('guard-piped-watcher-scripts.sh', f'{us} Complete | tail -2', env={})
    check('piped no-op outside orch sessions', rc == 0)


# ---------------------------------------------------------------- strip-cmd-mentions
def stripmentions():
    """Output length IS the contract: a caller that sees a mismatch drops the
    stripped view and pattern-matches the raw command instead."""
    def same_length(label, cmd):
        p = subprocess.run([os.path.join(HOOKS, 'strip-cmd-mentions.sh')], input=cmd,
                           capture_output=True, text=True, timeout=30)
        check(f'strip-cmd-mentions length preserved: {label}', len(p.stdout) == len(cmd),
              f'in={len(cmd)} out={len(p.stdout)}')

    same_length('unterminated heredoc', "cat > /tmp/a.md <<'EOF'\nline one\nline two\n")
    same_length('second heredoc unterminated', 'cat <<A\nx\nA\ncat <<B\ny\n')
    same_length('terminated heredoc', "cat > /tmp/a.md <<'EOF'\nbody\nEOF\necho ok")
    same_length('quotes and backticks', 'echo "hi" && ls | head -2 && echo `date`')
    # A conflict marker inside a heredoc body opens no heredoc of its own.
    conflict = ("python3 - <<'PY'\nimport re\ns = re.sub(r'<<<<<<< HEAD\\n.*?>>>>>>> x', '', s)\nPY\n"
                f'{AW}/update-status.sh {TEST_GID} Complete | tail -2')
    same_length('conflict marker inside a heredoc body', conflict)
    rc, out, err = hook('guard-piped-watcher-scripts.sh', conflict, env={'AGENT_TASK_GID': TEST_GID})
    got = json.loads(out)['hookSpecificOutput']['updatedInput']['command'] if rc == 0 and out.strip() else None
    check('conflict marker does not hide the call after the heredoc',
          got is not None and got.endswith(f'{AW}/update-status.sh {TEST_GID} Complete'), f'rc={rc} got={got!r}')
    # The consumer proof: an unterminated heredoc must not disable the gate that
    # rides on the stripped view's offsets.
    rc, out, err = hook('guard-piped-watcher-scripts.sh',
                        f"cat > /tmp/agent-state-{TEST_GID}.md <<'EOF'\nran {AW}/update-status.sh 1 Complete | tail -2\n",
                        env={'AGENT_TASK_GID': TEST_GID})
    check('unterminated heredoc still hides a quoted watcher pipe', rc == 0 and not out.strip(),
          f'rc={rc} out={out[:160]} err={err[:160]}')


# ---------------------------------------------------------------- skill-read blame
def skillread():
    """The gate requires the same units as before; only the deny's blast-radius
    reporting changed. Markers are cleared before each call because a delivered
    body writes one."""
    import glob
    env = {'AGENT_TASK_GID': TEST_GID}

    def clear():
        for p in glob.glob(f'/tmp/agent-skill-read-{TEST_GID}-*'):
            os.remove(p)

    def deny(label, cmd, seg, heredoc_note):
        clear()
        rc, out, err = hook('require-skill-read-for-scripts.sh', cmd, env=env)
        head = err.split('=====')[0]
        check(f'skill-read deny names the gated segment: {label}',
              rc == 2 and 'NOTHING in it ran' in err and 'ENTIRE command' in err and seg in head,
              f'rc={rc} head={head[:400]}')
        check(f'skill-read heredoc note {"present" if heredoc_note else "absent"}: {label}',
              ('That write did NOT happen either' in head) == heredoc_note, head[:400])

    def allows(label, cmd):
        clear()
        rc, out, err = hook('require-skill-read-for-scripts.sh', cmd, env=env)
        check(f'skill-read allows: {label}', rc == 0, f'rc={rc} err={err[:200]}')

    gated = f'~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task {TEST_GID} --comment-file /tmp/agent-comment-{TEST_GID}.txt 2>&1 | tail -3'
    deny('heredoc write then gated attach',
         f"cat > /tmp/agent-comment-{TEST_GID}.txt <<'EOF'\nbody line\nEOF\n{gated}", gated, True)
    deny('cd, gated call, echo',
         f'cd ~/git/x && {AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1; echo done',
         f'{AW}/check-followup-scope.sh --task-gid {TEST_GID} 2>&1', False)
    allows('compound with no gated script', 'cd ~/git/x && git status --short; echo done')
    allows('gated path only quoted in a heredoc body',
           f"cat > /tmp/agent-note-{TEST_GID}.md <<'EOF'\nran {AW}/check-followup-scope.sh --task-gid 1\nEOF")
    clear()
    for p in (f'/tmp/agent-comment-{TEST_GID}.txt', f'/tmp/agent-note-{TEST_GID}.md'):
        os.path.exists(p) and os.remove(p)


# ---------------------------------------------------------------- tdd doc SIGPIPE
def tddsigpipe(tmp):
    """A 108KB+ doc used to make `git show ... | grep -q` die of SIGPIPE; pipefail
    turned that 141 into "unstamped", and the legacy branch then blocked a doc the
    stamp calls current. The gate must still block a genuinely stale stamp."""
    stamp = os.path.expanduser('~/.cursor/skills/tdd/scripts/tdd-stamp.sh')
    if not os.access(stamp, os.X_OK):
        check('tdd sigpipe: tdd-stamp.sh is executable', False, stamp)
        return
    genv = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')

    def git(cmd, cwd):
        p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, env=genv)
        if p.returncode:
            raise RuntimeError(f'{cmd}\n{p.stdout}{p.stderr}')
        return p.stdout

    home = os.path.join(tmp, 'tddhome')
    os.makedirs(os.path.join(home, '.cursor/skills/tdd/scripts'))
    os.symlink(os.path.expanduser('~/.config'), os.path.join(home, '.config'))
    os.symlink(stamp, os.path.join(home, '.cursor/skills/tdd/scripts/tdd-stamp.sh'))
    fv = os.path.join(home, '.cursor/skills/asana-field-value.sh')
    with open(fv, 'w') as fh:
        fh.write('#!/bin/bash\necho tdd\n')
    os.chmod(fv, 0o755)
    repo = os.path.join(home, 'git/.agent-worktrees', TEST_GID, 'repo')
    os.makedirs(os.path.join(repo, 'src/docs'))
    git('git init -q -b master', repo)
    open(os.path.join(repo, 'src/a.ts'), 'w').write('export const a = 1\n')
    git('git add -A && git commit -q -m Base', repo)
    git('git checkout -q -b feature', repo)
    open(os.path.join(repo, 'src/feat.ts'), 'w').write('export const feat = 1\n')
    git('git add -A && git commit -q -m Feature', repo)
    first = git('git rev-parse HEAD', repo).strip()
    open(os.path.join(repo, 'src/more.ts'), 'w').write('export const more = 2\n')
    git('git add -A && git commit -q -m More', repo)

    doc = 'src/docs/big.md'
    # Far past the pipe buffer, so `git show | grep -q` reaches SIGPIPE every run
    # rather than racing the reader.
    filler = ''.join(f'Line {i} of the design body, long enough to outrun a pipe buffer.\n'
                     for i in range(8000))
    with open(os.path.join(repo, doc), 'w') as fh:
        fh.write('# Big design\n\n| | |\n|---|---|\n| Status | Implemented |\n\n## Contents\n\n' + filler)
    size = os.path.getsize(os.path.join(repo, doc))
    check('tdd sigpipe fixture doc is far larger than a pipe buffer', size > 400 * 1024, f'{size} bytes')
    subprocess.run([stamp, repo, doc], capture_output=True, text=True, env=genv)
    git(f'git add -A && git commit -q --fixup {first}', repo)
    git('GIT_SEQUENCE_EDITOR=: git rebase -q -i --autosquash master', repo)
    # Code commits AFTER the doc commit that leave the tree (and so the stamp)
    # unchanged: the stamped branch must pass, the legacy timestamp branch would
    # block. Only a hook that reads the stamp can tell them apart.
    genv['GIT_COMMITTER_DATE'] = f'{int(time.time()) + 90} +0000'
    open(os.path.join(repo, 'src/a.ts'), 'w').write('export const a = 99\n')
    git('git add -A && git commit -q -m Churn', repo)
    open(os.path.join(repo, 'src/a.ts'), 'w').write('export const a = 1\n')
    git('git add -A && git commit -q -m Revert', repo)

    def gate():
        e = dict(genv, HOME=home, AGENT_TASK_GID=TEST_GID)
        e.pop('AGENT_SIM_UDID', None)
        p = subprocess.run([os.path.join(HOOKS, 'require-tdd-current.sh')],
                           input=json.dumps({'tool_name': 'Bash', 'tool_input': {
                               'command': f'{AW}/update-status.sh {TEST_GID} Complete'}}),
                           capture_output=True, text=True, env=e, timeout=60)
        return p.returncode, p.stderr

    rc, err = gate()
    check('current stamp on a large doc passes Complete', rc == 0, f'rc={rc} {err[:300]}')
    check('large doc is not misreported as unstamped', 'older than the code' not in err, err[:300])
    open(os.path.join(repo, 'src/later.ts'), 'w').write('export const later = 3\n')
    git('git add -A && git commit -q -m Later', repo)
    rc, err = gate()
    check('stale stamp on a large doc still blocks', rc == 2 and 'different code tree' in err,
          f'rc={rc} {err[:300]}')


# ---------------------------------------------------------------- maestro device
def maestro(stub):
    base = {'AGENT_SIM_UDID': UDID, 'AGENT_METRO_PORT': '8183', 'PATH': stub + ':' + os.environ['PATH'],
            'STUB_ADB_LOG': os.path.join(stub, 'adb.log')}

    def run(cmd, extra=None, tool='Bash', tool_input=None):
        env = dict(base, **(extra or {}))
        if os.path.exists(env['STUB_ADB_LOG']):
            os.remove(env['STUB_ADB_LOG'])
        rc, out, err = hook('require-maestro-device.sh', cmd, tool=tool, tool_input=tool_input, env=env)
        adb = os.path.exists(env['STUB_ADB_LOG'])
        return rc, err, adb

    rc, err, adb = run('maestro --device "$AGENT_SIM_UDID" --driver-host-port $((AGENT_METRO_PORT + 1000)) test f.yaml')
    check('maestro "$AGENT_SIM_UDID" reaches the iOS path and passes', rc == 0 and not adb, f'rc={rc} adb={adb} {err[:140]}')
    rc, err, adb = run('maestro --device "$AGENT_SIM_UDID" --driver-host-port $((AGENT_METRO_PORT + 1000)) test f.yaml',
                       {'STUB_SIM_STATE': 'Shutdown'})
    check('maestro "$AGENT_SIM_UDID" with sim down hits the iOS booted guard', rc == 2 and 'NOT booted' in err and not adb, err[:140])
    rc, err, adb = run(f'U={UDID}\nS=/tmp/x\ncd /tmp && timeout 800 maestro --device $U --driver-host-port 9183 test f.yaml 2>&1 | tail -30')
    check('maestro $U from an earlier line resolves to the slot UDID', rc == 0 and not adb, f'rc={rc} {err[:140]}')
    rc, err, adb = run(f'U={UDID}\nmaestro --device ${{U}} test f.yaml')
    check('maestro ${U} without driver port blocks on the iOS rule, not adb', rc == 2 and 'driver-host-port' in err and not adb, err[:140])
    rc, err, adb = run(f'D={SERIAL}; sleep 1; timeout 60 maestro --device $D hierarchy 2>/dev/null | python3 -c "import json,sys"',
                       {'STUB_ADB_SERIAL': SERIAL})
    check('maestro $D Android serial resolves and passes when attached', rc == 0 and adb, f'rc={rc} {err[:140]}')
    rc, err, adb = run(f'D={SERIAL}; timeout 60 maestro --device $D hierarchy')
    check('maestro $D Android serial blocks when detached, naming the serial', rc == 2 and SERIAL in err and '$D' not in err, err[:140])
    rc, err, _ = run('maestro --device $(xcrun simctl list devices | grep Booted | head -1) test f.yaml')
    check('maestro --device $(...) blocks as unresolvable', rc == 2 and 'literal UDID/serial' in err, err[:140])
    rc, err, _ = run('maestro --device "$NOT_A_SET_VARIABLE" test f.yaml')
    check('maestro --device unset variable blocks as unresolvable', rc == 2 and 'literal UDID/serial' in err, err[:140])
    rc, err, _ = run(f'cd /x/maestro-dev && timeout 900 maestro --device {OTHER_UDID} --driver-host-port 9 test c.yaml 2>&1 | tail -40')
    check('maestro neighbor slot UDID blocks', rc == 2 and 'NOT this session' in err, err[:140])
    rc, err, _ = run('cd /tmp && timeout 420 maestro test /tmp/q.yaml 2>&1 | tail -35')
    check('maestro drive without --device blocks', rc == 2 and 'no --device' in err, err[:140])
    rc, err, _ = run('export PATH="$HOME/.maestro/bin:$PATH"; maestro --version 2>&1 | head -2')
    check('maestro --version passes', rc == 0, err[:140])
    rc, err, _ = run("cat > /tmp/f.yaml <<'YAML'\n- runFlow: maestro test x\nYAML\necho written")
    check('heredoc mentioning maestro test passes', rc == 0, err[:140])
    rc, err, _ = run(None, {'STUB_SIM_STATE': 'Shutdown'}, 'mcp__maestro__list_devices', {})
    check('mcp list_devices skips the booted guard', rc == 0, err[:140])
    rc, err, _ = run(None, {'STUB_SIM_STATE': 'Shutdown'}, 'mcp__maestro__take_screenshot', {})
    check('mcp take_screenshot keeps the booted guard', rc == 2, err[:140])
    rc, err, _ = run(None, {'STUB_SIM_STATE': 'Shutdown'}, 'mcp__maestro__inspect_screen', {})
    check('mcp inspect_screen keeps the booted guard', rc == 2 and 'NOT booted' in err, err[:140])
    rc, err, _ = run(None, None, 'mcp__maestro__inspect_screen', {'device_id': SERIAL})
    check('mcp call naming a non-slot device still blocks', rc == 2 and 'IGNORES' in err, err[:140])


# ---------------------------------------------------------------- playbook
def playbook():
    marker = f'/tmp/agent-playbook-read-{TEST_GID}'
    if os.path.exists(marker):
        os.remove(marker)
    env = {'AGENT_TASK_GID': TEST_GID}

    def run(label, want, cmd=None, tool='Bash', tool_input=None):
        rc, _, err = hook('require-playbook-before-drive.sh', cmd, tool=tool, tool_input=tool_input, env=env)
        check(f'playbook {"blocks" if want else "passes"}: {label}', rc == want, f'rc={rc} {err[:100]}')

    run('mcp list_devices', 0, tool='mcp__maestro__list_devices', tool_input={})
    run('mcp take_screenshot (read-only)', 0, tool='mcp__maestro__take_screenshot', tool_input={})
    run('mcp inspect_screen (read-only)', 0, tool='mcp__maestro__inspect_screen', tool_input={})
    run('mcp tap_on', 2, tool='mcp__maestro__tap_on', tool_input={'text': 'x'})
    run('maestro --version then grep package.json', 0,
        'export PATH="$HOME/.maestro/bin:$PATH"; maestro --version 2>&1 | head -2; echo "=== npm:"; grep -n \'"maestro"\' package.json')
    run('ls of maestro dirs', 0,
        'ls ~/.cursor/skills/build-and-test/flows/ 2>/dev/null | head -20; ls /x/git/maestro/ 2>/dev/null | head -20')
    run('ls maestro + find -iname maestro', 0,
        'cd ~/git/r && ls maestro 2>/dev/null | head; find . -maxdepth 3 -iname "*maestro*" | head -20')
    run('mcp run_flow', 2, tool='mcp__maestro__run_flow', tool_input={'flow_yaml': 'appId: x'})
    run('timeout maestro test piped to tail', 2,
        'cd maestro-dev && timeout 600 maestro --device X --driver-host-port $((AGENT_METRO_PORT + 1000)) test c.yaml 2>&1 | tail -12')
    run('heredoc flow then maestro test', 2,
        "mkdir -p /tmp/f && cat > /tmp/f/a.yaml <<'EOF'\nappId: x\nEOF\ncd /tmp/f && timeout 900 maestro --device \"$AGENT_SIM_UDID\" test a.yaml")
    run('capture-buy-quote.sh by path', 2, '~/.cursor/skills/build-and-test/scripts/capture-buy-quote.sh --device X')


# ---------------------------------------------------------------- plan gate
def plan(tmp):
    gid = TEST_GID
    task_dir = f'/tmp/asana-task-{gid}'
    ctx = f'{task_dir}/.context-fetched'
    followup = f'/tmp/agent-followup-scope-{gid}.json'
    state = os.path.join(tmp, 'state')
    vdir = os.path.join(state, 'agent-watcher', 'versions')
    os.makedirs(vdir, exist_ok=True)
    scratch_root = tempfile.mkdtemp(prefix='claude-hooktest-', dir='/private/tmp')
    scratch = os.path.join(scratch_root, 'proj', 'sess', 'scratchpad')
    os.makedirs(scratch)
    env = {'AGENT_TASK_GID': gid, 'XDG_STATE_HOME': state}
    us = f'{AW}/update-status.sh {gid} Developing'

    def reset():
        for pth in (ctx, followup, os.path.join(vdir, f'{gid}.jsonl')):
            if os.path.exists(pth):
                os.remove(pth)
        for f in os.listdir(scratch):
            os.remove(os.path.join(scratch, f))
        for f in os.listdir('/tmp'):
            if f.startswith(f'plan-{gid}-'):
                os.remove(os.path.join('/tmp', f))

    def ingest():
        os.makedirs(task_dir, exist_ok=True)
        open(ctx, 'w').close()

    def run(label, want, cmd, needle=''):
        rc, _, err = hook('require-plan-before-developing.sh', cmd, env=env, cwd='/nonexistent')
        check(f'plan {"blocks" if want else "passes"}: {label}', rc == want and needle in err, f'rc={rc} {err[:140]}')

    try:
        reset()
        run('no ingestion evidence', 2, us, 'no task-ingestion evidence')
        ingest()
        run('ingested, no plan anywhere', 2, us, 'no plan document')
        run('plan written AFTER the status call', 2, f"{us}\ncat > /tmp/q/plan-{gid}-late.md <<'EOF'\n# Plan\nEOF")
        run('heredoc writes a non-plan file first', 2, f"cat > /tmp/agent-state-{gid}.md <<'EOF'\nplan-{gid}-x.md\nEOF\n{us}")
        run('status call only quoted in echo', 0, f'echo "{us}"')
        run('heredoc plan write earlier in the same command', 0,
            f"cat > /var/folders/q/plan-{gid}-coherent-history.md <<'EOF'\n# Plan\n\n## Summary\nx\nEOF\n{us}")
        run('cp scratchpad plan into place && status', 0,
            f'cp "/private/tmp/claude-501/p/s/scratchpad/plan-{gid}-send.md" /var/folders/q/plan-{gid}-send.md && {us}')
        run('cp to a $VAR destination assigned earlier', 0,
            f'D=/var/folders/q\ncp /x/plan.md "$D/plan-{gid}-v.md" && {us}')
        open(os.path.join(scratch, f'plan-{gid}-s.md'), 'w').close()
        run('plan in the harness scratchpad', 0, us)
        reset()

        # Followup segments.
        with open(os.path.join(vdir, f'{gid}.jsonl'), 'w') as fh:
            fh.write(json.dumps({'ts': '2026-09-10T10:00:00Z', 'gid': gid}) + '\n')
            fh.write(json.dumps({'ts': '2026-09-12T10:00:00Z', 'gid': gid}) + '\n')
        with open(followup, 'w') as fh:
            json.dump({'checked_at': '2026-09-12T11:00:00Z', 'watermark': '2026-09-11T00:00:00.000Z'}, fh)
        run('followup: fresh followup-scope check, no ingestion marker, no plan', 0, us)
        with open(followup, 'w') as fh:
            json.dump({'checked_at': '2026-09-11T11:00:00Z', 'watermark': '2026-09-11T00:00:00.000Z'}, fh)
        run('followup: check from a PRIOR segment', 2, us, 'no task-ingestion evidence')
        with open(followup, 'w') as fh:
            json.dump({'checked_at': '2026-09-12T11:00:00Z', 'watermark': ''}, fh)
        run('never-reported task: followup marker without watermark', 2, us, 'no task-ingestion evidence')
    finally:
        reset()
        shutil.rmtree(task_dir, ignore_errors=True)
        shutil.rmtree(scratch_root, ignore_errors=True)


# ---------------------------------------------------------------- multi-repo subtasks
def subtasks(tmp):
    home = os.path.join(tmp, 'home')
    os.makedirs(home)
    os.symlink(os.path.expanduser('~/.config'), os.path.join(home, '.config'))
    wt = os.path.join(home, 'git', '.agent-worktrees', TEST_GID)
    genv = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
    for repo in ('repo-a', 'repo-b'):
        d = os.path.join(wt, repo)
        os.makedirs(d)
        for c in ('git init -q -b develop', 'git commit -q --allow-empty -m base',
                  'git update-ref refs/remotes/origin/develop HEAD', 'git checkout -q -b feature',
                  'git commit -q --allow-empty -m work'):
            subprocess.run(c, shell=True, cwd=d, check=True, env=genv, capture_output=True)
    env = {'AGENT_TASK_GID': TEST_GID, 'HOME': home}
    pc = '~/.cursor/skills/pr-create/scripts/pr-create.sh'

    def run(label, want, cmd):
        rc, _, err = hook('require-subtasks-for-multi-repo-pr.sh', cmd, env=env)
        check(f'subtasks {"blocks" if want else "passes"}: {label}', rc == want, f'rc={rc} {err[:120]}')

    run('pr-create without --asana-attach (default no attach)', 0,
        f'{pc} --title "Fix x" --body-file /tmp/pr-body.md --asana-task {TEST_GID} --draft 2>&1 | tail -15')
    run('pr-create --no-asana-attach', 0, f'{pc} --title x --no-asana-attach')
    run('pr-create --help', 0, f'git status --short && {pc} --help 2>&1 | head -20')
    run('grep of pr-create.sh for flags', 0, f'grep -n "\\-\\-draft\\|--asana-attach\\|usage" {pc} | head -20')
    run('pr-create --asana-attach in a 2-repo run', 2, f'{pc} --title x --asana-attach --asana-task {TEST_GID}')
    run('timeout-wrapped pr-create --asana-attach in a 2-repo run', 2,
        f'timeout 120 {pc} --title x --asana-attach --asana-task {TEST_GID} 2>&1')
    shutil.rmtree(os.path.join(wt, 'repo-b'))
    run('pr-create --asana-attach in a 1-repo run', 0, f'{pc} --title x --asana-attach --asana-task {TEST_GID}')


# ---------------------------------------------------------------- cmd-executes
def cmdexec():
    def run(label, want, cmd, name='update-status.sh'):
        p = subprocess.run([os.path.join(HOOKS, 'cmd-executes.sh'), name], input=cmd, capture_output=True, text=True)
        check(f'cmd-executes {"runs" if want == 0 else "not run"}: {label}', p.returncode == want, f'rc={p.returncode}')

    us = f'{AW}/update-status.sh 1 Complete'
    run('bare', 0, us)
    run('timeout N', 0, f'timeout 30 {us}')
    run('gtimeout with -k flag and 30s', 0, f'gtimeout -k 5 30s {us}')
    run('timeout -s KILL N', 0, f'timeout -s KILL 30 {us}')
    run('env VAR=val VAR=val', 0, f'env FOO=1 BAR=2 {us}')
    run('env -u NAME', 0, f'env -u X {us}')
    run('nice -n N', 0, f'nice -n 10 {us}')
    run('nohup', 0, f'nohup {us}')
    run('command', 0, f'command {us}')
    run('exec', 0, f'exec {us}')
    run('time -p', 0, f'time -p {us}')
    run('stacked wrappers after &&', 0, f'cd x && time nohup timeout 5 {us}')
    run('VAR=x prefix', 0, f'FOO=1 {us}')
    run('inside $( ) with timeout', 0, f'X=$(timeout 9 {us})')
    run('command -v only prints a path', 1, f'command -v {AW}/update-status.sh')
    run('timeout-wrapped grep of the script', 1, f'timeout 30 grep -n x {AW}/update-status.sh')
    run('env-wrapped cat of the script', 1, f'env FOO=1 cat {AW}/update-status.sh')
    run('nice-wrapped sed of the script', 1, f'nice sed -n 1p {AW}/update-status.sh')
    run('different basename', 1, f'timeout 5 {AW}/update-status.sh.bak')


# ---------------------------------------------------------------- md-write-target
def mdtarget():
    lib = os.path.join(HOOKS, 'lib', 'md-write-target.sh')
    strip = os.path.join(HOOKS, 'strip-cmd-mentions.sh')

    def run(label, want, cmd, ext='md'):
        p = subprocess.run(['bash', '-c', f'. {lib}; m=$(printf "%s" "$1" | {strip}); bash_write_target "$m" /cwd "$2" "$1"',
                            '_', cmd, ext], capture_output=True, text=True, env=dict(os.environ, HOME='/home/t'))
        check(f'md-write-target: {label}', p.stdout == want, f'got={p.stdout!r} err={p.stderr[:120]}')

    run('cat > "$D/x.md" heredoc', '/tmp/d/x.md', "D=/tmp/d\ncat > \"$D/x.md\" <<'EOF'\nhi\nEOF")
    run('tee "$D/x.md" with quoted assignment', '/tmp/d/x.md', 'D="/tmp/d"; tee "$D/x.md" < /dev/null')
    run('tee -a "$D"/x.md reads the whole word', '/tmp/d/x.md', 'D=/tmp/d; tee -a "$D"/x.md')
    run("single-quoted literal path", '/tmp/q/x.md', "cat > '/tmp/q/x.md' <<'EOF'\nx\nEOF")
    run("single quotes keep $HOME literal", '/cwd/$HOME/x.md', "cat > '$HOME/x.md'")
    run('"$HOME/..." expands from env', '/home/t/n/x.md', 'cat > "$HOME/n/x.md"')
    run('unresolvable $(...) keeps the literal', '/cwd/$(mktemp -d)/x.md', 'cat > "$(mktemp -d)/x.md"')
    run('exact basename CHANGELOG.md', '/r/CHANGELOG.md', 'R=/r; cat >> "$R/CHANGELOG.md"', 'CHANGELOG.md')
    run('quoted redirect inside a heredoc body is not a write', '', "cat > /tmp/a.txt <<'EOF'\ncat > \"/tmp/b.md\"\nEOF")
    run('quoted redirect inside an echo is not a write', '', 'echo "cat > \\"/tmp/b.md\\""')
    run('quoted non-md target', '', 'cat > "/tmp/b.txt"')
    run('non-BMP char before the target keeps offsets', '/tmp/y.md', 'echo "\U0001F600" && D=/tmp; cat > "$D/y.md"')


# ---------------------------------------------------------------- lint-md-on-write
def lintmd():
    def run(label, want, cmd, tool='Bash', tool_input=None, needle=''):
        rc, _, err = hook('lint-md-on-write.sh', cmd, tool=tool, tool_input=tool_input, cwd='/Users/nobody/git/.agent-worktrees/1/repo')
        check(f'lint-md {"blocks" if want else "passes"}: {label}', rc == want and needle in err, f'rc={rc} {err[:140]}')

    body = f'\nThe selection rule {EM} and the other one.\nEOF'
    run('heredoc into the harness scratchpad', 0,
        f"mkdir -p /private/tmp/claude-501/-p/abc/scratchpad && cat > /private/tmp/claude-501/-p/abc/scratchpad/notes.md <<'EOF'{body}")
    run('$M target resolving into ~/.claude', 0, f"M=~/.claude/projects/-x/memory\ncat > $M/some-note.md <<'EOF'{body}")
    run('quoted "$M/..." target resolving into ~/.claude', 0, f"M=~/.claude/projects/-x/memory\ncat > \"$M/some-note.md\" <<'EOF'{body}")
    run('/tmp/agent-state file', 0, f"cat > /tmp/agent-state-{TEST_GID}.md <<'EOF'{body}")
    run('/tmp/plan file', 0, f"cat > /tmp/plan-{TEST_GID}-x.md <<'EOF'{body}")
    run('$D target resolving into a repo blocks with the resolved path', 2,
        f"D=/Users/nobody/git/repo/docs\ncat > $D/guide.md <<'EOF'{body}", needle='/Users/nobody/git/repo/docs/guide.md')
    run('quoted "$D/..." target resolving into a repo blocks with the resolved path', 2,
        f"D=/Users/nobody/git/repo/docs\ncat > \"$D/guide.md\" <<'EOF'{body}", needle='/Users/nobody/git/repo/docs/guide.md')
    run('outward PR body in /tmp', 2, f"cat > /tmp/pr-body-x.md <<'EOF'{body}")
    run('Write of an outward doc in /tmp', 2, None, 'Write',
        {'file_path': '/tmp/partner-api-handoff-test.md', 'content': f'# Handoff\n\nThe plugin {EM} merged.\n'})


def main():
    tmp = tempfile.mkdtemp(prefix='hook-fp-')
    try:
        stub = os.path.join(tmp, 'stub')
        os.makedirs(stub)
        with open(os.path.join(stub, 'xcrun'), 'w') as fh:
            fh.write(f'#!/bin/bash\necho "    Test Sim ({UDID}) (${{STUB_SIM_STATE:-Booted}})"\n')
        with open(os.path.join(stub, 'adb'), 'w') as fh:
            fh.write('#!/bin/bash\necho "$*" >> "${STUB_ADB_LOG:-/dev/null}"\n'
                     '[ "$2" = "${STUB_ADB_SERIAL:-none}" ] && echo device || exit 1\n')
        for f in ('xcrun', 'adb'):
            os.chmod(os.path.join(stub, f), 0o755)
        piped()
        stripmentions()
        skillread()
        tddsigpipe(tmp)
        maestro(stub)
        playbook()
        plan(tmp)
        subtasks(tmp)
        cmdexec()
        mdtarget()
        lintmd()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    if fails:
        print(f'{len(fails)} FAILURES')
        for f in fails:
            print(' ', f)
        return 1
    print('ALL PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
