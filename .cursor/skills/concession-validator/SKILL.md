<goal>RETIRED 2026-09-10. The concession validator is now one section of the COMPLETION JUDGE (`~/.cursor/skills/completion-judge`), which rules on every completion event (Complete, pr-create, blocked=Yes) in a fresh headless context outside the run. Nothing invokes this skill any more: the gate `hooks/require-completion-judgment.sh` runs the judge itself and the run never writes a verdict.</goal>

<references>
- Taxonomy (moved verbatim): `~/.cursor/skills/completion-judge/references/concession-taxonomy.md`
- Rubric: `~/.cursor/skills/completion-judge/references/rubric.md` (dimension J5 deferral-validity carries the block / downgrade judgment)
- Why: the validator ran INSIDE the conceding session (19 of 19 verdicts in the 14 days before retirement were written by the run's own Bash, typically 30 to 60 seconds after loading the skill), so it was self-grading with a taxonomy in front of it.
</references>
