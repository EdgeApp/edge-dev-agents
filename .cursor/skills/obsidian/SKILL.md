---
name: obsidian
description: Create, append to, read, and organize Markdown notes in the user's Obsidian vault at ~/Documents/ob-vault. Use when the user mentions "obsidian" or "obs", or says "make a note" (e.g. "make a note of this", "write this to obsidian", "capture this in obs", "add this to my obsidian"). Handles note creation, appending to existing notes, folders, frontmatter, and wikilinks.
compatibility: Requires the Obsidian vault at ~/Documents/ob-vault (contains .obsidian/). No other deps.
metadata:
  author: j0ntz
---

<goal>Capture and organize Markdown notes in the user's Obsidian vault (`~/Documents/ob-vault`) using Obsidian-native conventions, without clobbering existing notes.</goal>

<rules description="Non-negotiable constraints.">
<rule id="vault-path">The vault is `~/Documents/ob-vault` (confirmed Obsidian vault — has `.obsidian/`). Write only inside it. Create subfolders as needed with `mkdir -p`.</rule>
<rule id="no-clobber">NEVER overwrite an existing note's content blindly. Before writing, check whether a matching note exists: if it clearly matches the topic, APPEND (read it first, then add a new dated section); otherwise create a NEW note. If a destructive overwrite seems intended, confirm with the user first.</rule>
<rule id="obsidian-markdown">Use Obsidian-friendly Markdown: `#` headings, bullets, fenced code. Use wikilinks `[[Note Name]]` (or `[[Folder/Note]]`) when cross-referencing other vault notes, not bare paths. Use `#tag` or frontmatter tags, not ad-hoc conventions.</rule>
<rule id="frontmatter">Give reference notes light YAML frontmatter: `tags` (array), `created` (YYYY-MM-DD), optional `status`. Keep it minimal. Daily notes (root `YYYY-MM-DD.md`) follow the existing plain style — don't force frontmatter on them.</rule>
<rule id="stop-if-target-missing">If the user references a specific intended note or folder to write into and it cannot be found in the vault, STOP and ask — do NOT create a divergent folder/note, guess an alternate, or silently write elsewhere. (Creating a new folder/note is fine ONLY when the user explicitly asks to start/create one.)</rule>
<rule id="confirm-location">If the user gives NO target and it's ambiguous where the note belongs, pick a sensible location, state where you put it, and offer to move it — don't silently guess into an obscure path. (This applies only when no specific target was named; a named-but-missing target falls under `stop-if-target-missing`.)</rule>
</rules>

<step id="1" name="Determine target note">
Decide where the content goes:
1. User named a target folder/file:
   - It exists → use it.
   - User explicitly said to start/create it → `mkdir -p` and create.
   - Named as if it exists but NOT found → **STOP and ask** (per `stop-if-target-missing`). Do not guess or create a divergent one.
2. Content clearly matches an existing note (search the vault) → plan to APPEND.
3. No target given → new note. Choose folder per `<organization-conventions>`; default to a sensible topic folder or vault root, and say where it landed.

Find candidates when unsure:
```bash
ls ~/Documents/ob-vault; find ~/Documents/ob-vault -name '*.md' ! -path '*/.obsidian/*'
```
</step>

<step id="2" name="Write or append">
- **New note**: write clean Markdown with light frontmatter (`tags`, `created`, optional `status`) + a top-level `#` title.
- **Append**: Read the existing note first, then add a new `##` section (date-stamped if it's a running log). Preserve everything already there.

Report the exact path written and whether it was create vs append.
</step>

<organization-conventions description="PLACEHOLDER — to be expanded by the user. How notes should be filed/tagged.">
<!-- TODO(jon): fill in the vault's organization scheme. Until then, use sensible defaults and state choices.
Known so far:
- Root: daily notes `YYYY-MM-DD.md` (plain style, no frontmatter).
- Folders observed: Kanban/, Projects/, Claude/ (Claude-related notes).
To define later:
- Folder taxonomy (where do topic/reference notes go vs daily notes?)
- Tagging scheme (controlled vocabulary?)
- Naming conventions for note titles.
- When to append to a running note vs create a new one.
-->
Until this section is filled in: put Claude/agent-related notes under `Claude/`, otherwise choose the closest existing folder (or vault root), and tell the user where it landed so they can refile.
</organization-conventions>

<edge-cases>
<case name="Vault missing">If `~/Documents/ob-vault` doesn't exist, STOP and tell the user — do not create a vault or write elsewhere.</case>
<case name="Ambiguous append vs new">If unsure whether to append to an existing note or create a new one, prefer creating a new note and mention the existing related note as a `[[wikilink]]`, then ask if they'd rather merge.</case>
<case name="Sensitive content">Don't write secrets/tokens into notes. If the content contains credentials, flag it and ask before writing.</case>
</edge-cases>
