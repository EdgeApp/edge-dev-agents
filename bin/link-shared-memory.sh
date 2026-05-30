#!/usr/bin/env bash
# link-shared-memory.sh
# Symlink the canonical shared memory notes (~/.claude/memory-shared/*.md) into
# the Claude auto-memory directory for a given working directory, and maintain a
# delimited "shared" block in that dir's MEMORY.md. Repo-specific notes (real
# files you add to the memory dir) are left untouched.
#
# Why: Claude auto-memory is keyed per project (git repo root, or cwd outside a
# repo) at ~/.claude/projects/<sanitized-path>/memory/ with no global tier. This
# script gives cross-cutting notes (orchestration, user-role) a single source of
# truth, surfaced wherever you choose to link them.
#
# Usage:
#   link-shared-memory.sh [path]     # path defaults to $PWD
# Idempotent: safe to re-run; refreshes symlinks and the shared block.

set -euo pipefail

SHARED_DIR="$HOME/.claude/memory-shared"
TARGET_CWD="${1:-$PWD}"

[[ -d "$SHARED_DIR" ]] || { echo "Error: shared store $SHARED_DIR not found" >&2; exit 1; }

# Resolve the target memory dir. Claude keys auto-memory by the MAIN git repo
# root: a session in a worktree reads memory from the main repo's dir, NOT the
# worktree path. Verified empirically (a worktree `claude -p` session loaded the
# git-root memory word but not a worktree-path one). So resolve via the common
# git dir (worktrees -> main repo root), else the cwd outside a repo.
cwd_abs="$(cd "$TARGET_CWD" && pwd)"
common="$(git -C "$TARGET_CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$common" ]]; then gitroot="$(cd "$(dirname "$common")" && pwd)"; else gitroot="$cwd_abs"; fi

roots=("$gitroot")

link_into() {
  local root="$1" san memdir base f
  # Sanitize the way Claude names project dirs: every "/" AND "." becomes "-"
  # (e.g. /Users/jon/.agent-worktrees -> -Users-jon--agent-worktrees).
  san="$(printf '%s' "$root" | sed 's#[/.]#-#g')"
  memdir="$HOME/.claude/projects/$san/memory"
  mkdir -p "$memdir"
  # Symlink each shared note (skip a MEMORY.md in the store, if any).
  for f in "$SHARED_DIR"/*.md; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "MEMORY.md" ]] && continue
    ln -sfn "$f" "$memdir/$base"
  done
  # Rebuild the delimited shared block in MEMORY.md, preserving any other lines.
  MEMDIR="$memdir" SHARED_DIR="$SHARED_DIR" node -e '
    const fs = require("fs"); const path = require("path");
    const memDir = process.env.MEMDIR, sharedDir = process.env.SHARED_DIR;
    const START = "<!-- shared-memory:start -->", END = "<!-- shared-memory:end -->";
    const files = fs.readdirSync(sharedDir).filter(f => f.endsWith(".md") && f !== "MEMORY.md").sort();
    const lines = files.map(f => {
      const txt = fs.readFileSync(path.join(sharedDir, f), "utf8");
      const fm = /^---\n([\s\S]*?)\n---/.exec(txt);
      let name = f.replace(/\.md$/, "").replace(/_/g, " "), desc = "";
      if (fm) {
        const n = /\bname:\s*"?([^"\n]+)"?/.exec(fm[1]); if (n) name = n[1].trim();
        const d = /\bdescription:\s*"?([^"\n]+)"?/.exec(fm[1]); if (d) desc = d[1].trim();
      }
      return `- [${name}](${f})${desc ? " — " + desc : ""}`;
    });
    const block = [START, "<!-- Symlinks to ~/.claude/memory-shared/ — managed by link-shared-memory.sh. Edit the source there. -->", ...lines, END].join("\n");
    const memFile = path.join(memDir, "MEMORY.md");
    let cur = fs.existsSync(memFile) ? fs.readFileSync(memFile, "utf8") : "";
    const re = new RegExp(START.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[\\s\\S]*?" + END.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
    if (re.test(cur)) {
      cur = cur.replace(re, block);
    } else {
      cur = block + (cur.trim() ? "\n\n" + cur.trim() + "\n" : "\n");
    }
    fs.writeFileSync(memFile, cur.replace(/\n{3,}/g, "\n\n").replace(/\s*$/, "\n"));
  '
  echo ">> linked into $memdir"
}

for r in "${roots[@]}"; do link_into "$r"; done
echo ">> shared notes: $(ls "$SHARED_DIR"/*.md 2>/dev/null | grep -v MEMORY.md | wc -l | tr -d ' ') | roots: ${roots[*]}"
