# release-merge-lib.sh — shared helpers for the edge-react-gui release merges:
# develop-staging/scripts/staging-release-merge.sh (develop → staging),
# staging-master/scripts/master-release-merge.sh (staging → master) and
# point-release/scripts/point-release-ship.sh (picks onto master and staging).
#
# SOURCED, never executed. The caller owns `set -euo pipefail` and these
# globals, read by the ledger and cleanup paths:
#   PHASES      space-separated phase names, in report order
#   KEEP_WS     non-empty to keep the temp worktree
#   WT          temp worktree path (may be unset before the Workspace phase)
#
# Every helper here behaves identically for both callers; anything that
# differs by direction (branch names, which side wins) is a parameter.

say()  { printf '>> %s\n' "$*"; }
WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '!! %s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

# Step ledger. Every phase records its outcome here, and finish() renders it on
# EVERY exit path, so a run that stopped at a gate still reports what the phases
# before it did. Kept as a newline-delimited string rather than an associative
# array, which bash 3.2 (the macOS system bash) does not have.
STEP_LOG=""
step() { STEP_LOG="$STEP_LOG$1|$2|$3
"; }
render_steps() {
  printf '\n=== Step report ===\n'
  for ph in $PHASES; do
    line="$(printf '%s' "$STEP_LOG" | grep "^$ph|" || true)"
    if [ -z "$line" ]; then
      printf '  %-16s %-11s %s\n' "$ph" "not-reached" "-"
      continue
    fi
    st="$(printf '%s' "$line" | cut -d'|' -f2)"
    detail="$(printf '%s' "$line" | cut -d'|' -f3-)"
    printf '  %-16s %-11s %s\n' "$ph" "$st" "$detail"
  done
}
RESULT_PRINTED=""
finish() {
  # The kept-workspace note prints HERE, not from the EXIT trap, so that
  # `RESULT:` is always the last line a caller reads.
  [ -n "${KEEP_WS:-}" ] && [ -n "${WT:-}" ] && [ -d "$WT" ] && say "workspace kept at $WT"
  render_steps
  RESULT_PRINTED=1
  printf '\nRESULT: %s\n' "$1"
  exit "$2"
}
die()   { printf '!! %s\n' "$*" >&2; finish error 1; }

read_json_field() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=process.argv[1].split(".").reduce((o,k)=>(o||{})[k],JSON.parse(s));console.log(v==null?"":v)})' "$1"; }

# release_ws_prep <repo> <worktree>
# Stage the gitignored artifacts the repo's precommit chain needs into a fresh
# worktree. Nothing is symlinked into the caller's checkout, so no hook run in
# the worktree can write back into it.
release_ws_prep() {
  local repo="$1" wt="$2" p
  # node_modules must be a REAL directory: react-native's jest asset transformer
  # builds snapshot image paths relative to its own location inside node_modules,
  # so a symlink resolves them against the caller's checkout and every image
  # snapshot fails. Clone it (APFS clone-on-write costs seconds and little disk).
  if [ ! -e "$wt/node_modules" ] && [ -d "$repo/node_modules" ]; then
    say "cloning node_modules (a symlink breaks image snapshots)"
    cp -c -R "$repo/node_modules" "$wt/node_modules" 2>/dev/null \
      || cp -R "$repo/node_modules" "$wt/node_modules" \
      || die "could not stage node_modules"
  fi
  # COPIED, never symlinked: a symlink named `_` is a file, so husky's own
  # `_/.gitignore` (which lives INSIDE the real dir) cannot ignore it, and a
  # scoped commit can sweep the link into the repo as a dangling absolute path
  # that breaks husky on every other machine.
  if [ ! -e "$wt/.husky/_" ] && [ -d "$repo/.husky/_" ]; then
    mkdir -p "$wt/.husky"
    cp -R "$repo/.husky/_" "$wt/.husky/_"
    say "copied .husky/_"
  fi
  # Copied, not symlinked: the prepare step regenerates this dir (typechain
  # mkdir), which fails with EEXIST when the path is a symlink.
  if [ ! -e "$wt/src/plugins/contracts" ] && [ -d "$repo/src/plugins/contracts" ]; then
    cp -R "$repo/src/plugins/contracts" "$wt/src/plugins/contracts"
    say "copied src/plugins/contracts"
  fi
  # Without these, the precommit tsc fails on unresolvable modules.
  for p in env.json config.json keys.json src/controllers/edgeProvider/client/rolledUp.js src/controllers/edgeProvider/injectThisInWebView.js; do
    [ -e "$wt/$p" ] && continue
    [ -e "$repo/$p" ] || { warn "missing $p in $repo, the precommit hooks may fail"; continue; }
    mkdir -p "$(dirname "$wt/$p")"
    cp "$repo/$p" "$wt/$p"
    say "copied $p"
  done
}

