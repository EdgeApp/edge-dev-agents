#!/usr/bin/env python3
"""Vectors for the Jev money router, the pre-PR diff check, the landing decision and the pairs-ledger fixes
(~/.config/jev/routing: jev_route.py, jev_diffcheck.py, jev-pair.py, jev-shadow-run.sh).

No network: every Jev call is stubbed. Run: python3 ~/.config/agent-watcher/hooks/tests/jev-money-route.test.py
"""
import importlib.util, json, os, re, subprocess, sys, tempfile

ROUTING = os.path.expanduser("~/.config/jev/routing")
HOOKS = os.path.expanduser("~/.config/agent-watcher/hooks")
TMP = tempfile.mkdtemp(prefix="jev-route-test-")
os.environ["JEV_SHADOW_ROOT"] = TMP  # no vector may write to the live shadow logs
sys.path.insert(0, ROUTING)
import jev_route as R  # noqa: E402
import jev_diffcheck as D  # noqa: E402

spec = importlib.util.spec_from_file_location("jev_pair", os.path.join(ROUTING, "jev-pair.py"))
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)

fails = []


def ok(name, cond, detail=""):
    if not cond:
        fails.append(name)
    print(("ok   " if cond else "FAIL ") + name + (("  " + str(detail)) if detail and not cond else ""))


def stub(answers):
    """Replace jev.ask with a recorder that returns fixed noul answers."""
    calls = []

    def ask(state, questions, timeout=None):
        calls.append((state, questions))
        return {"answers": {k: {"noul": answers[k]} for k in questions}, "usage": {"input_tokens": 100}}
    R.jev.ask = ask
    return calls


# ── 1. router ──────────────────────────────────────────────────────────────────────
src = open(os.path.join(ROUTING, "jev_route.py")).read() + open(os.path.join(ROUTING, "jev_diffcheck.py")).read()
defn = open(R.DEFINITION).read().strip()
first = next(l for l in defn.splitlines() if len(l) > 60)
ok("definition is read from DEFINITION.md", R.definition() == defn)
ok("definition is not pasted into the router or the diff check", first[:60] not in src)
q = R.money_question()["money"]
ok("money question carries the file's text", defn[:200] in json.dumps(q, ensure_ascii=False) or defn[:200] in str(q))
alt = os.path.join(TMP, "DEF.md")
open(alt, "w").write("ALTERNATE CRITERION 7731")
keep, R.DEFINITION = R.DEFINITION, alt
ok("an edit to the file changes the question with no code change", "ALTERNATE CRITERION 7731" in str(R.money_question()["money"]))
R.DEFINITION = keep

body = "Operator ask.\n\n===== CURRENT STATE (agent) =====\n- merged swap fix in PR 12"
plan = "Edit edge-react-gui src/components/scenes/SendScene2.tsx and src/locales/en_US.ts."
state, c = R.build_state("Title", body, plan)
ok("state keys", set(state) == {"task_title", "task_description", "approved_plan", "computed_facts"})
ok("state drops the CURRENT STATE tail", "merged swap fix" not in state["task_description"] and "Operator ask." in state["task_description"])
ok("state lists the files the plan names", "src/components/scenes/SendScene2.tsx" in state["computed_facts"] and c["n_files"] == 2)
ok("state is scrubbed with the shared scrub", R.scrub.__globals__["_scrub"].__module__ == "scrub")

ok("threshold is 0.2", R.THRESHOLD == 0.2 and D.JEV_THRESHOLD == 0.2)
for p, pick in ((0.0, "sonnet"), (0.19, "sonnet"), (0.2, "keep"), (0.21, "keep"), (0.97, "keep")):
    stub({"money": p})
    ok(f"money {p} picks {pick}", R.route(state)["pick"] == pick)


def boom(*a, **k):
    raise RuntimeError("down")


R.jev.ask, sleep = boom, R.time.sleep
R.time.sleep = lambda s: None
ok("a Jev error yields no pick", "pick" not in R.route(state) and "error" in R.route(state))
ok("a router error never routes", R.decide({"error": "x"}, "opus[1m]", None)["would_route"] is False)

son, kp = {"pick": "sonnet", "money": 0.03}, {"pick": "keep", "money": 0.6}
d = R.decide(son, "opus[1m]", None, "PR")
ok("not money on opus would switch to sonnet", d["would_route"] and d["model"] == "sonnet[1m]")
ok("money keeps the task's model", R.decide(kp, "opus[1m]", None) == {"model": "opus[1m]", "would_route": False, "why": "money"})
for field in ("Opus", "Sonnet", "Fable"):
    d = R.decide(son, "opus[1m]", field)
    ok(f"agent_model field {field} always wins", not d["would_route"] and d["model"] == "opus[1m]" and d["why"] == "agent_model field set")
