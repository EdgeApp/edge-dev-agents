#!/usr/bin/env node
// pr-land-discover.sh — Discovers open PRs across EdgeApp repos with approval status.
//
// Accepts mixed argument types:
//   Repo names:     edge-react-gui edge-core-js
//   PR URLs:        https://github.com/EdgeApp/edge-react-gui/pull/123
//   PR shorthand:   edge-react-gui#123
//   Asana tasks:    https://app.asana.com/0/<project>/<taskGid>
//   --branch-scan:  scan all EdgeApp repos for $GIT_BRANCH_PREFIX/* PRs
//   No args:        Asana "PR Pipeline" section, incomplete tasks assigned to me
//
// No args (default): queries the configured Asana section, filters to incomplete
// tasks assigned to the current Asana user (resolved via asana-whoami.sh), and
// walks each task's attachments + subtasks for GitHub PR links. Tasks without a
// PR link are reported in `errors` but do not block. Requires ASANA_TOKEN.
//
// Explicit PRs (URL/shorthand) are fetched directly — no branch-prefix filter.
// Asana tasks are resolved to linked GitHub PRs via the Asana API.
// Repo names trigger a branch-prefix scan of those repos.
// --branch-scan triggers the legacy no-args behavior (all EdgeApp repos).

const { spawnSync } = require("child_process");
const https = require("https");
const path = require("path");

const rawArgs = process.argv.slice(2);
const edgeAppRepos = [
  "edge-react-gui",
  "edge-exchange-plugins",
  "edge-currency-accountbased",
  "edge-core-js",
  "edge-login-ui-rn",
  "edge-currency-plugins",
];

// "🔍 Review/Publish" section in the EdgeApp PR Pipeline project — the no-args queue.
// Project: https://app.asana.com/1/9976422036640/project/1213880789473005
// Resolved via: GET /projects/1213880789473005/sections
const ASANA_PR_LAND_SECTION_GID = "1214062531915722";

const BRANCH_PREFIX = process.env.GIT_BRANCH_PREFIX || "jon";

// Parse flags out of args (the rest is classified below).
let useBranchScan = false;
const args = [];
for (const arg of rawArgs) {
  if (arg === "--branch-scan") {
    useBranchScan = true;
  } else {
    args.push(arg);
  }
}

// --- Argument classification ---

const PR_URL_RE = /^https:\/\/github\.com\/EdgeApp\/([^/]+)\/pull\/(\d+)/;
const PR_SHORT_RE = /^([a-z][a-z0-9-]+)#(\d+)$/;
// Matches both old (app.asana.com/0/<project>/<taskGid>) and new
// (app.asana.com/1/<workspace>/project/<projectId>/task/<taskGid>) URL formats.
// Strips query params via the [^?]* fallback.
const ASANA_URL_RE = /^https:\/\/app\.asana\.com\/(?:\d+\/\d+\/(?:project\/\d+\/)?(?:task\/)?(\d+))/;

const repoArgs = [];
const explicitPrs = []; // {repo, prNumber}
const asanaGids = [];

for (const arg of args) {
  let m;
  if ((m = arg.match(PR_URL_RE))) {
    explicitPrs.push({ repo: m[1], prNumber: Number(m[2]) });
  } else if ((m = arg.match(PR_SHORT_RE))) {
    explicitPrs.push({ repo: m[1], prNumber: Number(m[2]) });
  } else if ((m = arg.match(ASANA_URL_RE))) {
    asanaGids.push(m[1]);
  } else {
    repoArgs.push(arg);
  }
}

// No-args default = Asana section scan (handled in main()).
// --branch-scan with no other args = scan all EdgeApp repos for branch-prefix PRs.
// Otherwise scan only explicitly named repos.
const noArgs = args.length === 0;
const scanRepos =
  useBranchScan && repoArgs.length === 0
    ? edgeAppRepos
    : repoArgs;
const useAsanaSection = noArgs && !useBranchScan;

// --- Helpers ---

function requireGh() {
  const check = spawnSync("gh", ["auth", "status"], { encoding: "utf8" });
  if (check.status !== 0) {
    console.error("PROMPT_GH_AUTH");
    process.exit(2);
  }
}

