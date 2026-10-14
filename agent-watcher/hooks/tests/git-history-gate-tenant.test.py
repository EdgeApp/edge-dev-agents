"""git-history-gate.sh: commit discipline is Edge's contract, so a site-orch tenant is exempt.

A tenant is a repo with orch.config.json at its root (worktrees included). Its CLAUDE.md says
plain `git commit`; there is no lint-commit.sh path for it. Cases:
  1. `git commit` with the hook cwd inside a tenant repo -> allowed (exit 0)
  2. the same from a tenant worktree -> allowed (the marker file is committed, so it is there)
  3. `git commit --no-verify` inside a tenant -> still blocked (exit 2)
  4. `git commit` inside a plain repo (no marker) -> blocked (exit 2)
  5. `cd <tenant> && git commit` with the hook cwd elsewhere -> allowed (the leading cd wins)

The gate reads the line through cmd-parse.sh, so a commit is found wherever the line runs one
and nowhere the line only names one. The second table covers that: `git -C <dir>`, `git -c k=v`,
`bash -c '...'`, a commit after a sanctioned script on the same line, `-n` as --no-verify, and
the directory each commit acts on. The third table checks which lines reach the PR lookup (a
stub `gh` on PATH records the call): a push or an autosquash wherever it runs, never a mention.
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


def gate(cwd, command, env=None):
    payload = json.dumps({'cwd': cwd, 'tool_input': {'command': command}})
    return subprocess.run(['bash', HOOK], input=payload, capture_output=True, text=True, cwd=cwd, env=env).returncode


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
        skill = '~/.cursor/skills/lint-commit.sh'
        cases += [
            ('git -C plain commit', tenant, f'git -C {plain} commit -m "x"', 2),
            ('git -C tenant commit from a plain cwd', plain, f'git -C {tenant} commit -m "x"', 0),
            ('git -c k=v commit', plain, 'git -c user.name=a commit -m "x"', 2),
            ('git --no-pager commit', plain, 'git --no-pager commit -m "x"', 2),
            ('commit inside bash -c', plain, "bash -c 'git commit -m x'", 2),
            ('commit inside sh -c after a cd', tenant, f"sh -c 'cd {plain} && git commit -m x'", 2),
            ('commit inside bash -c in a tenant', tenant, "bash -c 'git commit -m x'", 0),
            ('commit after a sanctioned script', plain, f'{skill} -m "a" && git commit -m "x"', 2),
            ('commit inside a substitution', plain, 'echo "$(git commit -m x)"', 2),
            ('--no-verify after a sanctioned script', tenant, f'{skill} -m "a"; git commit --no-verify -m "x"', 2),
            ('-n is --no-verify', tenant, 'git commit -n -m "x"', 2),
            ('-nm is --no-verify', tenant, 'git commit -nm "x"', 2),
            ('--no-verify inside bash -c', tenant, "bash -c 'git commit --no-verify -m x'", 2),
            ('a message that says --no-verify', tenant, 'git commit -m "never use --no-verify"', 0),
            ('a message that says --amend', plain, 'git commit -m "--amend"', 2),
            ('amend', plain, 'git commit --amend --no-edit', 0),
            ('amend, then a plain commit', plain, 'git commit --amend --no-edit && git commit -m "x"', 2),
            ('two commits, the second in a plain repo', tenant, f'git commit -m "x" && cd {plain} && git commit -m "y"', 2),
            ('subshell cd does not leak', plain, f'(cd {tenant} && git status); git commit -m "x"', 2),
            ('cd to a hidden directory', tenant, 'cd "$SOMEWHERE" && git commit -m "x"', 2),
            ('a loop variable set to the tenant worktree', plain, f'while true; do wt={wt}; git -C "$wt" commit -m x; break; done', 0),
            ('a loop variable set to a plain repo', tenant, f'while true; do wt={plain}; git -C "$wt" commit -m x; break; done', 2),
            ('the sanctioned script alone', plain, f'{skill} -m "git commit"', 0),
            ('a quoted mention', plain, 'echo "run git commit -m x"', 0),
            ('a heredoc mention', plain, "cat > /dev/null <<'E'\ngit commit --no-verify -m x\nE", 0),
            ('a commented mention', plain, 'ls # git commit -m x', 0),
            ('eval text is not read', plain, 'eval "git commit -m x"', 0),
            ('git log --grep commit', plain, 'git log --grep commit', 0),
            ('git show of a commit', plain, 'git show commit', 0),
        ]
        for name, cwd, cmd, want in cases:
            got = gate(cwd, cmd)
            mark = 'ok  ' if got == want else 'FAIL'
            print(f'{mark} {name}: exit {got} (want {want})')
            if got != want:
                fails.append(name)

        # Which lines reach the PR lookup. The stub gh prints nothing, so the gate fails open
        # after it; the call log shows the directory the lookup ran in.
        bindir = os.path.join(tmp, 'bin')
        os.makedirs(bindir)
        calls = os.path.join(tmp, 'gh-calls')
        with open(os.path.join(bindir, 'gh'), 'w') as fh:
            fh.write(f'#!/bin/sh\necho "$(pwd -P)" >> {calls}\nexit 1\n')
        os.chmod(os.path.join(bindir, 'gh'), 0o755)
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ['PATH'])
        rp = os.path.realpath
        lookups = [
            ('git push', plain, 'git push origin HEAD', plain),
            ('cd then push', tenant, f'cd {plain} && git push', plain),
            ('git -C push', tenant, f'git -C {plain} push', plain),
            ('git -c k=v push', plain, 'git -c push.default=current push', plain),
            ('push inside bash -c', tenant, f"bash -c 'cd {plain} && git push'", plain),
            ('push after a sanctioned script', plain, f'{skill} -m "a" && git push', plain),
            ('push after a later cd', tenant, f'git status; cd {plain}; git push', plain),
            ('rebase --autosquash', plain, 'GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash main', plain),
            ('git -C rebase --autosquash', tenant, f'git -C {plain} rebase --autosquash main', plain),
            ('git-branch-ops.sh push', plain, '~/.cursor/skills/git-branch-ops.sh push', plain),
            ('a quoted push', plain, 'echo "git push"', None),
            ('a commit message naming a push', tenant, 'git commit -m "git push --autosquash"', None),
            ('git log --grep push', plain, 'git log --grep push', None),
            ('git stash push', plain, 'git stash push -u -m tag', None),
            ('the sanctioned finalize script', plain, '~/.cursor/skills/pr-finalize-fixups.sh', None),
            ('eval text is not read', plain, 'eval "git push"', None),
        ]
        for name, cwd, cmd, want in lookups:
            if os.path.exists(calls):
                os.remove(calls)
            rc = gate(cwd, cmd, env)
            got = open(calls).read().split('\n')[0] if os.path.exists(calls) else None
            ok = rc == 0 and (got is None if want is None else got == rp(want))
            print(f"{'ok  ' if ok else 'FAIL'} lookup, {name}: exit {rc}, looked up in {got}")
            if not ok:
                fails.append('lookup, ' + name)
    if fails:
        print(f'{len(fails)} failing: {fails}')
        sys.exit(1)
    print('all cases pass')


if __name__ == '__main__':
    main()