ok("agent_model field wins on a money pick too", R.decide(kp, "fable[1m]", "Fable")["model"] == "fable[1m]")
ok("a run already on sonnet does not switch", R.decide(son, "sonnet[1m]", None)["why"] == "already sonnet")
ok("a Task deliverable is logged but never routed", R.decide(son, "opus[1m]", None, "Task")["would_route"] is False)
ok("fable run with a sonnet pick would switch", R.decide(son, "fable[1m]", None)["would_route"])

stub({"money": 0.04})
row = R.gate_row("1", "T", body, plan, "/tmp/p.md", "opus[1m]", None, "PR", "spawn")
ok("gate row schema", all(k in row for k in ("q", "money", "threshold", "pick", "agent_model_field", "deliverable", "would_model", "would_route", "why", "qualifies"))
   and row["q"] == "money" and row["would_route"] and row["would_model"] == "sonnet[1m]")
ok("fresh_rows keeps one money-question PR row per task",
   [r["gid"] for r in R.fresh_rows([{"gid": "a", "pick": "keep"}, {"gid": "b", "q": "money", "pick": "keep"},
                                    {"gid": "b", "q": "money", "pick": "sonnet"}, {"gid": "c", "q": "money", "error": "x"},
                                    {"gid": "d", "q": "money", "pick": "sonnet", "deliverable": "Task"}])] == ["b"])

# ── 2. diff check ──────────────────────────────────────────────────────────────────
MONEY = [("src/components/scenes/WcConnectScene.tsx", "edge-react-gui"), ("src/components/modals/WcSmartContractModal.tsx", "edge-react-gui"),
         ("src/components/scenes/SendScene2.tsx", "edge-react-gui"), ("src/plugins/ramps/paybis/paybisRampPlugin.ts", "edge-react-gui"),
         ("src/util/helpers.ts", "edge-exchange-plugins"), ("src/ethereum/EthereumEngine.ts", "edge-currency-accountbased"),
         ("src/core/login/login.ts", "edge-core-js"), ("src/util/addressUtils.ts", None)]
CLEAN = [("src/components/themed/EdgeText.tsx", "edge-react-gui"), ("src/components/scenes/SettingsScene.tsx", "edge-react-gui"),
         ("CHANGELOG.md", "edge-exchange-plugins"), ("src/locales/strings/es.json", "edge-react-gui"),
         ("src/__tests__/scenes/SendScene2.test.tsx", "edge-react-gui"), ("test/swap/quote.test.ts", "edge-exchange-plugins"),
         ("README.md", "edge-core-js"), ("maestro/flows/send.yaml", "edge-react-gui"), ("package-lock.json", "edge-currency-accountbased"),
         ("scripts/build.sh", "edge-dev-agents"), ("docs/swap.md", "edge-react-gui")]
for f, repo in MONEY:
    ok(f"path rule flags {repo}:{f}", R.money_path_files([f], repo) == [f])
for f, repo in CLEAN:
    ok(f"path rule passes {repo}:{f}", R.money_path_files([f], repo) == [])

DIFF = ("diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n-x\n+y\n"
        "diff --git a/CHANGELOG.md b/CHANGELOG.md\n--- a/CHANGELOG.md\n+++ b/CHANGELOG.md\n@@ -1 +1 @@\n-a\n+b\n")
ok("split_files", [p for p, _ in D.split_files(DIFF)] == ["src/a.ts", "CHANGELOG.md"])
ok("split_prs: plain diff is one section", D.split_prs(DIFF, "r") == [("r", DIFF)])
ok("split_prs: labeled headers name the repo", [r for r, _ in D.split_prs("### edge-react-gui#1 x\n" + DIFF + "### edge-core-js#2 y\n" + DIFF)] == ["edge-react-gui", "edge-core-js"])
ok("chunks drop inert files", len(D.chunks(D.split_files(DIFF))) == 1 and "CHANGELOG" not in D.chunks(D.split_files(DIFF))[0])
big = [(f"src/f{i}.ts", "x" * 30000) for i in range(40)]
cs = D.chunks(big)
ok("chunks are capped in size and count", len(cs) == D.MAX_CHUNKS and all(len(c) <= D.CHUNK for c in cs))
ok("an oversized file is cut to one chunk", [len(c) for c in D.chunks([("src/a.ts", "y" * 200000)])] == [D.CHUNK])

