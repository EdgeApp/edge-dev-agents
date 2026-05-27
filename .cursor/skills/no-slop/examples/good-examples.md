# Good Examples — Human-Sounding Rewrites

Each example below is a rewrite of the corresponding bad example from [bad-examples.md](bad-examples.md).

---

## Example 1: Project Description

> React Query handles data fetching, caching, and background sync for React apps. You describe what data you need, and it handles refetching, deduplication, and cache invalidation. The community is large — over 40k GitHub stars — and most major React codebases have adopted it.

**Why this works:**
- Opens with what it does, not how important it is
- "handles" and "is" instead of "serves as" or "boasts"
- Specific number (40k stars) instead of "vibrant community"
- No promotional adjectives
- No "not only... but also"

---

## Example 2: Blog Post Intro

> Machine learning and NLP have converged over the past five years, mostly because transformer architectures turned out to work well for both. This post covers how that happened and what it means if you're building products that process text.

**Why this works:**
- No "in today's landscape" opener
- No "let's delve into"
- States the timeframe ("past five years") instead of vague "rapidly evolving"
- Says what the post will cover, directly
- Conversational but not chummy

---

## Example 3: Email Draft

> Quick note about the Q3 infrastructure migration. We're moving the main API cluster to the new cloud provider. The main risk is compatibility with the legacy auth system — it uses a session format the new platform doesn't support natively. I've outlined two workarounds in the attached doc. Can we discuss Thursday?

**Why this works:**
- Gets to the point immediately
- Names the specific risk instead of "faces challenges"
- No "represents a significant shift" or "crucial"
- Uses "uses" instead of "leverages" or "utilizes"
- Ends with a concrete action, not "it remains to be seen"
- Contractions ("we're," "doesn't," "I've") sound natural

---

## Example 4: Documentation

> This module handles communication between microservices. It serializes messages, retries failed calls with exponential backoff, and trips a circuit breaker after five consecutive failures. Errors are caught at the transport layer and returned as typed results — callers don't need try/catch blocks.

**Why this works:**
- "handles" instead of "plays a crucial role in facilitating"
- Lists what it actually does with specifics (exponential backoff, five failures)
- "is" and "are" as copulas
- No "additionally," no "holistic," no "robust"
- One em dash, used purposefully
- Technical detail instead of vague claims about "reliability"

---

## Example 5: PR Description (bonus)

**Bad:**
> This PR represents a significant enhancement to our authentication system. It leverages modern cryptographic patterns to foster a more robust security posture, showcasing our commitment to safeguarding user data. The changes encompass token validation, session management, and rate limiting, providing a comprehensive solution that elevates our platform's security to new heights.

**Good:**
> Replaces the JWT validation logic with Ed25519 signatures. Adds per-user rate limiting (100 req/min) and moves session tokens from cookies to HttpOnly + SameSite=Strict. The old HMAC-SHA256 tokens are still accepted for 30 days during migration.

**Why this works:**
- Says exactly what changed
- Includes specific numbers and technical details
- No promotional language about "elevating" or "commitment"
- Migration plan is stated as a fact, not a "challenge"
