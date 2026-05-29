#!/usr/bin/env bash
# slot-fixup.sh
# Move HEAD (a fixup! commit) to sit immediately after its target's group.
# A target's group = the target commit + any same-headline fixups already
# slotted next to it. The new fixup goes at the END of that group, preserving
# chronological order among siblings.
#
# Designed to be called after `lint-commit.sh` creates a fixup, keeping the
# "every fixup sits next to its target" invariant continuously.
#
# Usage:
#   slot-fixup.sh [--base <ref>]
#
# --base <ref>   Base commit/ref to rebase from. Defaults to merge-base of
#                origin's default branch with HEAD.
#
# Exit codes:
#   0 — slotted cleanly (HEAD now points to the slotted fixup)
#   1 — error (HEAD not a fixup, target not found, rebase conflict, etc.)
#
# On conflict the script aborts the rebase and exits non-zero so the caller
# can surface the issue. The working tree is left clean.

set -euo pipefail

BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$BASE" ]]; then
  DEFAULT_UPSTREAM="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    || echo "origin/$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
    || echo "origin/master")"
  if [[ -z "$DEFAULT_UPSTREAM" || "$DEFAULT_UPSTREAM" == "origin/" ]]; then
    DEFAULT_UPSTREAM="origin/master"
  fi
  BASE="$(git merge-base "$DEFAULT_UPSTREAM" HEAD 2>/dev/null || true)"
  if [[ -z "$BASE" ]]; then
    echo "Error: could not determine merge-base with $DEFAULT_UPSTREAM" >&2
    exit 1
  fi
fi

HEAD_MSG="$(git log -1 --format='%s')"
if [[ ! "$HEAD_MSG" =~ ^fixup!\  ]]; then
  echo "Error: HEAD is not a fixup! commit (subject: $HEAD_MSG)" >&2
  exit 1
fi

HEADLINE="${HEAD_MSG#fixup! }"
HEAD_SHA_FULL="$(git rev-parse HEAD)"

TARGET_FOUND="$(git log "$BASE..HEAD~1" --format='%H %s' \
  | awk -v h="$HEADLINE" '$0 ~ ("^[0-9a-f]+ " h "$") { print $1; found=1 } END { exit !found }')"

if [[ -z "$TARGET_FOUND" ]]; then
  echo "Error: target commit with subject \"$HEADLINE\" not found in $BASE..HEAD~1" >&2
  exit 1
fi

# If HEAD is already next to its target group, no-op.
PARENT_MSG="$(git log -1 --format='%s' HEAD~1)"
if [[ "$PARENT_MSG" == "$HEADLINE" || "$PARENT_MSG" == "fixup! $HEADLINE" ]]; then
  echo ">> Already slotted next to target group ($HEADLINE) — no-op"
  exit 0
fi

EDITOR_SCRIPT="$(mktemp -t slot-fixup-editor.XXXXXX.js)"
trap 'rm -f "$EDITOR_SCRIPT"' EXIT

cat > "$EDITOR_SCRIPT" <<'NODEEOF'
const fs = require('fs')
const path = process.argv[2]
const headSha = process.env.SLOT_HEAD_SHA
const headline = process.env.SLOT_HEADLINE
const text = fs.readFileSync(path, 'utf8')
const lines = text.split('\n')

const isPick = l => /^(pick|p)\s+[0-9a-f]+/.test(l)
const getSha = l => {
  const m = l.match(/^[a-z]+\s+([0-9a-f]+)/)
  return m ? m[1] : null
}
const getMsg = l => {
  // Some git builds / `rebase.instructionFormat` settings emit the todo as
  // `pick <sha> # <subject>`; strip the optional `# ` so subject matching
  // works regardless of that prefix.
  const m = l.match(/^[a-z]+\s+[0-9a-f]+\s+(?:#\s+)?(.+)$/)
  return m ? m[1] : ''
}

const todos = []
const trailing = []
let inTrailing = false
for (const line of lines) {
  if (inTrailing) { trailing.push(line); continue }
  if ((line.startsWith('#') || line === '') && todos.length > 0) {
    inTrailing = true
    trailing.push(line)
    continue
  }
  if (isPick(line)) {
    todos.push(line)
  } else if (todos.length === 0) {
    trailing.unshift(line)
  } else {
    trailing.push(line)
  }
}

const headIdx = todos.findIndex(t => {
  const sha = getSha(t)
  if (!sha) return false
  return headSha.startsWith(sha) || sha.startsWith(headSha)
})
if (headIdx < 0) {
  console.error('ERROR: HEAD ' + headSha + ' not found in todos')
  process.exit(1)
}

const headLine = todos[headIdx]
const remaining = todos.filter((_, i) => i !== headIdx)

const targetIdx = remaining.findIndex(t => getMsg(t) === headline)
if (targetIdx < 0) {
  console.error('ERROR: target "' + headline + '" not found in todos')
  process.exit(1)
}

let slotIdx = targetIdx + 1
while (slotIdx < remaining.length && getMsg(remaining[slotIdx]) === 'fixup! ' + headline) {
  slotIdx++
}

const result = [...remaining.slice(0, slotIdx), headLine, ...remaining.slice(slotIdx)]
const out = result.join('\n') + '\n' + (trailing.length > 0 ? trailing.join('\n') : '')
fs.writeFileSync(path, out)
NODEEOF

# --autostash lets slotting proceed when the working tree has unrelated
# uncommitted changes (e.g. the next fixup's edits staged for a following
# pass). It stashes tracked modifications before the rebase and restores them
# after, without touching untracked files like node_modules.
if ! SLOT_HEAD_SHA="$HEAD_SHA_FULL" SLOT_HEADLINE="$HEADLINE" \
    GIT_SEQUENCE_EDITOR="node $EDITOR_SCRIPT" \
    GIT_EDITOR=true \
    git rebase --autostash -i "$BASE" >/dev/null 2>&1; then
  echo "Error: rebase failed during slotting" >&2
  if [[ -d .git/rebase-merge ]] || [[ -d .git/rebase-apply ]]; then
    echo "Aborting rebase to leave working tree clean" >&2
    git rebase --abort 2>&1 | sed 's/^/  /' >&2 || true
  fi
  exit 1
fi

echo ">> Slotted fixup '$HEADLINE' next to its target group"
