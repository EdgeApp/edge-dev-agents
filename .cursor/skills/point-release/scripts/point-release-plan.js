#!/usr/bin/env node
// point-release-plan.js — resolve an edge-react-gui point release (X.Y.Z, Z > 0)
// from Asana into the develop commits that carry it. Read-only: Asana, GitHub
// and the local repo are only read.
//
// Called by point-release-ship.sh, never by an agent directly.
//
// Usage: point-release-plan.js --repo <path> --version X.Y.Z --remote <name>
//          --master <branch> --develop <branch>
//          [--skip-task <gid>]... [--pick <sha>]...
//
// Sources, in order:
//   1. Tasks whose "Release (4.x.x)" field is the version's option ("52.1" for
//      4.52.1), found by a workspace search. --skip-task drops one.
//   2. Each task's GitHub PRs (attachments and subtasks, via pr-land-discover.sh).
//      - edge-react-gui PR merged to develop: its commits (a merge commit unpacks
//        as <merge>^1..<merge>^2) and the CHANGELOG entries it added.
//      - dependency PR (a repo in the GUI's package.json): the first published
//        dep version carrying the merge, then the develop commit that first
//        pinned that version or newer. Every dep CHANGELOG entry between
//        master's pin and that pin rides along, so all of them are reported.
//      - open PR: reported as unmerged; the caller decides what that blocks.
//   3. --pick <sha>: a develop commit the operator adds (a lockfile prerequisite).
//
// Output (stdout): one JSON object
//   { option, tasks[], picks[], entries[], deps[], unmerged[], blockers[] }
// Exit: 0 resolved (blockers may still be listed), 1 error (stderr says why).

const { spawnSync } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");

const SKILLS = path.join(os.homedir(), ".cursor", "skills");
const WORKSPACE_GID = "9976422036640";
const ENG_BOARD_GID = "1213880789473005";
const RELEASE_FIELD_NAME = "Release (4.x.x)";
const GUI_REPO = "edge-react-gui";
// Entry shape shared with the release and landing scripts.
const { ENTRY_RE } = require(path.join(SKILLS, "release-lib.js"));

const args = { skip: [], pick: [] };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--skip-task") args.skip.push(argv[++i]);
  else if (a === "--pick") args.pick.push(argv[++i]);
  else if (a.startsWith("--")) args[a.slice(2)] = argv[++i];
}
for (const k of ["repo", "version", "remote", "master", "develop"]) {
  if (!args[k]) fail(`missing --${k}`);
}

function fail(msg) {
  console.error(`!! ${msg}`);
  process.exit(1);
}

if (!process.env.ASANA_TOKEN) {
  try {
    const t = JSON.parse(
      fs.readFileSync(path.join(os.homedir(), ".config/agent-watcher/credentials.json"), "utf8")
    ).asana_token;
    if (t) process.env.ASANA_TOKEN = t;
  } catch {}
}

function run(cmd, cmdArgs, opts = {}) {
  const r = spawnSync(cmd, cmdArgs, { encoding: "utf8", maxBuffer: 64 << 20, ...opts });
  if (r.status !== 0 && !opts.allowFail) {
    fail(`${cmd} ${cmdArgs.join(" ")} failed: ${(r.stderr || "").trim().slice(0, 400)}`);
  }
  return r.status === 0 ? r.stdout : null;
}
const git = (...a) => run("git", ["-C", args.repo, ...a]);
const gitTry = (...a) => run("git", ["-C", args.repo, ...a], { allowFail: true });
const asana = (p) => JSON.parse(run(path.join(SKILLS, "asana-paged-get.sh"), [p])).data;
const ghJson = (a) => JSON.parse(run("gh", a));

const semver = (v) => String(v).replace(/^[v^~]/, "").split(/[.+-]/).slice(0, 3).map(Number);
const cmp = (a, b) => {
  const x = semver(a), y = semver(b);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
};

const [MAJ, MIN, PAT] = semver(args.version);
const OPTION = `${MIN}.${PAT}`;
const MASTER = `${args.remote}/${args.master}`;
const DEVELOP = `${args.remote}/${args.develop}`;
const BASE = git("merge-base", MASTER, DEVELOP).trim();
const DEV_LINE = git("rev-list", "--first-parent", "--reverse", `${BASE}..${DEVELOP}`).trim().split("\n").filter(Boolean);
const devIndex = new Map(DEV_LINE.map((c, i) => [c, i]));
const pkgAt = (ref) => JSON.parse(git("show", `${ref}:package.json`));
const MASTER_PKG = pkgAt(MASTER);
const DEV_PKG = pkgAt(DEVELOP);
const depPin = (pkg, name) => (pkg.dependencies || {})[name] || (pkg.devDependencies || {})[name] || null;

