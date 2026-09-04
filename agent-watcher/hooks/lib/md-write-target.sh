#!/usr/bin/env bash
# md-write-target.sh -- shared extraction of the file a Bash command WRITES.
# Source this; do not execute it.
#
# One implementation for every hook that gates or lints Bash-authored files
# (lint-md-on-write.sh, require-skill-for-file.sh): a vector added here reaches
# all of them at once, so no gate is left covering redirects while another also
# covers in-place editors.
#
# Vectors, in match order:
#   redirect   '> x.md', '>> x.md' (heredoc bodies ride inside the command)
#   tee        'tee x.md', 'tee -a x.md'
#   in-place   'sed -i ... x.md', 'perl -pi ... x.md', 'perl -i ... x.md'
# The operator must be preceded by whitespace or start-of-line: prose like
# '<repo>/README.md' inside a heredoc otherwise reads as a redirect. The
# in-place branch takes the LAST bare path token in the command, since sed and
# perl put the file after the expression.
#
# bash_write_target <cmd> [cwd] [ext]
#   Prints the absolute target path (empty when the command writes no matching
#   file). <ext> defaults to 'md'; pass a full basename such as 'CHANGELOG.md'
#   to match one file name only.

bash_write_target() {
  local cmd="$1" cwd="${2:-}" ext="${3:-md}" target=""
  case "$ext" in
    *.*) local tail="$ext" ;;      # exact basename
    *)   local tail="[^\"'[:space:];|&]+\\.$ext" ;;
  esac
  target=$(printf '%s' "$cmd" \
    | grep -oE "(^|[[:space:]])(>>?|tee([[:space:]]+-a)?)[[:space:]]*\"?'?[^\"'[:space:];|&]*${tail}" \
    | sed -E "s/^[[:space:]]*(>>?|tee([[:space:]]+-a)?)[[:space:]]*[\"']?//" | head -1 || true)
  if [ -z "$target" ] && printf '%s' "$cmd" | grep -qE "(^|[[:space:]|;&(])(sed[[:space:]]+(-[a-zA-Z]*)?-i|perl[[:space:]]+(-[a-zA-Z]*)?-[a-zA-Z]*i)"; then
    target=$(printf '%s' "$cmd" \
      | grep -oE "(^|[[:space:]])\"?'?[^\"'[:space:];|&]*${tail}([[:space:]]|$|;|\\|)" \
      | sed -E "s/^[[:space:]]*[\"']?//; s/[[:space:];|]+$//" | tail -1 || true)
  fi
  [ -n "$target" ] || return 0
  target="${target/#\~/$HOME}"
  case "$target" in /*) ;; *) target="${cwd:+$cwd/}$target" ;; esac
  printf '%s' "$target"
}
