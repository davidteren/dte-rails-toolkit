# CSV import footguns — what each flag means and how to fix it

Grounded in *Mastering CSV in Ruby* (the analysis lives at
`dte-skills:Books/learnings/mastering-csv.md`). That source is ~90% stdlib any
model already writes correctly — `headers:`, `col_sep:`, custom converters,
`CSV.generate`. This checker deliberately ignores all of that and flags only the
**three durable footguns** that recur in every real import feature: memory
blow-up, encoding/BOM mojibake, and (the one the book itself gets wrong)
all-or-nothing imports with no per-row error reporting.

A clean run is a **gate, not a proof** — see the Ceiling at the end.

## Contents

- `whole-file-load` (HIGH) — streaming vs. loading the whole file
- `missing-encoding` (HEURISTIC) — BOM / non-UTF-8 uploads
- `no-row-reporting` (HIGH) — transaction + per-row error collection
- Reference template — a safe streaming importer + a streamed exporter
- Running · Ceiling

---

## `whole-file-load` — `CSV.read(...)` / `CSV.parse(File.read(...))`  (HIGH)

**What:** an import path loads the entire CSV into memory before iterating —
`CSV.read(path)` returns an array of every row; `CSV.parse(File.read(path))`
reads the whole file into a string *and then* parses it into an array.

**Why:** memory scales with file size. The book's own example OOMs on a 400 MB
upload. This is the one genuinely common, genuinely costly CSV footgun, and it
is invisible in review — it runs fine on the 12-row fixture and falls over on
the real file. Trust does not save you: a 400 MB *trusted* file OOMs too, so
streaming is strictly better here regardless of source.

**Fix:** stream. `CSV.foreach(path, headers: true) { |row| ... }` reads one row
at a time; `CSV.new(io)` streams an IO. Never materialise the whole file.

> `CSV.parse(a_string) { |row| ... }` (the **block** form, over a string already
> in memory) is fine and is **not** flagged — it streams over the string and the
> string isn't a file you read into memory.

---

## `missing-encoding` — `CSV.foreach/read/table(path)` with no `encoding:`  (HEURISTIC)

**What:** a file is ingested via `CSV.foreach` / `CSV.read` / `CSV.table`
(these always read a file/IO — you never hand them CSV *content*) with no
`encoding:` option.

**Why:** two real failures. (1) A non-UTF-8 upload raises
`CSV::MalformedCSVError` / "invalid byte sequence in UTF-8" mid-import. (2) A
file saved by Excel on Windows carries a **UTF-8 BOM**, so the first header
parses as `"﻿id"` instead of `"id"` — every `row["id"]` then returns `nil`
and the import silently does nothing. The book covers the encoding option and
*omits* the BOM, which is the half that bites.

**Fix:** `CSV.foreach(path, headers: true, encoding: "bom|utf-8")`. The
`bom|utf-8` encoding strips a leading BOM if present and reads UTF-8 otherwise.
For known-foreign files name the real encoding (e.g. `"ISO-8859-1"`).

> **Why HEURISTIC, not HIGH:** a static scan can't tell a trusted internal CSV
> (fixed path, known UTF-8) from an untrusted upload. On a guaranteed-UTF-8
> internal file the missing option is harmless. Confirm the source before
> acting; this rule only fails CI under `STRICT=1`.

---

## `no-row-reporting` — `create!`/`save!`/`update!` in a row loop, no transaction, no error collection  (HIGH)

**What:** a bang persistence call (`create!`, `save!`, `update!`,
`find_or_create_by!`, …) runs **lexically inside** a `CSV.foreach` / `CSV.parse`
row loop, and the loop has **neither** a surrounding transaction **nor** any
per-row error accumulation (`rescue` / `errors << ...`).

**Why:** this is the book's own import concern, and it's the highest-value
catch because the book gets it wrong. With no transaction and no rescue, the
**first** invalid row raises and aborts the whole import — every earlier row is
already committed (half-done state), every later row never runs, and the user
sees a raw exception with no idea which row failed or how many succeeded. A real
import has to answer "which rows failed and why?" — this pattern can't.

