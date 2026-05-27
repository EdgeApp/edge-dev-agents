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

## 9. Em dash discipline

Use em dashes sparingly — maximum one per paragraph, and only when parentheses or a comma won't work. AI text is riddled with em dashes.

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

## Examples

For concrete before/after examples showing these rules applied, see [examples/bad-examples.md](examples/bad-examples.md) and [examples/good-examples.md](examples/good-examples.md).
