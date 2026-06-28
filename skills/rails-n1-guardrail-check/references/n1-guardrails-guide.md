# N+1 guardrail rules — what each flag means and how to fix it

Grounded in Benito Serna's *Avoid/Fix N+1 Queries on Rails* (see
`dte-skills:Books/learnings/n-plus-one-queries.md`). This checker does **not**
detect arbitrary N+1s — Bullet, Prosopite, and `strict_loading` already do that
at runtime, with query fingerprints, far better than a grep can. It does two
things a grep *can* do with high confidence: assert a defense is wired up at
all, and flag the two N+1 shapes that are mechanically greppable.

## Contents

- The principle: detection is runtime, presence is static · `no-n1-guardrail`
  (advisory) · `count-in-view` / `count-in-loop` (HIGH) ·
  `relation-breaker-in-loop` (HEURISTIC) · Decision rules: count vs size vs
  length, the includes-ignored trap, counter_cache both-sides · Demoted/dropped

## The principle: detection is runtime, presence is static

An N+1 is "a failure with no error" — the page renders, the tests are green, it
is merely slow. The mature detectors (`strict_loading`, Prosopite, Bullet,
NPlusOneControl) catch it at **runtime**, by fingerprinting repeated queries
while code executes. They only help if they are *installed and exercised*. So
the one thing worth checking statically, in CI, at rest is: **is any guardrail
wired up at all?** Plus the two anti-patterns whose textual shape is
unambiguous enough to flag without a parser. Everything else stays with the
runtime tools — trying to infer N+1s from text reinvents Bullet, worse.

---

## `no-n1-guardrail` — no defense is wired up (advisory)

**What:** none of the following is present anywhere in the app — no
`config.active_record.strict_loading_by_default` / `action_on_strict_loading_violation`
in `config/**`, and no `prosopite` / `bullet` / `n_plus_one_control` gem in the
`Gemfile` or test setup.
**Why:** with no guardrail, every N+1 introduced from now on passes CI
silently. There is nothing to make the failure visible.
**Fix (the lazy win):** the platform already ships the defense — enable
`config.active_record.strict_loading_by_default = true` (Rails ≥6.1). It raises
(or logs, via `action_on_strict_loading_violation`) when code lazily loads an
association that wasn't preloaded. Or add a detection gem and a **test-suite
gate** (e.g. `Prosopite.raise = true` in the test env, or NPlusOneControl
matchers) so a new N+1 fails the build. Advisory: it fires once, and only fails
CI under `--strict`.

---

## `count-in-view` / `count-in-loop` — `recv.assoc.count` (HIGH)

**What:** a dotted association count — `record.comments.count` — inside a view
template (`count-in-view`) or inside an `.each`/`.map` block (`count-in-loop`).
**Why:** `.count` on an association **always** issues a `SELECT COUNT(*)`
query. In a row partial or a loop that is one COUNT *per row* — the N+1 you
never see because the page works. Even on a single object in a view it is a
needless query on every render.
**Fix:** prefer `.size`, and back it with a counter cache. `.size` is the safe
default: it returns the counter-cache column if present, else the count of
already-loaded records, else a single COUNT — never worse than `.count`, often
free. Add `counter_cache: true` so the count is a column read with no query at
all (see the both-sides rule below). Reach for `.count` only when you
deliberately want a fresh COUNT and the records aren't loaded.

---

## `relation-breaker-in-loop` — `recv.assoc.order(/.where(/.pluck(` in a loop (HEURISTIC)

**What:** a relation builder (`.order(`, `.where(`, `.pluck(`) chained on an
association reference *inside* an `.each`/`.map` block or a view loop —
`post.comments.order(:created_at).last`.
**Why:** this is the **includes-ignored trap**. You can add a perfectly correct
`Post.includes(:comments)` and still N+1, because calling `.order` / `.where` /
`.pluck` on the association builds a *new* relation and runs a *new* query,
ignoring the preloaded records entirely. The eager-load is silently wasted.
**Fix:** operate on the loaded records in Ruby (`comments.sort_by(&:created_at).last`),
or define the ordering/filter as a **default-ordered or scoped association** and
preload *that* — e.g. `has_many :comments, -> { order(:created_at) }`, then
`includes(:comments)` returns them already ordered, no per-row query.
**Caveat (why HEURISTIC):** "inside a loop" is detected by indentation, and the
checker can't prove the receiver is a preloaded association vs a local relation.
Open the file and confirm it's an association that an `includes` should have
covered.

---

## Decision rules (cite these verbatim)

**count vs size vs length** — in a view or loop:
- `.count` → always a `SELECT COUNT(*)` query. Avoid in views/loops.
- `.size` → the safe default: counter-cache column → loaded-records count →
  one COUNT, in that order. Use this.
- `.length` → forces the *whole* association to load into memory. Only when you
  already need the records.
- Nate Berkopec's tip: if the view both counts *and* iterates the same records,
  use `.load.size` — load them once, then `.size` reads the loaded set.

**The includes-ignored trap** — having `includes(:comments)` does **not** save
you if you then call `.order` / `.where` / `.first` / `.last` / `.count` /
`.pluck` on the association inside the loop; each re-queries per row. Fix in
Ruby on the loaded records, or move the ordering/filter into a default-ordered /
scoped association and preload that.

**counter_cache both-sides** — for `.size` to read the cache, set the option on
**both** sides of a custom-column cache, or `.size` silently falls back to a
COUNT. The convention column is `#{table}_count` (e.g. `comments_count`).
Backfilling: `reset_counters` is fine for *few* records but runs one query per
row — for *many* records, backfill with raw SQL
(`UPDATE … SET comments_count = (SELECT COUNT(*) …)`) in one statement.

---

## Demoted / dropped (false-positive control)

False positives are the failure mode for a CI gate, so these were narrowed or
cut:

- **Bare `.first` / `.last` as a relation-breaker — dropped.** The spec lists
  them, but `.first`/`.last` on an *already-loaded* association returns a loaded
  record without re-querying, so flagging them bare is a false positive. The
  real trap is `.order(...).first/last`, which the `.order(` match already
  catches. Only `.order(` / `.where(` / `.pluck(` are flagged.
- **`.count` with a block or on an Enumerable transformer — excluded.**
  `tags.uniq.count { … }` is in-memory `Enumerable#count`, not a SQL count;
  block-form counts and `.uniq`/`.map`/`.select`/… receivers are skipped.
- **Relation-method receivers — excluded.** `scope.distinct.pluck(...)` in a
  loop is a deliberate relation chain on a local, not an association ignoring an
  eager-load; pre-words like `distinct`/`all`/`where`/`includes` are skipped.
- **General static N+1 inference — never built.** `rails-n1-detector` was
  explicitly rejected: it duplicates Bullet/Prosopite/`strict_loading` worse.
  Detection stays at runtime; this checker stays at presence + two shapes.
