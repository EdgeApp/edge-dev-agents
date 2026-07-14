#!/usr/bin/env node
// pr-land-prepare.sh
// Prepares a branch for merge: checkout, autosquash, rebase, verify.
// Uses edge-repo.js for shared utilities (no GitHub API calls needed).
//
// Usage: echo '[{"repo":"edge-react-gui","branch":"jon/feature"}]' | ./pr-land-prepare.sh
//
// For each branch:
//   1. Checkout + fetch
//   2. Autosquash fixup commits
//   3. Rebase onto upstream (repo's default branch via origin/HEAD; origin/develop for GUI)
//   4. Detect conflicts: code OR CHANGELOG = rebase left IN PROGRESS for the
//      agent to resolve semantically (abort + skip only if not resolvable)
//   5. Run full verification (CHANGELOG + code)
//
// Exit codes:
//   0 = At least one branch prepared (or has resolvable CHANGELOG conflict)
//   1 = All branches failed (verification or other errors, none ready)
//
// Output: JSON with results for each branch

const { execSync } = require("child_process");
const { existsSync, readFileSync } = require("fs");
const path = require("path");
const {
  getRepoDir,
  getUpstreamBranch,
  runGit,
  parseConflictFiles,
  isChangelogOnly,
  runVerification,
  installAndPrepare,
} = require(path.join(__dirname, "edge-repo.js"));

