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
//   3. Rebase onto upstream (origin/master or origin/develop for GUI)
//   4. Detect conflicts: code files = SKIP, CHANGELOG-only = report
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
  const repoDir = getRepoDir(repo);
  const upstream = getUpstreamBranch(repo);
  const result = {
    repo,
    branch,
    repoDir,
    status: "unknown",
    message: "",
  };

  console.error(`\n=== Preparing ${repo}/${branch} ===`);
  console.error(`Directory: ${repoDir}`);

  // Step 1: Ensure repo exists
  if (!existsSync(path.join(repoDir, ".git"))) {
    console.error(`Cloning ${repo}...`);
    try {
      execSync(`git clone git@github.com:EdgeApp/${repo}.git "${repoDir}"`, {
        stdio: "inherit",
      });
    } catch (e) {
      result.status = "clone_failed";
      result.message = "Failed to clone repository";
      return result;
    }
  }

  // Step 2: Fetch and checkout
  console.error(`Fetching and checking out ${branch}...`);
  try {
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
      console.error("\n=== Skipping: Code conflict detected ===");
      for (const f of conflictFiles) {
        console.error(`  - ${f}`);
      }
      runGit(["rebase", "--abort"], repoDir, { allowFailure: true });
      result.status = "code_conflict";
      result.message = "Code conflict — skipped";
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

  // Step 6: Run verification (lint scoped to files changed vs upstream)
  console.error("\nRunning verification...");
  const verifyResult = runVerification(repoDir, upstream, {
    skipInstall: true,
  });

  if (!verifyResult.success) {
    console.error("Branch state:");
    console.error(describeBranchState(repoDir, branch));
    result.status = "verification_failed";
    result.message = `Verification failed (exit code ${verifyResult.exitCode})`;
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

async function main() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }

  const branches = JSON.parse(input);
  const results = {
    prepared: [],
    failed: [],
    skipped: [],
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
        results.skipped.push(result);
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
  if (results.skipped.length > 0) {
    console.error(`\nSkipped — code conflicts (${results.skipped.length}):`);
    for (const r of results.skipped) {
      console.error(
        `  ⚠ ${r.repo}/${r.branch}: ${r.conflictFiles?.join(", ")}`
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

  if (
    results.prepared.length === 0 &&
    results.changelogConflicts.length === 0 &&
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
