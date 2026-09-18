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
#   inline     an interpreter run inline ('python3 - <<', 'python3 -c',
#              'node - <<', 'node -e') whose body opens or writes a quoted
#              path with the matching tail ('open(...)', '.write(', 'write_text(',
#              'writeFileSync(', 'writeFile('; a bare 'open(' read does not
#              count). Callers pass the RAW command for this vector: the
#              mention-stripped view blanks heredoc bodies, and the body is
#              where the path lives. A 2026-09-07 run rewrote
#              CHANGELOG.md through a python heredoc and walked past every
#              write gate, since nothing above sees a path inside a script.
# The operator must be preceded by whitespace or start-of-line: prose like
# '<repo>/README.md' inside a heredoc otherwise reads as a redirect. The
# in-place branch takes the LAST bare path token in the command, since sed and
# perl put the file after the expression.
#
# A QUOTED redirect/tee target ('cat > "$D/x.md"', "tee '/tmp/x.md'") is blank
# in the mention-stripped view, so the operator positions found there are mapped
# onto the raw command and the whole shell word is read from it (quotes kept for
# lib/shell-word-resolve.sh). Operators inside heredoc bodies or quoted prose
# stay invisible, because positions still come from the stripped view.
#
# A target written through a variable ('M=~/notes' then 'cat > $M/x.md') is
# expanded by lib/shell-word-resolve.sh: the last same-command assignment
# before the target, then the hook environment. An unresolvable target keeps
# its literal text (joined to cwd), so gates keep treating it as a write.
#
# bash_write_target <cmd> [cwd] [ext] [raw-cmd] [mode]
#   Prints the absolute target path (empty when the command writes no matching
#   file). <ext> defaults to 'md'; pass a full basename such as 'CHANGELOG.md'
#   to match one file name only. <raw-cmd>: the unstripped command when <cmd>
#   is the mention-stripped view, so quoted assignment values stay readable
#   for variable expansion (defaults to <cmd>). <mode>: 'first' (default) or
#   'all', which prints EVERY matching target, one per line. A caller deciding
#   whether a command writes a gated path needs 'all', because one command can
#   write an ungated file and a gated one, and stopping at the first match
#   would clear the whole command on the strength of the ungated write.

_MD_WRITE_TARGET_LIB="$(dirname "${BASH_SOURCE[0]}")"
[ -f "$_MD_WRITE_TARGET_LIB/shell-word-resolve.sh" ] && . "$_MD_WRITE_TARGET_LIB/shell-word-resolve.sh"

