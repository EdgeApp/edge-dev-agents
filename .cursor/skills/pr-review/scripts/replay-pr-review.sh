#!/usr/bin/env bash
# replay-pr-review.sh — Replay /pr-review offline on a past PR snapshot, from a pinned
# edge-dev-agents commit, and write the findings as JSON. Posts nothing; cannot reach GitHub.
#
# Usage:
#   replay-pr-review.sh --snapshot <repo-N|dir> --eda <sha> [--level <lvl>] [--model <m>]
#                       [--effort <e>] [--me <login>] [--eda-repo <dir>] [--timeout <sec>]
#   replay-pr-review.sh --snapshot <repo-N|dir> --eda <sha> --probe '<bash command>'
#   replay-pr-review.sh --snapshot <repo-N|dir> --eda <sha> --canary
#
# Snapshots come from replay-snapshot.py (~/.config/pr-review/replay/snapshots/<repo>-<N>/).
# The pinned commit is read from the local edge-dev-agents clone (default ~/git/edge-dev-agents,
# never fetched) and extracted once to ~/.config/pr-review/replay/eda/<sha>/tree (read-only).
# That tree is the replay's HOME/.cursor, so every ~/.cursor path the pinned skill names
# resolves to the pinned files: SKILL.md, rules, scripts, and the code-review-sonnet workflow
# (HOME/.claude/workflows). HOME/.claude/CLAUDE.md is regenerated from the pinned rules.
# Nothing from the live ~/.cursor, ~/.claude, memory, hooks or MCP servers reaches the replay.
#
# GitHub guard (every layer applies to the session and every workflow agent it spawns):
#   env -i with a whitelist, so GH_TOKEN / GITHUB_TOKEN / GH_ENTERPRISE_TOKEN are absent;
#   GH_CONFIG_DIR points nowhere; PATH leads with shims (gh, curl, wget, hub, ssh, scp, nc)
#   that log the attempt to guard.log and exit 97; HTTP(S)_PROXY is a dead local port with
#   only Anthropic hosts exempt; git runs with a global config that disables every transport
#   but file and rewrites github.com URLs to an invalid host; the session denies WebFetch,
#   WebSearch, RemoteTrigger and Bash(gh/curl/wget); sandbox-exec denies reads of the live
#   repos, the mining data, other snapshots and runs, and the live ~/.cursor and ~/.claude, and
#   denies writes under $HOME outside the run's work dir and its pinned HOME.
# test-replay-offline.sh proves the guard with --probe and --canary.
#
# Output: ~/.config/pr-review/replay/runs/<repo>-<N>/<sha12>-<level>-<stamp>/
#   findings.json (schema pr-review-replay/1, readable by replay-compare.js), review.json, rejected.json, transcript.jsonl,
#   guard.log, stderr.log, prompt.md

set -euo pipefail

REPLAY_ROOT="$HOME/.config/pr-review/replay"
EDA_REPO="$HOME/git/edge-dev-agents"
LEVEL="high"
MODEL="opus"
EFFORT="high"
ME="j0ntz"
TIMEOUT=5400
SNAP="" EDA="" PROBE="" CANARY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAP="$2"; shift 2 ;;
    --eda) EDA="$2"; shift 2 ;;
    --eda-repo) EDA_REPO="$2"; shift 2 ;;
    --level) LEVEL="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --me) ME="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --probe) PROBE="$2"; shift 2 ;;
    --canary) CANARY=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$SNAP" && -n "$EDA" ]] || { echo "Error: --snapshot and --eda are required" >&2; exit 2; }
[[ -d "$SNAP" ]] || SNAP="$REPLAY_ROOT/snapshots/$SNAP"
[[ -f "$SNAP/meta.json" && -d "$SNAP/repo/.git" ]] || { echo "Error: no snapshot at $SNAP" >&2; exit 2; }

REPO_NAME=$(jq -r .repo "$SNAP/meta.json")
PR_NUM=$(jq -r .pr "$SNAP/meta.json")
if (( PR_NUM % 3 == 2 )) && [[ "${REPLAY_ALLOW_HELD_OUT:-}" != "1" ]]; then
  echo "Error: $REPO_NAME#$PR_NUM is held out (mod 3 == 2); set REPLAY_ALLOW_HELD_OUT=1 only for the replay run" >&2
  exit 2
fi

SHA=$(git -C "$EDA_REPO" rev-parse --verify --quiet "$EDA^{commit}") || { echo "Error: $EDA is not a commit in $EDA_REPO" >&2; exit 2; }
PIN="$REPLAY_ROOT/eda/$SHA"
PHOME="$PIN/home"

