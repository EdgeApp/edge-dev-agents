#!/usr/bin/env bash
# Pipe tests for require-skill-for-file.sh, lint-md-on-write.sh, mark-skill-read.sh.
cd /Users/eddy
G=~/.config/agent-watcher/hooks/require-skill-for-file.sh
L=~/.config/agent-watcher/hooks/lint-md-on-write.sh
M=~/.config/agent-watcher/hooks/mark-skill-read.sh
CLL=~/.cursor/skills/changelog/scripts/changelog-entry-lint.sh
CL=/Users/eddy/git/edge-react-gui/CHANGELOG.md
rm -f /tmp/agent-skill-read-TESTGID-* /tmp/agent-skill-read-sess-S1-* /tmp/agent-skill-read-sess-S2-*
t(){ local name="$1" want="$2"; shift 2; out=$("$@" 2>&1); rc=$?; [ "$rc" = "$want" ] && v=PASS || v=FAIL; printf '%s rc=%s want=%s  %s\n' "$v" "$rc" "$want" "$name"; [ "$v" = FAIL ] && printf '      %s\n' "$(printf '%s' "$out" | head -2 | cut -c1-150)"; }
EMD=$(printf '\xe2\x80\x94')
LONG="- fixed: (Zano) $(printf 'word %.0s' $(seq 60))"

echo "== require-skill-for-file"
t "orch Edit CHANGELOG, no marker" 2 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Edit\",\"session_id\":\"S1\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: y\"}}"
[ -f /tmp/agent-skill-read-TESTGID-changelog ] && echo "PASS marker written by delivery" || echo "FAIL marker missing"
t "orch Edit CHANGELOG, retry" 0 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Edit\",\"session_id\":\"S1\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: y\"}}"
t "interactive Edit CHANGELOG (orch-only row)" 0 $G <<< "{\"tool_name\":\"Edit\",\"session_id\":\"S1\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: y\"}}"
t "interactive Write AGENTS.md, no marker" 2 $G <<< '{"tool_name":"Write","session_id":"S1","tool_input":{"file_path":"/Users/eddy/git/edge-core-js/AGENTS.md","content":"x"}}'
t "interactive Write AGENTS.md, retry" 0 $G <<< '{"tool_name":"Write","session_id":"S1","tool_input":{"file_path":"/Users/eddy/git/edge-core-js/AGENTS.md","content":"x"}}'
t "interactive Edit agents.md lowercase, same session" 0 $G <<< '{"tool_name":"Edit","session_id":"S1","tool_input":{"file_path":"/x/agents.md","old_string":"a","new_string":"b"}}'
$M <<< '{"tool_name":"Skill","session_id":"S2","tool_input":{"skill":"agents-md"}}'
t "interactive Skill agents-md marks, then Write passes" 0 $G <<< '{"tool_name":"Write","session_id":"S2","tool_input":{"file_path":"/x/AGENTS.md","content":"x"}}'
rm -f /tmp/agent-skill-read-TESTGID-*
t "orch Bash sed -i CHANGELOG" 2 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"sed -i '' 's/^## Unreleased/## Unreleased\\\\n- fixed: y/' CHANGELOG.md\"}}"
rm -f /tmp/agent-skill-read-TESTGID-*
t "orch Bash perl -pi CHANGELOG" 2 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"perl -pi -e 's/a/b/' CHANGELOG.md\"}}"
rm -f /tmp/agent-skill-read-TESTGID-*
t "orch Bash heredoc > CHANGELOG" 2 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"cat > CHANGELOG.md <<'X'\\n- fixed: y\\nX\"}}"
rm -f /tmp/agent-skill-read-TESTGID-*
t "orch Bash tee -a CHANGELOG" 2 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"printf x | tee -a CHANGELOG.md\"}}"
rm -f /tmp/agent-skill-read-TESTGID-*
t "orch Bash grep CHANGELOG (read)" 0 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"grep -n '^## ' CHANGELOG.md | head\"}}"
t "orch Bash report heredoc mentioning CHANGELOG.md" 0 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/tmp\",\"tool_input\":{\"command\":\"cat > /tmp/agent-run-report-1.md <<'X'\\nUpdated CHANGELOG.md with one entry\\nX\"}}"
t "orch Bash git add CHANGELOG (not a write)" 0 env AGENT_TASK_GID=TESTGID $G <<< "{\"tool_name\":\"Bash\",\"session_id\":\"S1\",\"cwd\":\"/x\",\"tool_input\":{\"command\":\"git add CHANGELOG.md && git commit -m x\"}}"
t "orch Write unrelated md" 0 env AGENT_TASK_GID=TESTGID $G <<< '{"tool_name":"Write","session_id":"S1","tool_input":{"file_path":"/x/README.md","content":"x"}}'
rm -f /tmp/agent-skill-read-TESTGID-* /tmp/agent-skill-read-sess-S1-* /tmp/agent-skill-read-sess-S2-*

