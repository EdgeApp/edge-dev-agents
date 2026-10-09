#!/usr/bin/env bash
# Pipe tests for the skill and rule narration check in lint-md-on-write.sh
# (author `no-incident-narration`): every vector, on a fixture tree whose paths
# have the skill-prose shape. Run: bash narration-on-write.test.sh
L="$HOME/.config/agent-watcher/hooks/lint-md-on-write.sh"
R=$(mktemp -d /tmp/narr-test.XXXXXX)
trap 'rm -rf "$R"' EXIT
mkdir -p "$R/.cursor/skills/foo/references" "$R/.cursor/rules" "$R/.cursor/skills/agent-eval/references"
SEED='<rule id="a">Do X. The Foo run (2031-01-05) showed why. It no longer waits.</rule>'
SK="$R/.cursor/skills/foo/SKILL.md"; RF="$R/.cursor/skills/foo/references/x.md"
MDC="$R/.cursor/rules/r.mdc"; ERA="$R/.cursor/skills/agent-eval/references/era.md"
seed() { for f in "$SK" "$RF" "$MDC" "$ERA"; do printf '%s\n' "$SEED" > "$f"; done; }
FAILS=0
t() { local name="$1" want="$2" json="$3" out rc v
  seed
  out=$("$L" <<< "$json" 2>&1); rc=$?
  [ "$rc" = "$want" ] && v=PASS || { v=FAIL; FAILS=$((FAILS+1)); }
  printf '%s rc=%s want=%s  %s\n' "$v" "$rc" "$want" "$name"
  [ "$v" = FAIL ] && printf '      %s\n' "$(printf '%s' "$out" | head -2 | cut -c1-200)"
  return 0; }
w() { jq -cn --arg p "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}'; }
e() { jq -cn --arg p "$1" --arg o "$2" --arg n "$3" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:$o,new_string:$n}}'; }
b() { jq -cn --arg c "$1" --arg cwd "${2:-/tmp}" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'; }

echo "== Write: total matches, new content minus the file on disk"
t "new SKILL.md with a date" 2 "$(w "$R/.cursor/skills/new/SKILL.md" 'Do X (2031-02-02).')"
t "existing file, same counts" 0 "$(w "$SK" 'Do X. Seen 2031-01-05. It no longer waits. More text.')"
t "existing file, one date swapped for another" 0 "$(w "$SK" 'Do X. Seen 2031-03-03. It no longer waits.')"
t "existing file, one more date" 2 "$(w "$SK" 'Do X. 2031-01-05 and 2031-03-03. It no longer waits.')"
t "existing file, narration removed" 0 "$(w "$SK" 'Do X.')"

echo "== Edit: total matches, new_string minus old_string"
t "adds no longer" 2 "$(e "$SK" 'Do X.' 'Do X. The gate no longer skips it.')"
t "keeps the phrase it replaces" 0 "$(e "$SK" 'It no longer waits.' 'It no longer waits, and it exits 1.')"
t "removes narration" 0 "$(e "$SK" 'The Foo run (2031-01-05) showed why. ' '')"
t "passive is/be used to" 0 "$(e "$SK" 'Do X.' 'Do X. The flag is used to mark it; it can be used to skip.')"
t "history used to" 2 "$(e "$SK" 'Do X.' 'Do X. The watch used to burn the budget.')"
t "NOTE since" 2 "$(e "$SK" 'Do X.' 'Do X. NOTE since the split: read both.')"
t "16-digit id" 2 "$(e "$SK" 'Do X.' 'Do X (task 1219257022153194).')"
t "12-digit number" 0 "$(e "$SK" 'Do X.' 'Do X (id 121925702215).')"
t "references slice" 2 "$(e "$RF" 'Do X.' 'Do X (2031-04-04).')"
t "rules .mdc" 2 "$(e "$MDC" 'Do X.' 'Do X (2031-04-04).')"
t "era.md is exempt" 0 "$(e "$ERA" 'Do X.' 'Do X (2031-04-04).')"
t "unrelated .md" 0 "$(e "$R/notes.md" 'Do X.' 'Do X (2031-04-04).')"
t "~/.claude/skills alias" 2 "$(e "$HOME/.claude/skills/foo/SKILL.md" 'Do X.' 'Do X (2031-04-04).')"

echo "== Bash: per literal, command text beyond the file on disk"
t "sed -i deleting a date the file has" 0 "$(b "sed -i '' 's/ (2031-01-05)//' $SK")"
t "sed -i inserting a new date" 2 "$(b "sed -i '' 's/Do X\\./Do X (2031-05-05)./' $SK")"
t "perl -pi inserting used to on a rule" 2 "$(b "perl -pi -e 's/Do X/It used to do X/' $MDC")"
t "heredoc rewrite, same narration" 0 "$(b "cat > $SK <<'EOF'
Do X. Seen 2031-01-05. It no longer waits.
EOF")"
t "heredoc rewrite adding a phrase" 2 "$(b "cat > $RF <<'EOF'
Do X. NOTE since then, do Y.
EOF")"
t "python regex strip, no literal" 0 "$(b "python3 - <<'PY'
import re
p='$SK'
s=open(p).read()
open(p,'w').write(re.sub(r' \\(\\d{4}-\\d\\d-\\d\\d\\)','',s))
PY")"
t "python inline adding a date" 2 "$(b "python3 - <<'PY'
p='$SK'
open(p,'a').write('Seen again 2031-06-06.')
PY")"
t "unrelated .md, then a skill file with a new date" 2 "$(b "cat > $R/a.md <<'EOF'
x
EOF
cat >> $SK <<'EOF'
Added 2031-07-07.
EOF")"
t "heredoc to an unrelated .md with a date" 0 "$(b "cat > $R/b.md <<'EOF'
Meeting on 2031-07-07.
EOF")"
t "grep of a skill for a date, redirected to scratch" 0 "$(b "grep -n 2031-09-09 $SK > $R/out.txt")"
t "era.md append with a date" 0 "$(b "cat >> $ERA <<'EOF'
| 2031-08-08 | A3 | ruling |
EOF")"
t "relative sed from the skill dir adding a date" 2 "$(b "sed -i '' 's/Do X/Do X 2031-05-05/' SKILL.md" "$R/.cursor/skills/foo")"
t "leading cd into the skill dir, relative sed adding a date" 2 "$(b "cd $R/.cursor/skills/foo && sed -i '' 's/Do X/Do X 2031-05-05/' SKILL.md" /tmp)"
t "command that reaches no skill path" 0 "$(b "ls -la /tmp")"

[ "$FAILS" = 0 ] && echo "ALL PASS" || { echo "$FAILS failure(s)"; exit 1; }