# --- Pinned tree and HOME (built once per commit) ---
if [[ ! -f "$PIN/.ready" ]]; then
  mkdir -p "$REPLAY_ROOT/eda"
  TMP=$(mktemp -d "$REPLAY_ROOT/eda/.tmp.XXXXXX")
  mkdir -p "$TMP/tree" "$TMP/home/.claude" "$TMP/home/Library"
  git -C "$EDA_REPO" archive "$SHA" | tar -x -C "$TMP/tree"
  ln -s ../tree/.cursor "$TMP/home/.cursor"
  ln -s ../../tree/.cursor/skills "$TMP/home/.claude/skills"
  [[ -d "$TMP/tree/claude-workflows" ]] && ln -s ../../tree/claude-workflows "$TMP/home/.claude/workflows"
  ln -s "$HOME/Library/Keychains" "$TMP/home/Library/Keychains"
  GEN="$TMP/tree/.cursor/skills/convention-sync/scripts/generate-claude-md.sh"
  if [[ -f "$GEN" ]]; then HOME="$TMP/home" bash "$GEN" >/dev/null 2>&1 || true; fi
  # Account metadata only (never the token; that stays in the Keychain).
  python3 - "$HOME/.claude.json" "$TMP/home/.claude.json" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))
json.dump({k: src[k] for k in ('oauthAccount', 'hasCompletedOnboarding', 'lastOnboardingVersion', 'userID') if k in src},
          open(sys.argv[2], 'w'))
PY
  chmod -R a-w "$TMP/tree"
  touch "$TMP/.ready"
  if ! mv "$TMP" "$PIN" 2>/dev/null; then chmod -R u+w "$TMP"; rm -rf "$TMP"; fi
fi

# --- Guard: shims and git config (shared) ---
GUARD="$REPLAY_ROOT/guard"
mkdir -p "$GUARD/bin"
for tool in gh curl wget hub ssh scp nc; do
  cat > "$GUARD/bin/$tool" <<EOF
#!/bin/sh
echo "\$(date -u +%Y-%m-%dT%H:%M:%SZ) $tool \$*" >> "\${REPLAY_GUARD_LOG:-/dev/null}"
echo "replay guard: $tool is blocked in replay mode (no GitHub or network calls)" >&2
exit 97
EOF
  chmod +x "$GUARD/bin/$tool"
done
cat > "$GUARD/gitconfig" <<'EOF'
[protocol]
	allow = never
[protocol "file"]
	allow = always
[url "https://replay-blocked.invalid/"]
	insteadOf = https://github.com/
	insteadOf = http://github.com/
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
	insteadOf = git://github.com/
[http]
	proxy = http://127.0.0.1:9
[credential]
	helper =
[user]
	name = replay
	email = replay@localhost
EOF

# --- Run dirs ---
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
MODE=review; [[ -n "$PROBE" ]] && MODE=probe; (( CANARY )) && MODE=canary
RUN_ID="${SHA:0:12}-$LEVEL-$STAMP"; [[ "$MODE" != review ]] && RUN_ID="${SHA:0:12}-$MODE-$STAMP-$$"
RUN="$REPLAY_ROOT/runs/$REPO_NAME-$PR_NUM/$RUN_ID"
WORK="$REPLAY_ROOT/work/$REPO_NAME-$PR_NUM-$RUN_ID"
OUT="$WORK/out"
mkdir -p "$RUN" "$OUT" "$WORK/tmp"
cp -R "$SNAP/repo" "$WORK/repo"
# The sandbox denies the runs dir, so the guard log lives in the work dir until the run ends.
GUARD_LOG="$WORK/guard.log"; : > "$GUARD_LOG"

# Context in the shape the pinned `github-pr-review.sh context` prints: a new PR, no reviews.
# The description is included only when the pinned context fetches it.
PINNED_GPR="$PIN/tree/.cursor/skills/pr-review/scripts/github-pr-review.sh"
WITH_BODY=0
grep -E -- '--json [a-zA-Z,]*\bbody\b' "$PINNED_GPR" >/dev/null 2>&1 && WITH_BODY=1
python3 - "$SNAP/meta.json" "$WORK/repo" "$ME" "$WITH_BODY" > "$WORK/pr-context.json" <<'PY'
import json, subprocess, sys
meta, repo, me, with_body = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4] == '1'
def git(*a):
  return subprocess.run(['git', '-C', repo] + list(a), capture_output=True, text=True, check=True).stdout
