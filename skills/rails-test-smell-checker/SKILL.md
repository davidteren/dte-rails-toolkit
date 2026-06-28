---
name: rails-test-smell-checker
description: Fast, deterministic, no-LLM static checker that flags test smells which make a Rails test suite flaky, slow, or unable to catch a real bug — `sleep` in feature/system tests, missing WebMock/VCR guard, stubbing the system under test, boolean predicates inside assertions, Mystery Guest setup, and tautological assertions. Reads BOTH Minitest (test/**/*_test.rb) and RSpec (spec/**/*_spec.rb). Use when adding a CI test-quality gate, reviewing a test suite for flakiness/false-greens, or pre-filtering before the dte-test-auditor LLM judge. This is a CHECKER, not a test-writer.
---

# Rails test-smell checker

Deterministic static analysis over a Rails test suite. It points at
`file:line` and names the smell. It **does not write or edit tests** — that's
how it stays out of the way of the test-writing skills (`rails-testing-v8`,
`minitest-coder`, `rspec-coder`) and the baseline. It reads **both Minitest
and RSpec**.

It complements **`dte-test-auditor`** (an LLM judge: coverage + quality +
mutation signal) by being the fast, no-LLM, CI-gateable pass. Run `--json` and
the auditor can consume its findings directly.

## When to use

- Wiring a test-quality gate into CI (fail the build on high-confidence smells).
- Reviewing an existing suite for flakiness and false-greens before trusting it.
- A pre-filter before `dte-test-auditor` — clear the cheap deterministic smells
  first, then spend LLM budget on the judgement calls.

Not for: writing tests, judging coverage, or assessing whether the *right*
things are tested — that's the auditor and the coder skills.

## Run

```bash
scripts/lint_test_smells.sh path/to/rails-app          # human-readable
scripts/lint_test_smells.sh path/to/rails-app --json   # for dte-test-auditor
scripts/lint_test_smells.sh path/to/rails-app --strict # also fail on heuristics
```

Exit: `0` = no high-confidence smells, `1` = high-confidence smells found (or
heuristics under `--strict`), `2` = bad usage / no `python3`.

## What it flags

**HIGH confidence (fails CI):**
- `sleep` in a feature/system test — flaky by construction.
- External HTTP referenced (`Net::HTTP`/`Faraday`/`HTTParty`/`RestClient`/`open-uri`)
  with no WebMock/VCR guard configured — tests can hit live APIs.
- Stubbing the SUT (`allow(subject)`/`allow(described_class)`/`expect(subject).to receive`).
- A boolean predicate (`has_css?`/`has_content?`/…) inside an `expect`/`assert`
  — can't fail meaningfully and doesn't auto-wait; use the `have_*` matcher.

**HEURISTIC (caveated — review, doesn't fail CI without `--strict`):**
- Mystery Guest: an oversized `setup`/`before` block, or many `let!` in a file.
- Tautological equality: `expect(x).to eq(x)` / `assert_equal x, x`.

Full what/why/fix for each, and the **red-first** principle behind them, in
`references/test-smells-guide.md`.

## Ceiling

Line-oriented regex plus indentation-based block matching — **not a Ruby
parser**. It assumes rubocop-style consistent indentation and deliberately
**under-reports**: false positives are the worse failure for a CI gate, so
anything ambiguous is emitted as HEURISTIC (caveated), never HIGH. The
predicate and tautology rules see only single lines (multi-line forms slip
through). Several thoughtbot antipatterns are **deliberately not flagged**
(bloated factories, factories-as-fixtures, testing-code-you-don't-own,
copy/DOM coupling) because they false-positive too readily — those stay with
`dte-test-auditor`, which can read intent. See the guide's "Deliberately NOT
flagged" section.

Verified: clean (0 findings, exit 0) on miela_app's 121-file Rails 8 Minitest
suite; flags all six rules and exits 1 on a synthetic broken suite.
