#!/usr/bin/env bash
# phone-capture-ledger.sh -- shared detection and record of PHONE SCREENSHOT
# provenance. Source this; do not execute it.
#
# WHY PROVENANCE AND NOT A PATH LIST. downscale-phone-screenshots.sh has to know
# a frame came from a phone, because websites are out of scope and geometry
# cannot tell them apart (a mobile-viewport web capture is phone-SHAPED). The
# path was the only provenance available, so it matched a name list -- and a
# name list only ever covers the names someone thought to add. Agents name
# working captures freely and the harness prompt pushes temp files into the
# session scratchpad, so the same run writes frames to /tmp/agent-proof-*,
# /tmp/probe-*, and <scratchpad>/probe.png with no stable shape between them.
#
# The capture COMMAND, by contrast, always says where the frame went:
#   xcrun simctl io <udid> screenshot [flags] <dest>
#   adb [flags] exec-out screencap [flags] > <dest>
# Recording that destination as it happens makes the directory irrelevant: a
# frame is downscaled because a simulator or a device produced it. A PNG nothing
# captured (a design comp, a downloaded asset, a web preview) is never recorded
# and is never touched, which is what keeps non-sim scratchpad files out.
#
# Detection follows lib/maestro-cmd.sh: anchors are found in the MENTION-
# STRIPPED view (strip-cmd-mentions.sh blanks heredoc bodies and quoted spans
# while preserving length), so a capture command quoted inside an echo or a
# heredoc is not a capture. The destination WORD is then read from the RAW text
# at the same offset, because the path is often quoted and the stripped view has
# blanked exactly those characters. Callers resolve the word through
# lib/shell-word-resolve.sh, so "$AGENT_SIM_UDID"-style paths resolve instead of
# being recorded as literal text.
#
# `adb shell screencap <path>` writes to the DEVICE, not here, so only the
# exec-out redirect form is a local capture. `screencapture` is the macOS
# desktop tool and is not a phone.
#
# Ledger: TSV of <epoch><TAB><path> at /tmp (not $TMPDIR, which differs between
# a tmux session and a launchd-spawned one and would split the file). A reader
# honors an entry only while the file's mtime is at or before the recorded time:
# the record is written after the capture wrote the file, so anything that
# REWRITES that path afterwards (a path reused for a non-phone image) pushes
# mtime past the record and the entry stops applying.
#
# Every function fails by returning non-zero and printing nothing; callers treat
# that as "not known to be a phone capture" and fall back to their path rules.

PHONE_CAPTURE_LEDGER="${AGENT_PHONE_CAPTURE_LEDGER:-/tmp/agent-phone-captures.tsv}"
PHONE_CAPTURE_TTL="${AGENT_PHONE_CAPTURE_TTL:-86400}"
PHONE_CAPTURE_MAX="${AGENT_PHONE_CAPTURE_MAX:-4000}"

