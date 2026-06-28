# AGENTS.md — dte-rails-toolkit

A general-purpose suite of Claude Code **skills + runnable checkers** for Rails —
deterministic linters that flag the failures that produce *no error*. See
**[README.md](./README.md)** for the catalog and **[STATUS.md](./STATUS.md)** for
the living tracker (releases, backlog, what's wired where).

## What this is

The **deterministic layer** of a Rails AI toolchain. Coders and reviewers elsewhere
are LLM-driven; these are fast, exact, CI-gateable scripts that run as a grounding
**pre-pass** for the LLM reviewers (e.g. [dte-skills](https://github.com/davidteren/dte-skills)
runs them before its lenses). This repo is a **staging home** — a checker lands here
first, and a category graduates into its own focused plugin once mature (as the
Hotwire checkers became [hotwire-rails-toolkit](https://github.com/davidteren/hotwire-rails-toolkit)).

## How a skill is structured

```
skills/<name>/
  SKILL.md          # YAML frontmatter: name + description (the trigger). Then usage + ceiling.
  references/*.md   # what each rule means + the fix, grounded (cite the source book/path)
  scripts/*.sh      # runnable, dependency-free checker (bash, or bash + python3 for AST-ish scans)
```

## The bar for adding/editing a checker

- **Deterministic, names its ceiling.** Heuristic text/AST scan, not a full parser — the script must say
  so. A clean run is a *gate, not a proof*.
- **Verified both ways before shipping.** Run it against a **real** app (must be truthful — no false
  positives) **and** a **synthetic** broken case (must flag it + exit non-zero). This is non-negotiable: the
  sibling `lint_stimulus` shipped a typed-Values false positive because it was only tested on one app, and
  `layer-boundary-lint`'s `PaperTrail.request` false positive was caught here only because of the real-app
  run. Test on `miela_app` (the standing real target) or another live Rails repo.
- **False positives are the failure mode.** When a rule can't be made high-confidence cheaply, demote it to
  a caveated heuristic (doesn't fail CI unless `--strict`) or drop it — never ship it loose. Document drops.
- **Exit non-zero on findings** (CI-friendly); print `file:line` + the rule + the fix.
- **Passes the skill-lint** — `## Contents` on any >100-line reference, real markdown links from SKILL.md to
  every reference (a backtick path mention doesn't count), no orphan reference files.
- **One built and verified beats five stubs.** STATUS lists candidates; build on demand from the source
  analysis (`dte-skills:Books/learnings/`) — don't scaffold empty dirs.

## Graduation rule

When a category here has enough mature, verified checkers to stand alone, extract it into a focused plugin
and leave a pointer back. Precedent: `dte-workflows → dte-skills`, and the Hotwire checkers → hotwire-rails-toolkit.

## Release steps

Bump the version in **both** `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, run
`claude plugin validate .`, push, then `claude plugin update`.

## Provenance

Distilled from a review of Rails reference books (palkan's *Layered Design for Rails*, thoughtbot's
*Testing Rails*) in the analysis lineage; the selection rationale lives in `dte-skills:Books/learnings/00_INDEX.md`.
