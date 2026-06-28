---
name: rails-csv-io
description: Fast, deterministic, no-LLM static checker for the three CSV import footguns that produce NO error in review but bite in production — loading a whole CSV into memory instead of streaming (CSV.read / CSV.parse(File.read) on an import path), missing encoding/BOM handling on file ingest (mojibake, or a BOM that nulls the first header), and create!/save!/update! inside a CSV row loop with no transaction and no per-row error reporting (first bad row aborts the import, no idea which row failed). Scans only import/upload-reachable code (controllers, jobs, services, interactors, models, lib). Use when adding a CI gate for a CSV import feature, or reviewing one for memory blow-up and silent/all-or-nothing imports. This is a CHECKER, not a CSV-writer.
---

# rails-csv-io

A runnable grep + block-walk gate for the **three CSV import footguns** that
recur in every real import feature and produce no error in review. Everything
else about CSV (`headers:`, `col_sep:`, custom converters, `CSV.generate`) is
stdlib any model writes correctly unprompted — this checker deliberately scans
only the durable footguns, not the prose.

Full per-rule what/why/fix, plus a reference template for a safe streaming
importer and a streamed exporter: [`references/csv-io-guide.md`](references/csv-io-guide.md).

## When to use

- Wiring a CI gate onto a CSV import feature (fail the build on the HIGH rules).
- Reviewing a CSV importer for memory blow-up on big files, or for the
  all-or-nothing / first-error-aborts import that can't tell the user which row
  failed.
- As a cheap deterministic pre-pass before an LLM review of an import path.

Not for: writing the importer (use the template in the guide), CSV *output*
formatting, or whole-app review.

## The rules

| Label | Flags | Severity |
|---|---|---|
| `whole-file-load` | `CSV.read(` / `CSV.parse(File.read(` — loads the entire file into memory | HIGH |
| `missing-encoding` | `CSV.foreach/read/table(` on a file with no `encoding:` (BOM / non-UTF-8) | HEURISTIC |
| `no-row-reporting` | `create!`/`save!`/`update!` in a CSV row loop with no transaction **and** no per-row error accumulation | HIGH |

`whole-file-load` ignores the block form `CSV.parse(a_string) { |row| ... }`
(streams over an in-memory string — correct). `no-row-reporting` is lexical: it
does not follow persistence extracted into a helper the loop merely calls.

## How to run

```bash
scripts/lint_csv_io.sh path/to/rails-app          # defaults to .
SKIP="missing-encoding" scripts/lint_csv_io.sh .  # turn a rule off
STRICT=1 scripts/lint_csv_io.sh .                 # heuristics also fail the exit code
```

- `SKIP="rule-a,rule-b"` — turn individual rules off.
- `STRICT=1` — the `missing-encoding` heuristic also fails the exit code.
- Exit: `0` clean, `1` HIGH findings (or any under `STRICT=1`), `2` bad usage.
- Needs `python3` (block/indentation walk, not a Ruby load).

## Ceiling

Heuristic **path-scoped grep + indentation block-walk, not a Ruby parser**. It
scans only import/upload-reachable layers
(`app/{controllers,jobs,services,interactors,models,lib}`) — a `CSV.read` of a
trusted config in an initializer or a one-off rake task is out of scope on
purpose (different risk than an upload).

- `no-row-reporting` is **lexical**: persistence extracted into a helper method
  the loop only calls is not followed (deliberate under-report). Any
  `transaction` in the enclosing method or any `rescue`/`errors <<` in the block
  suppresses the flag — tuned so false positives stay near zero.
- `missing-encoding` can't tell a trusted internal CSV from an untrusted upload,
  so it's a caveated HEURISTIC (fails CI only under `STRICT=1`).

Treat every flag as "open the file and confirm", not as proof. Complements — does
not replace — an LLM review. Full per-rule detail in
[`references/csv-io-guide.md`](references/csv-io-guide.md).

## Verified

- **miela_app** (Rails 8, real Backstage CSV import): 1 HIGH + 1 heuristic, both
  on `app/jobs/sync_all_users_job.rb` — `find_or_create_by!`/`update!` inside a
  `CSV.foreach` loop with no transaction and no per-row rescue (`no-row-reporting`,
  manually confirmed real: a bad row aborts the whole job, earlier rows committed,
  no per-row report), and the same `CSV.foreach` lacking an `encoding:` option
  (`missing-encoding`). The well-written `app/interactors/users/import_from_csv.rb`
  (block-parse of a string + per-row transaction + `rescue RecordInvalid`) and the
  two `CSV.generate` exporters are correctly **not** flagged — zero false positives.
- **Synthetic break**: a temp app with `CSV.read(f).each { User.create!(...) }` and
  `CSV.foreach(f) { u.save! }` — all three rules fire, exit 1; a clean control
  (string block-parse + transaction + per-row rescue) and a `find_each`/`encoding:`
  exporter produce zero flags.
