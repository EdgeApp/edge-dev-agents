// release-lib.js: CHANGELOG entry and app-version helpers shared by the release
// and landing scripts. One copy of the entry type order lives here; every script
// that sorts, checks or validates entry types loads it from this file.
//
// Callers:
//   pr-land/scripts/changelog-union-merge.sh      TYPE_ORDER via typeRank
//   verify-repo.sh                                orderErrors, ENTRY_RE
//   point-release/scripts/point-release-ship.sh   sortEntries, orderErrors,
//                                                 bumpAppVersion, ENTRY_RE
//   point-release/scripts/point-release-plan.js   ENTRY_RE
//   develop-staging/scripts/staging-release-merge.sh  bumpAppVersion
//
// Load from inline node with
//   require(require("os").homedir() + "/.cursor/skills/release-lib.js")

const fs = require("fs");

// The order entry types are grouped in within one CHANGELOG section.
const TYPE_ORDER = ["added", "changed", "deprecated", "fixed", "removed", "security"];

// A well-formed entry line: `- <type>: <text>`.
const ENTRY_RE = new RegExp(`^- (${TYPE_ORDER.join("|")}): `);

// Lowercased type of an entry line, or null for a line with no `- word:` prefix.
const entryType = (line) => {
  const m = line.match(/^- (\w+):/);
  return m ? m[1].toLowerCase() : null;
};

// Position in TYPE_ORDER; lines with no known type rank after every type.
const typeRank = (line) => {
  const i = TYPE_ORDER.indexOf(entryType(line));
  return i === -1 ? TYPE_ORDER.length : i;
};

// Stable sort by type: entries of one type keep their relative order.
const sortEntries = (lines) => [...lines].sort((a, b) => typeRank(a) - typeRank(b));

// One message per entry whose type comes before the type of an earlier entry.
// `entries` is a list of strings or of { text, lineNum }.
const orderErrors = (entries, label = "section") => {
  const errors = [];
  let last = -1;
  for (const e of entries) {
    const text = typeof e === "string" ? e : e.text;
    const idx = TYPE_ORDER.indexOf(entryType(text));
    if (idx === -1) continue;
    if (idx < last) {
      const where = typeof e === "string" ? "" : `Line ${e.lineNum}: `;
      errors.push(`${where}"${TYPE_ORDER[idx]}" entry after "${TYPE_ORDER[last]}" in ${label}, expected order: ${TYPE_ORDER.join(", ")}`);
    }
    last = Math.max(last, idx);
  }
  return errors;
};

// Set the app's own version in <wt>/package.json and, when present,
// <wt>/package-lock.json (which records it twice, at the top level and on
// packages[""], both before the first "node_modules/" entry). Returns the
// previous version. Throws when either file does not end up at `version`.
const bumpAppVersion = (wt, version) => {
  const pkgFile = `${wt}/package.json`;
  const pkgText = fs.readFileSync(pkgFile, "utf8");
  const prev = JSON.parse(pkgText).version;
  const pkgOut = pkgText.replace(/("version":\s*)"[^"]+"/, `$1"${version}"`);
  if (JSON.parse(pkgOut).version !== version) throw new Error("package.json version did not update");
  fs.writeFileSync(pkgFile, pkgOut);

  const lockFile = `${wt}/package-lock.json`;
  if (fs.existsSync(lockFile)) {
    const lock = fs.readFileSync(lockFile, "utf8");
    const cut = lock.indexOf('"node_modules/');
    const head = cut === -1 ? lock : lock.slice(0, cut);
    let n = 0;
    const out = head.replace(/("version":\s*)"[^"]+"/g, (m, p) => (n++ < 2 ? `${p}"${version}"` : m)) + (cut === -1 ? "" : lock.slice(cut));
    const j = JSON.parse(out);
    if (j.version !== version || (j.packages && j.packages[""] && j.packages[""].version !== version)) {
      throw new Error("package-lock.json version did not update");
    }
    fs.writeFileSync(lockFile, out);
  }
  return prev;
};

module.exports = { TYPE_ORDER, ENTRY_RE, entryType, typeRank, sortEntries, orderErrors, bumpAppVersion };