// Detect NEW CHANGELOG entries (added vs baseRef) placed under a DATED
// released heading instead of `## Unreleased` or `## X.Y.Z (staging)`.
// Pure inspection — returns an array of { line, text, section } misplaced entries.
// Does not modify the repo. Empty array means no concerns.
function checkChangelogPlacement(repoDir, baseRef) {
  const changelogPath = path.join(repoDir, "CHANGELOG.md");
  if (!existsSync(changelogPath)) return [];

  let content;
  try {
    content = readFileSync(changelogPath, "utf8");
  } catch (e) {
    return [];
  }
  const lines = content.split("\n");

  // Build ordered list of section headings with kind: unreleased | staging | released
  const sections = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let kind = null;
    if (/^## Unreleased/i.test(line)) kind = "unreleased";
    else if (/^## .+\(staging\)/i.test(line)) kind = "staging";
    else if (/^## \d+\.\d+\.\d+/.test(line)) kind = "released";
    if (kind != null) {
      sections.push({ startLine: i + 1, text: line.replace(/^##\s*/, "").trim(), kind });
    }
  }

  const sectionForLine = (lineNum) => {
    let last = null;
    for (const s of sections) {
      if (s.startLine <= lineNum) last = s;
      else break;
    }
    return last;
  };

  // Diff-added lines on HEAD side
  let diffOut;
  try {
    diffOut = execSync(
      `git diff --unified=0 --no-color ${baseRef}...HEAD -- CHANGELOG.md`,
      { cwd: repoDir, encoding: "utf8" }
    );
  } catch (e) {
    return [];
  }

  const misplaced = [];
  let headLine = 0;
  for (const raw of diffOut.split("\n")) {
    const h = raw.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (h) {
      headLine = parseInt(h[1], 10);
      continue;
    }
    if (raw.startsWith("+++") || raw.startsWith("---")) continue;
    if (raw.startsWith("+")) {
      const text = raw.slice(1);
      if (/^- (added|changed|deprecated|fixed|removed|security):/i.test(text)) {
        const sect = sectionForLine(headLine);
        if (sect != null && sect.kind === "released") {
          misplaced.push({ line: headLine, text, section: sect.text });
        }
      }
      headLine++;
    } else if (raw.startsWith("-")) {
      // deleted line on BASE side — do not advance HEAD line counter
    } else if (raw.length > 0) {
      headLine++;
    }
  }

  return misplaced;
}

// Locate a worktree (other than the canonical clone) that currently has
// `branch` checked out. Tools like agent-watcher leave such worktrees behind,
// and git refuses to `checkout` a branch already held by another worktree.
// In that case prepare must operate inside that worktree — its content is the
// same branch. Returns the worktree path, or null if none holds the branch.
function findWorktreeForBranch(repoDir, branch) {
  const res = runGit(["worktree", "list", "--porcelain"], repoDir, {
    allowFailure: true,
  });
  if (!res.success || !res.stdout) return null;
  const target = `refs/heads/${branch}`;
  let currentPath = null;
  for (const line of res.stdout.split("\n")) {
    if (line.startsWith("worktree ")) {
      currentPath = line.slice("worktree ".length).trim();
    } else if (line.startsWith("branch ")) {
      const ref = line.slice("branch ".length).trim();
      if (ref === target && currentPath) return currentPath;
    }
  }
  return null;
}

function describeBranchState(repoDir, branch) {
  const parts = [];
  const local = runGit(["rev-parse", branch], repoDir, { allowFailure: true });
  if (local.success) {
    parts.push(`Local commit (${branch}): ${local.stdout}`);
  } else {
    parts.push(`Local branch "${branch}" missing`);
  }

  const remote = runGit(["rev-parse", `origin/${branch}`], repoDir, { allowFailure: true });
  if (remote.success) {
    parts.push(`Remote commit (origin/${branch}): ${remote.stdout}`);
  } else {
    parts.push(`Remote branch origin/${branch} missing`);
  }

  const status = runGit(["status", "-sb"], repoDir, { allowFailure: true });
  if (status.stdout) {
    parts.push(`Status: ${status.stdout.trim()}`);
  }
  return parts.join("\n");
}

async function prepareBranch(repo, branch) {
  const canonicalDir = getRepoDir(repo);
  let repoDir = canonicalDir;
  const result = {
    repo,
    branch,
    repoDir,
    status: "unknown",
    message: "",
  };

  console.error(`\n=== Preparing ${repo}/${branch} ===`);

  // Step 1: Ensure the canonical clone exists
  if (!existsSync(path.join(canonicalDir, ".git"))) {
    console.error(`Cloning ${repo}...`);
    try {
      execSync(`git clone git@github.com:EdgeApp/${repo}.git "${canonicalDir}"`, {
        stdio: "inherit",
      });
    } catch (e) {
      result.status = "clone_failed";
      result.message = "Failed to clone repository";
      return result;
    }
  }

  // If the branch is checked out in another worktree (left behind by an
  // agent-watcher run), git won't let the canonical clone check it out.
  // Landing always operates on the PRIMARY checkout: free the branch by
  // detaching the worktree's HEAD when its tree is clean. A dirty worktree
  // means unfinished work — fail with a clear message instead of landing
  // inside a stale orch workspace.
  const wtDir = findWorktreeForBranch(canonicalDir, branch);
  if (wtDir && path.resolve(wtDir) !== path.resolve(canonicalDir)) {
    console.error(`Branch ${branch} is held by worktree: ${wtDir}`);
    let wtDirty = true;
    try {
      wtDirty =
        execSync(`git -C "${wtDir}" status --porcelain`, { encoding: "utf8" }).trim() !== "";
    } catch (e) {
      // status failure → treat as dirty and refuse below.
    }
    if (wtDirty) {
      result.status = "checkout_failed";
      result.message = `Branch is held by DIRTY worktree ${wtDir} — resolve or stash its changes (or remove the worktree) before landing`;
      return result;
    }
    try {
      execSync(`git -C "${wtDir}" checkout --detach`, { stdio: "pipe" });
      console.error(`Worktree is clean — detached its HEAD to free the branch; operating on the primary checkout.`);
    } catch (e) {
      result.status = "checkout_failed";
      result.message = `Failed to detach worktree ${wtDir}: ${e.message}`;
      return result;
    }
  }
  console.error(`Directory: ${repoDir}`);

  // Resolve upstream AFTER clone + worktree resolution so the repo's actual
  // default branch (origin/HEAD: master, main, …) can be inspected on disk.
  const upstream = getUpstreamBranch(repo, repoDir);
  console.error(`Upstream: ${upstream}`);

  // Step 2: Fetch and checkout.
  // Dirty-tree policy: prepare operates on the user's primary checkout, which
  // may hold in-progress local work. Auto-stash it under a labeled stash so
  // checkout can proceed, and surface the stash in the JSON so it is never
  // silently lost (recover: `git stash list | grep pr-land-autostash`).
  console.error(`Fetching and checking out ${branch}...`);
  try {
    const dirty = runGit(["status", "--porcelain"], repoDir, {
      allowFailure: true,
    });
    if (dirty.success && dirty.stdout.trim().length > 0) {
      const onBranch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], repoDir, {
        allowFailure: true,
      });
      const stashMsg = `pr-land-autostash ${new Date().toISOString()} (was on ${onBranch.stdout || "unknown"})`;
      runGit(["stash", "push", "--include-untracked", "-m", stashMsg], repoDir);
      console.error(`⚠ Dirty working tree — auto-stashed: "${stashMsg}"`);
      result.autostash = stashMsg;
    }
    runGit(["fetch", "origin"], repoDir);
    runGit(["fetch", "origin", branch], repoDir, { allowFailure: true });
    runGit(["checkout", branch], repoDir);
    runGit(["pull", "--ff-only", "origin", branch], repoDir, {
      allowFailure: true,
    });
  } catch (e) {
    result.status = "checkout_failed";
    result.message = e.message;
    return result;
  }

  // Step 3: Autosquash fixup commits
  console.error("Autosquashing fixup commits...");
  try {
    const baseResult = runGit(["merge-base", upstream, "HEAD"], repoDir);
    const base = baseResult.stdout;
    runGit(["rebase", "-i", base, "--autosquash"], repoDir);
    console.error("✓ Autosquash complete");
  } catch (e) {
    runGit(["rebase", "--abort"], repoDir, { allowFailure: true });
    result.status = "autosquash_failed";
    result.message = e.message;
    return result;
  }

  // Step 4: Rebase onto upstream
  console.error(`Rebasing onto ${upstream}...`);
  const rebaseResult = runGit(["rebase", upstream], repoDir, {
    allowFailure: true,
  });

  if (!rebaseResult.success) {
    const combinedOutput = rebaseResult.stdout + "\n" + rebaseResult.stderr;
    const conflictFiles = parseConflictFiles(combinedOutput);

    console.error(`Conflict detected in: ${conflictFiles.join(", ")}`);

    if (conflictFiles.some((f) => !f.includes("CHANGELOG"))) {
      // Leave the rebase IN PROGRESS (do NOT abort) so the agent can resolve
      // code conflicts semantically when confidently determinable, then
      // `git add` + `git rebase --continue` (regenerating lockfiles if deps
      // changed) and re-run prepare. The agent aborts + skips only when the
      // resolution is not confidently determinable. Mirrors CHANGELOG conflicts.
      console.error("\n=== Code conflict — rebase left IN PROGRESS for resolution ===");
      for (const f of conflictFiles) {
        console.error(`  - ${f}`);
      }
      result.status = "code_conflict";
      result.message =
        "Code conflict — resolve in place (git add + GIT_EDITOR=true git rebase --continue, regenerate lockfiles if deps changed), then re-run prepare; or `git rebase --abort` and skip if not confidently resolvable";
      result.conflictFiles = conflictFiles;
      return result;
    }

    if (isChangelogOnly(conflictFiles)) {
      console.error(
        "\nCHANGELOG-only conflict. Rebase left in conflict state — resolve semantically, `git add CHANGELOG.md && GIT_EDITOR=true git rebase --continue`, then re-run prepare to verify."
      );
      // Do NOT abort the rebase: the agent resolves in place and runs --continue.
      result.status = "changelog_conflict";
      result.message = "CHANGELOG conflict - resolve semantically, continue rebase, then re-run";
      result.conflictFiles = conflictFiles;
      return result;
    }
  }

  console.error("✓ Rebase complete");

  // Step 5: Install dependencies and prepare
  try {
    installAndPrepare(repoDir);
  } catch (e) {
    result.status = "install_failed";
    result.message = `Dependency install failed: ${e.message}`;
    return result;
  }

  // Step 6: Run verification (lint scoped to files changed vs upstream).
  // requireChangelog: every landed PR must have updated CHANGELOG.md — the
  // diff-based existence check is format-agnostic (works for Unreleased-style
  // AND legacy versions-only CHANGELOGs).
  console.error("\nRunning verification...");
  const verifyResult = runVerification(repoDir, upstream, {
    skipInstall: true,
    requireChangelog: true,
  });

  if (!verifyResult.success) {
    console.error("Branch state:");
    console.error(describeBranchState(repoDir, branch));
    result.status = "verification_failed";
    result.failedStep = verifyResult.failedStep;
    result.logPath = verifyResult.logPath;
    result.message = `Verification failed (exit code ${verifyResult.exitCode})${
      verifyResult.failedStep ? ` at step: ${verifyResult.failedStep}` : ""
    }${verifyResult.logPath ? ` — log: ${verifyResult.logPath}` : ""}`;
    return result;
  }

  // Step 7: Inspect CHANGELOG placement — warn if new entries landed under a
  // dated released heading instead of `## Unreleased` or staging. Non-fatal:
  // the agent prompts the user to decide (leave / move to Unreleased / move to
  // staging) before pushing.
  const misplaced = checkChangelogPlacement(repoDir, upstream);
  if (misplaced.length > 0) {
    console.error(
      `\n⚠ CHANGELOG placement warning: ${misplaced.length} new entry(s) under a released heading:`
    );
    for (const m of misplaced) {
      console.error(`  line ${m.line} in "${m.section}": ${m.text}`);
    }
    result.placementWarnings = misplaced;
  }

  result.status = "ready";
  result.message = "Branch prepared and verified successfully";
  return result;
}


// Per-repo land mutex (repo-land-lock.sh): serializes rebase/merge/publish trains
// across sessions — land-on-approval means two approved tasks in one repo can land
// concurrently, and this script's sequencing is only per-invocation. Exit 75 = busy.
const LAND_LOCK = `${process.env.HOME}/.cursor/skills/pr-land/scripts/repo-land-lock.sh`;
const LAND_LOCK_OWNER = process.env.AGENT_SESSION_UUID || `op-${process.env.USER || "shell"}`;
function landLock(cmd, repo) {
  const r = require("child_process").spawnSync(LAND_LOCK, [cmd, "--repo", repo, "--owner", LAND_LOCK_OWNER], { stdio: ["ignore", "pipe", "inherit"] });
  return (r.status || 0) === 0;
}

async function main() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }

  const branches = JSON.parse(input);

  for (const repo of [...new Set(branches.map((b) => b.repo))]) {
    if (!landLock("acquire", repo)) {
      console.error(`pr-land-prepare: land lock busy for ${repo} — another session is landing there; wait and retry.`);
      process.exit(75);
    }
  }
  const results = {
    prepared: [],
    failed: [],
    skipped: [],
    codeConflicts: [],
    changelogConflicts: [],
  };

  let exitCode = 0;

  for (const { repo, branch } of branches) {
    const result = await prepareBranch(repo, branch);

    switch (result.status) {
      case "ready":
        results.prepared.push(result);
        break;
      case "code_conflict":
        results.codeConflicts.push(result);
        break;
      case "changelog_conflict":
        results.changelogConflicts.push(result);
        break;
      default:
        results.failed.push(result);
        exitCode = Math.max(exitCode, 1);
    }
  }

  // Summary
  console.error("\n=== Prepare Summary ===");
  if (results.prepared.length > 0) {
    console.error(`Ready (${results.prepared.length}):`);
    for (const r of results.prepared) {
      const warn = r.placementWarnings?.length
        ? ` ⚠ ${r.placementWarnings.length} CHANGELOG placement warning(s)`
        : "";
      console.error(`  ✓ ${r.repo}/${r.branch}${warn}`);
    }
  }
  if (results.codeConflicts.length > 0) {
    console.error(
      `\nCode conflicts — rebase left in progress, resolve in place then re-run (${results.codeConflicts.length}):`
    );
    for (const r of results.codeConflicts) {
      console.error(
        `  ⚠ ${r.repo}/${r.branch}: ${r.conflictFiles?.join(", ")}`
      );
    }
  }
  if (results.skipped.length > 0) {
    console.error(`\nSkipped (${results.skipped.length}):`);
    for (const r of results.skipped) {
      console.error(
        `  ⚠ ${r.repo}/${r.branch}: ${r.conflictFiles?.join(", ") || r.message}`
      );
    }
  }
  if (results.changelogConflicts.length > 0) {
    console.error(
      `\nCHANGELOG conflicts (${results.changelogConflicts.length}):`
    );
    for (const r of results.changelogConflicts) {
      console.error(
        `  ⚠ ${r.repo}/${r.branch}: Resolve semantically, then re-run`
      );
    }
  }
  if (results.failed.length > 0) {
    console.error(`\nFailed (${results.failed.length}):`);
    for (const r of results.failed) {
      console.error(`  ✗ ${r.repo}/${r.branch}: ${r.message}`);
    }
  }

  const autostashed = [
    ...results.prepared,
    ...results.skipped,
    ...results.codeConflicts,
    ...results.changelogConflicts,
    ...results.failed,
  ].filter((r) => r.autostash);
  if (autostashed.length > 0) {
    console.error(`\nAuto-stashed dirty trees (${autostashed.length}) — recover with \`git stash list | grep pr-land-autostash\`:`);
    for (const r of autostashed) {
      console.error(`  ⚠ ${r.repo}: "${r.autostash}"`);
    }
  }

  if (
    results.prepared.length === 0 &&
    results.changelogConflicts.length === 0 &&
    results.codeConflicts.length === 0 &&
    exitCode === 0
  ) {
    exitCode = 1;
  }

  console.log(JSON.stringify(results, null, 2));
  process.exit(exitCode);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