calls = stub({"money": 0.05})
r = D.check(DIFF, "edge-react-gui")
ok("neutral path + low Jev score is clean", r["flag"] is False and len(calls) == 1)
ok("the diff sent to Jev names the repo and files", calls[0][0]["repository"] == "edge-react-gui" and "src/a.ts" in calls[0][0]["changed_files"])
stub({"money": 0.43})
r = D.check(DIFF, "edge-react-gui")
ok("neutral path + Jev 0.43 is flagged (plan drift in a neutral file)", r["flag"] and r["jev_flag"] and not r["path_flag"])
stub({"money": 0.2})
ok("Jev exactly 0.2 is flagged", D.check(DIFF, "edge-react-gui")["flag"])
stub({"money": 0.0})
r = D.check(DIFF, "edge-exchange-plugins")
ok("a live file in a plugin repo is flagged by path alone", r["flag"] and r["path_flag"] and r["path_hits"] == ["src/a.ts"])
calls = stub({"money": 0.9})
r = D.check("diff --git a/CHANGELOG.md b/CHANGELOG.md\n+x\n", "edge-exchange-plugins")
ok("a CHANGELOG-only diff is clean with no Jev call", r["flag"] is False and calls == [])
R.jev.ask = boom
r = D.check(DIFF, "edge-react-gui")
ok("a Jev error fails closed", r["flag"] and "error" in r)
ok("path-only mode makes no Jev call", D.check(DIFF, "edge-react-gui", use_jev=False)["flag"] is False)

real = os.path.expanduser("~/.config/jev/results/2026-09-29-money-split/diffs/1217260776555871.diff")
if os.path.exists(real):
    r = D.check(open(real).read(), None, use_jev=False)
    ok("1217260776555871's diff is flagged by the path rule alone", r["flag"] and any("WcConnectScene.tsx" in f for f in r["path_hits"]), r["path_hits"])
else:
    ok("1217260776555871's labeled diff is present", False)

# ── 5. landing ─────────────────────────────────────────────────────────────────────
OP = {"gid": R.OPERATOR_GID}


def c(ts, text, by=OP):
    return {"resource_subtype": "comment_added", "created_at": ts, "created_by": by, "text": text}


st, f = R.segment_state("Land 4.52", "Land every approved PR for 4.52.\n===== CURRENT STATE\n- landed", [], [])
ok("first segment state is title + description, CURRENT STATE stripped", "Land 4.52" in st["instructions"] and "- landed" not in st["instructions"] and f["mentions_land"])
atts = [{"name": "agent-run-report.md", "created_at": "2026-09-10T00:00:00Z"}]
stories = [c("2026-09-09T00:00:00Z", "fix the fee bug"), c("2026-09-11T00:00:00Z", "Approved. Land it."),
           c("2026-09-11T01:00:00Z", "\U0001f94b landed nothing yet \U0001f44a"), c("2026-09-11T02:00:00Z", "please merge", {"gid": "999"})]
st, f = R.segment_state("Swap - fix the fee bug", "Fix the fee rounding in the swap plugin.", stories, atts)
ok("re-arm state is only operator comments since the last report", st["instructions"] == "Approved. Land it." and f["comments"] == 1 and f["reports"] == 1)
ok("Force Land is not part of the landing state", "force" not in json.dumps(st).lower() and "Force Land" not in json.dumps(R.LANDING_Q))
calls = stub({"land": 0.99, "other": 0.01})
_, f0 = R.segment_state("t", "d", [c("2026-09-09T00:00:00Z", "old")], atts)
ok("re-arm with no operator comment (Force Land alone) never qualifies, no Jev call", R.landing_route({}, f0)["landing"] == 0.0 and calls == [])
_, f1 = R.segment_state("Swap - add provider", "Implement the new swap provider.", [], [])
ok("no land or merge word never qualifies, no Jev call", R.landing_route({}, f1)["landing"] == 0.0 and calls == [])
ok("'landing page' still asks Jev", R.segment_state("Fix the landing page", "", [], [])[1]["mentions_land"])
ok("landing score is min(land, 1 - other)", R.landing_route(st, f)["landing"] == 0.99)
stub({"land": 0.95, "other": 0.6})
res = R.landing_route(st, f)
ok("land plus other work scores low", res["landing"] == 0.4)
ok("below threshold stays on the run's model", R.landing_decide(res, "opus[1m]", None)["would_route"] is False)
hi = {"landing": 0.85}
ok("landing-focused on opus would spawn on sonnet", R.landing_decide(hi, "opus[1m]", None) == {"model": "sonnet[1m]", "would_route": True, "why": "landing-focused"})
ok("agent_model field wins over landing", R.landing_decide(hi, "opus[1m]", "Opus")["would_route"] is False)
ok("landing threshold boundary", R.landing_decide({"landing": R.LANDING_THRESHOLD}, "opus[1m]", None)["would_route"]
   and not R.landing_decide({"landing": R.LANDING_THRESHOLD - 0.01}, "opus[1m]", None)["would_route"])
