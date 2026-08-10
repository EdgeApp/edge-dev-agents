#!/usr/bin/env bash
# tdd-codeblock-link.sh — turn each code block's leading path comment into a
# caption link pinned to a commit SHA, so a reader can open the real file and
# the link keeps working after the PR merges and its branch is deleted.
#
# A markdown link cannot render inside a fence, so the path moves OUT of the
# block and becomes the caption line directly above it:
#
#   ```ts                            [`src/attestation/challenges.ts`](https://github.com/O/R/blob/<sha>/src/attestation/challenges.ts)
#   // src/attestation/challenges.ts   ->   ```ts
#   export const createChallenge...        export const createChallenge...
#   ```                              ```
#
# The SHA is the branch tip of the checkout that tracks the file, resolved per
# repo, so a multi-repo TDD pins each block to its own repo. A branch URL would
# 404 once the branch is deleted at merge; a commit URL stays reachable.
#
# Re-running refreshes the SHA when the branch has moved, so a doc updated on a
# later turn cites the code it now quotes. Otherwise it is a no-op.
#
# Usage:
#   tdd-codeblock-link.sh <file.md> --repo <checkout-dir> [--repo <dir>...] [--check]
#   --check reports what would change and exits 1 if anything would.
# Exit: 0 = clean/updated, 1 = --check found stale/missing captions, 2 = usage.
set -euo pipefail

FILE=""
CHECK="false"
REPOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPOS+=("$2"); shift 2 ;;
    --check) CHECK="true"; shift ;;
    *) [[ -z "$FILE" ]] && { FILE="$1"; shift; } || { echo "Unknown arg: $1" >&2; exit 2; } ;;
  esac