# release_classify_conflict <conflicted-file> <ours-label> <theirs-label>
# Prints one verdict line (plus up to three "only on <ours>" lines). The verdict
# contains "loses nothing" exactly when taking the THEIRS side drops nothing the
# OURS side has; callers route on that phrase.
release_classify_conflict() {
  node - "$1" "$2" "$3" <<'NODE'
// A purely textual subset test is not enough. A dependency pin that moved on
// BOTH branches (ours took a hotfix bump, theirs went further) has no line in
// common, yet theirs supersedes ours and taking theirs is correct. Calling that
// "ours carries content theirs lacks" would tell the operator to downgrade,
// and it would fire on package.json / package-lock.json / Podfile.lock at
// every single release.
const fs = require("fs");
const [file, OURS, THEIRS] = process.argv.slice(2);
const lines = fs.readFileSync(file, "utf8").split("\n");

// A semver range prefix is part of the version: an exact pin on one side and a
// caret range on the other ("2.48.2" vs "^2.53.0") are the same entry.
const VER = /[\^~]?\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?/g;
// Lockfiles and Podfile.lock distinguish the same entry by CHECKSUM rather than
// by version, so blank those too or every lockfile hunk reads as missing
// content. A line that differs only in a version or a checksum is the same
// entry at a different revision.
const HASH = /\b(?:sha\d+-[A-Za-z0-9+/=]{20,}|[0-9a-f]{32,})\b/g;
const shape = (l) => l.trim().replace(HASH, "\u0000H\u0000").replace(VER, "\u0000V\u0000");
const versionsOf = (l) => (l.trim().replace(HASH, "").match(VER) || []).map((v) => v.replace(/^[\^~]/, ""));
const cmpVer = (a, b) => {
  const pa = a.split(/[.+-]/).map(Number);
  const pb = b.split(/[.+-]/).map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (Number.isNaN(x) || Number.isNaN(y)) return 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
};

let i = 0, hunks = 0, superseded = 0;
const missing = [];
while (i < lines.length) {
  if (!lines[i].startsWith("<<<<<<< ")) { i++; continue; }
  i++; const ours = [];
  while (i < lines.length && !lines[i].startsWith("=======")) ours.push(lines[i++]);
  i++; const theirs = [];
  while (i < lines.length && !lines[i].startsWith(">>>>>>> ")) theirs.push(lines[i++]);
  i++; hunks++;

  const thExact = new Set(theirs.map((l) => l.trim()).filter(Boolean));
  const thByShape = new Map();
  for (const l of theirs) {
    if (!l.trim()) continue;
    const k = shape(l);
    if (!thByShape.has(k)) thByShape.set(k, []);
    thByShape.get(k).push(l);
  }

  for (const raw of ours) {
    const l = raw.trim();
    if (!l || thExact.has(l)) continue;
    // Same entry, different version: theirs wins as long as it is not older.
    const twins = thByShape.get(shape(raw)) || [];
    const sv = versionsOf(raw);
    const newerOnTheirs = twins.some((t) => {
      const tv = versionsOf(t);
      return tv.length === sv.length && sv.every((v, n) => cmpVer(v, tv[n]) <= 0);
    });
    if (newerOnTheirs) { superseded++; continue; }
    if (missing.length < 3) missing.push(l);
  }
}

if (missing.length) {
  console.log(`${hunks} hunk(s): ${OURS} carries content ${THEIRS} lacks, back-port it to ${THEIRS} first`);
  for (const m of missing) console.log(`         only on ${OURS}: ${m.slice(0, 110)}`);
} else if (superseded) {
  console.log(`${hunks} hunk(s): ${THEIRS} supersedes ${OURS} (${superseded} entr(y/ies) at a newer version), taking ${THEIRS}'s side loses nothing`);
} else {
  console.log(`${hunks} hunk(s): ${THEIRS} is a superset of ${OURS}, taking ${THEIRS}'s side loses nothing`);
}
NODE
}

