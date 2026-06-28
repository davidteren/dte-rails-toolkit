---
name: layer-boundary-lint
description: Deterministically flag layer-boundary violations from palkan's "Layered Design for Rails" — the failures that produce no runtime error but leak request-global state, push queries into the wrong layer, or hide I/O in model callbacks. Use as a cheap, reproducible PRE-PASS before an architectural review, when auditing a Rails app for layering smells, or in CI to gate Current-attributes misuse, request leaks into the domain layer, query-building in controllers/views, and I/O in after_* callbacks. Emits file:line + the rule that fired.
---

# layer-boundary-lint

A runnable grep-based gate for the **mechanically-detectable** layer violations
the *Layered Design for Rails* book names. The `layered-rails` plugin documents
every one of these as prose and ships no executable check; this is that check.

Full per-rule rationale and fixes: [`references/layer-boundaries-guide.md`](references/layer-boundaries-guide.md).

## When to use

- As a **pre-pass before** `layered-rails-reviewer` / `dte-arc-review` — surface
  the greppable violations with file:line first (cheap, reproducible), then let
  the LLM lenses handle the semantic ones.
- Auditing a Rails app for layering smells, or gating them in CI.
- Specifically when you suspect: `Current` read from models, the request/params
  leaking into services/interactors, query-building in controllers/views, mail
  or HTTP fired from `after_*` callbacks, or a bloated `Current`.

## The rules

| Label | Flags | Severity |
|---|---|---|
| `current-in-models` | `Current.<attr>` **read** in `app/models/**` | hard |
| `request-in-domain` | bare `request.` / `params[...]` / `params.permit\|require` in `app/services/**` & `app/interactors/**` | hard |
| `query-in-controller` | `.where(` `.order(` `.joins(` `.pluck(` in `app/controllers/**` & `app/views/**` | hard |
| `io-in-callback` | `deliver_later\|deliver_now` / `Net::HTTP\|Faraday\|HTTParty\|RestClient` inside an `after_*` model callback (inline block or referenced method) | hard |
| `current-write-location` | `Current.<attr> =` outside `app/{controllers,jobs,channels,middleware}` | hard |
| `skip-action` | `skip_before/after/around_action` | advisory |
| `current-attr-count` | `Current` declares > `CURRENT_ATTR_MAX` (default 7) attributes | advisory |

It checks **both** `app/services/` and `app/interactors/` — apps have one or the
other (this project mandates interactors).

## How to run

```bash
scripts/lint_layer_boundaries.sh path/to/rails-app          # defaults to .
SKIP="skip-action,query-in-controller" scripts/lint_layer_boundaries.sh .
CURRENT_ATTR_MAX=10 STRICT=1 scripts/lint_layer_boundaries.sh .
```

- `SKIP="rule-a,rule-b"` — turn individual rules off.
- `CURRENT_ATTR_MAX=N` — threshold for `current-attr-count`.
- `STRICT=1` — advisory findings also fail the exit code.
- Exit: `0` clean, `1` hard findings (or any with `STRICT=1`), `2` bad usage.
- Needs `python3` (used for block/brace walking, not a Ruby load).

## Ceiling

Heuristic **path-scoped grep, not a Ruby parser**. It scans file paths + line
text; it does not load code or resolve constants.

- Pure comment lines are skipped, but a pattern inside a **string** or a
  **trailing inline comment** can still match (rare for these tokens).
- `request-in-domain` matches only the **bare** request object — `.request` on
  another receiver (e.g. `PaperTrail.request`) is correctly ignored. `params` is
  matched only as `params[...]` / `params.permit` / `params.require`.
- `io-in-callback` walks the callback's inline `do..end` block or its referenced
  `def` by **indentation**; unconventional formatting, or a callback passed a
  **dynamic** (non-literal-symbol) method name, can miss it.
- `query-in-controller` is volume-heavy on apps that genuinely build queries in
  controllers (true positives, but noisy) — `SKIP` it for a focused run.

Treat every flag as "open the file and confirm", not as proof. This is a
deterministic pre-pass that **complements, not replaces**, the LLM
`layered-rails-reviewer` / `dte-arc-review`.

## Verified

- **miela_app** (Rails 8, uses `app/interactors/`): 125 genuine findings — 1
  `current-in-models` (`identity.rb` reads `Current.session` in a model method)
  + 124 `query-in-controller` (controllers/views build queries inline). Zero
  false positives after fixing a `.request`-chain over-match (`PaperTrail.request`).
- **Synthetic break**: a temp app exercising all 7 rules — every rule fires,
  both `io-in-callback` forms (symbol method + inline block) caught,
  `PaperTrail.request` correctly not flagged, non-zero exit.