files = []
status_map = {'A': 'added', 'D': 'removed', 'M': 'modified', 'R': 'renamed', 'C': 'copied', 'T': 'changed'}
for line in git('diff', '--name-status', '-M', 'replay/base', 'replay/head').splitlines():
  parts = line.split('\t')
  path = parts[-1]
  num = git('diff', '--numstat', '-M', 'replay/base', 'replay/head', '--', *parts[1:]).split('\t')
  patch = git('diff', '-M', '--unified=3', 'replay/base', 'replay/head', '--', *parts[1:])
  hunks = patch[patch.find('\n@@') + 1:] if '\n@@' in patch else None
  add = int(num[0]) if num[0].isdigit() else 0
  dele = int(num[1]) if len(num) > 1 and num[1].isdigit() else 0
  files.append({'path': path, 'status': status_map.get(parts[0][0], 'modified'), 'additions': add,
                'deletions': dele, 'patch': hunks.rstrip('\n') if hunks else None})
ctx = {
  'number': meta['pr'], 'title': meta['title'],
  'url': 'https://github.com/%s/%s/pull/%d' % (meta['owner'], meta['repo'], meta['pr']),
  'author': meta['author'], 'me': me, 'headRef': 'replay/head', 'baseRef': meta['baseRef'],
  'headSha': git('rev-parse', 'replay/head').strip(),
  'reviews': [], 'myStanding': {'state': None, 'blockingReviewIds': [], 'blockingThreads': []},
  'myPendingReview': None, 'threads': [], 'inlineComments': [], 'files': files,
}
if with_body:
  ctx['body'] = meta.get('body') or ''
json.dump(ctx, sys.stdout, indent=2)
PY

# --- Replay environment ---
NO_PROXY_HOSTS="api.anthropic.com,.anthropic.com,claude.ai,.claude.ai,claude.com,.claude.com,localhost,127.0.0.1"
TOOL_PATH="$GUARD/bin:$(dirname "$(command -v claude)"):$(dirname "$(command -v node)"):$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin"
REPLAY_ENV=(
  HOME="$PHOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/bash TERM=dumb LANG=en_US.UTF-8
  TMPDIR="$WORK/tmp/" PATH="$TOOL_PATH"
  REPLAY_GUARD_LOG="$GUARD_LOG" GH_CONFIG_DIR=/nonexistent/gh GIT_TERMINAL_PROMPT=0
  GIT_CONFIG_GLOBAL="$GUARD/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$GUARD/bin/ssh"
  HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
  https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9
  NO_PROXY="$NO_PROXY_HOSTS" no_proxy="$NO_PROXY_HOSTS" NODE_USE_ENV_PROXY=1
)

R=$(cd "$HOME" && pwd -P)
SB="$WORK/sandbox.sb"
cat > "$SB" <<EOF
(version 1)
(allow default)
(deny file-read* file-write*
  (subpath "$R/git")
  (subpath "$R/.config/pr-review/mining")
  (subpath "$R/.config/pr-review/replay/cache")
  (subpath "$R/.config/pr-review/replay/snapshots")
  (subpath "$R/.config/pr-review/replay/runs")
  (subpath "$R/.cursor")
  (subpath "$R/.claude")
  (subpath "$R/.config/gh"))
(deny file-write*
  (require-all (subpath "$R")
    (require-not (subpath "$(cd "$WORK" && pwd -P)"))
    (require-not (subpath "$(cd "$PHOME" && pwd -P)"))
    (require-not (subpath "$R/Library/Keychains"))
    (require-not (subpath "$R/Library/Caches"))))
EOF

in_replay() { # command... -> runs inside the sandbox with the replay env, cwd = snapshot copy
  (cd "$WORK/repo" && sandbox-exec -f "$SB" env -i "${REPLAY_ENV[@]}" "$@")
}

if [[ "$MODE" == probe ]]; then
  set +e
  in_replay /bin/bash -c "$PROBE"
  rc=$?
  cp "$GUARD_LOG" "$RUN/guard.log"
  echo "probe exit=$rc guard_lines=$(wc -l < "$GUARD_LOG" | tr -d ' ') guard_log=$RUN/guard.log" >&2
  rm -rf "$WORK"
  exit $rc
fi

SETTINGS="$WORK/settings.json"
jq -n --arg model "$MODEL" --arg effort "$EFFORT" '{
  model: $model, effortLevel: $effort, skipWorkflowUsageWarning: true,
  env: {CLAUDE_CODE_SUBAGENT_MODEL: $model},
  hooks: {},
  permissions: {deny: ["WebFetch", "WebSearch", "RemoteTrigger", "PushNotification", "DesignSync",
    "CronCreate", "ScheduleWakeup", "Bash(gh:*)", "Bash(curl:*)", "Bash(wget:*)", "Bash(hub:*)"]}
}' > "$SETTINGS"
DISALLOWED="WebFetch,WebSearch,RemoteTrigger,PushNotification,DesignSync,CronCreate,CronDelete,ScheduleWakeup,SendMessage"

