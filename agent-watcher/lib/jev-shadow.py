#!/usr/bin/env python3
"""Jev shadow mode: log Jev's verdict beside a live decision, never act on it.

One helper for every shadow path (the scrub, the Jev call, the questions, the
logs). Live callers only ENQUEUE: a scrubbed JSON row lands in the spool and the
caller moves on. The launchd drain (com.jontz.jev-shadow) reads the key once,
asks Jev with a hard timeout, writes one decision row per question under
~/.config/jev/shadow/<path>/decisions.jsonl, and deletes the spool file. Rows
carry hashes, labels and confidences, never transcript text. Every failure is
swallowed: shadow mode must never change a live decision or its latency.

Release signing key material never leaves the box: scrub() runs at enqueue and
again right before the POST.

Usage:
  jev-shadow.py enqueue <path>          # JSON payload on stdin, exit 0 always
  jev-shadow.py tick                    # launchd (300s): tracker-poll, then drain
  jev-shadow.py drain [--max N]         # launchd: ask Jev for spooled rows
  jev-shadow.py tracker-poll            # launchd: spool new Master Kanban tasks
  jev-shadow.py backfill --gids <file>  # tracker rows for given task gids now
  jev-shadow.py audit-board [--out f]   # board-wide disagreements at >=0.9
  jev-shadow.py report [--json]         # per-path agreement + recommendation
Kill switch: touch ~/.config/jev/shadow/OFF (enqueue and drain become no-ops).
"""
import hashlib, json, os, re, subprocess, sys, time, urllib.request

ROOT = os.path.expanduser(os.environ.get("JEV_SHADOW_ROOT", "~/.config/jev/shadow"))
SPOOL = os.path.join(ROOT, "_spool")
URL = "https://api.typesafe.ai/v1/systemone"
MODEL = os.environ.get("JEV_MODEL", "jev-latest")
TIMEOUT = 20
PATHS = ("tracker", "prose", "watchdog", "prompt", "followup", "command", "gates", "blocker")
BOARD = "1213843652804305"
JUDGE = os.path.expanduser("~/.cursor/skills/no-slop/scripts/no-slop-judge.sh")
KANBAN = os.path.expanduser("~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh")
SPOOL_MAX = 2000          # enqueue refuses past this many pending rows
SPOOL_TTL = 86400         # a row Jev could not answer for a day is dropped

_LINE = re.compile(r"storePassword|keyPassword|keyAlias|-Pstore|\.jks|\.keystore")
_B64 = re.compile(r"[A-Za-z0-9+/=_-]{201,}")


def scrub(text):
    if not text:
        return text or ""
    lines = [l for l in str(text).split("\n") if not _LINE.search(l)]
    return _B64.sub("[base64 removed]", "\n".join(lines))


def scrub_obj(o):
    if isinstance(o, str):
        return scrub(o)
    if isinstance(o, dict):
        return {k: scrub_obj(v) for k, v in o.items()}
    if isinstance(o, list):
        return [scrub_obj(v) for v in o]
    return o


def h(text):
    return hashlib.sha256(str(text).encode()).hexdigest()[:16]


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def off():
    return os.path.exists(os.path.join(ROOT, "OFF"))