**Fix:** wrap each row in a transaction and rescue `ActiveRecord::RecordInvalid`
per row, collecting `{ line:, errors: }`; report all failures at the end instead
of aborting on the first. See the template below. (If you genuinely want
all-or-nothing semantics, wrap the **whole loop** in one transaction *and* still
surface the failing row — but per-row reporting is almost always what you want.)

> Persistence extracted into a helper the loop merely *calls*
> (`rows.each { |r| import_row(r) }`) is **not** flagged — the checker doesn't
> follow calls out of the block. That's a deliberate under-report (see Ceiling).

---

## Reference template — safe streaming importer + streamed exporter

Drop-in shapes that clear all three rules. An interactor here, but the same
applies in a job or service.

```ruby
# app/interactors/users/import_from_csv.rb
require "csv"

module Users
  class ImportFromCsv
    include Interactor  # context.io (an uploaded file or IO), context.results

    def call
      context.imported = 0
      context.errors   = []   # collected, never raised past the first bad row

      # Stream (no whole-file load) + handle BOM/encoding on the file source.
      CSV.foreach(context.io, headers: true, encoding: "bom|utf-8").with_index(1) do |row, line|
        import_row(row, line)
      end
    rescue CSV::MalformedCSVError => e
      context.fail!(error_message: "Invalid CSV: #{e.message}")
    end

    private

    def import_row(row, line)
      # One transaction per row: a bad row rolls back only its own writes.
      ActiveRecord::Base.transaction do
        user = User.find_or_initialize_by(external_id: row["id"])
        user.update!(name: row["name"], email: row["email"])
      end
      context.imported += 1
    rescue ActiveRecord::RecordInvalid => e
      # Collect, with the line number, so EVERY failure is reported — not just the first.
      context.errors << { line: line, errors: e.record.errors.full_messages }
    end
  end
end
```

```ruby
# app/controllers/exports_controller.rb — stream the export too.
# find_each batches the query (constant memory); CSV.generate builds rows lazily.
require "csv"

def export
  send_data(
    CSV.generate do |csv|
      csv << %w[name email created_at]
      User.find_each { |u| csv << [u.name, u.email, u.created_at] }
    end,
    filename: "users-#{Date.current}.csv", type: "text/csv"
  )
end
```

For very large exports, stream the response body row-by-row instead of building
the whole string (`response.stream` + an enumerator) — same `find_each` shape,
no full-string buffer. That's a performance refinement covered by
`majestic-rails:performance-reviewer`, not this checker.

---

## Running

```bash
scripts/lint_csv_io.sh path/to/rails-app          # defaults to .
SKIP="missing-encoding" scripts/lint_csv_io.sh .  # turn a rule off
STRICT=1 scripts/lint_csv_io.sh .                 # heuristics also fail the exit code
```

Exit: `0` = clean, `1` = HIGH findings (or any with `STRICT=1`), `2` = bad usage
/ no `python3`.

## Ceiling

Heuristic path-scoped grep + indentation block-walk, **not a Ruby parser**. It
does not load code, resolve constants, or follow method calls out of a loop
block.

- **Scope:** only import/upload-reachable layers
  (`app/{controllers,jobs,services,interactors,models,lib}`). A `CSV.read` of a
  tiny trusted config in an initializer or a one-off rake task is out of scope on
  purpose — different risk than an upload.
- **`no-row-reporting` is lexical:** a loop whose persistence is extracted into a
  helper method is not followed (under-reports). Any `transaction` token in the
  enclosing method, or any `rescue`/`errors <<` in the block, suppresses the flag
  — chosen to keep false positives near zero.
- **`missing-encoding`** can't distinguish a trusted internal CSV from an
  untrusted upload, so it's a caveated HEURISTIC.
- Patterns inside a string or trailing inline comment can still match (rare for
  these tokens).

Treat every flag as "open the file and confirm", not as proof. This is a
deterministic pre-pass that complements, not replaces, an LLM review.