PROMPT="$WORK/prompt.md"
if (( CANARY )); then
  # Unquoted heredoc: $R is the real home, so item 7 targets the live paths.
  cat > "$PROMPT" <<EOF
This is an automated network-guard test. Try each of these and report the exact output of each, one line per attempt:
1. Bash: gh api repos/EdgeApp/edge-core-js --jq .full_name
2. Bash: curl -sS -m 10 https://api.github.com/repos/EdgeApp/edge-core-js
3. Bash: git ls-remote https://github.com/EdgeApp/edge-core-js HEAD
4. Bash: python3 -c "import urllib.request;print(urllib.request.urlopen('https://api.github.com',timeout=10).status)"
5. Bash: node -e "fetch('https://api.github.com').then(r=>console.log(r.status)).catch(e=>console.log('ERR',e.cause&&e.cause.code||e.message))"
6. Bash: /opt/homebrew/bin/gh api user --jq .login
7. Bash: head -2 $R/git/edge-core-js/package.json; ls $R/.config/pr-review/mining | head -2
8. WebFetch https://api.github.com
Then print the line CANARY DONE.
EOF
else
  cat > "$PROMPT" <<EOF
Run the /pr-review skill in OFFLINE REPLAY mode on $(jq -r '.owner + "/" + .repo' "$SNAP/meta.json")#$PR_NUM at level $LEVEL with --no-comment.

Read ~/.cursor/skills/pr-review/SKILL.md and follow it as written, except where this replay contract overrides it. There is no user: never ask questions, never wait for approval.

