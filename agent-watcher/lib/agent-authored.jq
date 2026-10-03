# agent-authored.jq: the ONE test for "this Asana text carries the orch's
# authorship markers" (agent-authored-text.sh writes them):
#   🥋 <text starts inline>
#   ...
#   👊            <- last non-blank line, alone
# Blank lines and surrounding whitespace are ignored, so a trailing space or a
# leading newline Asana adds never turns an agent comment into an operator one.
#
# Load with: jq -L "$HOME/.config/agent-watcher/lib" 'include "agent-authored"; ...'
# Input: a string (null reads as ""). Output: boolean.
# Callers: agent-authored-text.sh --check, hooks/mark-agent-authored-asana.sh,
# check-followup-scope.sh, hooks/inject-run-context.sh, asana-get-context.sh.

def agent_authored:
  (. // "")
  | (split("\n") | map(select(test("^\\s*$") | not))) as $ne
  | ($ne | length) > 0
    and (($ne[0] | sub("^\\s+"; "")) | startswith("🥋"))
    and (($ne[-1] | gsub("\\s"; "")) == "👊");

# The authored class of an Asana story: "agent" when marked, else "operator"
# when posted by the operator's user gid, else "other". The agent and the
# operator post as the same Asana user, so the marker decides first.
def authored_class($op_gid):
  if ((.text // "") | agent_authored) then "agent"
  elif ((.created_by.gid // "") == $op_gid and $op_gid != "") then "operator"
  else "other" end;
