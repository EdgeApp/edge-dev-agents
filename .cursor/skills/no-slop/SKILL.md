---
name: no-slop
description: Avoid AI writing patterns when producing prose. Use when writing articles, blog posts, documentation, emails, proposals, reports, README content, PR descriptions, release notes, or any long-form text. Activates for drafting, composing, or writing tasks.
---

# no-slop — Anti-AI-Detection Rules

When writing any prose (articles, docs, emails, reports, descriptions, proposals), follow every rule below. These patterns are documented tells of AI-generated text. Violating even a few destroys credibility.

## 1. Banned vocabulary

Do NOT use any word or phrase listed in [banned-vocabulary.md](banned-vocabulary.md). If you catch yourself reaching for one, use a plain, specific alternative or restructure the sentence.

## 2. Use simple copulas

Use "is," "are," "was," "has," "had." Do not substitute with:
- "serves as," "stands as," "represents," "marks"
- "boasts," "features," "offers"
- "ventured into" instead of "tried" or "ran for"

Bad: "The library serves as a foundational component in the ecosystem."
Good: "The library is the base of the stack."

## 3. No promotional tone

Write like a journalist or engineer, not a marketer. Never hype. State facts and let them speak.

Bad: "This groundbreaking framework revolutionizes how developers build APIs."
Good: "This framework generates API clients from OpenAPI specs."

## 4. No vague attributions

Never write "experts say," "industry reports suggest," "observers note," "some critics argue," or "modern researchers believe." Either name the source or drop the claim.

## 5. No structural formulas

- **No rule of three**: Do not use three-adjective or three-phrase lists as a rhetorical device. Two or four is fine. Three in a row signals AI.
- **No "not just X, but Y"**: Drop the "not only... but also" and "it's not just... it's" constructions entirely.
- **No "challenges and future prospects"**: Never end a piece with a section about challenges faced and future outlook. If challenges matter, weave them into the body.

## 6. No present-participle chains

Do not string together "-ing" words as filler commentary: "highlighting," "emphasizing," "contributing to," "reflecting," "showcasing," "cultivating." These add no information. Replace with concrete verbs or cut entirely.

Bad: "The update introduces new caching, improving performance while highlighting the team's commitment to speed."
Good: "The update adds caching. Page loads dropped from 3s to 800ms."

## 7. No elegant variation

Do not swap synonyms for the same thing across sentences to avoid repetition. If you're talking about a "server," call it a "server" every time. Do not alternate between "the server," "the machine," "the node," "the instance" for style.

## 8. No overstating significance

Do not call things pivotal, transformative, revolutionary, or groundbreaking. Do not say something "marks a turning point" or "leaves an indelible mark." If it's important, show why with evidence — don't announce it.

## 9. No em dashes

Do not use em dashes (`—`, U+2014). Use a comma, colon, semicolon, parentheses, or two sentences instead. Zero is the rule for every destination this skill governs (external prose and chat responses). Hyphens (`-`) and en-dashes (`–`) are fine. AI text is riddled with em dashes.

## 10. No collaborative language

Never write "let's explore," "let us delve into," "we will examine," "as we can see." Write directly. The reader is reading, not exploring with you.

## 11. No knowledge-cutoff disclaimers

Never apologize for gaps, say "as of my last update," or speculate about missing information. Either state the fact or don't.

## 12. Formatting restraint

- Do not bold excessively. Bold a term once at most when introducing it.
- Do not use emoji unless the user explicitly asks.
- Do not use title case in headings beyond the first word and proper nouns (sentence case).
- Do not create "key takeaways" sections.

## 13. Write like a human

- Vary sentence length naturally. Mix short and long.
- Start some sentences with "But," "And," "So," or "Or."
- Use contractions (don't, isn't, can't) in informal contexts.
- Be specific over general. Numbers over adjectives. Evidence over claims.
- It's OK to be blunt, dry, or even terse. Humans are.

## 14. State findings, don't grade or announce them

A sentence must carry a claim, not an evaluation or preview of the claim you're about to make. Strip the sentence and check: if nothing is lost, cut it.

- No evidence-grading: "the article is clear," "the data is unambiguous," "the answer is straightforward."
- No stance-validation preambles: "your concern is fair," "good question," "you're right to push on this." When the reader is right, the confirmation is the fact itself: "Confirmed: the rules were in force; 4 of 7 runs violated them."
- No forward references: "here's the precise failure:", "here's what matters:", "the key thing is this:".
- No structure announcements: "Summary, in three parts.", "Three things:", "Let me break this down." Just write the parts.
- No pre-verdicts the next sentence restates: "it's the opposite of a penalty" followed by the terms that show that.
- No per-item self-grading in lists: "Cheapest item on the list.", "The easy one.", "Most important of these." If ordering matters, the list header states the principle once ("in rough order of effort, smallest first", "by impact", "no particular order") and the items carry only content.
- No "say the word" closers. When a decision is genuinely open, end with the decision stated directly: the current state plus a direct question ("Em-dash ban now also covers Asana comments. Keep it?") or the default plus the cost of changing it ("Default: included. Excluding it is a one-line change."). Banned framings: "say the word", "just say the word", "let me know if you'd like", "if you want, I can...". If no decision is open, end on the last substantive sentence.

Certainty belongs inside the claim, marked tersely: "Unverified: X." / "By the published terms, X." A hedge that changes what the reader should do is information; a sentence that grades your own prose is not.

Leading with a real answer is still required (see writing-style). The verdict sentence must carry the verdict's substance — "Your fleet is unaffected: it runs interactive sessions, which the change excludes" — not just its polarity ("it's good news").

Bad: "The support article is clear, and it's the opposite of a penalty. On June 15, usage moves to a separate credit."
Good: "On June 15, Agent SDK and -p usage moves to a separate monthly credit and stops counting against plan limits."

## 15. No courtesy enders in external communications

Scope: the external destinations defined in `~/.cursor/rules/writing-style.mdc` (its em-dash-free list — PR titles/descriptions/comments, commit messages, changelogs, release notes, Asana tasks/comments, agent run reports, review/issue comments, docs, emails, proposals). Do not close with an offer or pleasantry that carries no information:

- "We can file these as issues with repro steps if that helps tracking."
- "Happy to split this out / adjust / help however we can."
- "Let me know if you have any questions."
- "Hope this helps." / "Feel free to reach out."

The recipient knows they can reply. End on the last substantive sentence. If a follow-up action genuinely needs offering, make it a concrete item in the body ("If you want these as issues, say so and we'll file them with repro steps" belongs in the list, not as a sign-off), or leave it out.

## 16. Copy-paste drafts go in a plaintext block

When the user asks for a draft they will copy somewhere (a PR comment, an email, an issue reply, an Asana comment), deliver the draft inside a fenced plaintext block containing exactly the text to paste — nothing else in the block, no chat commentary mixed in. The block's content is formatted for its destination, not for chat: if the destination renders markdown poorly or at all unknown, keep the draft bare (numbered lists and blank lines only). Commentary about the draft goes outside the block.

## Examples

For concrete before/after examples showing these rules applied, see [examples/bad-examples.md](examples/bad-examples.md) and [examples/good-examples.md](examples/good-examples.md).
