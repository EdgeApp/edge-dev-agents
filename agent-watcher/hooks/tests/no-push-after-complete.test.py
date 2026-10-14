#!/usr/bin/env python3
"""Contract tests for no-push-after-complete.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/no-push-after-complete.test.py

The hook blocks branch/PR-head-moving commands while a task sits at
agent_status = Complete. Two properties matter and are easy to break later:

  1. Head-moving verbs block. Widening the wrappers or path prefixes must not
     drop one.
  2. Everything that does NOT move the head passes: local commits, title/body
     edits, and every comment operation. Those exemptions hold because the verbs
     are absent from the hook's TARGETS, so any broadening of that regex has to
     keep this file green. A compound command that mixes an exempt verb with a
     real push still blocks, which is why the exemption is not an early exit.

The Asana lookup is stubbed via a PATH shim so the tests neither hit the network
nor depend on a live task's status.
"""
import json, os, subprocess, sys, tempfile

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/no-push-after-complete.sh')
STATUS_FIELD = 'agent_status'


def make_shim(tmp, status):
    """A curl stand-in returning an Asana task payload with the given status."""
    path = os.path.join(tmp, 'curl')
    body = json.dumps({'data': {'custom_fields': [
        {'name': STATUS_FIELD, 'display_value': status}]}})
    with open(path, 'w') as fh:
        fh.write('#!/bin/bash\ncat <<\'JSON\'\n' + body + '\nJSON\n')
    os.chmod(path, 0o755)
    return path


def run(cmd, tmp, status='Complete'):
    env = dict(os.environ,
               AGENT_TASK_GID='1111111111',
               ASANA_TOKEN='stub',
               PATH=tmp + ':' + os.environ['PATH'])
    p = subprocess.run([HOOK],
                       input=json.dumps({'tool_name': 'Bash',
                                         'tool_input': {'command': cmd}}),
                       capture_output=True, text=True, env=env, timeout=30)
    return p.returncode


BLOCKS = [
    ('git push', 'cd /r && git push --force-with-lease origin br'),
    ('wrapped git push', 'timeout 900 git push origin br'),
    ('git-branch-ops push', 'cd /r && ~/.cursor/skills/git-branch-ops.sh push --branch br'),
    ('gh pr create', 'gh pr create --title t --body b'),
    ('gh pr ready', 'gh pr ready 485'),
    ('gh pr reopen', 'gh pr reopen 485'),
    ('gh pr edit --base', 'gh pr edit 485 --base staging'),
    ('comment op chained with a push', 'gh pr comment 485 --body x && git push origin br'),
    # The hook reads the line through cmd-parse.sh, so the verb is found behind
    # a tool's own options and inside a shell's -c text.
    ('git -C push', 'git -C /r push origin br'),
    ('git -c k=v push', 'git -c push.default=current push'),
    ('git --no-pager push', 'git --no-pager push'),
    ('push inside bash -c', "bash -c 'cd /r && git push origin br'"),
    ('push inside sh -lc', 'sh -lc "git push"'),
    ('push inside a substitution', 'OUT="$(git push 2>&1)"; echo "$OUT"'),
    ('push after a sanctioned script', '~/.cursor/skills/lint-commit.sh -m x && git push'),
    ('push in a loop body', 'for b in a b; do git push origin $b; done'),
    ('env-wrapped push', 'GIT_SSH_COMMAND=ssh env A=1 nice git push'),
    ('gh -R pr create', 'gh -R O/R pr create --fill'),
    ('gh pr -R ready', 'gh pr -R O/R ready 485'),
    ('gh pr edit --base=', 'gh pr edit 485 --base=staging'),
    ('gh pr edit -B', 'gh pr edit 485 -B staging'),
    ('gh pr edit title then --base', 'gh pr edit 485 --title "a; b" --base staging'),
    ('gh pr create inside bash -c', "bash -c 'gh pr create --fill'"),
    ('git-branch-ops push through bash', 'bash ~/.cursor/skills/git-branch-ops.sh push'),
]