function ghGraphql(query, variables = {}) {
  const gqlArgs = ["api", "graphql", "-f", `query=${query}`];
  for (const [k, v] of Object.entries(variables)) {
    gqlArgs.push(typeof v === "number" ? "-F" : "-f", `${k}=${v}`);
  }
  const result = spawnSync("gh", gqlArgs, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`GraphQL failed: ${(result.stderr || "").trim()}`);
  }
  const parsed = JSON.parse(result.stdout);
  if (parsed.errors) {
    throw new Error(`GraphQL errors: ${JSON.stringify(parsed.errors)}`);
  }
  return parsed.data;
}

function ghApi(endpoint) {
  const result = spawnSync("gh", ["api", endpoint], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`gh api failed: ${(result.stderr || "").trim()}`);
  }
  return JSON.parse(result.stdout);
}

function asanaGet(path) {
  const token = process.env.ASANA_TOKEN;
  if (!token) throw new Error("ASANA_TOKEN not set");
  return new Promise((resolve, reject) => {
    const req = https.get(
      `https://app.asana.com/api/1.0${path}`,
      { headers: { Authorization: `Bearer ${token}` } },
      (res) => {
        let body = "";
        res.on("data", (d) => (body += d));
        res.on("end", () => {
          if (res.statusCode !== 200)
            return reject(new Error(`Asana ${res.statusCode}: ${body}`));
          resolve(JSON.parse(body).data);
        });
      }
    );
    req.on("error", reject);
  });
}

function extractReviewers(reviews) {
  const latestByUser = {};
  for (const r of reviews) {
    const login = r.author?.login;
    if (!login) continue;
    if (
      !latestByUser[login] ||
      new Date(r.submittedAt) > new Date(latestByUser[login].submittedAt)
    ) {
      latestByUser[login] = r;
    }
  }
  const reviewers = Object.values(latestByUser);
  return {
    approved: reviewers.some((r) => r.state === "APPROVED"),
    changesRequested: reviewers.some((r) => r.state === "CHANGES_REQUESTED"),
    reviewers: reviewers.map((r) => ({
      user: r.author.login,
      state: r.state,
    })),
  };
}

// --- Main ---