Replay contract:
1. GitHub is unreachable by design. Never run gh, curl, or any network command, and never call github-pr-review.sh context, features, submit, or any other subcommand that talks to GitHub. Where a step gets data from GitHub, use the local snapshot instead.
2. Step 1 (context): the context output is already saved at $WORK/pr-context.json. Use it as the context JSON. It is a new PR with no reviews, threads, or comments yet.
3. Step 2 (checkout): the current directory, $WORK/repo, is already checked out at the PR head (branch replay/head). The PR's base commit is replay/base; the PR diff is \`git diff replay/base...replay/head\`. Do not fetch, pull, or check out anything else.
4. Deep workflow: invoke it exactly as the skill says, with the level and every other argument it names, but use the ref range \`replay/base...replay/head\` as the target in place of the PR URL. The workflow agents must also stay offline.
5. Any step that builds a features manifest from GitHub: build it from the local diff instead (\`git diff --name-only replay/base...replay/head\` piped into the feature-routing script the skill names, with --root .), or skip it when the pinned skill has no such step.
6. Deliver (step 6 with --no-comment): write the exact Review JSON you would pass to render (event, body, comments[] each with path, line, side, optional start_line, body, tag) to $OUT/review.json. You may run \`bash ~/.cursor/skills/pr-review/scripts/github-pr-review.sh render < $OUT/review.json\` to check it; render works offline. Also write the findings you rejected in curation to $OUT/rejected.json as a JSON array of {path, line, title, reason, tag}. Write [] when there are none.
7. Finish with one line: REPLAY DONE <number of inline comments> <event>.
EOF
fi
cp "$PROMPT" "$RUN/prompt.md"

CLAUDE_ARGS=(-p "$(cat "$PROMPT")" --model "$MODEL" --effort "$EFFORT"
  --permission-mode bypassPermissions --strict-mcp-config --mcp-config '{"mcpServers":{}}'
  --setting-sources user --settings "$SETTINGS" --disallowedTools "$DISALLOWED"
  --add-dir "$WORK" --output-format stream-json --verbose --no-session-persistence)
if (( CANARY )); then
  CLAUDE_ARGS=(-p "$(cat "$PROMPT")" --model haiku --effort low
    --permission-mode bypassPermissions --strict-mcp-config --mcp-config '{"mcpServers":{}}'
    --setting-sources user --settings "$SETTINGS" --add-dir "$WORK"
    --output-format stream-json --verbose --no-session-persistence)
fi

START=$(date +%s)
set +e
in_replay /usr/bin/perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" claude "${CLAUDE_ARGS[@]}" \
  < /dev/null > "$RUN/transcript.jsonl" 2> "$RUN/stderr.log"
RC=$?
set -e
END=$(date +%s)

cp "$GUARD_LOG" "$RUN/guard.log"
for f in review.json rejected.json; do if [[ -f "$OUT/$f" ]]; then cp "$OUT/$f" "$RUN/$f"; fi; done

# Validate with the pinned render, run offline under the pinned HOME.
RENDER="not-run"
if [[ -f "$RUN/review.json" ]]; then
  if R_OUT=$(env -i HOME="$PHOME" PATH="$TOOL_PATH" bash "$PINNED_GPR" render < "$RUN/review.json" 2>&1 >/dev/null); then
    RENDER="OK"
  else
    RENDER="refused: $(printf '%s' "$R_OUT" | tail -1)"
  fi
fi

python3 - "$RUN" "$SNAP/meta.json" "$SHA" "$LEVEL" "$MODEL" "$EFFORT" "$RC" "$((END - START))" "$RENDER" "$MODE" <<'PY'
import json, os, re, sys
run, meta_p, sha, level, model, effort, rc, secs, render, mode = sys.argv[1:]
meta = json.load(open(meta_p))
bash_cmds, paths, result, init = [], [], None, None
for line in open(os.path.join(run, 'transcript.jsonl'), errors='replace'):
  try:
    e = json.loads(line)
  except ValueError:
    continue
  if not isinstance(e, dict):
    continue
  if e.get('type') == 'system' and e.get('subtype') == 'init':
    init = e
  if e.get('type') == 'result':
    result = e
  msg = e.get('message')
  content = msg.get('content') if isinstance(msg, dict) else None
  for c in content if isinstance(content, list) else []:
    if isinstance(c, dict) and c.get('type') == 'tool_use':
      inp = c.get('input') or {}
      if c.get('name') == 'Bash':
        bash_cmds.append(inp.get('command', ''))
      for k in ('file_path', 'path'):
        if isinstance(inp.get(k), str):
          paths.append(inp[k])
net = re.compile(r'(^|[\s;&|(])(gh|curl|wget|hub)\s|github\.com|api\.github')
guard = [l.rstrip('\n') for l in open(os.path.join(run, 'guard.log'))]
home = os.path.expanduser('~')
forbidden = [p for p in paths if any(p.startswith(home + s) for s in ('/git/', '/.config/pr-review/mining', '/.cursor/', '/.claude/'))]
def load(name):
  try:
    return json.load(open(os.path.join(run, name)))
  except (OSError, ValueError):
    return None
review = load('review.json') or {}
rejected = load('rejected.json')
r = result or {}
out = {
  'schema': 'pr-review-replay/1', 'mode': mode,
  'repo': meta['repo'], 'owner': meta['owner'], 'number': meta['pr'], 'title': meta['title'],
  'prUrl': 'https://github.com/%s/%s/pull/%d' % (meta['owner'], meta['repo'], meta['pr']),
  'label': sha[:12], 'snapshot': os.path.join(os.path.dirname(meta_p), 'repo'),
  'snapshotRefs': {'firstReviewedCommit': meta['firstReviewedCommit'], 'baseCommit': meta['baseCommit'],
                   'head': meta['snapshot']['head'], 'base': meta['snapshot']['base']},
  'eda': sha, 'level': level, 'model': model, 'effort': effort,
  'exitCode': int(rc), 'durationSec': int(secs),
  'result': {k: r.get(k) for k in ('subtype', 'is_error', 'num_turns', 'duration_ms', 'total_cost_usd', 'usage', 'modelUsage')} if result else None,
  'finalText': (r.get('result') or '')[-600:] if result else None,
  'tools': (init or {}).get('tools'),
  'guard': {'blockedAttempts': guard, 'networkBashCommands': [c for c in bash_cmds if net.search(c)],
            'forbiddenPathToolInputs': forbidden},
  'renderCheck': render,
  'event': review.get('event'), 'body': review.get('body'),
  'findings': [{k: c.get(k) for k in ('path', 'line', 'start_line', 'side', 'tag', 'body') if k in c} for c in review.get('comments') or []],
  'rejected': rejected,
}
json.dump(out, open(os.path.join(run, 'findings.json'), 'w'), indent=2)
print(json.dumps({'run': run, 'exit': out['exitCode'], 'secs': out['durationSec'], 'event': out['event'],
                  'findings': len(out['findings']), 'rejected': len(rejected or []), 'render': render,
                  'guardBlocked': len(guard), 'netCmds': len(out['guard']['networkBashCommands']),
                  'forbidden': len(forbidden), 'turns': r.get('num_turns'), 'costUsd': r.get('total_cost_usd')}))
PY
rm -rf "$WORK"
exit $RC
