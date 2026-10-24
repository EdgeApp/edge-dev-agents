#!/usr/bin/env bash
# test-replay-offline.sh — Prove replay mode makes no GitHub call.
#
# Usage: test-replay-offline.sh [--snapshot <repo-N>] [--eda <sha>] [--canary]
#
# 1. Positive control, outside the replay env: `gh api rate_limit` reaches GitHub (this endpoint
#    costs no rate-limit points). Without it, a failure inside the env would prove nothing.
# 2. Inside the env (replay-pr-review.sh --probe, the exact env, sandbox and cwd a replay gets):
#    token vars absent; gh and curl shims exit 97 and log to guard.log; the real gh binary by
#    absolute path cannot authenticate; git ls-remote over https and ssh is refused; python and
#    node HTTPS fail on the dead proxy; the live repos, mining data and ~/.cursor are unreadable.
# 3. --canary: a haiku session in the replay env is told to reach GitHub eight ways; the test
#    fails if any tool result carries a GitHub response (repo JSON, a login, a ref line, HTTP 200).
# Prints one PASS/FAIL line per check and exits 0 only when every check passes.

set -euo pipefail

SNAP="edge-exchange-plugins-510"
EDA="a520576"
CANARY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAP="$2"; shift 2 ;;
    --eda) EDA="$2"; shift 2 ;;
    --canary) CANARY=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

DIR=$(cd "$(dirname "$0")" && pwd)
RUNNER="$DIR/replay-pr-review.sh"
FAILS=0
check() { # name, condition-result (0 = pass), detail
  if [[ "$2" == 0 ]]; then echo "PASS $1"; else echo "FAIL $1: $3"; FAILS=$((FAILS + 1)); fi
}

# 1. Positive control.
if limit=$(gh api rate_limit --jq .resources.core.limit 2>&1) && [[ "$limit" =~ ^[0-9]+$ ]]; then
  check "control: gh reaches GitHub outside the replay env" 0 ""
else
  check "control: gh reaches GitHub outside the replay env" 1 "$limit"
fi

# 2. Inside the replay env. Each line is <name>=<exit code>; 0 means the call succeeded.
PROBE=$(cat <<'EOF'
env | grep -qE '^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN)=' ; echo "token_vars=$?"
gh api user >/dev/null 2>&1; echo "gh_shim=$?"
curl -sS -m 8 https://api.github.com >/dev/null 2>&1; echo "curl_shim=$?"
for g in /opt/homebrew/bin/gh /usr/local/bin/gh; do
  [ -x "$g" ] && { "$g" api user --jq .login >/dev/null 2>&1; echo "gh_absolute=$?"; break; }
done
git ls-remote https://github.com/EdgeApp/edge-core-js HEAD >/dev/null 2>&1; echo "git_https=$?"
git ls-remote git@github.com:EdgeApp/edge-core-js HEAD >/dev/null 2>&1; echo "git_ssh=$?"
python3 -c "import urllib.request;urllib.request.urlopen('https://api.github.com',timeout=8)" >/dev/null 2>&1; echo "python_https=$?"
node -e "fetch('https://api.github.com').then(()=>process.exit(0),()=>process.exit(1))" >/dev/null 2>&1; echo "node_https=$?"
EOF
)
# The pinned HOME is ~/.config/pr-review/replay/eda/<sha>/home; the live paths are passed in
# absolute so the check does not depend on that depth.
R=$(cd "$HOME" && pwd -P)
PROBE="$PROBE
ls '$R/git' >/dev/null 2>&1; echo \"read_live_repos=\$?\"
ls '$R/.config/pr-review/mining' >/dev/null 2>&1; echo \"read_mining=\$?\"
ls '$R/.cursor' >/dev/null 2>&1; echo \"read_live_cursor=\$?\"
touch '$R/.replay-write-test' 2>/dev/null; echo \"write_home=\$?\""
OUT=$("$RUNNER" --snapshot "$SNAP" --eda "$EDA" --probe "$PROBE" 2>"${TMPDIR:-/tmp}/replay-probe-err.$$") || true
GLOG=$(sed -n 's/.*guard_log=//p' "${TMPDIR:-/tmp}/replay-probe-err.$$" | tail -1)
rm -f "${TMPDIR:-/tmp}/replay-probe-err.$$"
val() { printf '%s\n' "$OUT" | grep "^$1=" | tail -1 | cut -d= -f2; }
for name in token_vars gh_shim curl_shim gh_absolute git_https git_ssh python_https node_https read_live_repos read_mining read_live_cursor write_home; do
  v=$(val "$name")
  if [[ -z "$v" ]]; then
    [[ "$name" == gh_absolute ]] && { echo "SKIP $name: no gh binary installed"; continue; }
    check "replay env: $name fails" 1 "no result"
  else
    [[ "$v" != 0 ]]; check "replay env: $name fails (exit $v)" $? "the call succeeded"
  fi
done
[[ "$(val gh_shim)" == 97 && "$(val curl_shim)" == 97 ]]; check "replay env: gh and curl resolve to the guard shims" $? "gh=$(val gh_shim) curl=$(val curl_shim)"
if [[ -n "$GLOG" && -f "$GLOG" ]] && grep -q ' gh api user' "$GLOG" && grep -q ' curl ' "$GLOG"; then
  check "replay env: guard.log records the blocked gh and curl calls" 0 ""
else
  check "replay env: guard.log records the blocked gh and curl calls" 1 "missing entries in ${GLOG:-<none>}"
fi
rm -f "$R/.replay-write-test"

# 3. Canary session.
if (( CANARY )); then
  C_OUT=$("$RUNNER" --snapshot "$SNAP" --eda "$EDA" --canary --timeout 600 2>/dev/null | tail -1) || true
  C_RUN=$(printf '%s' "$C_OUT" | jq -r '.run // empty' 2>/dev/null)
  if [[ -z "$C_RUN" || ! -f "$C_RUN/transcript.jsonl" ]]; then
    check "canary: session ran" 1 "no transcript ($C_OUT)"
  else
    grep -q 'CANARY DONE' "$C_RUN/transcript.jsonl"; check "canary: session ran to the end" $? "no CANARY DONE in $C_RUN"
    LEAKS=$(jq -r 'select(.type=="user") | .message.content[]? | select(.type=="tool_result")
      | (.content | if type=="array" then map(.text? // "") | join("\n") else tostring end)' "$C_RUN/transcript.jsonl" \
      | grep -cE '"full_name"|"login"[[:space:]]*:|^[0-9a-f]{40}[[:space:]]+HEAD|^200$|"current_user_url"' || true)
    [[ "$LEAKS" == 0 ]]; check "canary: no tool result carries a GitHub response" $? "$LEAKS leaking lines in $C_RUN/transcript.jsonl"
    echo "INFO canary run: $C_RUN"
  fi
fi

if (( FAILS == 0 )); then echo "RESULT PASS"; else echo "RESULT FAIL ($FAILS)"; fi
(( FAILS == 0 ))