ok("landing router error never routes", R.landing_decide({"error": "x"}, "opus[1m]", None)["would_route"] is False)

g = R.conflict_guard("edge-react-gui", ["CHANGELOG.md"])
ok("guard: a CHANGELOG conflict never counts", g["stop"] is False and g["conflicted"] == [])
g = R.conflict_guard("edge-exchange-plugins", ["CHANGELOG.md", "src/swap/defi/thorchain.ts"])
ok("guard: money-path conflict stops and names the files", g["stop"] and g["money_files"] == ["src/swap/defi/thorchain.ts"])
ok("guard: CHANGELOG in a wallet repo still never counts", R.conflict_guard("edge-currency-accountbased", ["CHANGELOG.md"])["stop"] is False)
ok("guard: neutral conflict is safe to resolve", R.conflict_guard("edge-react-gui", ["src/components/themed/EdgeText.tsx", "package-lock.json"])["stop"] is False)
ok("guard: gui send scene conflict stops", R.conflict_guard("edge-react-gui", ["src/components/scenes/SendScene2.tsx"])["stop"])
cli = lambda files: subprocess.run([sys.executable, os.path.join(ROUTING, "jev_route.py"), "conflict-guard", "--repo", "edge-react-gui", "--files", files],
                                   capture_output=True, text=True)  # noqa: E731
ok("guard CLI exits 1 on a money-path conflict", cli("CHANGELOG.md,src/util/addressUtils.ts").returncode == 1)
ok("guard CLI exits 0 on a CHANGELOG conflict", cli("CHANGELOG.md").returncode == 0)

# ── 4. pairs ledger ────────────────────────────────────────────────────────────────
ok("ledger: CURRENT STATE stripped from the task text", P.strip_current_state("ask\n\n===== CURRENT STATE =====\n- PR merged") == "ask")
ok("ledger: body with no CURRENT STATE unchanged", P.strip_current_state("ask") == "ask")
FP = [("2026-09-02T00:00:00Z", "aaa", "bbb"), ("2026-09-05T00:00:00Z", "bbb", "ccc")]
ok("tip_at: report before the first force push uses its beforeCommit", P.tip_at(FP, "2026-09-01T00:00:00Z", "ccc") == ("aaa", "force-push-before"))
ok("tip_at: report between force pushes uses the next one's beforeCommit", P.tip_at(FP, "2026-09-03T00:00:00Z", "ccc") == ("bbb", "force-push-before"))
ok("tip_at: report after every force push walks today's head history", P.tip_at(FP, "2026-09-06T00:00:00Z", "ccc") == ("ccc", "pr-head-history"))
ok("tip_at: no force push", P.tip_at([], "2026-09-06T00:00:00Z", "ccc") == ("ccc", "pr-head-history"))
hsrc = open(os.path.join(ROUTING, "jev-pair.py")).read()
body_head = hsrc[hsrc.index("def head_at("):hsrc.index("def report_pr(")]
ok("head_at has no final-head fallback", "raise NoHeadAtReport" in body_head and body_head.count("return ") == 1 and "return sha" in body_head)


def sh_stub(out):
    def sh(cmd, **kw):
        class X:
            returncode, stderr = 0, ""
            stdout = out(cmd)
        return X
    return sh


P.force_pushes = lambda repo, pr: []
P.sh = sh_stub(lambda cmd: "finalhead\n" if cmd[-1] == ".head.sha" else "")
try:
    P.head_at("edge-react-gui", 1, "2026-09-01T00:00:00Z")
    ok("head_at refuses when no commit existed at report time", False)
except P.NoHeadAtReport:
    ok("head_at refuses when no commit existed at report time", True)
P.sh = sh_stub(lambda cmd: "finalhead\n" if cmd[-1] == ".head.sha" else ("0\n" if "compare" in cmd[2] else "basesha\t2026-08-30T00:00:00Z\n"))
try:
    P.head_at("edge-react-gui", 1, "2026-09-01T00:00:00Z", base="develop")
    ok("head_at refuses when the newest commit at T is on the base (plan-only report)", False)
except P.NoHeadAtReport:
    ok("head_at refuses when the newest commit at T is on the base (plan-only report)", True)
P.sh = sh_stub(lambda cmd: "finalhead\n" if cmd[-1] == ".head.sha" else ("2\n" if "compare" in cmd[2] else "midsha\t2026-08-31T00:00:00Z\n"))
ok("head_at returns the commit at T, not the final head", P.head_at("edge-react-gui", 1, "2026-09-01T00:00:00Z", base="develop")[0] == "midsha")

