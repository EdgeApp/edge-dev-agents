"""git-history-gate.sh: commit discipline is Edge's contract, so a site-orch tenant is exempt.

A tenant is a repo with orch.config.json at its root (worktrees included). Its CLAUDE.md says
plain `git commit`; there is no lint-commit.sh path for it. Cases:
  1. `git commit` with the hook cwd inside a tenant repo -> allowed (exit 0)
  2. the same from a tenant worktree -> allowed (the marker file is committed, so it is there)
  3. `git commit --no-verify` inside a tenant -> still blocked (exit 2)
  4. `git commit` inside a plain repo (no marker) -> blocked (exit 2)
  5. `cd <tenant> && git commit` with the hook cwd elsewhere -> allowed (the leading cd wins)
Run: python3 tests/git-history-gate-tenant.test.py
"""
import json, os, subprocess, sys, tempfile

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/git-history-gate.sh')
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
               GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')


def sh(cmd, cwd):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, env=GIT_ENV)
    if p.returncode != 0:
        raise RuntimeError(f'{cmd}\n{p.stdout}{p.stderr}')
    return p


def gate(cwd, command):
    payload = json.dumps({'cwd': cwd, 'tool_input': {'command': command}})
    return subprocess.run(['bash', HOOK], input=payload, capture_output=True, text=True, cwd=cwd).returncode


def main():
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        tenant = os.path.join(tmp, 'tenant')
        plain = os.path.join(tmp, 'plain')
        for repo, marker in ((tenant, True), (plain, False)):
            os.makedirs(repo)
            sh('git init -q -b main', repo)
            with open(os.path.join(repo, 'README.md'), 'w') as fh:
                fh.write('x\n')
            if marker:
                with open(os.path.join(repo, 'orch.config.json'), 'w') as fh:
                    fh.write('{"slug":"t"}\n')
            sh('git add -A && git commit -q -m init', repo)
        wt = os.path.join(tmp, 'tenant-wt')
        sh(f'git worktree add -q -b task {wt}', tenant)

        cases = [
            ('tenant repo, plain commit', tenant, 'git commit -m "x"', 0),
            ('tenant worktree, plain commit', wt, 'git commit -m "x"', 0),
            ('tenant repo, --no-verify', tenant, 'git commit --no-verify -m "x"', 2),
            ('plain repo, plain commit', plain, 'git commit -m "x"', 2),
            ('cd into tenant from elsewhere', plain, f'cd {tenant} && git commit -m "x"', 0),
        ]
        for name, cwd, cmd, want in cases:
            got = gate(cwd, cmd)
            mark = 'ok  ' if got == want else 'FAIL'
            print(f'{mark} {name}: exit {got} (want {want})')
            if got != want:
                fails.append(name)
    if fails:
        print(f'{len(fails)} failing: {fails}')
        sys.exit(1)
    print('all 5 cases pass')


if __name__ == '__main__':
    main()
