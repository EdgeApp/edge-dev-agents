// Tests for hooks/lib/shell-commands.js, the one reading of a Bash command
// line that the PreToolUse hooks share, and for its two fronts, cmd-parse.sh
// and cmd-executes.sh.
//
// Most cases are built from tables: three commands a gate cares about are put
// through every wrapper, every place a shell runs a command, and every place
// a shell only mentions one. A place that runs must report the command; a
// place that mentions must not. Further tables cover git's global options,
// the commit flags, directory tracking, gh, and input that is cut off or
// malformed, which must be read without an exception.
//
// Run: node ~/.config/agent-watcher/hooks/tests/shell-commands.test.js
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const HOOKS = path.join(os.homedir(), '.config', 'agent-watcher', 'hooks')
const { parse } = require(path.join(HOOKS, 'lib', 'shell-commands.js'))

let failed = 0
let ran = 0
function check (name, ok, detail) {
  ran++
  if (ok) return
  failed++
  console.log(`FAIL ${name}${detail === undefined ? '' : '\n     ' + String(detail).slice(0, 500)}`)
}
const ENV = { HOME: '/home/u' }
const sig = (r) => r.git ? `git:${r.git.sub}` : r.name === 'simctl' ? `simctl:${r.argv[1]}` : r.name
const sigs = (raw) => parse(raw, { env: ENV }).map(sig)
function runs (label, raw, want) { const got = sigs(raw); check(`${label}: ${JSON.stringify(raw)} runs ${want}`, got.includes(want), got.join(' | ')) }
function quiet (label, raw, want) { const got = sigs(raw); check(`${label}: ${JSON.stringify(raw)} does not run ${want}`, !got.includes(want), got.join(' | ')) }
function same (name, got, want) { check(name, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`) }

const TARGETS = [
  { text: 'git push origin HEAD', sig: 'git:push' },
  { text: 'xcrun simctl erase all', sig: 'simctl:erase' },
  { text: '~/.config/agent-watcher/update-status.sh 123 Complete', sig: 'update-status.sh' }
]

// ---- places that run the command ----
const RUNS = [
  'X', '  X  ', 'a; X', 'a && X', 'a || X', 'a | X', 'X | a', 'a |& X', 'a &\nX', 'a\nX', 'a;X', 'a&&X',
  '(X)', '( a; X )', '{ X; }', '((1)) && X', 'echo $(X)', 'echo "$(X)"', 'echo "a $(b; X) c"', 'echo `X`',
  'echo "`X`"', 'v=$(X)', 'diff <(X) f', 'tee >(X)', 'if a; then X; fi', 'if X; then a; fi',
  'if a; then b; elif c; then X; else d; fi', 'if a; then b; else X; fi', 'while a; do X; done',
  'until X; do a; done', 'for i in 1 2; do X; done', 'for i in 1 2\ndo\n  X\ndone', '! X', 'f() { X; }',
  'function f { X; }', 'f () {\n  X\n}\nf', 'case $a in x) X;; esac', 'case $a in\n  x|y) a;;\n  *) X ;;\nesac',
  'case $a in (x) X;; esac', 'for i in 1; do (X); done', 'for i in 1; do (a && X); done', 'if a; then (X); fi', 'while a; do ! (X); done', 'A=1 X', 'A=1 B="two words" X', 'A=$(a) X', 'a 2>&1 | X', 'a >/dev/null 2>&1; X',
  'a > "out file" && X', 'X > out 2>&1', 'X 2>/dev/null', 'X &>/dev/null', 'X < in', 'X <<< "text"',
  "a <<'E'\nbody\nE\nX", 'a <<E\nbody $(b)\nE\nX', 'a <<-E\n\tbody\n\tE\nX', 'a <<E | b\nbody\nE\nX',
  'echo "a\nb" && X', "echo 'a\nb' && X", 'echo a \\\n  b && X', 'a # note\nX', 'echo "it\'s" && X',
  "echo 'say \"hi\"' && X", 'echo a\\;b; X', '[[ -f a && -d b ]] && X', '[[ $a == b || $c < d ]] && X',
  '[ -f a ] && X', 'if [[ -n $a ]]; then X; fi', 'arr=(a b c); X', 'echo ${a:-b}; X', 'echo $((1 + 2)); X',
  "echo $'a\\'b'; X", 'cd /tmp && X', 'cd /tmp; X', '(cd /tmp && X)', 'true && { a; X; }',
  "bash -c 'X'", 'bash -c "X"', "sh -c 'X'", "zsh -c 'X'", "bash -lc 'X'", "bash -l -c 'X'", "bash -euo pipefail -c 'X'",
  "bash -c 'a && X'", "bash -c 'a; (X)'", "/bin/bash -c 'X'", "env A=1 bash -c 'X'", "timeout 60 bash -c 'X'",
  "bash -c 'bash -c \"X\"'", "sudo sh -c 'X'", "a && bash -c 'X' && b", "bash -c 'cd /tmp && X' arg0",
  'echo "$(bash -c \'X\')"', 'coproc X', 'time X', 'a; time X', 'exec X', 'a | xargs X', 'find . | xargs -n 1 X'
]
for (const t of TARGETS) for (const tpl of RUNS) runs('run', tpl.replace('X', t.text), t.sig)

// ---- wrappers that still run their argument ----
const WRAPPERS = [
  'env', 'env A=1', 'env A=1 B=2', 'env -i', 'env -u A', 'env -i A=1', '/usr/bin/env', 'timeout 30', 'timeout 30s',
  'timeout -s KILL 30', 'timeout -k 5 30', 'timeout --foreground 2m', 'timeout --signal=KILL 30', 'gtimeout 30',
  'nice', 'nice -n 10', 'nice -10', 'time', 'time -p', 'command', 'command -p', 'exec', 'exec -a name', 'builtin',
  'nohup', 'caffeinate', 'caffeinate -i', 'caffeinate -t 60', 'sudo', 'sudo -u root', 'sudo -n', 'sudo -E', 'doas',
  'noglob', 'nocorrect', 'setsid', 'stdbuf -oL', 'stdbuf -o L', 'ionice -c 3', 'unbuffer', 'arch -arm64', 'xargs',
  'xargs -n 1', 'xargs -I {}', 'env timeout 30 nice', 'sudo env A=1', 'nohup nice -n 5 timeout 10', 'A=1 env B=2'
]
for (const t of TARGETS) for (const w of WRAPPERS) runs('wrapper', `${w} ${t.text}`, t.sig)
// A shell or `source` handed a script path runs that script.
for (const w of ['bash', 'sh', 'zsh', 'bash -e', 'bash -x', 'bash -o pipefail', 'bash --', 'source', '.', 'env bash', 'timeout 30 bash', '/bin/sh']) {
  runs('script wrapper', `${w} ~/.config/agent-watcher/update-status.sh 123 Complete`, 'update-status.sh')
  runs('script wrapper', `a && ${w} /x/y/lint-commit.sh -m z`, 'lint-commit.sh')
}
// A syntax check (`bash -n`, `-o noexec`) runs nothing.
for (const w of ['bash -n', 'bash -xn', 'sh -n', 'bash -o noexec', 'bash -n -c']) {
  quiet('syntax check', `${w} ~/.config/agent-watcher/update-status.sh 123 Complete`, 'update-status.sh')
}

// ---- places that only mention the command ----
const MENTIONS = [
  "echo 'X'", 'echo "X"', "printf '%s\\n' 'X'", 'grep -n "X" file', "rg 'X' .", "sed -n 's/X//p' f", 'V="X"',
  "V='X'; echo \"$V\"", 'tool --reason "X"', "tool --reason 'ran X then stopped'", '[[ $a == "X" ]]',
  "case $a in 'X') echo;; esac", ": 'X'", "python3 -c 'X'", 'node -e "X"', "jq '.x' <<'E'\nX\nE", 'cat > f <<E\nX\nE\necho done',
  "cat <<'E' > f\nline\nX\nE", 'cat <<-E\n\tX\n\tE', 'echo a # X', '# X', 'a # X\nb', 'eval "X"', "eval 'X'",
  "bash <<'E'\nX\nE", "ssh host 'X'", 'cat <<< "X"', 'echo "a\nX\nb"', "echo 'a\nX\nb'", 'git log --grep="X"',
  "awk '/X/' f", 'tool "$(echo "X")"', "bash -c 'echo \"X\"'", "bash -c \"echo 'X'\"", "bash -c '# X'",
  'echo "X" | cat', 'echo X', 'a --flag X', "echo \"it's X\"", 'echo $\'X\'', 'write-note.sh "status: X"',
  "tool <<'E'\n$(X)\nE"
]
for (const t of TARGETS) for (const tpl of MENTIONS) quiet('mention', tpl.replace('X', t.text), t.sig)

// ---- lookups print a path and run nothing ----
for (const raw of ['command -v git', 'command -V git', 'xcrun --find simctl', 'xcrun -f simctl', 'xcrun --show-sdk-path']) {
  same(`lookup ${raw}`, sigs(raw), [])
}
same('which is its own command', sigs('which git'), ['which'])
same('xcrun with an sdk', sigs('xcrun --sdk iphonesimulator simctl list'), ['simctl:list'])

// ---- git: the subcommand after every global option ----
const GIT_GLOBAL = [
  '', '-C /repo', '-C /repo -C sub', '-c user.name=x', '-c user.name=x -c user.email=y', '-C /repo -c a.b=c',
  '--git-dir /repo/.git', '--git-dir=/repo/.git', '--work-tree /repo', '--work-tree=/repo', '--namespace ns',
  '--namespace=ns', '--config-env a.b=ENVVAR', '--config-env=a.b=ENVVAR', '--attr-source HEAD', '--super-prefix p/',
  '-p', '-P', '--paginate', '--no-pager', '--bare', '--no-replace-objects', '--literal-pathspecs', '--glob-pathspecs',
  '--noglob-pathspecs', '--icase-pathspecs', '--no-optional-locks', '--no-lazy-fetch', '--no-advice',
  '--exec-path=/usr/lib/git', '--no-pager -C /repo -c core.editor=true', '-c "user.name=A B" -C "/my repo"',
  "-c 'alias.x=push' --no-pager"
]
const GIT_SUBS = [['commit -m msg', 'git:commit'], ['push origin HEAD', 'git:push'], ['rebase -i --autosquash main', 'git:rebase'], ['status', 'git:status']]
for (const g of GIT_GLOBAL) {
  for (const [sub, want] of GIT_SUBS) {
    const raw = `git ${g} ${sub}`.replace(/ +/g, ' ')
    same(`git global: ${raw}`, sigs(raw), [want])
  }
}
for (const bin of ['/usr/bin/git', '/opt/homebrew/bin/git', '"git"', "'git'", '\\git', 'command git', 'env GIT_EDITOR=true git']) {
  same(`git spelled ${bin}`, sigs(`${bin} push`), ['git:push'])
}
same('git with no subcommand', sigs('git --version'), ['git:'])
same('a quoted subcommand', sigs('git "push"'), ['git:push'])
same('a variable subcommand set in the line', sigs('S=push; git $S'), ['git:push'])
same('a variable program set in the line', sigs('G=git; $G push'), ['git:push'])
same('an unknown variable program stays unknown', sigs('$G push'), ['$G'])

// ---- git commit flags ----
const flags = (raw) => { const g = parse(raw, { env: ENV }).filter((r) => r.git && r.git.sub === 'commit')[0].git; return [g.noVerify, g.amend] }
const COMMITS = [
  ['git commit -m x', false, false], ['git commit --no-verify -m x', true, false], ['git commit -m x --no-verify', true, false],
  ['git commit -n -m x', true, false], ['git commit -nm x', true, false], ['git commit -anm x', true, false],
  ['git commit -an -m x', true, false], ['git commit -m -n', false, false], ['git commit -m "--no-verify"', false, false],
  ['git commit -m "use --no-verify never"', false, false], ['git commit -m --amend', false, false], ['git commit -mn', false, false],
  ['git commit -m n', false, false], ['git commit -F -n', false, false], ['git commit -C HEAD -n', true, false],
  ['git commit --amend', false, true], ['git commit --amend --no-edit', false, true], ['git commit -m x --amend -n', true, true],
  ['git commit --amend -C HEAD', false, true], ['git commit -a', false, false], ['git commit -am x', false, false],
  ['git commit --fixup abc123', false, false], ['git commit --fixup=abc123 -n', true, false], ['git commit --author "n <e>" -m x', false, false],
  ['git commit -m x -- -n', false, false], ['git commit --message=--no-verify', false, false], ['git commit --no-verify-signatures', false, false],
  ['git -C /r commit --no-verify', true, false], ['git -c a=b commit --amend', false, true], ['git commit -v', false, false],
  ['git commit -S -m x', false, false], ['git commit -sn -m x', true, false], ['git commit --dry-run', false, false]
]
for (const [raw, nv, am] of COMMITS) same(`commit flags: ${raw}`, flags(raw), [nv, am])
const auto = (raw) => parse(raw, { env: ENV }).filter((r) => r.git)[0].git.autosquash
same('rebase --autosquash', auto('git rebase -i --autosquash main'), true)
same('rebase without it', auto('git rebase main'), false)
same('rebase with it only in a quoted word', auto('git rebase main -x "echo --autosquash"'), false)
same('pull --rebase --autosquash', auto('git pull --rebase --autosquash'), true)

// ---- directories ----
const dirs = (raw, cwd) => parse(raw, { env: ENV, cwd: cwd || null }).filter((r) => r.git).map((r) => r.git.dir)
const DIRS = [
  ['git push', null, [null]], ['git push', '/w', ['/w']], ['cd /r && git push', null, ['/r']], ['cd /r; git push', '/w', ['/r']],
  ['cd /r\ngit push', null, ['/r']], ['cd sub && git push', '/w', ['/w/sub']], ['cd sub && git push', null, [null]],
  ['cd .. && git push', '/w/x', ['/w']], ['cd /r && cd sub && git push', null, ['/r/sub']], ['cd "/my repo" && git push', null, ['/my repo']],
  ['cd ~/git/x && git push', null, ['/home/u/git/x']], ['cd $HOME/git/x && git push', null, ['/home/u/git/x']],
  ['cd "$HOME/git/x" && git push', null, ['/home/u/git/x']], ['cd ${HOME}/x && git push', null, ['/home/u/x']],
  ['R=/r; cd "$R" && git push', null, ['/r']], ['R=/r\ncd $R/sub\ngit push', null, ['/r/sub']], ['cd "$UNSET_DIR" && git push', '/w', [null]],
  ['cd $(pwd)/x && git push', '/w', [null]], ['cd - && git push', '/w', [null]], ['cd && git push', '/w', ['/home/u']],
  ['(cd /r && git status); git push', '/w', ['/r', '/w']], ['(cd /r; (cd /s; git status); git status); git push', null, ['/s', '/r', null]],
  ['pushd /r && git push', null, ['/r']], ['git -C /r push', '/w', ['/r']], ['git -C sub push', '/w', ['/w/sub']],
  ['cd /r && git -C sub push', null, ['/r/sub']], ['git -C /r -C sub push', null, ['/r/sub']], ['git -C ~/x push', null, ['/home/u/x']],
  ['git -C "$UNSET_DIR" push', '/w', [null]], ['cd /r && git -C /q push && git status', null, ['/q', '/r']],
  ["bash -c 'cd /r && git push'", '/w', ['/r']], ["cd /r && bash -c 'git push'", null, ['/r']], ["bash -c 'cd /r'; git push", '/w', ['/w']],
  ['cd /a || cd /b; git push', null, ['/b']], ['cd -P /r && git push', null, ['/r']], ['cd -- /r && git push', null, ['/r']],
  ['R=~/x; git -C "$R" push', null, ['/home/u/x']], ['R=~; cd $R && git push', null, ['/home/u']],
  ['while true; do R=/r; git -C "$R" push; done', null, ['/r']], ['if true; then R=/r; cd $R; git push; fi', null, ['/r']],
  ['for r in a; do (cd /r && git push); done; git status', '/w', ['/r', '/w']], ['if true; then (cd /r; git push); fi', null, ['/r']]
]
for (const [raw, cwd, want] of DIRS) same(`dir: ${raw} from ${cwd}`, dirs(raw, cwd), want)

// ---- gh ----
const gh = (raw) => parse(raw, { env: ENV }).filter((r) => r.gh).map((r) => r.gh.sub)
const GH = [
  ['gh pr merge 12 --admin', ['pr merge']], ['gh pr merge --admin 12', ['pr merge']], ['gh -R a/b pr merge 12', ['pr merge']],
  ['gh --repo a/b pr merge 12', ['pr merge']], ['gh pr -R a/b merge 12', ['pr merge']], ['gh pr create --title "gh pr merge"', ['pr create']],
  ['gh pr edit 5 --base main', ['pr edit']], ['gh pr view --json number', ['pr view']], ['gh api repos/a/b/pulls', ['api repos/a/b/pulls']],
  ['gh pr ready', ['pr ready']], ['gh pr reopen 4', ['pr reopen']], ['gh', ['']], ['gh --version', ['']],
  ['GH_TOKEN=x gh pr merge 1', ['pr merge']], ['echo "gh pr merge 1 --admin"', []], ['gh pr list | xargs -n 1 gh pr merge --admin', ['pr list', 'pr merge']],
  ["bash -c 'gh pr merge 1 --admin'", ['pr merge']], ['gh pr comment 1 --body "$(gh pr view 2 --json title)"', ['pr view', 'pr comment']]
]
for (const [raw, want] of GH) same(`gh: ${raw}`, gh(raw), want)
same('gh args keep the flags', parse('gh -R a/b pr merge 12 --admin --match-head-commit abc', { env: ENV })[0].gh.args,
  ['-R', 'a/b', '12', '--admin', '--match-head-commit', 'abc'])

// ---- words, expansion, redirects, spans ----
const one = (raw, o) => parse(raw, Object.assign({ env: ENV }, o || {}))[0]
same('quotes are removed from argv', one('tool "a b" \'c d\' e\\ f').argv, ['tool', 'a b', 'c d', 'e f'])
same('adjacent quoted parts join', one('tool a"b c"\'d\'').argv, ['tool', 'ab cd'])
same('a tilde path expands', one('~/x/tool.sh a').path, '/home/u/x/tool.sh')
same('a tilde inside quotes stays', one('"~/x/tool.sh" a').path, '~/x/tool.sh')
same('$HOME expands in double quotes', one('"$HOME/x/tool.sh"').path, '/home/u/x/tool.sh')
same('$HOME stays in single quotes', one("'$HOME/x/tool.sh'").path, '$HOME/x/tool.sh')
same('an escaped dollar stays', one('tool "\\$HOME"').argv[1], '$HOME')
same('a line assignment expands', one('G=123; tool "$G" ${G}x').argv, ['tool', '123', '123x'])
same('a later assignment wins', parse('G=1; G=2; tool $G', { env: ENV })[0].argv, ['tool', '2'])
same('an assignment from a substitution is unknown', one('G=$(a)\ntool $G', {}).name, 'a')
same('a prefix assignment is not a line assignment', parse('G=1 a; tool $G', { env: ENV })[1].argv, ['tool', '$G'])
same('unexpanded words are kept', one('tool "$HOME/a"').words, ['tool', '$HOME/a'])
same('redirects stay out of argv', one('tool a > out 2>&1 b').argv, ['tool', 'a', 'b'])
same('redirect targets are recorded', one('tool a > "out file" 2>> err').redirs, [{ op: '>', target: 'out file' }, { op: '>>', target: 'err' }])
same('a here-string is a redirect', one('tool <<< "git push" a').argv, ['tool', 'a'])
same('a fd number is not an argument', one('tool 2>/dev/null 3>&1').argv, ['tool'])
same('a number argument stays', one('tool 2 >/dev/null').argv, ['tool', '2'])
same('name is the basename', one('/a/b/c.sh x').name, 'c.sh')
{
  const raw = 'cd /x && A=1 ~/s/tool.sh "a b" > out; other'
  const recs = parse(raw, { env: ENV })
  same('a span covers prefix, words and redirect', raw.slice(recs[1].start, recs[1].end), 'A=1 ~/s/tool.sh "a b" > out')
  same('spans are in order', recs.map((r) => raw.slice(r.start, r.end)), ['cd /x', 'A=1 ~/s/tool.sh "a b" > out', 'other'])
  same('a wrapper is inside the span', (() => { const r = 'a; timeout 5 tool x; b'; const c = parse(r)[1]; return r.slice(c.start, c.end) })(), 'timeout 5 tool x')
  const n = parse("bash -c 'tool x'", { env: ENV })[0]
  same('a nested command has no span', [n.nested, n.start, n.end], [true, -1, -1])
  same('a top-level command is not nested', recs[0].nested, false)
}
same('a shell with a variable -c string is opaque', (() => { const r = one('bash -c "$CMD"'); return [r.name, r.opaque] })(), ['bash', true])
same('a bare shell is its own command', sigs('bash'), ['bash'])
same('a bare wrapper is its own command', sigs('env'), ['env'])
same('order follows the text', sigs('a; b && c | d'), ['a', 'b', 'c', 'd'])
same('a for clause is not a command', sigs('for git in push pull; do echo $git; done'), ['echo'])
same('case patterns are not commands', sigs('case $x in git|push) a;; simctl) b;; esac'), ['a', 'b'])
same('a function definition body runs', sigs('deploy() { a; b; }'), ['a', 'b'])
same('test operators are not separators', sigs('[[ $a == x && $b != y || -z $c ]] && tool'), ['[[', 'tool'])
same('an array assignment is not a command', sigs('arr=(git push); echo ${arr[@]}'), ['echo'])
same('arithmetic is not a command', sigs('(( i > 2 && j < 3 )) && tool'), ['tool'])
same('a comment hash inside a word is text', sigs('echo a#b; tool'), ['echo', 'tool'])
same('a heredoc tag in quotes ends the body', sigs("cat <<'EOF'\ngit push\nEOF\ntool"), ['cat', 'tool'])
same('two heredocs on one line', sigs('a <<A <<B\ngit push\nA\nxcrun simctl erase all\nB\ntool'), ['a', 'tool'])
same('a heredoc with a pipe after it', sigs('cat <<E | tool\ngit push\nE'), ['cat', 'tool'])
same('an unterminated heredoc swallows the rest', sigs('cat <<E\ngit push'), ['cat'])

// ---- input that is cut off or malformed is read without an exception ----
const BROKEN = [
  '', ' ', '\n', ';', ';;', '&&', '|', '(', ')', '((', '))', '{', '}', '"', "'", '`', '$(', '$((', '${', '$', '\\', '<<', '<<<', '<', '>',
  'git "push', "git 'push", 'git `push', 'git $(push', 'echo ${a', 'echo $((1', 'cat <<', 'cat <<E', 'case', 'case x in', 'case x in a)',
  'if', 'for', 'for x', 'function', 'bash -c', "bash -c '", 'bash -c "$(', 'env', 'timeout', 'xargs -I', 'git -C', 'git -c', 'gh -R',
  'a ))) b', 'a ((( b', '[[ a', ']]', '[[ ]] ]]', 'a 2>', 'a >', 'a &> ', '2>&1', '=x', 'A=', 'A=1', 'A+=1', '~', '~ a', 'a ~',
  'esac', 'done', 'fi', '!', '! !', 'time', 'coproc', '$', '$$', '$? $# $@ $* $! $-', 'a\\', '"\\', "$'", "$'\\"
]
for (const raw of BROKEN) {
  let ok = true
  let err
  try { const out = parse(raw, { env: ENV }); ok = Array.isArray(out) } catch (e) { ok = false; err = e.message }
  check(`reads ${JSON.stringify(raw)}`, ok, err)
}
same('a non-string reads as nothing', parse(undefined), [])
{
  // A fixed generator, so a failure repeats: 400 lines of shell punctuation.
  let seed = 12345
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
  const ATOMS = ['git', 'push', ' ', ' ', ';', '&&', '|', '(', ')', '{', '}', '"', "'", '`', '$(', '$', '\\', '\n', '<<E', 'E', '<', '>',
    '[[', ']]', 'case', 'in', 'esac', ';;', 'bash', '-c', 'cd', '/r', '#', '=', 'A=1', '~', '${', '((', '))', '<<<', '&', 'if', 'then', 'fi', 'for', 'do', 'done']
  let bad = null
  for (let i = 0; i < 400 && !bad; i++) {
    let raw = ''
    for (let j = 0, len = 1 + rnd(24); j < len; j++) raw += ATOMS[rnd(ATOMS.length)]
    try {
      for (const r of parse(raw, { env: ENV })) {
        if (typeof r.name !== 'string' || !Array.isArray(r.argv) || r.end < r.start || r.end > raw.length) throw new Error('bad record ' + JSON.stringify(r))
      }
    } catch (e) { bad = `${JSON.stringify(raw)}: ${e.message}` }
  }
  check('400 generated lines read without an exception', !bad, bad)
}
{
  const deep = 'echo ' + '$('.repeat(60) + 'git push' + ')'.repeat(60)
  let ok = true
  try { parse(deep, { env: ENV }) } catch (e) { ok = false }
  check('60 nested substitutions read without an exception', ok)
  const long = ('echo "a b" && ').repeat(5000) + 'git push'
  const t0 = process.hrtime.bigint()
  const got = sigs(long)
  check('a 70 KB line reads in under two seconds', Number(process.hrtime.bigint() - t0) / 1e9 < 2 && got[got.length - 1] === 'git:push')
}

// ---- cmd-parse.sh ----
function cli (script, args, input) {
  const r = spawnSync(path.join(HOOKS, script), args, { input, encoding: 'utf8', env: Object.assign({}, process.env, ENV) })
  return { rc: r.status, out: r.stdout }
}
{
  const r = cli('cmd-parse.sh', [], 'cd /r && git -C sub commit -n -m x')
  const lines = r.out.trim().split('\n').map((l) => JSON.parse(l))
  same('cmd-parse prints one JSON object per command', [r.rc, lines.length, lines[1].git.sub, lines[1].git.dir, lines[1].git.noVerify], [0, 2, 'commit', '/r/sub', true])
  same('cmd-parse takes a starting directory', JSON.parse(cli('cmd-parse.sh', ['--cwd', '/w'], 'git push').out).git.dir, '/w')
  same('cmd-parse prints nothing for an empty line', cli('cmd-parse.sh', [], ''), { rc: 0, out: '' })
  same('cmd-parse refuses an unknown option', cli('cmd-parse.sh', ['--nope'], 'a').rc, 2)
  same('cmd-parse refuses --rest without --under', cli('cmd-parse.sh', ['--rest'], 'a').rc, 2)
  same('cmd-parse refuses --under without --rest', cli('cmd-parse.sh', ['--under', '/x/'], 'a').rc, 2)

  const U = ['--rest', '--under', '/.cursor/skills/', '--under', '/.config/agent-watcher/']
  const rest = (raw) => cli('cmd-parse.sh', U, raw)
  let raw = 'cd /x && ~/.cursor/skills/a/b.sh "gh api -X POST" && gh api -X POST y'
  let v = rest(raw)
  same('the rest view keeps the length', [v.rc, v.out.length], [0, raw.length])
  check('the rest view blanks the sanctioned script', !v.out.includes('b.sh'), v.out)
  check('the rest view keeps the command after it', v.out.includes('gh api -X POST y'), v.out)
  check('the rest view keeps the command before it', v.out.startsWith('cd /x && '), v.out)
  raw = 'echo ~/.cursor/skills/a/b.sh && gh api -X POST y'
  check('a script that is only named is not blanked as a command', rest(raw).out.includes('echo ~/.cursor/skills/a/b.sh'), rest(raw).out)
  raw = 'bash ~/.config/agent-watcher/x.sh --flag\ngh api z'
  v = rest(raw)
  check('a script run through bash is blanked', !v.out.includes('x.sh') && v.out.includes('gh api z'), v.out)
  check('the rest view keeps newlines', v.out.split('\n').length === 2, v.out)
  raw = '/usr/bin/other.sh "gh api -X POST" && tool'
  check('quoted text is blanked as in the stripped view', !rest(raw).out.includes('gh api') && rest(raw).out.includes('/usr/bin/other.sh'), rest(raw).out)
}

// ---- cmd-executes.sh ----
{
  const ex = (args, raw) => cli('cmd-executes.sh', args, raw).rc
  const CASES = [
    [['lint-commit.sh'], '~/.cursor/skills/lint-commit.sh -m x', 0], [['lint-commit.sh'], 'cd /r && "$HOME/.cursor/skills/lint-commit.sh" -m x', 0],
    [['lint-commit.sh'], 'cat ~/.cursor/skills/lint-commit.sh', 1], [['lint-commit.sh'], 'echo "run lint-commit.sh"', 1],
    [['lint-commit.sh'], "bash -c '~/.cursor/skills/lint-commit.sh -m x'", 0], [['lint-commit.sh'], "bash -c 'cat lint-commit.sh'", 1],
    [['lint-commit.sh'], 'echo "$(~/.cursor/skills/lint-commit.sh -m x)"', 0], [['lint-commit.sh'], 'eval "~/.cursor/skills/lint-commit.sh"', 1],
    [['lint-commit.sh'], 'timeout 60 bash ~/.cursor/skills/lint-commit.sh', 0], [['lint-commit.sh'], 'command -v lint-commit.sh', 1],
    [['a.sh', 'b.sh'], 'x; /p/b.sh', 0], [['a.sh', 'b.sh'], 'x; /p/c.sh a.sh', 1], [['a.sh'], '', 1], [['a.sh'], '   ', 1],
    [['--under', '/.cursor/skills/'], '~/.cursor/skills/x/y.sh', 0], [['--under', '/.cursor/skills/'], 'git add ~/.cursor/skills/x/y.sh && git commit', 1],
    [['--under', '/.cursor/skills/'], 'A=1 env B=2 $HOME/.cursor/skills/x/y.sh', 0], [['--under', '/.cursor/skills/'], '${HOME}/.cursor/skills/x/y.sh', 0],
    [['--under', '/.cursor/skills/', '--under', '/.config/agent-watcher/'], 'a | ~/.config/agent-watcher/z.sh', 0],
    [['--under', '/.cursor/skills/'], "cat <<'E'\n~/.cursor/skills/x/y.sh\nE", 1], [['--under'], 'a', 2], [[], 'a', 2]
  ]
  for (const [args, raw, want] of CASES) same(`cmd-executes ${args.join(' ')} on ${JSON.stringify(raw)}`, ex(args, raw), want)
}

console.log(failed ? `\n${failed} failed of ${ran}` : `\nall passed (${ran} checks)`)
process.exit(failed ? 1 : 0)
