#!/usr/bin/env node
// generate-bugbot.js: render edge-react-gui's .cursor/BUGBOT.md from
// review-standards.mdc, so the file Bugbot reads never drifts from the rules
// the review skills load.
//
// The rule prose comes from ../review-standards.mdc. Bugbot-only content (the
// file title, a human title per rule, code examples) comes from
// bugbot-overlay.md in this directory, keyed by rule id. A rule's inline
// ❌/✅ lines are left out when the overlay gives it examples (they are the
// same examples in Bugbot's form) and become Bad/Good bullets when it does not.
//
// Usage:
//   generate-bugbot.js [--source <mdc>] [--overlay <md>]            print to stdout
//   generate-bugbot.js [...] --out <edge-react-gui>/.cursor/BUGBOT.md   write the file
//   generate-bugbot.js [...] --check <edge-react-gui>/.cursor/BUGBOT.md exit 1 on any difference
//
// Exits 2 when the overlay and the source disagree on the rule set, or when
// the output would carry an em dash.

const fs = require("fs");
const path = require("path");

const TITLE = "# Bugbot Review Rules";
const NOTE =
  "<!-- Generated from review-standards.mdc by generate-bugbot.js " +
  "(EdgeApp/edge-dev-agents, .cursor/rules/). Do not edit by hand: change the " +
  "source or bugbot-overlay.md and regenerate. -->";

const fail = (code, message) => {
  process.stderr.write(`generate-bugbot: ${message}\n`);
  process.exit(code);
};

const parseArgs = (argv) => {
  const args = {
    source: path.join(__dirname, "..", "review-standards.mdc"),
    overlay: path.join(__dirname, "bugbot-overlay.md"),
  };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const key = { "--source": "source", "--overlay": "overlay", "--out": "out", "--check": "check" }[flag];
    if (key == null || argv[i + 1] == null) fail(1, `bad argument: ${flag}`);
    args[key] = argv[++i];
  }
  if (args.out != null && args.check != null) fail(1, "--out and --check are exclusive");
  return args;
};

// [{ name, description, rules: [{ id, text }] }] in source order.
const parseSource = (text) => {
  const sections = [];
  const sectionRe = /<section name="([^"]+)"(?: description="([^"]*)")?>([\s\S]*?)<\/section>/g;
  for (const [, name, description, body] of text.matchAll(sectionRe)) {
    const rules = [];
    for (const [, id, ruleText] of body.matchAll(/<rule id="([^"]+)">([\s\S]*?)<\/rule>/g)) {
      rules.push({ id, text: ruleText.trim() });
    }
    sections.push({ name, description, rules });
  }
  return sections;
};

// Map of rule id -> { heading, examples }. Content before the first ### heading
// is the overlay's own documentation and is skipped.
const parseOverlay = (text) => {
  const entries = new Map();
  let current = null;
  let inFence = false;
  for (const line of text.split("\n")) {
    if (line.startsWith("```")) inFence = !inFence;
    const m = inFence ? null : line.match(/^### .+ \(`([^`]+)`\)$/);
    if (m != null) {
      if (entries.has(m[1])) fail(2, `overlay lists ${m[1]} twice`);
      current = { heading: line, lines: [] };
      entries.set(m[1], current);
    } else if (current != null) {
      current.lines.push(line);
    }
  }
  for (const entry of entries.values()) entry.examples = entry.lines.join("\n").trim();
  return entries;
};

const renderRule = (rule, entry) => {
  const lines = rule.text.split("\n");
  const isExample = (line) => /^[❌✅]/u.test(line);
  const prose = lines.filter((line) => !isExample(line)).join("\n");
  const blocks = [entry.heading, prose];
  if (entry.examples !== "") {
    blocks.push(entry.examples);
  } else if (lines.some(isExample)) {
    const bullets = lines
      .filter(isExample)
      .map((line) => line.replace(/^❌\s*/u, "- Bad: ").replace(/^✅\s*/u, "- Good: "));
    blocks.push(bullets.join("\n"));
  }
  return blocks.join("\n\n");
};

const render = (sections, overlay) => {
  const sourceIds = new Set(sections.flatMap((s) => s.rules.map((r) => r.id)));
  const missing = [...sourceIds].filter((id) => !overlay.has(id));
  const orphaned = [...overlay.keys()].filter((id) => !sourceIds.has(id));
  if (missing.length > 0 || orphaned.length > 0) {
    const parts = [];
    if (missing.length > 0) parts.push(`rules with no overlay entry: ${missing.join(", ")}`);
    if (orphaned.length > 0) parts.push(`overlay entries with no rule: ${orphaned.join(", ")}`);
    fail(2, parts.join("; "));
  }

  const blocks = [TITLE, NOTE];
  for (const section of sections) {
    blocks.push(`## ${section.name}`);
    if (section.description != null) blocks.push(section.description);
    for (const rule of section.rules) blocks.push(renderRule(rule, overlay.get(rule.id)));
  }
  const output = blocks.join("\n\n") + "\n";

  // BUGBOT.md ships in a product repo, where em dashes are banned.
  const dashed = output.split("\n").filter((line) => line.includes("—"));
  if (dashed.length > 0) fail(2, `em dash in generated output, fix the source:\n${dashed.join("\n")}`);
  return output;
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  const sections = parseSource(fs.readFileSync(args.source, "utf8"));
  if (sections.length === 0) fail(2, `no <section> blocks found in ${args.source}`);
  const output = render(sections, parseOverlay(fs.readFileSync(args.overlay, "utf8")));

  if (args.check != null) {
    const current = fs.existsSync(args.check) ? fs.readFileSync(args.check, "utf8") : null;
    if (current !== output) fail(1, `${args.check} is out of date; regenerate with --out`);
    process.stderr.write(`generate-bugbot: ${args.check} is up to date\n`);
  } else if (args.out != null) {
    fs.writeFileSync(args.out, output);
  } else {
    process.stdout.write(output);
  }
};

main();
