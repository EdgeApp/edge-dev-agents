#!/usr/bin/env bash
# require-force-land-rationale.sh -- PreToolUse(Bash).
# Blocks `gh pr merge ... --admin` until the PR carries this run's force-land
# rationale comment.
#
# WHY: an admin merge is the one land that no human ever approved, and the PR
# is where the next reader looks for why. pr-land `force-land-review-bypass`
# prescribes the comment; under mid-land momentum the merge command is the
# thing that gets typed and the comment is the thing that gets skipped, so the
# merge waits on the marker instead.
#
# The marker is written by ~/.cursor/skills/pr-land/scripts/force-land-rationale.sh
# AFTER the comment posts, so it can only exist if the comment does. It is
# per-PR (/tmp/agent-force-land-rationale-<owner>-<repo>-<pr>.json), names the
# head commit the comment vouched for, and must be fresher than MAX_AGE.
#
# The merge is read from cmd-parse.sh records, so it is found behind `gh -R`,
# after a cd, or inside `bash -c` text, and never in a quoted mention. For each
# admin merge the gate asks gh which PR and head the merge acts on (the PR
# argument, a PR URL, -R/--repo, or the current branch of the directory the
# merge runs in) and needs the marker for that repo and PR whose head equals
# the head being merged: --match-head-commit when given, else the PR's head
# now. A marker for another repo, another PR, or an older head does not count.
# When gh cannot answer, the gate falls back to the PR number in the command
# (any repo) and the age alone; when the line cannot be read, to the text
# match it had before.
#
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

MAX_AGE=21600 # 6h
# Where the markers live; a test points it at a scratch directory.
MARKER_DIR="${FORCE_LAND_MARKER_DIR:-/tmp}"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

NOW=$(date +%s)
fresh() {
  local mtime
  [ -f "$1" ] || return 1
  mtime=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)
  [ $((NOW - mtime)) -le "$MAX_AGE" ]
}

# A fresh marker matching the glob, and the head when one is known.
satisfied() {
  local pattern="$1" head="$2" marker
  for marker in $pattern; do
    fresh "$marker" || continue
    if [ -n "$head" ] && [ "$(jq -r '.headSha // empty' "$marker" 2>/dev/null)" != "$head" ]; then
      STALE_HEAD="$marker"
      continue
    fi
    return 0
  done
  return 1
}