const out = { option: OPTION, tasks: [], picks: [], entries: [], deps: [], unmerged: [], blockers: [] };
const pickSeen = new Set();

function addEntries(lines, source) {
  for (const l of lines) {
    if (!ENTRY_RE.test(l)) continue;
    if (out.entries.some((e) => e.text === l)) continue;
    out.entries.push({ text: l, source });
  }
}

// Order key: position of the develop first-parent commit that brought it in.
function addPick(sha, source, task, anchor, sub) {
  if (pickSeen.has(sha)) return;
  pickSeen.add(sha);
  const subject = git("log", "-1", "--format=%s", sha).trim();
  out.picks.push({ sha, short: sha.slice(0, 9), subject, source, task, order: [devIndex.get(anchor) ?? -1, sub] });
}

function changelogAdds(from, to) {
  const d = git("diff", from, to, "--", "CHANGELOG.md");
  return d.split("\n").filter((l) => l.startsWith("+") && !l.startsWith("+++")).map((l) => l.slice(1));
}

// ---------------------------------------------------------------- Asana --
const cfs = asana(`projects/${ENG_BOARD_GID}/custom_field_settings?opt_fields=custom_field.gid,custom_field.name,custom_field.enum_options.name,custom_field.enum_options.gid&limit=100`);
const field = cfs.map((s) => s.custom_field).find((f) => f && f.name === RELEASE_FIELD_NAME);
if (!field) fail(`no "${RELEASE_FIELD_NAME}" field on the Engineering board`);
const option = (field.enum_options || []).find((o) => o.name === OPTION);
if (!option) fail(`"${RELEASE_FIELD_NAME}" has no option "${OPTION}"; no task can be marked for ${args.version}`);
const tasks = asana(`workspaces/${WORKSPACE_GID}/tasks/search?custom_fields.${field.gid}.value=${option.gid}&opt_fields=name,completed,permalink_url&limit=100`);

