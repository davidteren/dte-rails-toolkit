---
name: rails-n1-guardrail-check
description: Fast, deterministic, no-LLM checker that asserts a Rails app's N+1 DEFENSES exist (strict_loading config, or a prosopite/bullet/n_plus_one_control gem + test gate) and flags two narrow, high-confidence N+1 anti-patterns — `.count` on an association in a view or loop (a COUNT query per row; use counter_cache + `.size`), and a relation-breaker (`.order`/`.where`/`.pluck`) chained on an association inside a loop (the "includes-ignored" trap that silently defeats an eager-load). This is NOT a general static N+1 detector — Bullet/Prosopite/strict_loading do that at runtime; a grep-based detector is strictly worse. Use as a CI gate or a cheap pre-pass before the runtime gems / dte-perf, to catch the failure-with-no-error (works, tests green, just slow) at rest. Emits file:line + rule + fix.
---

# rails-n1-guardrail-check

A runnable, dependency-free gate for the **mechanically-checkable** part of N+1
defense. It does **two** things — nothing more, on purpose:

1. **Asserts a guardrail is wired up at all** — `strict_loading` config, or a
   `prosopite` / `bullet` / `n_plus_one_control` gem + test gate.
2. **Flags the two N+1 shapes a grep can catch with high confidence** —
   `.count` on an association in a view/loop, and a relation-breaker chained on
   an association inside a loop.

It is **not** a general static N+1 detector. Bullet, Prosopite, and
`strict_loading` detect N+1s at runtime by fingerprinting repeated queries —
that is the right place to do it, and a grep-based detector is strictly worse.
This checker is the deterministic *presence* assertion the runtime tools can't
make about themselves, plus two narrow patterns.

Full per-rule rationale, the count-vs-size-vs-length / includes-ignored /
counter_cache decision rules, and the demoted patterns:
[`references/n1-guardrails-guide.md`](references/n1-guardrails-guide.md).

## When to use

- As a **CI gate** — fail the build when an association `.count` lands in a view
  or loop, or warn that no N+1 guardrail is wired.
- As a cheap **pre-pass before** the runtime gems / `dte-perf` /
  `performance-reviewer` — surface the greppable shapes with file:line first,
  then let the runtime tools and LLM lenses handle real detection.
- When onboarding an app and you want to know, at rest, whether N+1s can even be
  *caught* (is `strict_loading` on? is Prosopite gating the test suite?).

Not for: detecting arbitrary N+1s (that's the runtime gems), or prescribing
preload strategy for a measured slow query (that's `dte-perf`).

## What it flags

| Rule | Flags | Severity |
|---|---|---|
| `no-n1-guardrail` | no `strict_loading` config **and** no prosopite/bullet/n_plus_one_control gem or test gate found | advisory |
| `count-in-view` | `recv.assoc.count` inside `app/views/**` (`.erb`/`.haml`/`.slim`) | HIGH |
| `count-in-loop` | `recv.assoc.count` inside an `.each`/`.map` block in `app/**/*.rb` | HIGH |
| `relation-breaker-in-loop` | `recv.assoc.order(`/`.where(`/`.pluck(` inside a loop — defeats an eager-load | HEURISTIC |

HIGH fails CI. HEURISTIC + advisory are caveated — they print but only fail
under `--strict`. (False positives are the failure mode for a gate, so anything
that can't be made high-confidence cheaply is demoted, not shipped loose.)

## How to run

```bash
scripts/lint_n1_guardrails.sh path/to/rails-app          # defaults to .
scripts/lint_n1_guardrails.sh path/to/rails-app --strict # heuristic + advisory also fail
SKIP="count-in-loop,relation-breaker-in-loop" scripts/lint_n1_guardrails.sh .
```

- `SKIP="rule-a,rule-b"` — turn individual rules off.
- `--strict` — HEURISTIC and advisory findings also fail the exit code.
- Exit: `0` clean (no HIGH), `1` HIGH findings (or any under `--strict`), `2`
  bad usage / no `python3`.
- Needs `python3` (block/loop walking, not a Ruby load).

## Ceiling

Heuristic **line + indentation scan, NOT a Ruby/ERB parser**. It does not load
code, resolve constants, or know which methods are real associations vs plain
Ruby collections — it targets the `recv.assoc.count` / `recv.assoc.order(`
*shapes* inside views and `.each`/`.map` blocks (blocks found by indentation).

- It flags the `x.assoc.count` **dotted chain** only — `Post.count` (one query)
  and bare `@items.count` (an Array) are not matched. Block-form `.count { … }`
  and Enumerable receivers (`.uniq.count`) are skipped as in-memory.
- `relation-breaker-in-loop` is HEURISTIC: it can't prove the receiver is a
  *preloaded* association vs a local relation, and skips relation-method
  receivers (`scope.distinct.pluck`). Bare `.first`/`.last` are deliberately not
  flagged (no re-query on a loaded association) — only `.order(.where(.pluck(`.
- Loop detection relies on the `.each`/`.map do` opener and its `end` /
  `<% end %>` each living on their own line at consistent indentation.

A clean run is a **gate, not a proof**. Treat every flag as "open the file and
confirm". This complements — does not replace — the runtime N+1 gems
(`strict_loading`/Prosopite/Bullet) and the LLM perf reviewers (`dte-perf`,
`performance-reviewer`), which catch the N+1s this can't see at rest.

## Verified

- **miela_app** (Rails 8, no guardrail wired): 10 genuine `count-in-view`
  findings — `client.invoice_keys.count` / `team.members.count` in `_*_row`
  partials rendered with `collection:` (real COUNT-per-row N+1s, associations
  confirmed in the models) plus single-object `@x.assoc.count` in `show` views
  (real per-render COUNT) — 1 genuine `relation-breaker-in-loop`
  (`ik.billing_codes.order(:code).each`), and the `no-n1-guardrail` advisory.
  Zero false positives after fixing an in-memory `.uniq.count { }` over-match
  and a `scope.distinct.pluck`-in-loop over-match (relation chain, not an
  association).
- **Synthetic break**: a temp view with `post.comments.count` +
  `post.comments.order(:created_at).last` in an `@posts.each` loop and no
  `strict_loading` config — `count-in-view` (HIGH), `relation-breaker-in-loop`
  (HEURISTIC), and the advisory all fire, exit 1; the in-memory
  `@tags.uniq.count { }` and `@posts.count` are correctly not flagged; wiring
  `strict_loading_by_default` removes the advisory.
