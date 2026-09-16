#!/usr/bin/env bash
# operator-directives.sh -- ONE grammar for what an operator's words order a run
# to do, shared by hooks/operator-hold-prompt.sh (session prompts) and
# completion-judge.sh (Asana comments in the segment's scope). Source it, then:
#
#   anchor=$(printf '%s' "$text" | release_anchor)   # "", "release" or "release complete"
#   kinds=$(printf '%s' "$text" | directive_kinds)   # space-separated subset of:
#     complete  finish the task now (complete / finish / finalize / ship / land /
#               wrap it up / set it to complete / call it done)
#     stop      end the run now (stop|end|kill|abort the task|run|it, set it to
#               blocked, block the task, stop here|now)
#     bypass    skip the completion judge (bypass|skip|waive|override|ignore ...
#               judge / judgment)
#   or empty when the text orders none of these.
#
# Shape: only the FIRST and the LAST sentence are read for complete/stop (a
# directive opens or closes a message); bypass is read anywhere. A negation or a
# future condition in the same sentence voids it ("don't complete yet", "mark it
# complete when QA signs off"). Bare verbs must END their clause ("complete the
# task" yes, "complete garbage, the fee is wrong" no). "stop" alone, or "stop,
# I'll let QA test", is an interrupt, not a stop order. A leading ok/yes/please
# is skipped. Tests: hooks/tests/operator-hold.test.py, completion-judge.test.py.
# release_anchor: prints "release" when the first word (after ok/yes/sure/please) is
# go|resume|continue|proceed, or the last bare clause (after the final , ; . ! ? and/
# then) is go|go ahead|resume|continue|proceed|complete|finish up|wrap it up|wrap up;
# prints "release complete" when that last clause is one of the completion words.
release_anchor() {
  local norm first last
  norm=$(tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//')
  first=$(printf '%s' "$norm" | sed -E 's/^(ok|okay|k|yes|yep|yeah|sure|please)[[:punct:] ]+//' | grep -oE '^[a-z/]+' || true)
  last=$(printf '%s' "$norm" | sed -E 's/[[:punct:] ]+$//' | awk -F'[,;.!?]| and | then ' '{print $NF}' | sed -E 's/^[[:punct:] ]+//; s/^(and|then) +//; s/[[:punct:] ]+$//')
  case "$first" in go|resume|continue|proceed|/resume) printf 'release'; return 0 ;; esac
  case "$last" in go|"go ahead"|resume|continue|proceed) printf 'release' ;; complete|"finish up"|"wrap it up"|"wrap up") printf 'release complete' ;; esac
  return 0
}