def append(path, name, row):
    d = os.path.join(ROOT, path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    with open(os.path.join(d, name), "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


# ---------------------------------------------------------------- Jev call ---
_key = None


def key():
    global _key
    if _key is None:
        tok = json.load(open(os.path.expanduser("~/.config/edge-secrets/1password.json")))["OP_SERVICE_ACCOUNT_TOKEN"]
        _key = subprocess.run(["op", "read", "op://Agent Share/jev API/notesPlain"],
                              env={**os.environ, "OP_SERVICE_ACCOUNT_TOKEN": tok},
                              capture_output=True, text=True, check=True, timeout=60).stdout.strip()
    return _key


def ask(state, questions):
    body = json.dumps({"model": MODEL, "state": scrub_obj(state), "questions": questions}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Authorization": "Bearer " + key(), "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def choice(instructions, criteria):
    return {"type": "choice", "instructions": instructions, "criteria": criteria}


def noul(instructions, true=None, false=None):
    q = {"type": "noul", "instructions": instructions}
    if true or false:
        q["criteria"] = {"true": true, "false": false}
    return q


def ans(a):
    """(label, confidence) for a choice or noul answer."""
    if "choice" in a:
        return a["choice"], a.get("confidence", 0.0)
    p = a.get("noul", 0.5)
    return p >= 0.5, max(p, 1 - p)


# --------------------------------------------------------------- questions ---
CATEGORY = {
    "Bugfix/Tweak": "Fixing broken behavior or small adjustments to existing behavior. The catch-all; when torn between this and Feature, new capability wins.",
    "Feature": "New user-facing or system capability that did not exist before (new integrations, new chains/assets/pairs, new APIs, new screens).",
    "Investigation/Research": "The deliverable is a diagnosis, evaluation, or feasibility answer, including bug investigations with no committed fix.",
    "Dependency": "Upgrading an EXTERNAL or partner-provided dependency (SDK upgrades, partner contract upgrades, network hard-forks). NOT merely work that lands in a non-GUI repo; a core:/reports:/login-server: title prefix is not a Dependency signal.",
    "Spec/Refine": "The deliverable is a plan, spec, or refined task breakdown that spawns other tasks.",
    "Bug Bounty": "An external vulnerability report.",
    "Support Request": "A partner-originated or support-originated ask.",
    "Visual Design": "Work done by a designer: mockups, and producing icon or image assets, including requests titled Icon: <token> that list a token ticker and contract address. Not code.",
    "Marketing": "Content deliverables for marketing.",
}
DEPARTMENT = {
    "Engineering": "Writing or changing code, infrastructure, servers, builds, investigations of bugs.",
    "Design": "Producing visual assets, icons, mockups or UX designs.",
    "Marketing": "Content, campaigns, social posts, store listings, announcements.",
    "BizDev": "Partner relationships, contracts, listings, commercial integrations handled by people not code.",
    "Support": "Customer support operations, help articles, support tooling and reports.",
    "QA": "Manual testing, test plans, release verification.",
    "Growth": "User acquisition, analytics experiments, funnels.",
}
PANE = {
    "working": "The agent is mid-turn: output is streaming or a spinner / 'esc to interrupt' is shown.",
    "done": "The agent finished its turn and the prompt is empty and waiting; nothing is pending.",
    "awaiting choice": "A numbered menu or a yes/no permission prompt is waiting for a human to pick an option.",
    "safety dialog": "A 'Dangerous operation ... Do you want to proceed' confirmation is on screen.",
    "auth wall": "A login, OAuth, API key or re-authentication prompt blocks progress.",
    "compacting": "The conversation is being compacted or summarized.",
    "wedged": "The session is stuck: an error loop, a crashed process, or a frozen screen with no progress.",
}
# The watchdog regex distinguishes four states; Jev's extra states collapse onto them.
PANE_COLLAPSE = {"working": "working", "compacting": "working", "done": "idle", "auth wall": "idle",
                 "wedged": "idle", "awaiting choice": "awaiting choice", "safety dialog": "safety dialog"}
INTENT = {
    "stop": "The operator tells the agent to stop, halt, pause or stand down now.",
    "release": "The operator lifts an earlier hold: resume, continue, go ahead, you may proceed.",
    "hold": "The operator is asking a question or discussing, and the agent should answer and wait rather than act.",
    "steer": "The operator gives an instruction the agent should act on: a change of direction, a new step, a correction.",
}
_rules = None


def judge_rules():
    """Rule definitions, parsed from the haiku judge's prompt so both judges read the same text."""
    global _rules
    if _rules is None:
        _rules = {}
        for l in open(JUDGE):
            m = re.search(r'"Rule ([a-z-]+): (.*)",?\s*$', l.strip())
            if m:
                _rules[m.group(1)] = m.group(2).replace('\\"', '"').replace("\\x27", "'")
    return _rules


def clauses(text):
    parts = re.split(r"(?<=[.!?])\s+|\n+|;\s+", text or "")
    return [p.strip() for p in parts if len(p.strip()) >= 3][:20]


def questions(path, p):
    """(state, {name: question}, {name: live label}) for one spooled payload."""
    if path == "tracker":
        st = {"title": p["title"], "description": (p.get("notes") or "")[:1000]}
        q = {"category": choice("Classify this task by what kind of work it IS (work type), not by which repo or area it touches.", CATEGORY),
             "department": choice("Which department does the work in this task?", DEPARTMENT)}
        return st, q, {"category": p.get("category"), "department": p.get("departments") or []}
    if path == "prose":
        rules = judge_rules()
        crit = dict(rules)
        crit["none"] = "The sentence violates none of these rules; it carries real content."
        hint = p["hint"] if p.get("hint") in rules else "forward-reference"
        q = {"rule": choice("Which writing rule, if any, does this sentence violate?", crit),
             "hinted": noul("The sentence violates this rule: " + rules[hint])}
        return {"sentence": p["sentence"]}, q, {"violation": p.get("haiku")}
    if path == "watchdog":
        q = {"pane": choice("This is the visible tail of a Claude Code terminal pane. What state is the session in?", PANE)}
        return {"pane": p["pane"][-4000:]}, q, {"pane": p["live"]}
    if path == "prompt":
        q = {"intent": choice("An operator typed this message to a running coding agent. What does it ask the agent to do?", INTENT)}
        return {"message": p["prompt"][:2000]}, q, {"intent": p["live"]}
    if path == "command":
        q = {"executes": noul(f"This shell command actually executes {p['x']}, rather than only quoting or mentioning it.",
                              true=f"{p['x']} runs when this command runs.",
                              false=f"{p['x']} only appears inside a string, echo, grep pattern, heredoc, commit message or comment, and never runs.")}
        return {"command": p["cmd"][:3000]}, q, {"executes": p["live"] == "block"}
    if path == "gates":
        rules = judge_rules()
        desc = rules.get(p["rule"]) or p.get("msg") or ("The sentence breaks the writing rule named " + p["rule"] + ".")
        q = {"violates": noul("This line breaks the writing rule: " + desc)}
        return {"line": p["line"][:1000], "rule": p["rule"]}, q, {"violates": True}
    raise KeyError(path)


# ------------------------------------------------------------------ enqueue ---
def enqueue(path, payload):
    if off() or path not in PATHS:
        return
    os.makedirs(SPOOL, mode=0o700, exist_ok=True)
    if len(os.listdir(SPOOL)) >= SPOOL_MAX:
        return
    payload = scrub_obj(payload)
    payload["_path"], payload["_ts"] = path, now()
    name = f"{time.time_ns()}-{path}-{os.getpid()}.json"
    tmp = os.path.join(SPOOL, "." + name)
    with open(tmp, "w") as f:
        json.dump(payload, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(SPOOL, name))


# -------------------------------------------------------------------- drain ---
def load_cache():
    try:
        return json.load(open(os.path.join(ROOT, "_cache.json")))
    except Exception:
        return {}


def save_cache(c):
    if len(c) > 5000:
        c = dict(list(c.items())[-4000:])
    tmp = os.path.join(ROOT, "._cache.json")
    json.dump(c, open(tmp, "w"))
    os.replace(tmp, os.path.join(ROOT, "_cache.json"))


def agree(qname, live, jev):
    if live is None or live == []:
        return None
    if qname == "department":
        return jev in live
    if qname == "pane":
        return PANE_COLLAPSE.get(jev, jev) == live
    return jev == live


def record(path, p, st, answers, live, tokens, cached):
    base = {"ts": p.get("_ts") or now(), "h": h(json.dumps(st, sort_keys=True)), "cached": cached, "tok": tokens}
    for k in ("gid", "task", "session", "hook", "x", "story", "rule", "source"):
        if k in p:
            base[k] = p[k]
    if path == "prose":
        # prose pre-clear: Jev would clear the sentence before haiku when it names no
        # rule and scores the hinted rule under 0.1 (Phase 0 cutoff).
        rule, rconf = ans(answers["rule"])
        hp = answers["hinted"].get("noul", 1.0)
        clear = rule == "none" and hp < 0.1
        haiku = live["violation"]
        row = {**base, "q": "preclear", "live": haiku, "jev": not clear, "conf": rconf, "hinted_p": round(hp, 3),
               "jev_rule": rule, "hint": p.get("hint"), "agree": None if haiku is None else (not clear) == haiku,
               "lost": bool(clear and haiku)}
        append(path, "decisions.jsonl", row)
        append(path, "sidelog.jsonl", {"date": row["ts"][:10], "sentence": p["sentence"], "hint": p.get("hint"),
                                       "haiku": haiku, "haiku_rule": p.get("haiku_rule"), "jev_rule": rule,
                                       "jev_hinted_p": round(hp, 3), "jev_would_clear": clear})
        return
    for qname, a in answers.items():
        label, conf = ans(a)
        row = {**base, "q": qname, "live": live.get(qname), "jev": label, "conf": round(conf, 4),
               "agree": agree(qname, live.get(qname), label)}
        if path == "prompt":
            # Jev may add a hold in the log; it never releases.
            row["jev_adds_hold"] = label in ("hold", "stop") and live.get(qname) in ("steer", "release")
        append(path, "decisions.jsonl", row)


def drain_followup(p, cache):
    """Per-clause Noul, deduped by story gid."""
    seen_f = os.path.join(ROOT, "followup", "seen.json")
    try:
        seen = set(json.load(open(seen_f)))
    except Exception:
        seen = set()
    if p["story"] in seen:
        return 0
    q = {"addressed": noul("This clause, taken from a tracker comment on a task an agent is working, is addressed to the agent: it asks the agent to do, change, check or answer something.",
                           true="An instruction, request or question for the agent.",
                           false="Narration, a note to another human, a quote, a status remark, or a pleasantry.")}
    tok = 0
    for c in clauses(p["text"]):
        st = {"clause": c}
        ck = "followup:" + h(c)
        if ck in cache:
            a, cached = cache[ck], True
        else:
            r = ask(st, q)
            a, cached = r["answers"], False
            tok += r.get("usage", {}).get("input_tokens", 0)
            cache[ck] = a
        label, conf = ans(a["addressed"])
        append("followup", "decisions.jsonl", {"ts": p.get("_ts") or now(), "task": p.get("task"), "story": p["story"],
                                               "h": h(c), "q": "addressed", "live": True, "jev": label,
                                               "conf": round(conf, 4), "agree": label is True, "cached": cached})
    seen.add(p["story"])
    os.makedirs(os.path.dirname(seen_f), exist_ok=True)
    json.dump(sorted(seen), open(seen_f, "w"))
    return tok


def drain(maxn=300):
    if off() or not os.path.isdir(SPOOL):
        return
    files = sorted(f for f in os.listdir(SPOOL) if f.endswith(".json") and not f.startswith("."))[:maxn]
    if not files:
        return
    cache, done, failed, tok = load_cache(), 0, 0, 0
    for f in files:
        fp = os.path.join(SPOOL, f)
        try:
            p = json.load(open(fp))
            path = p["_path"]
            if path == "followup":
                tok += drain_followup(p, cache)
            else:
                st, q, live = questions(path, p)
                ck = path + ":" + h(json.dumps([st, q], sort_keys=True))
                if ck in cache:
                    a, cached = cache[ck], True
                else:
                    r = ask(st, q)
                    a, cached = r["answers"], False
                    tok += r.get("usage", {}).get("input_tokens", 0)
                    cache[ck] = a
                record(path, p, st, a, live, 0 if cached else r.get("usage", {}).get("input_tokens", 0), cached)
            os.remove(fp)
            done += 1
        except Exception as e:
            failed += 1
            try:
                if time.time() - os.path.getmtime(fp) > SPOOL_TTL or isinstance(e, (KeyError, ValueError)):
                    os.remove(fp)
            except Exception:
                pass
    save_cache(cache)
    append("_meta", "drains.jsonl", {"ts": now(), "done": done, "failed": failed, "tokens": tok})
    print(f"drain: done {done} failed {failed} tokens {tok}")


# ------------------------------------------------------------------ tracker ---
def board(out=None):
    out = out or os.path.join(ROOT, "tracker", "board.json")
    os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
    subprocess.run([KANBAN, "fetch", "--out", out], capture_output=True, text=True, check=True, timeout=300)
    return json.load(open(out))


def tracker_payload(t, source):
    return {"gid": t["gid"], "title": t["name"], "notes": t.get("notes") or "", "category": t.get("category"),
            "departments": t.get("departments") or [], "source": source}


def tracker_poll():
    """New board gids wait until a human (or the categorizer) sets Category, then spool once."""
    if off():
        return
    sf = os.path.join(ROOT, "tracker", "seen.json")
    try:
        seen = json.load(open(sf))
    except Exception:
        seen = None
    tasks = board()
    if seen is None:
        # First poll only records the baseline: every task already on the board is not "new".
        seen = {t["gid"]: "baseline" for t in tasks}
    else:
        for t in tasks:
            st = seen.get(t["gid"])
            if st is None:
                seen[t["gid"]] = st = "pending:" + now()
            if st.startswith("pending") and t.get("category"):
                enqueue("tracker", tracker_payload(t, "live"))
                seen[t["gid"]] = "logged"
    json.dump(seen, open(sf, "w"))
    print(f"tracker-poll: board {len(tasks)} pending {sum(v.startswith('pending') for v in seen.values())}")


def backfill(gids_file):
    want = set(l.strip() for l in open(gids_file) if l.strip())
    tasks = [t for t in board() if t["gid"] in want]
    n = 0
    for t in tasks:
        if t.get("category") or t.get("departments"):
            enqueue("tracker", tracker_payload(t, "backfill"))
            n += 1
    print(f"backfill: asked {len(want)} on-board {len(tasks)} spooled {n}")


def audit_board(out):
    """Board-wide: every task where Jev disagrees with the board at confidence >= 0.9, as a file."""
    from concurrent.futures import ThreadPoolExecutor
    tasks = [t for t in board() if t.get("category") or t.get("departments")]
    key()

    def one(t):
        st, q, live = questions("tracker", tracker_payload(t, "audit"))
        for i in range(3):
            try:
                r = ask(st, q)
                return t, r["answers"], r.get("usage", {}).get("input_tokens", 0)
            except Exception:
                time.sleep(1.5 * (i + 1))
        return t, None, 0

    with ThreadPoolExecutor(8) as ex:
        res = list(ex.map(one, tasks))
    rows, tok, stats = [], 0, {"category": [0, 0, 0, 0], "department": [0, 0, 0, 0]}
    for t, a, k in res:
        if not a:
            continue
        tok += k
        live = {"category": t.get("category"), "department": t.get("departments") or []}
        for qn in ("category", "department"):
            label, conf = ans(a[qn])
            ag = agree(qn, live[qn], label)
            if ag is None:
                continue
            s = stats[qn]
            s[0] += 1; s[1] += ag
            if conf >= 0.9:
                s[2] += 1; s[3] += ag
                if not ag:
                    rows.append((qn, t, live[qn], label, conf))
            append("tracker", "audit.jsonl", {"ts": now(), "gid": t["gid"], "q": qn, "live": live[qn], "jev": label,
                                              "conf": round(conf, 4), "agree": ag, "source": "audit"})
    rows.sort(key=lambda r: (r[0], -r[4]))
    with open(out, "w") as f:
        f.write(f"# Master Kanban audit: Jev disagrees at confidence >= 0.9 ({now()[:10]})\n\n")
        f.write("Log only: no field was edited. Board value is what the task carries now.\n\n")
        for qn, s in stats.items():
            f.write(f"- {qn}: {s[0]} tasks, agreement {s[1]/max(1,s[0]):.1%}; at >= 0.9 coverage {s[2]/max(1,s[0]):.1%}, agreement {s[3]/max(1,s[2]):.1%}; flagged {s[2]-s[3]}\n")
        f.write(f"- Jev input tokens {tok} (${tok*0.042/1e6:.4f})\n")
        for qn in ("category", "department"):
            f.write(f"\n## {qn.title()}\n\n| Task | Board | Jev | Conf |\n|---|---|---|---|\n")
            for q_, t, lv, jl, c in rows:
                if q_ != qn:
                    continue
                name = t["name"].replace("|", "/")[:90]
                lv = ", ".join(lv) if isinstance(lv, list) else lv
                f.write(f"| [{name}](https://app.asana.com/0/{BOARD}/{t['gid']}) | {lv} | {jl} | {c:.2f} |\n")
    print(f"audit: tasks {len(tasks)} answered {sum(1 for r in res if r[1])} flagged {len(rows)} tokens {tok} out {out}")


# ------------------------------------------------------------------- report ---
def rows(path, name="decisions.jsonl"):
    fp = os.path.join(ROOT, path, name)
    if not os.path.exists(fp):
        return []
    return [json.loads(l) for l in open(fp) if l.strip()]


def recommend(n, cov9, agr9, agr):
    # Switch only on a real sample: 50+ decisions, and at >=0.9 confidence Jev covers
    # at least half of them while agreeing with the live mechanism 95%+ of the time.
    if n < 50:
        return "hold", f"n={n} < 50"
    if cov9 >= 0.5 and agr9 >= 0.95:
        return "switch", f"agreement {agr9:.1%} at >=0.9 on {cov9:.0%} coverage (n={n})"
    return "hold", f"agreement {agr9:.1%} at >=0.9 on {cov9:.0%} coverage, overall {agr:.1%} (n={n})"


def distinct(R):
    """One row per (content hash, question, source): a draft linted five times, or a
    command retried, is one decision, not five."""
    seen, out = set(), []
    for r in R:
        k = (r.get("h"), r.get("q"), r.get("source", "live"))
        if r.get("h") is None or k not in seen:
            seen.add(k)
            out.append(r)
    return out


def summarize(R):
    L = [r for r in R if r.get("agree") is not None]
    n = len(L)
    out = {"n": n, "agreement": sum(r["agree"] for r in L) / n if n else 0.0}
    for th in (0.9, 0.99):
        b = [r for r in L if r.get("conf", 0) >= th]
        out[f"cov{th}"] = len(b) / n if n else 0.0
        out[f"agr{th}"] = sum(r["agree"] for r in b) / len(b) if b else 0.0
    out["rec"], out["why"] = recommend(n, out["cov0.9"], out["agr0.9"], out["agreement"])
    return out


def report(as_json=False):
    res = {}
    for path in PATHS:
        if path == "blocker":
            R = rows(path)
            res["blocker"] = {"n": len(R), "by_verdict": {v: sum(1 for r in R if r.get("verdict") == v) for v in sorted({r.get("verdict") for r in R})},
                              "with_reason": sum(1 for r in R if r.get("reason")), "rec": "n/a", "why": "no Jev call; logging only"}
            continue
        R = distinct(rows(path))
        for q in sorted({r["q"] for r in R}):
            for src in sorted({r.get("source", "live") for r in R if r["q"] == q}):
                s = summarize([r for r in R if r["q"] == q and r.get("source", "live") == src])
                if path == "prose":
                    s["would_clear"] = sum(1 for r in R if not r["jev"]) / max(1, len(R))
                    s["lost"] = sum(1 for r in R if r.get("lost"))
                if path == "prompt":
                    s["jev_adds_hold"] = sum(1 for r in R if r.get("jev_adds_hold"))
                res[f"{path}/{q}/{src}"] = s
        if path == "tracker":
            A = rows(path, "audit.jsonl")
            for q in ("category", "department"):
                if any(r["q"] == q for r in A):
                    res[f"tracker/{q}/audit"] = summarize([r for r in A if r["q"] == q])
    meta = rows("_meta", "drains.jsonl")
    res["_spend"] = {"drains": len(meta), "tokens": sum(m["tokens"] for m in meta), "usd": round(sum(m["tokens"] for m in meta) * 0.042 / 1e6, 4)}
    if as_json:
        print(json.dumps(res, indent=1))
        return
    print(f"{'path/question/source':34} {'n':>5} {'agree':>7} {'cov.9':>6} {'agr.9':>6} {'cov.99':>6} {'agr.99':>6}  rec")
    for k, s in res.items():
        if k.startswith("_") or "agreement" not in s:
            continue
        print(f"{k:34} {s['n']:>5} {s['agreement']:>7.1%} {s['cov0.9']:>6.0%} {s['agr0.9']:>6.1%} {s['cov0.99']:>6.0%} {s['agr0.99']:>6.1%}  {s['rec']}: {s['why']}")
    for k, s in res.items():
        if "agreement" not in s:
            print(k, json.dumps(s))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    opt = {argv[i]: argv[i + 1] for i in range(2, len(argv) - 1) if argv[i].startswith("--")}
    if cmd == "enqueue":
        try:
            enqueue(argv[2], json.load(sys.stdin))
        except Exception:
            pass
        return 0
    if cmd == "tick":
        # One launchd job: a failed tracker poll (Asana down) must not stop the drain.
        for step in (tracker_poll, drain):
            try:
                step()
            except Exception as e:
                append("_meta", "errors.jsonl", {"ts": now(), "step": step.__name__, "error": type(e).__name__})
    elif cmd == "drain":
        drain(int(opt.get("--max", 300)))
    elif cmd == "tracker-poll":
        tracker_poll()
    elif cmd == "backfill":
        backfill(opt["--gids"])
    elif cmd == "audit-board":
        audit_board(opt.get("--out", os.path.join(ROOT, "tracker", f"audit-{now()[:10]}.md")))
    elif cmd == "report":
        report("--json" in argv)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
