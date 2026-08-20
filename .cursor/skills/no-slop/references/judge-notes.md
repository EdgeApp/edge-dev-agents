# V2 semantic-judge calibration notes

Material for the small-model judge stage of no-slop-lint.sh (designed
2026-07-28, built 2026-08-19; see the lint header for the architecture:
wide-net regex for recall, judge for precision, verdict cache, fail-open,
default-clean). Rules judged: courtesy-ender, forward-reference,
validation-preamble, aphorism-formula (SKILL rule 17).
Distilled from blader/humanizer's detection guidance (MIT), adapted to this
machine's technical writing.

## Judge on clusters, not isolated tells

A single tell means nothing. One em dash, one "however", one short emphatic
sentence, one bold lead-in: all normal writing. The judge flags a sentence only
when the pattern is unambiguous in isolation (a count-announcement whose
deletion loses nothing) or when tells cluster.

## What NOT to flag (false-positive classes)

- Technical vocabulary that overlaps banned filler: key (cryptographic), harness
  (test), robust (failure-tolerance), ecosystem/landscape in literal use,
  underscore (the character). The lint's AMBIGUOUS set; the judge decides by
  sense, which is the whole reason it exists.
- Formal or polished prose without specific tells. Dry is not slop.
- One short sentence for emphasis. Flag staccato only in runs.
- A deliberate hedge ("unverified: X"). Hedges are information when they
  change what the reader should do.
- Quoted or discussed text: never flag a banned phrase inside a quotation, a
  title, or an example where the phrase is the subject.
- Bold lead-in list items whose content adds beyond the lead-in (operator
  ruling, 2026-07-28).

## Preserve human/technical signals

Specific hard-to-fabricate detail (line numbers, UDIDs, timings, exact error
strings), mixed or unresolved judgments, self-corrections, uneven sentence
rhythm. Over-editing these is worse than missing a tell.

## Deliberately NOT adopted from humanizer (operator rulings, 2026-07-28)

- Title-case headings as a tell: our rule 12 already prescribes sentence case;
  no separate detection wanted.
- Inline-header vertical lists as a pattern: fine here when newline-formatted
  and non-restating (see rule 12).
- Voice calibration / personality injection: for ghost-writing prose; this
  machine writes technical artifacts where neutral-and-plain IS the correct
  voice (humanizer itself says so for technical text).
- Curly quotes, hyphenated-pair predicate grammar: marginal for our surfaces.
