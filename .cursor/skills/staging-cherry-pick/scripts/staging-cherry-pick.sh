#!/usr/bin/env node
// staging-cherry-pick.sh
// Cherry-picks individual commits from merged PRs onto the staging branch.
//
// Usage: echo '[{"repo":"edge-react-gui","prNumber":123,"mergeSha":"abc123"}]' | ./staging-cherry-pick.sh
//
// For each PR:
//   1. Determine merge commit SHA (from input or by querying GitHub)
//   2. Extract non-merge commits: git log <merge>^1..<merge>^2
//   3. Pull latest staging branch
//   4. Cherry-pick each commit individually (oldest first)
//   5. Report results
//
// Exit codes:
//   0 = All cherry-picks succeeded
//   1 = Error (auth, git failure, etc.)
//   3 = Cherry-pick conflict (agent must resolve)

const { spawnSync } = require("child_process");
const path = require("path");
const { getRepoDir, runGit, ghApi } = require(
  path.join(__dirname, "..", "..", "pr-land", "scripts", "edge-repo.js")
);

// Verify gh auth
const authCheck = spawnSync("gh", ["auth", "status"], { encoding: "utf8" });
if (authCheck.status !== 0) {
  console.error("PROMPT_GH_AUTH");
  process.exit(2);
}

function getMergeCommit(repo, prNumber) {
  const data = ghApi(`repos/EdgeApp/${repo}/pulls/${prNumber}`);
  if (!data.merged) {
    return { error: `PR #${prNumber} is not merged` };
  }
  return { sha: data.merge_commit_sha };
}

function getCommitsToCherry(repoDir, mergeSha) {
  // Extract non-merge commits from the PR: merge^1..merge^2
  // This gives us the branch commits in chronological order
  const result = runGit(
    ["log", "--reverse", "--format=%H %s", `${mergeSha}^1..${mergeSha}^2`],
    repoDir,
    { allowFailure: true }
  );

  if (!result.success || !result.stdout) {
    return [];
  }

  return result.stdout.split("\n").filter(Boolean).map((line) => {
    const spaceIdx = line.indexOf(" ");
    return {
      sha: line.slice(0, spaceIdx),
      message: line.slice(spaceIdx + 1),
    };
  });
}

