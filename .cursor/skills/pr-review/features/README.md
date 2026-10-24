# Review features

/pr-review loads judgment rules per feature, chosen from the PR's changed files.
This directory is the canonical copy (synced to edge-dev-agents as
`.cursor/skills/pr-review/features/`). The loader is
`../scripts/feature-routing.rb`; `github-pr-review.sh features` runs it for a PR.

```
features/
  lenses.yaml                 lens catalog (name, focus)
  <repo>/features.yaml        one per GitHub repo name, e.g. edge-react-gui/
  <repo>/<feature>.rules.yaml rule files the features name
```

## features.yaml

```yaml
features:
  - name: Stealth send/swap          # unique in this file
    paths:                           # globs against repo-relative paths
      - src/components/scenes/Stealth*.tsx
      - src/util/stealth/**
      - '!src/**/__tests__/**'       # leading ! excludes
    owners: [some-login]             # optional, informational
    lenses: [keys-security, amount-precision]   # optional; names from lenses.yaml
    rules: stealth.rules.yaml        # optional; a file in this directory
    status: active                   # candidate | active | retired
```

Unknown keys are schema errors. Globs follow `File.fnmatch` with pathname,
extglob and dotmatch flags: `*` stays inside one directory, `**/` spans
directories, `{a,b}` alternates, matching is case-sensitive, and a trailing
`dir/**` means everything under `dir`. A file matches a feature when it matches
at least one plain pattern and no `!` pattern.

Status decides loading: `active` loads; `candidate` is a shadow feature, listed
in the manifest's `shadow` but loaded only by `/pr-review --candidates` (which
never posts); `retired` never loads.

## Rule files

```yaml
rules:
  - id: stealth-quote-before-send    # kebab-case, unique across the repo's rule files
    rule: Stealth sends re-fetch the quote after the user confirms.
    severity: warning                # critical | warning | suggestion
    scope: [src/util/stealth/**]     # optional; defaults to the feature's paths
    enabled: true                    # optional; default true
    sources:                         # optional; the review comments the rule came from
      - https://github.com/EdgeApp/<repo>/pull/<n>#discussion_r<id>
```

A rule loads when its feature loads, it is enabled, and a changed file matches
its scope. Rule ids become finding tags (`rule:<id>`), so they must not reuse an
id from review-standards.mdc or typescript-standards.mdc; `submit` refuses a
tag whose id is in neither the standards nor the review's feature manifest.

## lenses.yaml

`{lenses: [{name, focus}]}`. A feature's `lenses` choose which extra checkers
/pr-review step 4b spawns; `correctness` always runs and is never declared.

## Base branch, never the PR branch

The loader reads every file here from a committed ref: edge-dev-agents `main`,
or the PR's base branch when the PR under review is on edge-dev-agents itself.
A feature or rule edit therefore takes effect once it is synced to `main`, and
a PR cannot change the rules its own review applies. A repo with no
`features.yaml` on that ref routes to correctness only, which is the review as
it ran before features existed.

## Checking a file

```bash
~/.cursor/skills/pr-review/scripts/feature-routing.rb validate --repo <repo> --root ~/.cursor/skills/pr-review/features
```