done
[[ -f "$FILE" ]] || { echo "usage: tdd-codeblock-link.sh <file.md> --repo <dir> [--check]" >&2; exit 2; }
[[ ${#REPOS[@]} -gt 0 ]] || { echo "ERROR: at least one --repo <checkout-dir> required" >&2; exit 2; }

# Resolve each repo to "slug<TAB>sha<TAB>newline-separated tracked paths".
MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT
for d in "${REPOS[@]}"; do
  [[ -d "$d" ]] || { echo "ERROR: not a directory: $d" >&2; exit 2; }
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repo: $d" >&2; exit 2; }
  remote=$(git -C "$d" remote get-url origin 2>/dev/null || true)
  slug=$(printf '%s' "$remote" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
  case "$slug" in */*) ;; *) echo "ERROR: no github origin on $d" >&2; exit 2 ;; esac
  sha=$(git -C "$d" rev-parse HEAD)
  printf 'REPO\t%s\t%s\n' "$slug" "$sha" >> "$MANIFEST"
  git -C "$d" ls-files | sed "s#^#PATH\t$slug\t#" >> "$MANIFEST"
done

node -e '
const fs = require("fs")
// argv[0] is the node executable itself; the caller args start at [1]. Skipping
// the hole here is not cosmetic: destructuring from [0] made mdPath the node
// binary, which this script then read as UTF-8 and wrote back, corrupting it.
const [, mdPath, manifestPath, checkArg] = process.argv
const check = checkArg === "--check"
// Refuse to touch anything that is not markdown. This pass rewrites its target
// in place, so a bad path must fail loudly rather than shred a binary.
if (!/\.mdx?$/.test(mdPath || "")) {
  console.error("REFUSING: target is not a .md file: " + mdPath)
  process.exit(2)
}
const lines = fs.readFileSync(mdPath, "utf8").split("\n")

const shaBySlug = {}
const slugByPath = {}
for (const row of fs.readFileSync(manifestPath, "utf8").split("\n")) {
  const [kind, slug, rest] = row.split("\t")
  if (kind === "REPO") shaBySlug[slug] = rest
  else if (kind === "PATH" && !(rest in slugByPath)) slugByPath[rest] = slug
}

// A leading path comment: "// path", "# path", "-- path", with any trailing
// qualifier after a comma dropped ("as landed" and friends).
const pathComment = /^\s*(?:\/\/|#|--)\s*([A-Za-z0-9_./-]+\.[A-Za-z0-9]+)\s*(?:,.*)?$/
// A caption line. The ref is deliberately NOT restricted to a hex SHA: a
// hand-written caption normally points at a BRANCH ("blob/develop/..."), and a
// SHA-only pattern makes that line invisible here, so the script appends its
// own caption and the block ends up with two. That is the duplicate-link bug.
// Match any ref, then confirm the URL really addresses the labelled path.
const captionRe = /^\[`?([^`\]]+)`?\]\((https:\/\/github\.com\/[^/]+\/[^/]+\/blob\/\S+)\)\s*$/
const parseCaption = line => {
  const m = captionRe.exec(line || "")
  if (m == null) return null
  const [, labelPath, url] = m
  if (!url.endsWith("/" + labelPath)) return null
  const ref = url.slice(url.indexOf("/blob/") + 6, url.length - labelPath.length - 1)
  return { path: labelPath, ref }
}

const out = []
const changes = []
for (let i = 0; i < lines.length; i++) {
  const line = lines[i]
  // Any opening fence is consumed as a whole block, including mermaid and any
  // language we do not caption. Walking a mermaid block line by line would make
  // its CLOSING fence look like the next OPENING fence, flipping parity and
  // hiding every real code block after the first diagram.
  const fence = /^```(\S*)/.exec(line)
  if (fence == null) { out.push(line); continue }

  // Collect the block.
  const body = []
  let j = i + 1
  for (; j < lines.length && !/^```\s*$/.test(lines[j]); j++) body.push(lines[j])
  const closed = j < lines.length

  const lang = fence[1]
  const pm = lang !== "mermaid" && body.length > 0 ? pathComment.exec(body[0]) : null
  // A block captioned on an earlier run no longer carries an in-fence comment,
  // so the path is recovered from the caption itself. Without this the SHA
  // could only ever be written once and a stale pin would never refresh.
  const prevIdx = out.length - 1
  const prevCap = prevIdx >= 0 ? parseCaption(out[prevIdx]) : null
  const p = pm != null ? pm[1] : (prevCap != null ? prevCap.path : null)
  const slug = p != null ? slugByPath[p] : undefined

  if (p == null || slug === undefined) {
    out.push(line, ...body); if (closed) out.push(lines[j]); i = j; continue
  }

  const sha = shaBySlug[slug]
  const caption = "[`" + p + "`](https://github.com/" + slug + "/blob/" + sha + "/" + p + ")"

  // Replace the existing caption(s) directly above, else insert. More than one
  // can be stacked when a hand-written caption was left in place alongside a
  // generated one; collapse the run rather than adding a third.
  const stacked = []
  while (out.length > 0) {
    const cap = parseCaption(out[out.length - 1])
    if (cap == null || cap.path !== p) break
    stacked.unshift(cap)
    out.pop()
  }
  if (stacked.length === 0) {
    changes.push({ path: p, why: "caption added" })
  } else if (stacked.length > 1) {
    changes.push({ path: p, why: stacked.length + " stacked captions collapsed to 1 at " + sha.slice(0, 7) })
  } else if (stacked[0].ref !== sha) {
    changes.push({ path: p, why: "ref " + stacked[0].ref.slice(0, 7) + " -> " + sha.slice(0, 7) })
  }
  out.push(caption)

  out.push(line, ...body.slice(pm != null ? 1 : 0))   // drop the in-fence comment only if present
  if (closed) out.push(lines[j])
  i = j
}

if (check) {
  if (changes.length === 0) { console.log("CODEBLOCK_LINKS_OK"); process.exit(0) }
  changes.forEach(c => console.log(`MISSING ${c.path}: ${c.why}`))
  process.exit(1)
}
fs.writeFileSync(mdPath, out.join("\n"))
console.log("CODEBLOCK_LINKS_APPLIED " + changes.length)
changes.forEach(c => console.log(`  ${c.path} (${c.why})`))
' "$FILE" "$MANIFEST" "$([[ "$CHECK" == "true" ]] && echo --check || echo --write)"
