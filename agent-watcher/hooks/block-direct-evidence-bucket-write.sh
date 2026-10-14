#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Rule id: evidence-bucket-write-funnel.
# Blocks a typed command that writes to the evidence bucket directly, or that
# hands the bucket's credentials file to a program. A frame reaches the bucket
# only through pr-attach-screenshots.sh, which runs the privacy check ahead of
# every upload, and leaves it only through pr-evidence-withdraw.sh, which also
# clears the manifest entry and the PR body cell. A direct `put` hosts a frame
# no check has read; a direct `delete` leaves a table pointing at nothing.
#
# Blocked:
#   - evidence-bucket.sh (or `node .../evidence-bucket.js`) in command position
#     with the verb put, manifest-put or delete. The read verbs (check, get,
#     exists, list, url, manifest-key, manifest-get) pass.
#   - the credentials file (site-orch/secrets/r2.json) named in a command that
#     runs a program able to read or send it (cat, jq, curl, aws, node, ...).
#     A grep, rg or ls over the path passes.
#
# The attach and withdraw scripts call the bucket script from inside, so their
# typed commands never match. Known gap: a verb or script path held in a
# variable the line does not set, and `eval` text, are not seen.
#
# No-op unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

case "$CMD" in *evidence-bucket.*|*site-orch/secrets/r2.json*) ;; *) exit 0 ;; esac

HOOKS="$HOME/.config/agent-watcher/hooks"
# Mention-stripped view (heredoc bodies and quoted spans blanked, same length)
# for command-position tests; fail open to the raw command without the helper.
CMD_M=$(printf '%s' "$CMD" | "$HOOKS/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
# Jev shadow, log only (lib/jev-shadow.sh): on a raw trigger hit, log execute-vs-quote beside this hook's decision.
. "$HOME/.config/agent-watcher/lib/jev-shadow.sh" 2>/dev/null && jev_shadow_cmd_trap block-direct-evidence-bucket-write "a write to the evidence bucket (put, manifest-put or delete)" 'evidence-bucket\.(sh|js)' "$CMD" || true

deny() {
  echo "BLOCKED (evidence-bucket-write-funnel): $1 Upload proof frames with ~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh --repo <owner/repo> --pr <num> <png...> (it runs the privacy check first), and take a hosted frame down with ~/.cursor/skills/pr-create/scripts/pr-evidence-withdraw.sh --repo <owner/repo> --pr <num> <scene|url>. Reading the bucket (get, exists, list, url, manifest-get) is allowed." >&2
  exit 2
}

# A write verb on the bucket script. The write is read from cmd-parse.sh records: evidence-bucket.sh or .js run
# directly, or the .js handed to node, wherever the line runs it (after a cd,
# behind a wrapper, in a loop or a substitution, inside `bash -c` text). The
# verb is the script's first argument. When the line cannot be read, the text
# match the hook had before decides.
VERB=
if RECS=$(printf '%s' "$CMD" | "$HOOKS/cmd-parse.sh" 2>/dev/null); then
  VERB=$(printf '%s' "$RECS" | jq -r -s '
    [.[] | select(.opaque | not)
      | if (.name | test("^evidence-bucket\\.(sh|js)$")) then .argv[1]
        elif .name == "node" then
          (.argv[1:] | map(select(startswith("-") | not))) as $a
          | if (($a[0] // "") | test("(^|/)evidence-bucket\\.(sh|js)$")) then $a[1] else empty end
        else empty end
      | select(. == "put" or . == "manifest-put" or . == "delete")][0] // empty' 2>/dev/null || true)
else
  VERB=$(RAW="$CMD" STRIPPED="$CMD_M" node -e '
    const raw = process.env.RAW
    const stripped = process.env.STRIPPED.length === raw.length ? process.env.STRIPPED : raw
    // Every place the script is named with a write verb as its first argument.
    const re = /evidence-bucket\.(?:sh|js)["\x27]?[ \t]+["\x27]?(put|manifest-put|delete)(?=["\x27\s;&|)]|$)/g
    let m
    while ((m = re.exec(raw)) != null) {
      // The name must sit OUTSIDE a heredoc body, or be the quoted word of an
      // invocation: walk back over the path to the start of its word and read
      // the stripped view just before it. A segment start, a wrapper word or
      // `node` there means it runs.
      let i = m.index
      while (i > 0 && !/[\s;&|(]/.test(raw[i - 1])) i--
      const before = stripped.slice(0, i).replace(/[ \t]+$/, "")
      const tail = before.slice(before.search(/[^;&|(\n]*$/)).trim()
      if (tail === "" || /^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:(?:env|timeout|gtimeout|nice|time|command|exec|bash|sh|sudo|nohup|node)(?:\s+-?[\w.=-]+)*\s*)*$/.test(tail + " ")) {
        process.stdout.write(m[1])
        break
      }
    }
  ' 2>/dev/null || true)
fi
[ -z "$VERB" ] || deny "a direct \`$VERB\` on the evidence bucket is forbidden in agent sessions."

# The credentials file handed to a program
if printf '%s' "$CMD" | grep -q 'site-orch/secrets/r2\.json'; then
  if printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])(cat|less|more|head|tail|jq|curl|aws|rclone|s3cmd|mc|node|python3?|cp|scp|source|base64|xxd|open)([[:space:]]|$)'; then
    deny "the evidence bucket's credentials file is not read or passed to a program in agent sessions."
  fi
fi

exit 0