for (const t of tasks) {
  const task = { gid: t.gid, name: t.name, completed: !!t.completed, url: t.permalink_url, prs: [], skipped: args.skip.includes(t.gid) };
  out.tasks.push(task);
  if (task.skipped) continue;

  const disc = JSON.parse(run(path.join(SKILLS, "pr-land", "scripts", "pr-land-discover.sh"), [`https://app.asana.com/0/0/${t.gid}`]));
  const refs = [
    ...(disc.prs || []).map((p) => ({ repo: p.repo, number: p.prNumber })),
    ...(disc.notOpen || []).map((p) => ({ repo: p.repo, number: p.prNumber })),
  ];
  if (!refs.length) {
    out.blockers.push({ task: t.gid, reason: `task "${t.name}" links no GitHub PR` });
    continue;
  }

  for (const ref of refs) {
    const pr = ghJson(["pr", "view", String(ref.number), "-R", `EdgeApp/${ref.repo}`, "--json", "state,mergeCommit,baseRefName,title,url"]);
    const rec = { repo: ref.repo, number: ref.number, title: pr.title, url: pr.url, state: pr.state, base: pr.baseRefName };
    task.prs.push(rec);
    if (pr.state === "CLOSED") { rec.note = "closed unmerged, ignored"; continue; }
    if (pr.state === "OPEN") {
      out.unmerged.push({ task: t.gid, taskName: t.name, repo: ref.repo, number: ref.number, url: pr.url, title: pr.title });
      continue;
    }
    const merge = pr.mergeCommit && pr.mergeCommit.oid;

    if (ref.repo === GUI_REPO) {
      if (pr.baseRefName !== args.develop) {
        out.blockers.push({ task: t.gid, reason: `${pr.url} merged into ${pr.baseRefName}, not ${args.develop}; a point release picks from ${args.develop}` });
        continue;
      }
      if (gitTry("merge-base", "--is-ancestor", merge, DEVELOP) === null) {
        out.blockers.push({ task: t.gid, reason: `${pr.url} merge ${merge.slice(0, 9)} is not on ${DEVELOP} (fetch, or the PR was reverted out)` });
        continue;
      }
      const parents = git("rev-list", "--parents", "-n", "1", merge).trim().split(" ").slice(1);
      const commits = parents.length > 1
        ? git("rev-list", "--reverse", "--no-merges", `${merge}^1..${merge}^2`).trim().split("\n").filter(Boolean)
        : [merge];
      commits.forEach((c, i) => addPick(c, `${ref.repo}#${ref.number}`, t.gid, merge, i));
      addEntries(changelogAdds(parents.length > 1 ? `${merge}^1` : `${merge}^`, merge), `${ref.repo}#${ref.number}`);
      rec.commits = commits.length;
      continue;
    }

    // Dependency PR: it reaches the GUI as a published version pinned on develop.
    const masterPin = depPin(MASTER_PKG, ref.repo);
    const devPin = depPin(DEV_PKG, ref.repo);
    if (!masterPin || !devPin) {
      out.blockers.push({ task: t.gid, reason: `${pr.url}: ${ref.repo} is not a dependency of ${GUI_REPO} on both master and develop` });
      continue;
    }
    const allTags = run("gh", ["api", "--paginate", `repos/EdgeApp/${ref.repo}/tags`, "-q", ".[].name"])
      .trim().split("\n").filter((n) => /^v?\d+\.\d+\.\d+$/.test(n));
    const tags = allTags.filter((n) => cmp(n, masterPin) > 0 && cmp(n, devPin) <= 0)
      .sort(cmp);
    let required = null;
    for (const tag of tags) {
      const c = ghJson(["api", `repos/EdgeApp/${ref.repo}/compare/${merge}...${tag}`, "--jq", "{status: .status}"]);
      if (c.status === "ahead" || c.status === "identical") { required = tag; break; }
    }
    if (!required) {
      const reason = cmp(devPin, masterPin) <= 0
        ? `${ref.repo} on ${args.develop} (${devPin}) is no newer than ${args.master} (${masterPin})`
        : `no published ${ref.repo} version between ${masterPin} and ${devPin} contains ${pr.url}; publish it and pin it on ${args.develop} first`;
      out.blockers.push({ task: t.gid, reason });
      continue;
    }
    // The develop first-parent commit that first pinned `required` or newer.
    let bump = null;
    for (const c of DEV_LINE) {
      const now = depPin(pkgAt(c), ref.repo);
      const before = depPin(pkgAt(`${c}^1`), ref.repo);
      if (now && cmp(now, required) >= 0 && !(before && cmp(before, required) >= 0)) { bump = c; break; }
    }
    if (!bump) {
      out.blockers.push({ task: t.gid, reason: `no ${args.develop} commit since the release cut pins ${ref.repo} ${required} or newer` });
      continue;
    }
    if (git("rev-list", "--parents", "-n", "1", bump).trim().split(" ").length > 2) {
      out.blockers.push({ task: t.gid, reason: `${ref.repo} ${required} reached ${args.develop} inside merge ${bump.slice(0, 9)}; name the pinning commit with --pick` });
      continue;
    }
    const pinned = depPin(pkgAt(bump), ref.repo);
    addPick(bump, `${ref.repo}#${ref.number} via ${ref.repo}@${pinned.replace(/^[\^~]/, "")}`, t.gid, bump, 0);
    // Every dep release between master's pin and the new pin ships with it.
    const pinTag = allTags.find((n) => cmp(n, pinned) === 0) || required;
    const raw = run("gh", ["api", `repos/EdgeApp/${ref.repo}/contents/CHANGELOG.md?ref=${pinTag}`, "-H", "Accept: application/vnd.github.raw"]);
    const lines = [];
    const versions = [];
    let inRange = false;
    for (const l of raw.split("\n")) {
      const h = l.match(/^## (\d+\.\d+\.\d+)/);
      if (h) {
        inRange = cmp(h[1], masterPin) > 0 && cmp(h[1], pinned) <= 0;
        if (inRange) versions.push(h[1]);
        continue;
      }
      if (inRange && ENTRY_RE.test(l)) lines.push(l);
    }
    addEntries(lines, `${ref.repo} ${versions.slice().reverse().join(", ")}`);
    out.deps.push({ repo: ref.repo, pr: ref.number, from: masterPin, to: pinned, required: required.replace(/^v/, ""), versions, bump: bump.slice(0, 9) });
  }
}

for (const p of args.pick) {
  const sha = gitTry("rev-parse", "--verify", `${p}^{commit}`);
  if (!sha) fail(`--pick ${p}: no such commit`);
  const full = sha.trim();
  if (gitTry("merge-base", "--is-ancestor", full, DEVELOP) === null) fail(`--pick ${p}: not on ${DEVELOP}`);
  addPick(full, "operator --pick", null, full, 0);
  addEntries(changelogAdds(`${full}^`, full), `--pick ${full.slice(0, 9)}`);
}

out.picks.sort((a, b) => a.order[0] - b.order[0] || a.order[1] - b.order[1]);
for (const p of out.picks) delete p.order;
console.log(JSON.stringify(out, null, 2));