# release_restore_hook_rewrites <worktree> <staged-tree> <log>
# A conflicted merge commits through the repo's pre-commit hook, whose
# update-eslint-warnings step deletes every STAGED file from the warning list in
# eslint.config.mjs. A release merge stages a whole release delta, so the hook
# strips entries the source branch still carries and the target leaves the merge
# with a different list. The merge commit carries the file as it was staged: put
# that back and amend. --no-verify, because the hook would strip it again; its
# tsc, lint and jest steps already passed on the stricter list. Only the hook's
# own rewrite is undone, so any other difference still reaches the parity gate.
release_restore_hook_rewrites() {
  local wt="$1" staged="$2" log="$3" f="eslint.config.mjs"
  git -C "$wt" diff --quiet "$staged" HEAD -- "$f" && return 0
  git -C "$wt" checkout "$staged" -- "$f" \
    && git -C "$wt" commit --quiet --amend --no-edit --no-verify >>"$log" 2>&1 \
    || die "could not restore the staged $f into the merge commit (full log: $log)"
  say "restored $f as staged (the pre-commit hook rewrote it in the merge commit)"
}

# release_prefer_reviewed <repo> <remote> <tag> <base> <built> [<tag> <base> <built> ...]
# A real run rebuilds what its dry run built, so every gate still runs, but the
# rebuild has new SHAs. This picks what to push: the reviewed dry-run tag
# commits when the rebuild matches them, else the rebuild. One triple per
# pushed branch: its inspection tag on <remote>, the <base> ref the branch
# fast-forwards from, and the <built> commit. All or nothing, because one
# reviewed commit can cite another by SHA (a `cherry picked from` line).
# A match needs, per triple: <base> still an ancestor of the tag, the same final
# tree, and the same commits in <base>..tip by tree, author and message (built
# SHAs that a message cites are read as their reviewed counterparts), resting on
# the same boundary commits. Commit dates are ignored; they are what a rebuild
# changes. Verify ran on the rebuild's trees, which the match proves equal.
# Sets RELEASE_PUSH (one SHA per triple, in order) and RELEASE_REVIEWED_NOTE
# (empty on a match, else why the rebuild is pushed). Always returns 0.
release_prefer_reviewed() {
  local repo="$1" remote="$2" ref out args=()
  shift 2
  RELEASE_PUSH=(); RELEASE_REVIEWED_NOTE=""
  while [ $# -ge 3 ]; do
    RELEASE_PUSH+=("$(git -C "$repo" rev-parse "$3^{commit}")")
    # A private ref, not FETCH_HEAD or a local tag: other sessions fetch in this
    # repo too, and the dry run deletes its local copies of these tags.
    ref="refs/release-reviewed/$1"
    if [ -z "$RELEASE_REVIEWED_NOTE" ] && git -C "$repo" fetch --quiet --no-tags "$remote" "+refs/tags/$1:$ref" 2>/dev/null; then
      args+=("$1" "$2" "$(git -C "$repo" rev-parse "$ref^{commit}")" "${RELEASE_PUSH[${#RELEASE_PUSH[@]}-1]}")
      git -C "$repo" update-ref -d "$ref" 2>/dev/null || true
    else
      RELEASE_REVIEWED_NOTE="${RELEASE_REVIEWED_NOTE:-no $1 on $remote}"
    fi
    shift 3
  done
  [ -z "$RELEASE_REVIEWED_NOTE" ] || return 0
  out="$(node - "$repo" ${args[@]+"${args[@]}"} <<'NODE'
const { execFileSync } = require("child_process");
const [repo, ...rest] = process.argv.slice(2);
const git = (...a) => execFileSync("git", ["-C", repo, ...a], { encoding: "utf8", maxBuffer: 1 << 28 });
const isAncestor = (a, b) => {
  try { execFileSync("git", ["-C", repo, "merge-base", "--is-ancestor", a, b]); return true; } catch { return false; }
};
const items = [];
for (let i = 0; i < rest.length; i += 4) items.push({ tag: rest[i], base: rest[i + 1], reviewed: rest[i + 2], built: rest[i + 3] });
const toReviewed = (s) => items.reduce((acc, it) => acc.split(it.built).join(it.reviewed), s);
const id = (s) => s;
const commits = (base, tip, map) =>
  git("log", "-z", "--format=%T%n%an <%ae>%n%B", `${base}..${tip}`).split("\0").filter(Boolean).map((r) => map(r.trimEnd())).sort();
const boundary = (base, tip, map) =>
  git("rev-list", "--boundary", `${base}..${tip}`).split("\n").filter((l) => l.startsWith("-")).map((l) => map(l.slice(1))).sort();
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const differs = (it) => {
  if (it.reviewed === it.built) return "";
  if (!isAncestor(it.base, it.reviewed)) return `${it.base} moved since ${it.tag}`;
  if (git("rev-parse", `${it.reviewed}^{tree}`) !== git("rev-parse", `${it.built}^{tree}`)) return `the tree differs from ${it.tag}`;
  if (!same(commits(it.base, it.reviewed, id), commits(it.base, it.built, toReviewed))
    || !same(boundary(it.base, it.reviewed, id), boundary(it.base, it.built, toReviewed))) {
    return `the commits on ${it.base}..${it.tag} differ from the rebuild`;
  }
  return "";
};
const why = items.map(differs).find(Boolean);
console.log(why ? `NO ${why}` : ["OK", ...items.map((it) => it.reviewed)].join("\n"));
NODE
)" || { RELEASE_REVIEWED_NOTE="the comparison with the inspection tags failed"; return 0; }
  case "$out" in
    OK*)
      RELEASE_PUSH=()
      while IFS= read -r ref; do RELEASE_PUSH+=("$ref"); done < <(tail -n +2 <<< "$out")
      ;;
    *) RELEASE_REVIEWED_NOTE="${out#NO }" ;;
  esac
  return 0
}

