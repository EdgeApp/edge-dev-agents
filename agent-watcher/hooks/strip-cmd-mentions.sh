#!/usr/bin/env bash
# strip-cmd-mentions.sh — stdin: a Bash tool command string; stdout: the same
# string with heredoc bodies, quoted spans, and backticked spans blanked out
# (replaced by spaces, so offsets and separators survive).
#
# Why: the PreToolUse hooks decide "does this command DO X" by pattern-matching
# the command string. A plain substring/space-anchored match also fires when the
# command merely MENTIONS the trigger text — a heredoc writing a run report that
# documents `git push`, an `echo "probe: gh pr edit"`, a state-file note quoting
# `update-status.sh <gid> Complete`. Observed twice on 2026-08-19: the
# git-history-gate blocked an echo that quoted `git push`, and the first draft
# of no-push-after-complete blocked the report edit documenting itself. Real
# invocations live OUTSIDE quotes and heredoc bodies, so hooks match against
# this stripped view for TRIGGER detection (and keep the original string for
# argument extraction — quoted args like --reason "..." live inside quotes).
#
# LENGTH IS THE CONTRACT: stdout is byte-for-byte the same LENGTH as stdin, so
# callers can slice the raw command at offsets found in the stripped view
# (guard-piped-watcher-scripts.sh cuts pipes that way; the skill-read gate names
# the offending raw segment that way). A caller that sees a length mismatch
# falls back to the raw command and loses mention-stripping entirely, so every
# branch here must replace, never insert or drop.
#
# Known gap, deliberate: an invocation smuggled through a quoted string
# (`bash -c "git push"`) is invisible in the stripped view. That shape does not
# occur in this workflow, and false-blocking authoring work is the worse
# failure. Usage: CMD_M=$(printf '%s' "$CMD" | strip-cmd-mentions.sh)
set -euo pipefail

exec python3 -c '
import re, sys
cmd = sys.stdin.read()
# Blank heredoc bodies: <<EOF / <<"EOF" / <<-EOF ... through the terminator line.
for m in list(re.finditer(r"<<-?\s*[\x27\"]?(\w+)[\x27\"]?", cmd)):
    # Already inside a blanked body: a git conflict marker or a shift operator in
    # some outer heredoc opens no heredoc of its own, and letting one swallow the
    # rest of the command would hide the real invocations that follow it.
    if not cmd[m.start():m.end()].strip():
        continue
    tag = m.group(1)
    end = re.search(r"^\s*" + re.escape(tag) + r"\s*$", cmd[m.end():], re.M)
    # Unterminated heredoc: blank to end of string. Offsetting len(cmd) by
    # m.end() would run the span past the end and lengthen the output.
    stop = m.end() + end.end() if end else len(cmd)
    cmd = cmd[:m.end()] + " " * (stop - m.end()) + cmd[stop:]
# Blank quoted and backticked spans.
cmd = re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"|`[^`]*`", lambda m: " " * len(m.group(0)), cmd)
sys.stdout.write(cmd)
'