echo "== lint-md-on-write"
t "Edit 300-char entry" 2 $L <<< "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"$LONG\"}}"
t "Edit mechanism tail" 2 $L <<< "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: Sync ratio no longer latches, so a fresh wallet reports correctly\"}}"
t "Edit second sentence" 2 $L <<< "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: Sync ratio no longer latches. The SDK reports ready early.\"}}"
t "Edit clean short" 0 $L <<< "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: (Zano) Sync ratio no longer reports a fresh wallet as fully synced\"}}"
t "Edit em dash (no-slop still first)" 2 $L <<< "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CL\",\"old_string\":\"x\",\"new_string\":\"- fixed: Zano $EMD stall\"}}"
t "Bash sed -i em dash into CHANGELOG" 2 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"sed -i '' 's/^## Unreleased/## Unreleased\\\\n- fixed: Zano $EMD stall/' CHANGELOG.md\"}}"
t "Bash sed -i long entry into CHANGELOG" 2 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/Users/eddy/git/edge-react-gui\",\"tool_input\":{\"command\":\"sed -i '' 's/^## Unreleased/## Unreleased\\\\n$LONG/' CHANGELOG.md\"}}"
t "Bash sed -i em dash into README" 2 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/Users/eddy/git/edge-core-js\",\"tool_input\":{\"command\":\"sed -i '' 's/a/b $EMD c/' README.md\"}}"
t "Bash sed -i on .ts with em dash" 0 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/x\",\"tool_input\":{\"command\":\"sed -i '' 's/a $EMD b/c/' src/foo.ts\"}}"
t "Bash redirect README em dash (regression)" 2 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/Users/eddy/git/edge-core-js\",\"tool_input\":{\"command\":\"cat > README.md <<X\\nfoo $EMD bar\\nX\"}}"
t "Bash heredoc to .txt mentioning README.md path (FP guard)" 0 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/x\",\"tool_input\":{\"command\":\"cat > notes.txt <<X\\nsee <repo>/README.md $EMD there\\nX\"}}"
t "Bash heredoc to allowlisted /tmp/agent- report with sed -i mention" 0 $L <<< "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp\",\"tool_input\":{\"command\":\"cat > /tmp/agent-run-report-1.md <<'X'\\nran sed -i on CHANGELOG.md $EMD ok\\nX\"}}"
python3 - "$CL" "$LONG" <<'EOF' > /tmp/gate-test-payloads.json
import json,sys
cl,long=sys.argv[1],sys.argv[2]
s=open(cl).read()
a=s.replace('## Unreleased (develop)','## Unreleased (develop)\n\n- fixed: New short entry',1)
b=s.replace('## Unreleased (develop)','## Unreleased (develop)\n\n'+long,1)
print(json.dumps({'tool_name':'Write','tool_input':{'file_path':cl,'content':a}}))
print(json.dumps({'tool_name':'Write','tool_input':{'file_path':cl,'content':b}}))
EOF
t "Write full CHANGELOG, existing long entries + one new short (diff-only)" 0 $L <<< "$(sed -n 1p /tmp/gate-test-payloads.json)"
t "Write full CHANGELOG + one new long" 2 $L <<< "$(sed -n 2p /tmp/gate-test-payloads.json)"
rm -f /tmp/gate-test-payloads.json

echo "== entry lint on live files: HARD counts"
for r in edge-react-gui edge-core-js edge-exchange-plugins edge-currency-accountbased; do
  printf '%-28s top40=%s  old300-400=%s\n' $r "$(grep -E '^\s*- ' ~/git/$r/CHANGELOG.md | head -40 | $CLL | grep -c '^HARD')" "$(grep -E '^\s*- ' ~/git/$r/CHANGELOG.md | sed -n '300,400p' | $CLL | grep -c '^HARD')"
done
echo "-- old-slice HARD lines (false-positive review):"
for r in edge-react-gui edge-core-js edge-exchange-plugins edge-currency-accountbased; do grep -E '^\s*- ' ~/git/$r/CHANGELOG.md | sed -n '300,400p' | $CLL | grep '^HARD' | cut -c1-170; done