# phone_capture_dests <raw-cmd> [stripped-cmd]
#   Prints one line per capture: <offset><TAB><destination-word>, the raw text
#   with quotes kept (for lib/shell-word-resolve.sh). Prints nothing when the
#   command captures nothing.
phone_capture_dests() {
  node -e '
const [raw, strippedArg] = process.argv.slice(1);
const s = strippedArg && strippedArg.length === raw.length ? strippedArg : raw;
const SEP = /[;&|\n<>()]/;
// One shell word from RAW at i, quotes kept and spanned. Stops at a position
// whose STRIPPED char separates commands, so a ; inside a quoted path does not
// end the word and a real ; does.
function word(i) {
  while (i < raw.length && (raw[i] === " " || raw[i] === "\t")) i++;
  if (i >= raw.length || SEP.test(s[i])) return null;
  const at = i;
  let out = "";
  while (i < raw.length && !/\s/.test(raw[i]) && !SEP.test(s[i])) {
    const c = raw[i];
    if (c === "\"" || c === "\x27") {
      const j = raw.indexOf(c, i + 1);
      if (j < 0) { out += raw.slice(i); i = raw.length; break; }
      out += raw.slice(i, j + 1);
      i = j + 1;
    } else { out += c; i++; }
  }
  return out ? { w: out, at, next: i } : null;
}
function segStart(i) {
  let j = i;
  while (j > 0 && !/[;&|\n]/.test(s[j - 1])) j--;
  return j;
}
const out = [];
for (const m of s.matchAll(/\bsimctl\b/g)) {
  let t = word(m.index + "simctl".length);
  if (!t || t.w !== "io") continue;
  t = word(t.next);                       // the udid, whatever shape
  if (!t) continue;
  t = word(t.next);
  if (!t || t.w !== "screenshot") continue;
  let d = word(t.next);
  while (d && d.w.startsWith("-")) d = word(d.next);   // --type=png and friends
  if (d) out.push(d.at + "\t" + d.w);
}
for (const m of s.matchAll(/\bscreencap\b/g)) {
  if (!/\bexec-out\b/.test(s.slice(segStart(m.index), m.index))) continue;
  let i = m.index;
  while (i < s.length && s[i] !== ">" && !/[;&|\n]/.test(s[i])) i++;
  if (s[i] !== ">") continue;
  i++;
  if (s[i] === ">") i++;
  const d = word(i);
  if (d) out.push(d.at + "\t" + d.w);
}
if (out.length) process.stdout.write(out.join("\n") + "\n");
' "$1" "${2:-}"
}

# normalize_shot_path <path> -- prints the ledger form of an absolute image
# path, or returns 1 for anything that cannot be one.
normalize_shot_path() {
  local p="${1:-}"
  case "$p" in
    "") return 1 ;;
    *'$'*) return 1 ;;   # a variable nothing resolved; recording the literal would be a lie
    /*) ;;
    *) return 1 ;;       # relative: a compound command's cwd is not knowable here
  esac
  case "$p" in /private/tmp/*) p="${p#/private}" ;; esac
  case "$p" in
    *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG) ;;
    *) return 1 ;;
  esac
  printf '%s' "$p"
}

_ledger_prune() {
  local lines cutoff tmp
  lines=$(wc -l < "$PHONE_CAPTURE_LEDGER" 2>/dev/null) || return 0
  [ "${lines:-0}" -gt "$PHONE_CAPTURE_MAX" ] 2>/dev/null || return 0
  cutoff=$(( $(date +%s) - PHONE_CAPTURE_TTL ))
  tmp="$PHONE_CAPTURE_LEDGER.$$"
  if awk -F'\t' -v c="$cutoff" '$1 >= c' "$PHONE_CAPTURE_LEDGER" 2>/dev/null \
       | tail -n "$PHONE_CAPTURE_MAX" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$PHONE_CAPTURE_LEDGER" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# ledger_record <path> -- note that a phone capture wrote <path> just now.
ledger_record() {
  local p
  p=$(normalize_shot_path "${1:-}") || return 1
  printf '%s\t%s\n' "$(date +%s)" "$p" >> "$PHONE_CAPTURE_LEDGER" 2>/dev/null || return 1
  _ledger_prune
}

# ledger_says_phone <path> -- exit 0 iff <path> is a recorded phone capture that
# has not been rewritten since it was recorded.
ledger_says_phone() {
  local p rec cutoff mt
  p=$(normalize_shot_path "${1:-}") || return 1
  [ -r "$PHONE_CAPTURE_LEDGER" ] || return 1
  rec=$(awk -F'\t' -v p="$p" '$2 == p { t = $1 } END { if (t) print t }' \
        "$PHONE_CAPTURE_LEDGER" 2>/dev/null) || return 1
  [ -n "$rec" ] || return 1
  cutoff=$(( $(date +%s) - PHONE_CAPTURE_TTL ))
  [ "$rec" -ge "$cutoff" ] 2>/dev/null || return 1
  mt=$(stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null) || return 1
  [ "$mt" -le "$rec" ] 2>/dev/null
}