ok("report_pr: url", P.report_pr("---\npr: https://github.com/EdgeApp/x/pull/1\n---\nbody") == "https://github.com/EdgeApp/x/pull/1")
for v in ("none", "", '""', "null", "n/a"):
    ok(f"report_pr: {v!r} is plan-only", P.report_pr(f"---\ntask: 1\npr: {v}\n---\n") == "")
ok("report_pr: no frontmatter", P.report_pr("# report\npr: https://x") == "")

A = lambda name, ts: {"name": name, "created_at": ts, "gid": name + ts}  # noqa: E731
WITH, WITHOUT = "---\npr: https://github.com/EdgeApp/x/pull/1\n---\n", "---\npr: none\n---\n"
atts = [A("agent-run-report.md", "2026-09-01"), A("plan-x.md", "2026-09-02"), A("agent-run-report-2.md", "2026-09-03"),
        A("plan-x-v2.md", "2026-09-04"), A("agent-run-report-3.md", "2026-09-05")]
texts = {"2026-09-01": WITH, "2026-09-03": WITHOUT, "2026-09-05": WITH}
rep, text, pl, n = P.pick_report(atts, lambda a: texts[a["created_at"]])
ok("pick_report skips the inverted report (before the plan)", rep["created_at"] != "2026-09-01")
ok("pick_report skips the plan-only report", rep["created_at"] == "2026-09-05")
ok("pick_report pairs the newest plan before the report", pl["name"] == "plan-x-v2.md" and n == 2)
rep, _, pl, n = P.pick_report(atts[1:3] + atts[3:], lambda a: WITH)
ok("pick_report takes the first PR report after the first plan", rep["created_at"] == "2026-09-03" and pl["name"] == "plan-x.md" and n == 1)
try:
    P.pick_report(atts[:3], lambda a: texts[a["created_at"]])
    ok("pick_report refuses a task with only inverted and plan-only reports", False)
except SystemExit:
    ok("pick_report refuses a task with only inverted and plan-only reports", True)

body_f = os.path.join(TMP, "body.txt")
open(body_f, "w").write("Operator ask line.\n\n===== CURRENT STATE (agent) =====\n- merged in PR 9\n")
awk = re.search(r"awk '(/\^===== CURRENT STATE/[^']+)'", open(os.path.join(ROUTING, "jev-shadow-run.sh")).read())
ok("shadow brief strips CURRENT STATE with awk", bool(awk))
if awk:
    out = subprocess.run(["awk", awk.group(1), body_f], capture_output=True, text=True).stdout
    ok("shadow brief body carries the ask and not the CURRENT STATE section", "Operator ask line." in out and "merged in PR 9" not in out)

# ── 3. shadow only ─────────────────────────────────────────────────────────────────
ok("SHADOW_OFF is in place", os.path.exists(os.path.join(ROUTING, "SHADOW_OFF")))
spawn = open(os.path.expanduser("~/.config/agent-watcher/spawn-test-session.sh")).read()
ok("spawn logs the landing decision", "jev_route.py" in spawn and " landing " in spawn)
ok("spawn never reads a routing pick back into the model", not re.search(r"AGENT_MODEL=.*jev_route|MODEL=\$\(.*jev_route", spawn))
gate = open(os.path.join(HOOKS, "pre-pr-gate.sh")).read()
ok("pre-PR gate calls the diff check in shadow mode only", "jev_diffcheck.py" in gate and " shadow " in gate and "jev_diffcheck.py\" check" not in gate and "jev_diffcheck.py check" not in gate)
ok("plan gate calls the router", "jev_route.py" in open(os.path.join(HOOKS, "require-plan-before-developing.sh")).read())
for sh_file in ("hooks/pre-pr-gate.sh", "hooks/require-plan-before-developing.sh", "spawn-test-session.sh"):
    ok(f"bash -n {sh_file}", subprocess.run(["bash", "-n", os.path.expanduser("~/.config/agent-watcher/" + sh_file)]).returncode == 0)
ok("bash -n jev-shadow-run.sh", subprocess.run(["bash", "-n", os.path.join(ROUTING, "jev-shadow-run.sh")]).returncode == 0)
ok("no vector wrote to the live shadow logs", R.SHADOW_ROOT == TMP and D.LOG.startswith(TMP))

R.time.sleep = sleep
print(f"\n{'FAILED: ' + str(len(fails)) if fails else 'all vectors pass'}")
sys.exit(1 if fails else 0)
