#!/usr/bin/env bash
# splice-judge-section.sh -- write the run report's "## Completion Judge" section
# from the judge provenance log. Source this; do not execute it.
#
# The section is machine-generated (judge-report-section.sh renders one row per
# judge call), so the agent never writes it and every attach re-renders it.
# Two callers, because a report attached BEFORE the first judge call would
# otherwise carry "_No judge call yet._" for the life of the task:
#   hooks/require-clean-run-report.sh   at every attach
#   hooks/require-completion-judgment.sh  once a verdict exists for this segment
#
# splice_judge_section <gid> <report>: replaces an existing "## Completion Judge"
# block, else inserts before "## Testing", else appends. Always returns 0 (a
# caller under `set -e` must not die because a report lacked a section).
splice_judge_section() {
  local gid="$1" report="$2" section=""
  [ -n "$gid" ] && [ -s "$report" ] || return 0
  [ -x "$HOME/.config/agent-watcher/judge-report-section.sh" ] || return 0
  section="$("$HOME/.config/agent-watcher/judge-report-section.sh" --gid "$gid" 2>/dev/null || true)"
  [ -n "$section" ] || return 0
  SECTION="$section" node -e '
const fs=require("fs"); const f=process.argv[1]; let s=fs.readFileSync(f,"utf8"); const sec=process.env.SECTION.trimEnd()+"\n";
const re=/^## Completion Judge[^\n]*\n[\s\S]*?(?=^## |(?![\s\S]))/m;
if(re.test(s)) s=s.replace(re, sec+"\n");
else if(/^## Testing/m.test(s)) s=s.replace(/^## Testing/m, sec+"\n## Testing");
else s=s.trimEnd()+"\n\n"+sec;
fs.writeFileSync(f,s);' "$report" 2>/dev/null || true
  return 0
}
