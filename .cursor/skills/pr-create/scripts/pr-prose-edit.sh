#!/usr/bin/env bash
# pr-prose-edit.sh — Rewrite an owned PR's title and/or prose body.
#
# The sanctioned funnel for the edit block-raw-gh-writes.sh denies (`gh pr edit
# --title/--body/--body-file`). A raw edit has two failure modes this closes:
#   1. It can drop or mangle an agent-owned sentinel block (the test-evidence
#      table, the synced description). Every `<!-- agent-<name>:start/end -->`
#      block in the LIVE body is spliced back over the same-named block in the
#      new body verbatim (or appended when the new body omits it), so the caller
#      owns only the prose around the blocks and cannot lose evidence.
#   2. It skips the prose lint. Title and body run through the same
#      no-slop-lint.sh --semantic the pr-create body boundary uses; a HARD
#      finding refuses the edit (exit 2) with the findings on stderr.
# Author-scoped: refuses a PR whose author is not the authenticated gh user, so
# it cannot rewrite a human's PR description.
#
# Usage: pr-prose-edit.sh --repo <owner/repo> --pr <num>
#                         [--title "<title>"] [--body-file <path>] [--dry-run]
# At least one of --title / --body-file. --dry-run prints the final body and
# title without writing.
# Exit: 0 written (or dry run), 1 error, 2 lint refused.
set -euo pipefail
REPO=""; PR=""; TITLE=""; BODY_FILE=""; DRY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "usage: pr-prose-edit.sh --repo <owner/repo> --pr <num> [--title <t>] [--body-file <f>]" >&2; exit 1; }
[[ -n "$TITLE" || -n "$BODY_FILE" ]] || { echo "nothing to edit: pass --title and/or --body-file" >&2; exit 1; }
[[ -z "$BODY_FILE" || -f "$BODY_FILE" ]] || { echo "body file not found: $BODY_FILE" >&2; exit 1; }

ME=$(gh api user --jq .login)
AUTHOR=$(gh api "repos/$REPO/pulls/$PR" --jq .user.login)
[[ "$ME" == "$AUTHOR" ]] || { echo "refusing: $REPO#$PR is authored by $AUTHOR, not $ME" >&2; exit 1; }

LINT="$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$BODY_FILE" ]]; then
  gh api "repos/$REPO/pulls/$PR" --jq '.body // ""' > "$TMP/live.md"
  node -e '
    const fs = require("fs")
    const [live, next, out] = process.argv.slice(1)
    const L = fs.readFileSync(live, "utf8"), N = fs.readFileSync(next, "utf8")
    const re = /<!-- agent-([a-z0-9-]+):start -->[\s\S]*?<!-- agent-\1:end -->/g
    let body = N
    for (const m of L.matchAll(re)) {
      const name = m[1]
      const S = `<!-- agent-${name}:start -->`, E = `<!-- agent-${name}:end -->`
      const i = body.indexOf(S), j = body.indexOf(E)
      if (i >= 0 && j > i) body = body.slice(0, i) + m[0] + body.slice(j + E.length)
      else if ((i >= 0) !== (j >= 0)) { console.error(`new body has a broken agent-${name} block (half a sentinel pair)`); process.exit(1) }
      else body = body.replace(/\s*$/, "") + "\n\n" + m[0] + "\n"
    }
    fs.writeFileSync(out, body)
  ' "$TMP/live.md" "$BODY_FILE" "$TMP/body.md"
  set +e; OUT=$("$LINT" "$TMP/body.md" --semantic); RC=$?; set -e
  if [[ $RC -eq 1 ]]; then echo "BLOCKED: body fails the shared prose lint:" >&2; echo "$OUT" >&2; exit 2; fi
  printf '%s\n' "$OUT" | grep '^WARN ' >&2 || true
fi

if [[ -n "$TITLE" ]]; then
  printf '%s\n' "$TITLE" > "$TMP/title.md"
  set +e; OUT=$("$LINT" "$TMP/title.md"); RC=$?; set -e
  if [[ $RC -eq 1 ]]; then echo "BLOCKED: title fails the shared prose lint:" >&2; echo "$OUT" >&2; exit 2; fi
fi

if $DRY; then
  [[ -n "$TITLE" ]] && echo "TITLE: $TITLE"
  [[ -n "$BODY_FILE" ]] && cat "$TMP/body.md"
  exit 0
fi

ARGS=(pr edit "$PR" --repo "$REPO")
[[ -n "$TITLE" ]] && ARGS+=(--title "$TITLE")
[[ -n "$BODY_FILE" ]] && ARGS+=(--body-file "$TMP/body.md")
gh "${ARGS[@]}" >/dev/null
echo ">> pr-prose-edit: $REPO#$PR updated${TITLE:+ (title: \"$TITLE\")}${BODY_FILE:+ (body)}"