bash_write_target() {
  local cmd="$1" cwd="${2:-}" ext="${3:-md}" raw="${4:-$1}" mode="${5:-first}"
  local target="" resolved="" word_pos="" targets=""
  # In 'all' mode every branch keeps its whole match list; 'first' keeps the one
  # each branch has always taken (the earliest, or the last for in-place edits,
  # where sed and perl put the file after the expression).
  _pick() { if [ "$mode" = all ]; then cat; else head -1; fi; }
  _pick_last() { if [ "$mode" = all ]; then cat; else tail -1; fi; }
  case "$ext" in
    *.*) local tail="$ext" ;;      # exact basename
    *)   local tail="[^\"'[:space:];|&]+\\.$ext" ;;
  esac
  if [ "$raw" != "$cmd" ]; then
    # Quoted target: operator position from the stripped view, word from raw
    # (runs first, so '"$D"/x.md' is read whole rather than as its bare tail).
    # Prints "<raw-offset><TAB><raw word>" for the first matching target.
    local hit
    hit=$(node -e '
const [stripped, raw, ext, mode] = process.argv.slice(1);
const hits = [];
const S = Array.from(stripped), R = Array.from(raw);
if (S.length !== R.length) process.exit(0);
const s = S.join("");
const want = ext.includes(".")
  ? (w) => w === ext || w.endsWith("/" + ext)
  : (w) => w.length > ext.length + 1 && w.endsWith("." + ext);
for (const m of s.matchAll(/(^|\s)(>>?|tee(?:\s+-a)?)/g)) {
  // The stripped view blanks the quoted word, so skip whitespace in RAW.
  let cp = Array.from(s.slice(0, m.index + m[0].length)).length;
  while (cp < R.length && /\s/.test(R[cp])) cp++;
  let i = cp, word = "", plain = "";
  while (i < R.length) {
    const c = R[i];
    if (c === "\x27" || c === "\"") {
      let j = i + 1;
      while (j < R.length && R[j] !== c) { if (c === "\"" && R[j] === "\\") j++; j++; }
      if (j >= R.length) break;
      word += R.slice(i, j + 1).join(""); plain += R.slice(i + 1, j).join(""); i = j + 1; continue;
    }
    if (/[\s;|&<>()]/.test(c)) break;
    word += c; plain += c; i++;
  }
  if (/["\x27]/.test(word) && want(plain)) {
    hits.push(R.slice(0, cp).join("").length + "\t" + word);
    if (mode !== "all") break;
  }
}
if (hits.length) process.stdout.write(hits.join("\n"));
' "$cmd" "$raw" "$ext" "$mode" 2>/dev/null || true)
    [ -n "$hit" ] && targets="$hit"
  fi
  [ -n "$targets" ] || targets=$(printf '%s' "$cmd" \
    | grep -oE "(^|[[:space:]])(>>?|tee([[:space:]]+-a)?)[[:space:]]*\"?'?[^\"'[:space:];|&]*${tail}" \
    | sed -E "s/^[[:space:]]*(>>?|tee([[:space:]]+-a)?)[[:space:]]*[\"']?//" | _pick || true)
  if [ -z "$targets" ] && printf '%s' "$cmd" | grep -qE "(^|[[:space:]|;&(])(sed[[:space:]]+(-[a-zA-Z]*)?-i|perl[[:space:]]+(-[a-zA-Z]*)?-[a-zA-Z]*i)"; then
    targets=$(printf '%s' "$cmd" \
      | grep -oE "(^|[[:space:]])\"?'?[^\"'[:space:];|&]*${tail}([[:space:]]|$|;|\\|)" \
      | sed -E "s/^[[:space:]]*[\"']?//; s/[[:space:];|]+$//" | _pick_last || true)
  fi
  if [ -z "$targets" ] \
    && printf '%s' "$cmd" | grep -qE "(^|[[:space:]|;&(])(python3?|node)[[:space:]]+(-[[:space:]]*<<|-c[[:space:]]|-e[[:space:]])" \
    && printf '%s' "$cmd" | grep -qE "open\([^)]*[\"'][wa][\"']|\.write\(|write_text\(|writeFileSync\(|writeFile\("; then
    targets=$(printf '%s' "$cmd" \
      | grep -oE "[\"'][^\"'[:space:]]*${tail}[\"']" \
      | sed -E "s/^[\"']//; s/[\"']$//" | _pick || true)
  fi
  [ -n "$targets" ] || return 0

  while IFS= read -r target; do
  [ -n "$target" ] || continue
  word_pos=""
  # The quoted branch emits "<raw-offset><TAB><word>"; the others emit the path.
  case "$target" in
    [0-9]*$'\t'*) word_pos="${target%%$'\t'*}"; target="${target#*$'\t'}" ;;
  esac
  if [ -n "$word_pos" ]; then
    # Quoted word from raw: the shell's quoting decides what expands. An
    # unresolvable word keeps its literal text with the quotes dropped.
    if declare -F resolve_shell_word >/dev/null && resolved=$(resolve_shell_word "$target" "$raw" "$cmd" "$word_pos" 2>/dev/null); then
      target="$resolved"
    else
      target="${target//\"/}"
      target="${target//\'/}"
    fi
  else
    case "$target" in
      *'$'*)
        if declare -F resolve_shell_word >/dev/null && resolved=$(resolve_shell_word "$target" "$raw" "$cmd" 2>/dev/null); then
          target="$resolved"
        fi
        ;;
    esac
  fi
  target="${target/#\~/$HOME}"
  case "$target" in /*) ;; *) target="${cwd:+$cwd/}$target" ;; esac
  if [ "$mode" = all ]; then printf '%s\n' "$target"; else printf '%s' "$target"; fi
  done <<< "$targets"
}