CWD_IN=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
STALE_HEAD=""
if RECS=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/cmd-parse.sh" ${CWD_IN:+--cwd "$CWD_IN"} 2>/dev/null); then
  # One row per admin merge: PR selector, -R value, the --match-head-commit
  # value, the directory it runs in. The fields are split on the unit separator
  # (0x1f), since `read` collapses runs of a whitespace separator such as tab
  # and an empty field would shift the rest.
  MERGES=$(printf '%s' "$RECS" | jq -r '
    select((.opaque | not) and .gh != null and .gh.sub == "pr merge")
    | .gh.args as $a
    | select(any($a[]; . == "--admin" or startswith("--admin=")))
    | def val($n): ([range(0; $a | length) as $i | if $a[$i] == $n then $a[$i + 1] elif ($a[$i] | startswith($n + "=")) then ($a[$i] | ltrimstr($n + "=")) else empty end][0] // "");
      ["-R", "--repo", "--match-head-commit", "-t", "--subject", "-b", "--body", "-F", "--body-file", "-A", "--author-email"] as $valued
    | [range(0; $a | length) as $i
        | select(($a[$i] | startswith("-") | not) and ($i == 0 or (($valued | index($a[$i - 1])) == null)))
        | $a[$i]][0] as $sel
    | [($sel // ""), ((val("-R") | select(. != "")) // val("--repo")), val("--match-head-commit"), (.cwd // "")] | join("\u001f")' 2>/dev/null) || MERGES=""
  [ -n "$MERGES" ] || exit 0
  OK=yes
  while IFS=$'\x1f' read -r SEL REPO_ARG MATCH_HEAD RUN_DIR; do
    PR="" OWNER_REPO="" HEAD=""
    case "$SEL" in *github.com/*/pull/*)
      OWNER_REPO=$(printf '%s' "$SEL" | sed -nE 's|.*github\.com/([^/]+/[^/]+)/pull/.*|\1|p')
      PR=$(printf '%s' "$SEL" | sed -nE 's|.*/pull/([0-9]+).*|\1|p') ;;
    esac
    case "$SEL" in ''|*[!0-9]*) ;; *) PR="$SEL" ;; esac
    [ -n "$OWNER_REPO" ] || OWNER_REPO="$REPO_ARG"
    VIEW=$(cd "${RUN_DIR:-${CWD_IN:-.}}" 2>/dev/null && gh pr view ${SEL:+"$SEL"} ${OWNER_REPO:+--repo "$OWNER_REPO"} \
      --json number,headRefOid,url -q '[.number, .headRefOid, .url] | @tsv' 2>/dev/null) || VIEW=""
    if [ -n "$VIEW" ]; then
      IFS=$'\t' read -r V_PR V_HEAD V_URL <<<"$VIEW"
      PR="${V_PR:-$PR}" HEAD="$V_HEAD"
      V_REPO=$(printf '%s' "$V_URL" | sed -nE 's|.*github\.com/([^/]+/[^/]+)/pull/.*|\1|p')
      [ -z "$V_REPO" ] || OWNER_REPO="$V_REPO"
    fi
    [ -z "$MATCH_HEAD" ] || HEAD="$MATCH_HEAD"
    if [ -n "$OWNER_REPO" ] && [ -n "$PR" ]; then
      PATTERN="$MARKER_DIR/agent-force-land-rationale-${OWNER_REPO%%/*}-${OWNER_REPO#*/}-$PR.json"
    elif [ -n "$PR" ]; then
      PATTERN="$MARKER_DIR/agent-force-land-rationale-"*"-$PR.json"
    else
      PATTERN="$MARKER_DIR/agent-force-land-rationale-"*".json"
    fi
    satisfied "$PATTERN" "$HEAD" || OK=no
  done <<<"$MERGES"
  [ "$OK" = no ] || exit 0
else
  # The text match this gate had before the parser.
  CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
  printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' || exit 0
  printf '%s' "$CMD_M" | grep -qE '(^|[[:space:]])--admin([[:space:]]|=|$)' || exit 0
  PR=$(printf '%s' "$CMD_M" | sed -nE 's|.*/pull/([0-9]+).*|\1|p' | head -1)
  [ -n "$PR" ] || PR=$(printf '%s' "$CMD_M" | sed -nE 's/.*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+).*/\1/p' | head -1)
  if [ -n "$PR" ]; then
    PATTERN="$MARKER_DIR/agent-force-land-rationale-"*"-$PR.json"
  else
    PATTERN="$MARKER_DIR/agent-force-land-rationale-"*".json"
  fi
  satisfied "$PATTERN" "" && exit 0
fi

[ -z "$STALE_HEAD" ] || echo "BLOCKED: the force-land rationale in $STALE_HEAD was posted for an older head commit than the one being merged. Commits landed after the comment; post it again for the current head." >&2
echo "BLOCKED: no force-land rationale comment on this PR (pr-land \`force-land-review-bypass\`). An admin merge lands with no approving review, so the PR has to say why review was skipped. Run it first:" >&2
echo "  ~/.cursor/skills/pr-land/scripts/force-land-rationale.sh --owner <o> --repo <r> --pr <n> --task-gid \$AGENT_TASK_GID --rationale \"<the change class that made review unnecessary>\"" >&2
echo "It posts the comment, then writes the marker this gate reads. It refuses without Force Land authority or with checks not green, which is the same answer as not merging." >&2
exit 2
