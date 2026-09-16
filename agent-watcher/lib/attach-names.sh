# attach-names.sh: the ONE naming scheme for orch docs attached to Asana tasks.
#
#   run report:  <N>-agent-run-report.md     (N = report ordinal on the task)
#   plan:        <N>-plan-<anything>.md      (N = plan ordinal on the task)
#
# Operator request 2026-09-11: consistent, orderable names. Every producer
# (require-clean-run-report.sh renames reports, asana-task-update.sh numbers
# plans) and every matcher (followup watermark, run-context injection,
# resolve-run, flow-proposal harvest) sources this file instead of carrying
# its own regex, so a legacy name (agent-run-report-<slug>.md,
# agent-run-report-NN-<slug>.md, plan-<slug>.md) and a new one always count
# the same everywhere.
#
# Source it; it defines variables and functions only.

# jq/ERE-compatible patterns matching BOTH new and legacy names.
REPORT_ATTACH_RE='^([0-9]+-)?agent-run-report.*\.md$'
PLAN_ATTACH_RE='^([0-9]+-)?plan-.*\.md$'

# next_attach_ordinal <report|plan>  (attachment names on stdin, one per line)
# Prints max existing ordinal + 1; when no name carries an ordinal (legacy era),
# falls back to count of matching names + 1.
next_attach_ordinal() {
  local kind="$1" names re max count
  names=$(cat)
  case "$kind" in
    report) re="$REPORT_ATTACH_RE" ;;
    plan) re="$PLAN_ATTACH_RE" ;;
    *) echo "next_attach_ordinal: unknown kind '$kind'" >&2; return 1 ;;
  esac
  names=$(printf '%s\n' "$names" | grep -E "$re" || true)
  if [ "$kind" = report ]; then
    max=$(printf '%s\n' "$names" | sed -nE 's/^([0-9]+)-agent-run-report.*/\1/p; s/^agent-run-report-([0-9]+)-.*/\1/p' | sort -n | tail -1)
  else
    max=$(printf '%s\n' "$names" | sed -nE 's/^([0-9]+)-plan-.*/\1/p' | sort -n | tail -1)
  fi
  if [ -n "$max" ]; then
    echo $((10#$max + 1))
  else
    count=$(printf '%s\n' "$names" | grep -c . || true)
    echo $((${count:-0} + 1))
  fi
}

# report_attach_name <N>
report_attach_name() { printf '%s-agent-run-report.md\n' "$1"; }

# plan_attach_suffix <name>: the <anything> part of a plan name, ordinal and
# "plan-" prefix stripped ("3-plan-foo.md" and "plan-foo.md" both -> "foo.md").
plan_attach_suffix() { printf '%s\n' "$1" | sed -E 's/^[0-9]+-//; s/^plan-//'; }

# plan_attach_name <N> <name>
plan_attach_name() { printf '%s-plan-%s\n' "$1" "$(plan_attach_suffix "$2")"; }
