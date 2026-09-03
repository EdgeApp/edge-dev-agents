#!/usr/bin/env bash
# reviewer-outage-noise.sh — the ONE definition of "reviewer-bot outage
# narration", sourced by every boundary that must keep it out.
#
# Operator ruling (2026-09-02): a reviewer bot that did not run (quota, credit,
# outage, disabled) is recorded as exactly one UNCHECKED box in the run report's
# Finalize Gate, with its one-line reason, and NOWHERE ELSE: no completion
# comment bullet, no Follow-ups & Risks item, no Testing-gap line, no PR comment,
# no "re-gate when quota returns". Nothing can be done about it, so every extra
# mention is noise the operator reads for nothing.
#
# reviewer_noise_hits <file>   prints "N: line" for each offending line, exit 0
#                              when there are hits, 1 when clean.
# The pattern pairs a reviewer-bot noun with an availability verb on the same
# line, or names the quota itself, so ordinary sentences about bots reviewing
# code do not match.
REVIEWER_NOISE_RE='((bugbot|reviewer[- ]?bots?|cursor ?\[?bot\]?|security reviewer)[^.\n]{0,90}(quota|credits?|(has|have|had|did|does|do) not (yet )?(run|review|post|scan|gate)|never (ran|run|reviewed)|still (has|have) not|unavailable|no check[- ]?run|skipped (it|the|this)|out of (quota|credit)|not (been )?(re-?)?(gated|reviewed|scanned) by)|(quota|credits?)[^.\n]{0,40}(return|reset|replenish|restor|refill)|re-?gate[^.\n]{0,40}(quota|credit|bugbot|bots?))'
reviewer_noise_hits() {
  local f="$1"
  grep -n -i -E "$REVIEWER_NOISE_RE" "$f" 2>/dev/null
}
