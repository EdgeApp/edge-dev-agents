#!/usr/bin/env node
// pr-land-extract-asana-task.sh
// Extracts Asana task GIDs from PR bodies so /pr-land can skip loading full descriptions.
// Input: JSON array of {repo, prNumber}. Output: JSON object {tasks: [...], missing: [...]}, where each entry contains label/repo info.
//
// Each PR body's Asana link is resolved to its PARENT task when one exists, so
// /pr-land updates the feature parent (the thing that represents the unit of
// work) rather than the per-repo subtask. Walks up only one level. Output
// deduplicated by taskGid so sibling subtasks collapse into a single parent
// entry. Falls back to the original GID (no walk-up) if ASANA_TOKEN is unset.
//
// The script is intentionally terse: it only emits structured JSON and does not print raw PR bodies.
const { execSync } = require("child_process");
const https = require("https");
const path = require("path");

async function readStdin() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }
  return input.trim();
}

function fetchPrBody(repo, prNumber) {
  const endpoint = `repos/EdgeApp/${repo}/pulls/${prNumber}`;
  const result = execSync(`gh api "${endpoint}" --jq '.body'`, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return result.trim();
}

function buildLabel(repo, prNumber) {
  return `${repo}#${prNumber}`;
}

function asanaGetTask(gid) {
  const token = process.env.ASANA_TOKEN;
  if (!token) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    const req = https.get(
      `https://app.asana.com/api/1.0/tasks/${gid}?opt_fields=parent.gid`,
      { headers: { Authorization: `Bearer ${token}` } },
      (res) => {
        let body = "";
        res.on("data", (d) => (body += d));
        res.on("end", () => {
          if (res.statusCode !== 200)
            return reject(new Error(`Asana ${res.statusCode}: ${body}`));
          try {
            resolve(JSON.parse(body).data);
          } catch (e) {
            reject(e);
          }
        });
      }
    );
    req.on("error", reject);
  });
}

async function resolveToParent(gid) {
  try {
    const data = await asanaGetTask(gid);
    if (data && data.parent && data.parent.gid) return data.parent.gid;
  } catch (err) {
    console.error(
      `Warning: failed to resolve parent for task ${gid}: ${err.message}. Using original GID.`
    );
  }
  return gid;
}

async function main() {
  const input = await readStdin();
  if (!input) {
    console.error("Error: no input received (expecting JSON array with repo/prNumber)");
    process.exit(2);
  }

  let entries;
  try {
    entries = JSON.parse(input);
  } catch (err) {
    console.error("Error: failed to parse JSON input");
    process.exit(2);
  }

  const regex = /https:\/\/app\.asana\.com\/(?:\d+\/\d+\/(?:project\/\d+\/)?(?:task\/)?(\d+))/i;
  const tasks = [];
  const missing = [];

  for (const { repo, prNumber } of entries) {
    const label = buildLabel(repo, prNumber);
    let body;
    try {
      body = fetchPrBody(repo, prNumber);
    } catch (err) {
      missing.push({
        label,
        reason: `Failed to fetch PR body: ${err.message}`,
      });
      continue;
    }

    if (!body) {
      missing.push({
        label,
        reason: "PR body empty",
      });
      continue;
    }

    const match = body.match(regex);
    if (match) {
      const originalGid = match[1];
      const resolvedGid = await resolveToParent(originalGid);
      tasks.push({
        taskGid: resolvedGid,
        label,
      });
    } else {
      missing.push({
        label,
        reason: "No Asana link found",
      });
    }
  }

  // Dedupe by taskGid: sibling subtasks collapse into one parent entry.
  // Preserve first-seen order and merge labels for traceability.
  const seen = new Map();
  for (const entry of tasks) {
    const existing = seen.get(entry.taskGid);
    if (existing) {
      existing.label = `${existing.label}, ${entry.label}`;
    } else {
      seen.set(entry.taskGid, { taskGid: entry.taskGid, label: entry.label });
    }
  }
  const dedupedTasks = Array.from(seen.values());

  console.log(JSON.stringify({ tasks: dedupedTasks, missing }, null, 2));
  process.exit(0);
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