async function main() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }

  const prs = JSON.parse(input);
  const results = {
    cherryPicked: [],
    skipped: [],
    conflict: null,
    status: "complete",
  };

  let exitCode = 0;
  let stagingCheckedOut = false;
  let currentRepoDir = null;

  for (let i = 0; i < prs.length; i++) {
    const { repo, prNumber, mergeSha: inputMergeSha } = prs[i];
    const repoDir = getRepoDir(repo);
    currentRepoDir = repoDir;

    console.error(
      `\n=== Cherry-picking ${repo}#${prNumber} to staging [${i + 1}/${prs.length}] ===`
    );

    // Get merge commit SHA
    let mergeSha = inputMergeSha;
    if (!mergeSha) {
      console.error("Fetching merge commit SHA...");
      const mergeInfo = getMergeCommit(repo, prNumber);
      if (mergeInfo.error) {
        console.error(`⚠ ${mergeInfo.error} — skipping`);
        results.skipped.push({ repo, prNumber, reason: mergeInfo.error });
        continue;
      }
      mergeSha = mergeInfo.sha;
    }
    console.error(`Merge commit: ${mergeSha.slice(0, 10)}`);

    // Fetch latest
    runGit(["fetch", "origin"], repoDir);

    // Get commits to cherry-pick
    const commits = getCommitsToCherry(repoDir, mergeSha);
    if (commits.length === 0) {
      console.error("⚠ No commits found to cherry-pick — skipping");
      results.skipped.push({ repo, prNumber, reason: "No commits found" });
      continue;
    }

    console.error(
      `Found ${commits.length} commit(s):\n${commits.map((c) => `  ${c.sha.slice(0, 10)} ${c.message}`).join("\n")}`
    );

    // Checkout staging (only once per repo)
    if (!stagingCheckedOut) {
      console.error("Checking out staging branch...");
      const checkoutResult = runGit(["checkout", "staging"], repoDir, {
        allowFailure: true,
      });
      if (!checkoutResult.success) {
        // Try tracking remote
        const trackResult = runGit(
          ["checkout", "-b", "staging", "origin/staging"],
          repoDir,
          { allowFailure: true }
        );
        if (!trackResult.success) {
          console.error(`✗ Cannot checkout staging: ${trackResult.stderr}`);
          results.skipped.push({
            repo,
            prNumber,
            reason: "Cannot checkout staging branch",
          });
          continue;
        }
      }

      console.error("Pulling latest staging...");
      const pullResult = runGit(["pull", "origin", "staging"], repoDir, {
        allowFailure: true,
      });
      if (!pullResult.success) {
        // Reset to remote if pull fails (e.g. diverged)
        runGit(["reset", "--hard", "origin/staging"], repoDir);
      }
      stagingCheckedOut = true;
    }

    // Cherry-pick each commit individually
    for (let j = 0; j < commits.length; j++) {
      const commit = commits[j];
      console.error(
        `Cherry-picking [${j + 1}/${commits.length}]: ${commit.sha.slice(0, 10)} ${commit.message}`
      );

      const cpResult = runGit(["cherry-pick", commit.sha], repoDir, {
        allowFailure: true,
      });

      if (!cpResult.success) {
        // Check if it's a conflict
        const statusResult = runGit(["status", "--porcelain"], repoDir, {
          allowFailure: true,
        });
        const conflictFiles = statusResult.stdout
          .split("\n")
          .filter((l) => l.startsWith("UU ") || l.startsWith("AA "))
          .map((l) => l.slice(3).trim());

        if (conflictFiles.length > 0) {
          const isChangelogOnly =
            conflictFiles.length > 0 &&
            conflictFiles.every(
              (f) => f === "CHANGELOG.md" || f.endsWith("/CHANGELOG.md")
            );

          if (isChangelogOnly) {
            console.error(
              "\n=== CHANGELOG conflict — agent resolution needed ==="
            );
            console.error(`Files: ${conflictFiles.join(", ")}`);
            console.error(
              `Commit: ${commit.sha.slice(0, 10)} ${commit.message}`
            );
            console.error("\nTo resolve:");
            console.error(
              `  1. Read ${path.join(repoDir, "CHANGELOG.md")} with conflict markers`
            );
            console.error(
              "  2. Resolve semantically (upstream/staging entries first, then ours)"
            );
            console.error(
              "  3. git add CHANGELOG.md && git cherry-pick --continue"
            );
            console.error("  4. Re-run staging-cherry-pick for remaining PRs");

            results.conflict = {
              repo,
              prNumber,
              repoDir,
              commit: commit.sha,
              commitMessage: commit.message,
              conflictFiles,
              type: "changelog",
              remainingCommits: commits.slice(j + 1),
              remainingPRs: prs.slice(i + 1),
            };
            results.status = "changelog_conflict";
            exitCode = 3;
          } else {
            console.error(`✗ Code conflict in: ${conflictFiles.join(", ")}`);
            console.error("Aborting cherry-pick...");
            runGit(["cherry-pick", "--abort"], repoDir, {
              allowFailure: true,
            });

            results.conflict = {
              repo,
              prNumber,
              repoDir,
              commit: commit.sha,
              commitMessage: commit.message,
              conflictFiles,
              type: "code",
            };
            results.status = "code_conflict";
            exitCode = 1;
          }
          break;
        }

        // Not a conflict — some other failure
        console.error(`✗ Cherry-pick failed: ${cpResult.stderr}`);

        // Check if it's an empty commit (already applied)
        if (
          cpResult.stderr.includes("empty") ||
          cpResult.stdout.includes("empty")
        ) {
          console.error("  (Commit already applied — skipping)");
          runGit(["cherry-pick", "--skip"], repoDir, { allowFailure: true });
          continue;
        }

        runGit(["cherry-pick", "--abort"], repoDir, { allowFailure: true });
        results.skipped.push({
          repo,
          prNumber,
          reason: `Cherry-pick failed: ${cpResult.stderr}`,
        });
        break;
      }

      console.error(`  ✓ Applied`);
    }

    if (exitCode !== 0) break;

    // If we got here without conflict, all commits cherry-picked
    if (!results.conflict) {
      results.cherryPicked.push({
        repo,
        prNumber,
        mergeSha,
        commits: commits.map((c) => ({
          sha: c.sha.slice(0, 10),
          message: c.message,
        })),
      });
    }
  }

  // Summary
  console.error("\n=== Cherry-Pick Summary ===");
  if (results.cherryPicked.length > 0) {
    console.error(`Cherry-picked (${results.cherryPicked.length}):`);
    for (const r of results.cherryPicked) {
      console.error(
        `  ✓ ${r.repo}#${r.prNumber} (${r.commits.length} commit(s))`
      );
    }
  }
  if (results.skipped.length > 0) {
    console.error(`Skipped (${results.skipped.length}):`);
    for (const r of results.skipped) {
      console.error(`  ⚠ ${r.repo}#${r.prNumber}: ${r.reason}`);
    }
  }
  if (results.conflict) {
    console.error(
      `\nConflict: ${results.conflict.repo}#${results.conflict.prNumber} (${results.conflict.type})`
    );
  }

  console.log(JSON.stringify(results, null, 2));
  process.exit(exitCode);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
