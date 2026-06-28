# STATUS — dte-rails-toolkit

_Living tracker. Last updated: 2026-06-28._

**What this is:** a general-purpose toolkit of **runnable, deterministic Rails checkers** — CI-friendly
linters that flag the failures that produce *no error*. A **staging home**: individual checkers/skills land
here, and a category graduates into its own focused plugin once mature (as the Hotwire checkers became
[hotwire-rails-toolkit](https://github.com/davidteren/hotwire-rails-toolkit)). The deterministic layer that
complements the LLM-driven toolchain — and the grounding pre-pass that
[dte-skills](https://github.com/davidteren/dte-skills) runs before its review lenses.

**Current:** **v0.1.1**, 2 skills, public. Install: `claude plugin marketplace add davidteren/dte-rails-toolkit`
→ `claude plugin install dte-rails-toolkit@dte-rails-toolkit-marketplace`.

---

## Shipped ✅

| Skill | Catches | Checker |
|---|---|---|
| `layer-boundary-lint` | Rails layering violations: `Current.` read in models, `request`/`params` in the domain layer (services **and** interactors), raw `.where/.order/.joins/.pluck` in controllers/views, mailer/HTTP I/O in `after_*` callbacks, off-layer `Current` writes, oversized `Current` | `lint_layer_boundaries.sh` (bash + python3) |
| `rails-test-smell-checker` | Test smells (Minitest **and** RSpec): `sleep` in system tests, missing `disable_net_connect!`, stubbing the SUT, `has_css?`/`has_content?` in an assertion; caveated heuristics (Mystery Guest, tautological eq) | `lint_test_smells.sh` (python3) |

**Provenance:** distilled from a review of Rails reference books (palkan's *Layered Design for Rails*,
thoughtbot's *Testing Rails*) in the [Rails skills analysis](https://github.com/davidteren/dte-skills) lineage.
The convergent finding across 8 books: the gap our LLM-driven skills had was **deterministic checkers**, not
new topics/coders — this repo is that layer.

## Releases

- **v0.1.0** (2026-06-28) — repo created; extracted `layer-boundary-lint` + `rails-test-smell-checker` from
  the analysis adoption workbench. Each built against the hotwire-rails-toolkit bar and **verified both
  ways** (truthful on `miela_app` + flags a synthetic break); a real `PaperTrail.request` false positive was
  caught + fixed (negative lookbehind) at build time. Published public (MIT).
- **v0.1.1** (2026-06-28) — skill-lint clean: the keystone linter (palkan `reference.toc` + `no-orphans`)
  flagged both reference guides (a >100-line guide needs a `## Contents`; the guide must be a real markdown
  link from SKILL.md, not a backtick mention). Fixed → 2 pass / 0 fail, Plugin-wide PASS.

## Wired into

- **dte-skills v1.4.5** — `dte-arc-review` runs `layer-boundary-lint` as a deterministic pre-pass before its
  LLM architecture lenses; `dte-test-auditor` runs `rails-test-smell-checker` before its quality lens. Both
  Optional ⚪ (degrade-with-a-note if not installed) — the checker **grounds**, never replaces, the LLM pass.

---

## Backlog 🔭

Status: ☐ todo · ◐ designed/parked · ▶ next.

### Checker candidates (from the Books review — `dte-skills:Books/learnings/00_INDEX.md`, Tier-2)
- ☐ **rails-n1-guardrail-check** — assert N+1 *defenses exist* (config presence + 2 narrow grep patterns).
  NOT a general N+1 detector (Bullet/Prosopite own that).
- ☐ **rails-csv-io** — streaming import/export template + 3-footgun checker (whole-file load, encoding/BOM,
  `create!`-in-loop with no transaction/row-error collection).
- ☐ **cable-stream-security** — websocket/Turbo-Stream hardening checker (signed stream ids, reject
  unauthorized subs, `allowed_request_origins`, never `constantize` client strings). Stack-agnostic.
- ◐ **geocoding-guard** / **ruby-hotspot-finder** — the Books review recommended folding these into existing
  skills (performance-reviewer / rails-testing-v8 / dte-tooling-scan) rather than standalone; park here only
  if that proves wrong.

### Graduation rule
When a category here has enough mature, verified checkers to stand alone (e.g. a cluster of
security checkers, or query/perf checkers), extract it into a focused plugin and leave a pointer — the
`dte-workflows → dte-skills` and Hotwire-checker extractions are the precedent.

---

## How to add a checker (the bar)

1. **Deterministic + names its ceiling.** Heuristic text/AST scan, not a full parser — say so. A clean run
   is a gate, not a proof.
2. **Verified both ways** before shipping — truthful on a **real** app (no false positives) **and** flags a
   **synthetic** broken case. False positives are the failure mode; demote a shaky rule to a caveated
   heuristic or drop it (don't ship it loose).
3. **Passes the skill-lint** (`## Contents` on >100-line guides, real markdown links, no orphan refs).
4. Bump version in both manifests, `claude plugin validate .`, push, `claude plugin update`.