async function main() {
  requireGh();

  const results = { prs: [], errors: [] };

  // 0. No-args: pull task GIDs from the configured Asana section, filtered to
  //    incomplete tasks assigned to the current user. They flow through the
  //    same Asana resolution path below as if the user passed task URLs.
  if (useAsanaSection) {
    if (!process.env.ASANA_TOKEN) {
      results.errors.push(
        "No-args mode requires ASANA_TOKEN. Set it, pass repo/PR/task args, or use --branch-scan."
      );
    } else {
      try {
        const whoami = spawnSync(
          path.join(__dirname, "..", "..", "asana-whoami.sh"),
          [],
          { encoding: "utf8" }
        );
        if (whoami.status !== 0) {
          throw new Error(`asana-whoami.sh failed: ${(whoami.stderr || "").trim()}`);
        }
        const userGid = whoami.stdout.trim();

        const sectionTasks = await asanaGet(
          `/sections/${ASANA_PR_LAND_SECTION_GID}/tasks` +
            `?opt_fields=name,assignee.gid,completed&completed_since=now&limit=100`
        );
        for (const t of sectionTasks) {
          if (t.completed) continue;
          if (!t.assignee || t.assignee.gid !== userGid) continue;
          asanaGids.push(t.gid);
        }
      } catch (e) {
        results.errors.push(`Asana section scan: ${e.message}`);
      }
    }
  }

  // 1. Resolve Asana tasks → explicit PRs
  // GitHub integration attachments are the source of truth.
  // Walk subtasks as well, since parent tasks often carry multiple subtasks each
  // holding their own PR. Subtasks without PR attachments are silently skipped.
  // Only fall back to scanning task notes (parent only) if nothing else found.
  const ghPrRe =
    /https:\/\/github\.com\/EdgeApp\/([^/]+)\/pull\/(\d+)/g;

  async function extractPrsFromAttachments(taskGid) {
    const out = [];
    const attachments = await asanaGet(
      `/tasks/${taskGid}/attachments?opt_fields=resource_subtype,view_url`
    );
    for (const att of attachments) {
      if (att.resource_subtype !== "external" || !att.view_url) continue;
      const m = att.view_url.match(
        /^https:\/\/github\.com\/EdgeApp\/([^/]+)\/pull\/(\d+)/
      );
      if (m) {
        out.push({ repo: m[1], prNumber: Number(m[2]) });
      }
    }
    return out;
  }

  for (const gid of asanaGids) {
    try {
      const task = await asanaGet(
        `/tasks/${gid}?opt_fields=name,notes,permalink_url`
      );
      let found = false;

      // Parent task attachments
      for (const pr of await extractPrsFromAttachments(gid)) {
        explicitPrs.push(pr);
        found = true;
      }

      // Subtasks: walk each and pull PR attachments. Subtasks without PRs are
      // silently skipped (e.g. a verification-only subtask).
      const subtasks = await asanaGet(
        `/tasks/${gid}/subtasks?opt_fields=name`
      );
      for (const sub of subtasks) {
        for (const pr of await extractPrsFromAttachments(sub.gid)) {
          explicitPrs.push(pr);
          found = true;
        }
      }

      // Fall back to parent task notes only if nothing else matched.
      if (!found) {
        let match;
        while ((match = ghPrRe.exec(task.notes || "")) !== null) {
          explicitPrs.push({ repo: match[1], prNumber: Number(match[2]) });
          found = true;
        }
        ghPrRe.lastIndex = 0;
      }

      if (!found) {
        results.errors.push(
          `Asana task ${gid} (${task.name}): no GitHub PR link found on task or subtasks`
        );
      }
    } catch (e) {
      results.errors.push(`Asana task ${gid}: ${e.message}`);
    }
  }

  // 2. Fetch explicit PRs directly (no branch-prefix filter)
  for (const { repo, prNumber } of explicitPrs) {
    try {
      const pr = ghApi(`repos/EdgeApp/${repo}/pulls/${prNumber}`);
      const reviewsRaw = ghApi(
        `repos/EdgeApp/${repo}/pulls/${prNumber}/reviews`
      );
      const { approved, changesRequested, reviewers } = extractReviewers(
        reviewsRaw.map((r) => ({
          author: { login: r.user?.login },
          state: r.state,
          submittedAt: r.submitted_at,
        }))
      );
      results.prs.push({
        repo,
        prNumber: pr.number,
        branch: pr.head.ref,
        title: pr.title,
        updatedAt: pr.updated_at,
        approved,
        changesRequested,
        reviewers,
      });
    } catch (e) {
      results.errors.push(`${repo}#${prNumber}: ${e.message}`);
    }
  }

  // 3. Scan repos by branch prefix (original behavior)
  if (scanRepos.length > 0) {
    const repoFragments = scanRepos
      .map((repo, i) => {
        const alias = `repo${i}`;
        return `${alias}: repository(owner: "EdgeApp", name: "${repo}") {
    name
    pullRequests(first: 100, states: OPEN) {
      nodes {
        number
        title
        headRefName
        updatedAt
        reviews(last: 30) {
          nodes {
            author { login }
            state
            submittedAt
          }
        }
      }
    }
  }`;
      })
      .join("\n  ");

    const query = `{ ${repoFragments} }`;

    let data;
    try {
      data = ghGraphql(query);
    } catch (e) {
      console.error("ERROR:", e.message);
      process.exit(1);
    }

    for (const key of Object.keys(data)) {
      const repoData = data[key];
      if (!repoData) continue;
      const repo = repoData.name;

      for (const pr of repoData.pullRequests.nodes) {
        if (!pr.headRefName.startsWith(`${BRANCH_PREFIX}/`)) continue;

        const { approved, changesRequested, reviewers } = extractReviewers(
          pr.reviews.nodes
        );

        results.prs.push({
          repo,
          prNumber: pr.number,
          branch: pr.headRefName,
          title: pr.title,
          updatedAt: pr.updatedAt,
          approved,
          changesRequested,
          reviewers,
        });
      }
    }
  }

  // Dedupe by repo+prNumber (in case Asana/explicit overlap with scan)
  const seen = new Set();
  results.prs = results.prs.filter((pr) => {
    const key = `${pr.repo}#${pr.prNumber}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  results.prs.sort(
    (a, b) =>
      a.repo.localeCompare(b.repo) || a.branch.localeCompare(b.branch)
  );
  console.log(JSON.stringify(results, null, 2));
}

main().catch((e) => {
  console.error("ERROR:", e.message);
  process.exit(1);
});