# hold_trigger: prints "hold" when the human text asks the run to pause, else
# nothing. Triggers (operator policy 2026-09-16: a hold is the exception, a plain
# steer keeps the run autonomous):
#   question   a sentence ending in "?", unless it opens with can/could/would/will
#              you (a request phrased as a question: "can you also do X?")
#   interrupt  wait | hold on | hang on | hold up | pause as the first word of the
#              message, or any of those plus bare "stop" as a whole clause
#              ("no, hold on"; "Stop, I'll let QA test"); "stop the sim" is a steer
#   negated go don't/do not/never continue|proceed|go ahead|go on, or "not yet"
# A release anchor in the same message wins (the caller checks release first).
hold_trigger() {
  local norm sent clause q first
  norm=$(tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//')
  [ -n "$norm" ] || return 0
  # questions: every sentence closed by "?"
  while IFS= read -r q; do
    q=$(printf '%s' "$q" | awk -F'[.!;]' '{print $NF}' | sed -E 's/^[[:punct:] ]+//; s/^(ok|okay|k|yes|yep|yeah|sure|please|and|so|also|but)[[:punct:] ]+//')
    [ -n "$q" ] || continue
    printf '%s' "$q" | grep -qE '^(can|could|would|will|can you|could you)( you| u)?( please)? [a-z]' && continue
    printf 'hold'; return 0
  done < <(printf '%s' "$norm" | grep -oE '[^?]+\?' || true)
  first=$(printf '%s' "$norm" | sed -E 's/^(ok|okay|k|yes|yep|yeah|sure|please|no|hmm|hm|uh)[[:punct:] ]+//')
  printf '%s' "$first" | grep -qE '^(wait|hold on|hang on|hold up|pause)([[:punct:] ]|$)' && { printf 'hold'; return 0; }
  while IFS= read -r clause; do
    clause=$(printf '%s' "$clause" | sed -E 's/^[[:punct:] ]+//; s/[[:punct:] ]+$//; s/^(ok|okay|please|no|and|then) +//; s/ (please|a sec|a second|a moment|a minute|there|here|now)$//')
    case "$clause" in wait|"hold on"|"hang on"|"hold up"|pause|stop) printf 'hold'; return 0 ;; esac
  done < <(printf '%s\n' "$norm" | tr ',;.!?' '\n\n\n\n\n' | sed -E 's/ (and|then) /\n/g')
  printf '%s' "$norm" | grep -qE "(^|[^a-z])(don'?t|do not|never|not) (continue|proceed|go ahead|go on|move on)([^a-z]|$)|(^|[^a-z])not yet([^a-z]|$)" && { printf 'hold'; return 0; }
  return 0
}
directive_kinds() {
  local norm first_sent last_sent last_clause sent kinds="" lead obj tail complete_re stop_re neg_re bypass_re
  norm=$(tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//')
  [ -n "$norm" ] || return 0
  first_sent=$(printf '%s' "$norm" | sed -E 's/^(ok|okay|k|yes|yep|yeah|sure|please)[[:punct:] ]+//' | awk -F'[.!?;]' '{print $1}' | sed -E 's/^[[:punct:] ]+//; s/[[:punct:] ]+$//')
  last_sent=$(printf '%s' "$norm" | sed -E 's/[[:punct:] ]+$//' | awk -F'[.!?;]' '{print $NF}' | sed -E 's/^[[:punct:] ]+//; s/^(ok|okay|k|yes|yep|yeah|sure|please)[[:punct:] ]+//')
  lead='^(please |just |now |then |and |so |ok |okay |yes )*'
  obj='( (it|this|the task|the run|the pr|up|now))?'
  tail='([,;] .*| and .*)?$'
  complete_re="$lead"'((complete|finish|finalize)'"$obj"'|wrap( it| this| things)? up|ship( it| this| the pr)?|land( it| this| the pr)?|(set|mark|move|flip|put) (it|this|the task|the status|status|agent_status)( (as|to))? complete|call it (done|complete)|go ahead and (complete|finish|finalize|ship|land)'"$obj"')[[:punct:]]*'"$tail"
  stop_re="$lead"'((stop|end|kill|abort|abandon|halt) (the |this )?(task|run|work|session|it|here|now)|(set|mark|move|flip|put) (it|this|the task|status|agent_status)( (as|to))? blocked|block (it|this|the task)|stop here|stop now|stop and block)([[:space:][:punct:]]|$)'
  neg_re="(^|[^a-z])(don'?t|do not|never|not|wait|hold (on|off)|instead of|rather than|when|once|until|unless|after|before)([^a-z]|$)"
  # bypass is a standing grant ("after this point" is not a condition): only true negations void it
  neg_only_re="(^|[^a-z])(don'?t|do not|never|not|no longer|stop)([^a-z]|$)"
  bypass_re="(bypass|skip|waive|override|ignore|disable)[a-z]*( the| this| your| our)?( completion)?( judge|judg[e]?ment)"
  # The last clause too ("Looks fine, complete the task"): text after the final , ; and/then.
  last_clause=$(printf '%s' "$last_sent" | awk -F'[,;]| and | then ' '{print $NF}' | sed -E 's/^[[:punct:] ]+//; s/^(and|then) +//')
  for sent in "$first_sent" "$last_sent" "$last_clause"; do
    printf '%s' "$sent" | grep -qE "$neg_re" && continue
    printf '%s' "$sent" | grep -qE "$complete_re" && kinds="$kinds complete"
    printf '%s' "$sent" | grep -qE "$stop_re" && kinds="$kinds stop"
  done
  # bypass: any sentence naming the judge with a bypass verb and no negation.
  while IFS= read -r sent; do
    printf '%s' "$sent" | grep -qE "$bypass_re" || continue
    printf '%s' "$sent" | grep -qE "$neg_only_re" && continue
    kinds="$kinds bypass"; break
  done < <(printf '%s\n' "$norm" | tr '.!?;' '\n\n\n\n')
  printf '%s' "$kinds" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed -E 's/ $//'
}
