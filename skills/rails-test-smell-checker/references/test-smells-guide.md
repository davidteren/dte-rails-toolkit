# Rails test-smell guide

Grounded in thoughtbot's *Testing Rails* "Antipatterns" chapter (see
`Books/learnings/testing-rails.md`). Each smell: **what** the checker flags,
**why** it's a problem, **the fix**. Rules are split by confidence — HIGH ones
fail CI; HEURISTIC ones are caveated and need a human glance.

## Contents

- The red-first principle · HIGH: `sleep-in-feature`, `missing-net-guard`, `stub-the-sut`,
  `predicate-in-assertion` · HEURISTIC: `mystery-guest`, `tautological-eq` · Deliberately not flagged

## The principle behind all of it: red-first

A test that has never failed has never been shown to test anything. If you
can't watch it go red, you don't know it can catch the bug it's supposed to
catch — comment out the production line it covers and confirm the test fails,
*then* make it pass. This is the same signal mutation testing automates: a
test that survives every mutant is a test that asserts nothing. Most smells
below are variants of "this test is green for the wrong reason" — it passes
whether or not the code works.

---

## HIGH confidence (hard flag — fails CI)

### `sleep` in a feature/system test — `sleep-in-feature`
**What:** a literal `sleep` statement inside a `test/system/**`, `*_system_test.rb`,
`spec/system/**`, or `spec/features/**` file (or a spec tagged `type: :system`/`:feature`).
**Why:** `sleep N` is flaky by construction — it's a bet that the page settles
in under N seconds. Too short and it fails on a slow CI box; too long and the
suite crawls. Either way the wait is unconditional.
**Fix:** wait on a *condition*, not the clock. Capybara's matchers
(`have_css`, `have_content`, `have_button`) auto-retry up to `default_max_wait_time`,
so `expect(page).to have_content("Saved")` blocks exactly as long as needed and
no longer.

### Missing WebMock/VCR guard — `missing-net-guard`
**What:** the suite references an external HTTP client (`Net::HTTP`, `Faraday`,
`HTTParty`, `RestClient`, `open-uri`/`URI.open`) but no no-real-connections
guard is configured anywhere in it.
**Why:** without a guard, a stubbed-out test that misses one request silently
hits the live API — slow, non-deterministic, and occasionally destructive.
**Fix:** add `require "webmock/minitest"` to `test_helper.rb` (this alone
disables real connections by default — that is why the checker treats a WebMock
*require* as satisfying the guard, not only an explicit `disable_net_connect!`),
or configure VCR. The checker is satisfied by any of: `require "webmock"`,
`WebMock.…`, `disable_net_connect!`, `require "vcr"`, or `VCR.…`.

### Stubbing the System Under Test — `stub-the-sut`
**What:** `allow(subject)` / `allow(described_class)` /
`expect(subject).to receive` / `expect(described_class).to receive`.
**Why:** stubbing a method *on the thing you're testing* means the test
asserts against your own stub, not the real behaviour. It's green by
definition. It almost always signals a collaborator that wants extracting into
its own object (which you'd then inject and stub at the boundary).
**Fix:** extract the collaborator and stub *it*, or set up real state so the
SUT exercises its real code path.

### Boolean predicate inside an assertion — `predicate-in-assertion`
**What:** a Capybara predicate (`has_css?`, `has_content?`, `has_selector?`,
`has_text?`, `has_button?`, …) used inside `expect(...)`, `assert`, `refute`,
or `should` on the same line.
**Why:** the `has_*?` predicates return a plain boolean and do **not** retry.
`expect(page.has_css?(".done")).to be true` evaluates the page once,
immediately — so on a slow render it returns `false` and the test flakes, and
more subtly it can pass for the wrong reason. (The non-bang `have_*` matcher
form is the one that auto-waits.)
**Fix:** use the matcher form: `expect(page).to have_css(".done")` /
`assert_selector ".done"`. These retry until `default_max_wait_time`.

---

## HEURISTIC (caveated — review, does not fail CI unless `--strict`)

These are flagged conservatively and will sometimes be fine in context. They
are signals to look, not verdicts.

### Mystery Guest — `mystery-guest`
**What:** a `setup`/`before` block longer than 25 lines, or 5+ `let!`
definitions in one file.
**Why:** when the data a test depends on lives in a big shared block far from
the test body, the reader can't tell what each test actually needs — the
"Mystery Guest." Eager `let!` runs for *every* example whether it needs the
record or not, slowing the suite and coupling tests to incidental state.
thoughtbot's stated position: prefer plain Ruby setup methods over
`let`/`subject`/`before`, and set up only what the test under the cursor needs.
**Fix:** push setup down into the individual tests (or small named helper
methods) so each test names its own dependencies. **Caveat:** a long block of
genuinely shared, cheap fixture references can be reasonable — judge by whether
a reader can follow what a single test depends on.

### Tautological equality — `tautological-eq`
**What:** `expect(x).to eq(x)` or `assert_equal x, x` where both sides are the
*textually identical* expression.
**Why:** the assertion re-implements (or literally repeats) its own expected
value, so it stays green even when the value is wrong — a classic false-green.
The broader version is an expectation that re-runs production logic to compute
the "expected" (`expect(x).to eq Item.pluck(:name).uniq.sort`); that can't be
caught textually, so only the identical-expression case is flagged here.
**Fix:** assert the expected *literal* you actually want
(`assert_equal "new-client-name", client.slug`). **Caveat:** only the literal
identical-token case is detected; review for the dressed-up version by eye.

---

## Deliberately NOT flagged (dropped for false-positive risk)

The thoughtbot catalog has more smells than this checker enforces. These were
dropped because catching them statically produces more false positives than
signal — they are better left to `dte-test-auditor` (the LLM judge):

- **Bloated factories** (factory defines more attrs than the model validates) —
  needs cross-file model-validation parsing; brittle and noisy.
- **Factories-used-as-fixtures** (many named single-purpose `factory :pam`
  defs) — plenty of legitimately named factories exist; can't tell intent.
- **Testing code you don't own** (unit-testing `save`/`valid?`/a gem's HTTP) —
  not reliably distinguishable from legitimate integration tests.
- **Copy/DOM coupling** (asserting literal copy or CSS class names instead of
  i18n keys / `data-role`) — far too many false positives; asserting visible
  text is often exactly right.

These remain in scope for `dte-test-auditor`, which can read intent.