# release_reviewed_step <phase> <what>
# Records the <phase> row for the last release_prefer_reviewed call: ok when it
# chose the reviewed commits, warn with the reason when it chose the rebuild.
release_reviewed_step() {
  if [ -z "$RELEASE_REVIEWED_NOTE" ]; then
    say "pushing the reviewed commits from $2"
    step "$1" ok "pushing the reviewed $2 commits; the rebuild matches them"
  else
    warn "pushing the rebuild, not the reviewed $2: $RELEASE_REVIEWED_NOTE"
    step "$1" warn "pushing the rebuild, not $2: $RELEASE_REVIEWED_NOTE"
  fi
}

# release_verify <worktree> <log>
# Runs the repo verify. Returns 0 on a pass, 3 on a pass after one retry of a
# jest-worker SIGSEGV (an infra flake, not a merge defect), 1 on failure.
release_verify() {
  local wt="$1" log="$2"
  ( cd "$wt" && "$HOME/.cursor/skills/pm.sh" run verify ) >"$log" 2>&1 && return 0
  if grep -qa "was terminated by another process: signal=SIGSEGV" "$log"; then
    say "verify hit a jest-worker SIGSEGV; retrying once"
    ( cd "$wt" && "$HOME/.cursor/skills/pm.sh" run verify ) >"$log" 2>&1 && return 3
  fi
  return 1
}