PASSES = [
    ('local commit', '~/.cursor/skills/lint-commit.sh --fixup abc src/x.ts'),
    ('raw git commit', 'cd /r && git commit --amend --no-edit'),
    ('gh pr edit body', 'gh pr edit 485 --body-file /tmp/b.md'),
    ('gh pr edit title', 'gh pr edit 485 --title "new title"'),
    ('gh pr comment', 'gh pr comment 485 --body "note"'),
    ('gh pr review', 'gh pr review 485 --comment --body "x"'),
    ('PATCH issue comment', 'gh api -X PATCH repos/O/R/issues/comments/1 --input /tmp/p.json'),
    ('POST review comment', 'gh api -X POST repos/O/R/pulls/485/comments --input /tmp/p.json'),
    ('DELETE review comment', 'gh api -X DELETE repos/O/R/pulls/comments/1'),
    ('pr-address reply', '~/.cursor/skills/pr-address/scripts/pr-address.sh reply --pr 485 --comment-id 1 --body x'),
    ('pr-address resolve-thread', '~/.cursor/skills/pr-address/scripts/pr-address.sh resolve-thread --thread-id T'),
    ('attach screenshots', '~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh --repo O/R --pr 485 a.png'),
    ('quoted mention', 'echo "then git push and gh pr ready"'),
    ('heredoc mention', 'cat > /tmp/d.md <<EOF\nrun git push then gh pr create\nEOF\nls'),
    ('unrelated', 'ls -la && cat README.md'),
    ('title that says --base', 'gh pr edit 485 --title "move --base later"'),
    ('git stash push', 'git stash push -u -m tag'),
    ('git log --grep push', 'git -C /r log --grep push'),
    ('push named inside bash -c text', "bash -c 'echo \"git push\"'"),
    ('eval text is not read', 'eval "git push"'),
    ('commented push', 'ls # git push'),
    ('gh pr view of a base', 'gh pr view 485 --json baseRefName'),
    ('git-branch-ops other verb', '~/.cursor/skills/git-branch-ops.sh note-scope --note push'),
]

# Nothing may block while the task is NOT Complete.
NOT_COMPLETE = [c for _, c in BLOCKS]


STAMP = '/tmp/agent-operator-present-1111111111'


def main():
    fails = []
    # The operator-present stamp must not exist for the baseline sections.
    if os.path.exists(STAMP):
        os.remove(STAMP)
    with tempfile.TemporaryDirectory() as tmp:
        make_shim(tmp, 'Complete')
        for name, cmd in BLOCKS:
            got = run(cmd, tmp)
            ok = got == 2
            print(f"{'PASS' if ok else 'FAIL'} blocks: {name} (rc={got})")
            if not ok:
                fails.append(('blocks', name, got))
        for name, cmd in PASSES:
            got = run(cmd, tmp)
            ok = got == 0
            print(f"{'PASS' if ok else 'FAIL'} passes: {name} (rc={got})")
            if not ok:
                fails.append(('passes', name, got))

    # Operator-present carve-out: a fresh human-prompt stamp allows the push
    # past Complete; a stale one (> 30 min) blocks as before.
    import time
    with tempfile.TemporaryDirectory() as tmp:
        make_shim(tmp, 'Complete')
        try:
            open(STAMP, 'w').close()
            got = run('git push origin br', tmp)
            ok = got == 0
            print(f"{'PASS' if ok else 'FAIL'} fresh operator stamp allows push (rc={got})")
            if not ok:
                fails.append(('stamp-fresh', 'git push', got))
            old = time.time() - 3600
            os.utime(STAMP, (old, old))
            got = run('git push origin br', tmp)
            ok = got == 2
            print(f"{'PASS' if ok else 'FAIL'} stale operator stamp blocks push (rc={got})")
            if not ok:
                fails.append(('stamp-stale', 'git push', got))
        finally:
            if os.path.exists(STAMP):
                os.remove(STAMP)

    with tempfile.TemporaryDirectory() as tmp:
        make_shim(tmp, 'Reviewing')
        for cmd in NOT_COMPLETE:
            got = run(cmd, tmp)
            ok = got == 0
            label = cmd[:44]
            print(f"{'PASS' if ok else 'FAIL'} not-Complete allows: {label} (rc={got})")
            if not ok:
                fails.append(('not-complete', label, got))

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
