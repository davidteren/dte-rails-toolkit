#!/usr/bin/env bash
# Lint a Rails app for the three CSV import footguns that produce NO error in
# review but bite in production — memory blow-up on big files, mojibake/BOM from
# missing encoding handling, and all-or-nothing imports with no per-row error
# reporting. Each finding prints  file:line  + the rule label + the fix.
#
# Everything else about CSV (headers:, col_sep:, custom converters, CSV.generate)
# is stdlib any model writes correctly unprompted — this checker deliberately
# scans ONLY for the three durable footguns, not the prose.
#
# Rules (individually skippable via SKIP="rule-a,rule-b ..."):
#   whole-file-load   CSV.read( / CSV.parse(File.read( reachable from import code  (HIGH)
#   missing-encoding  CSV.foreach/read/table( on a file with no encoding: option   (HEURISTIC)
#   no-row-reporting  create!/save!/update! in a CSV row loop, no transaction AND
#                     no per-row error accumulation                                (HIGH)
#
# Usage:  lint_csv_io.sh <rails-app-dir>        # defaults to .
# Env:    SKIP="..."   STRICT=1 (heuristic findings also fail the exit code)
# Exit:   0 = clean, 1 = HIGH findings (or any finding with STRICT=1), 2 = bad usage.
#
# SCOPE: scans only import/upload-reachable code — app/{controllers,jobs,services,
# interactors,models,lib}. A CSV.read of a tiny trusted config in an initializer
# or a one-off rake task is out of scope on purpose (different risk than an
# upload). See the CEILING below for why this is still a heuristic, not a proof.
#
# CEILING: heuristic path-scoped grep + indentation block-walk, NOT a Ruby parser.
# It does not load code, resolve constants, or follow method calls out of a loop
# block. A row loop whose persistence is extracted into a helper method is NOT
# followed (under-reports — false negatives preferred over false positives).
# `missing-encoding` cannot tell a trusted internal CSV from an untrusted upload,
# so it is a caveated HEURISTIC. Treat every flag as "open the file and confirm".
set -uo pipefail
command -v python3 >/dev/null || { echo "needs python3" >&2; exit 2; }

ROOT="${1:-.}"
[ -d "$ROOT/app" ] || { echo "no app/ dir under $ROOT — not a Rails app root" >&2; exit 2; }

SKIP="${SKIP:-}" STRICT="${STRICT:-0}" \
python3 - "$ROOT" <<'PY'
import os, re, sys, glob

ROOT = sys.argv[1]
SKIP = set(s.strip() for s in os.environ.get("SKIP","").replace(","," ").split() if s.strip())
STRICT = os.environ.get("STRICT","0") not in ("0","","false","no")

# Import/upload-reachable layers only. A CSV.read in an initializer or rake task
# (trusted, one-off) is a different risk and deliberately out of scope.
IMPORT_DIRS = ("app/controllers", "app/jobs", "app/services",
               "app/interactors", "app/models", "app/lib")

high = 0       # HIGH findings -> exit 1
heuristic = 0  # heuristic -> printed, exit 1 only under STRICT

def rel(p): return os.path.relpath(p, ROOT)
def is_comment(line): return line.lstrip().startswith("#")

def import_files():
    out = []
    for d in IMPORT_DIRS:
        out += sorted(glob.glob(os.path.join(ROOT, d, "**", "*.rb"), recursive=True))
    return out

def report(label, path, lineno, text, fix, heur=False):
    global high, heuristic
    tag = "ℹ️  heuristic" if heur else "⚠️  footgun"
    print(f"  {tag} [{label}] {rel(path)}:{lineno}")
    print(f"      {text.strip()}")
    print(f"      fix: {fix}")
    if heur: heuristic += 1
    else:    high += 1

PATHS = import_files()

# Persistence calls that abort the whole import on the first bad row if unguarded.
BANG_RX = re.compile(
    r"\b(?:create|create_or_find_by|find_or_create_by|save|update|update_column|"
    r"update_columns|destroy|insert|insert_all|upsert|upsert_all|toggle|"
    r"increment|decrement)!")

# ── whole-file-load: CSV.read / CSV.parse(File.read(...)) loads the entire file
#    into memory. CSV.foreach / CSV.new(io) streams. CSV.parse(a_string){...} is
#    fine (string already in memory, block form streams) — NOT flagged.
if "whole-file-load" not in SKIP:
    # CSV.read(...)  OR  CSV.parse|new( ... File.read / IO.read / something.read ... )
    WFL_RX = re.compile(
        r"\bCSV\.read\s*\("
        r"|\bCSV\.(?:parse|new)\s*\([^)]*\b(?:File|IO)\.(?:read|binread)\b"
        r"|\bCSV\.(?:parse|new)\s*\([^)]*\.read\b")
    for p in PATHS:
        try: src = open(p, encoding="utf-8", errors="replace").read().splitlines()
        except OSError: continue
        for i, line in enumerate(src, 1):
            if is_comment(line): continue
            if WFL_RX.search(line):
                report("whole-file-load", p, i, line,
                       "stream it: CSV.foreach(path, headers: true) { |row| ... } "
                       "or CSV.new(io) — never load the whole file into memory.")

# ── missing-encoding: file ingest with no encoding: option. CSV.{foreach,read,
#    table} always read a FILE/IO (you never pass CSV *content* to them), so a
#    missing encoding: is the mojibake/BOM footgun. HEURISTIC: can't tell a
#    trusted internal CSV from an untrusted upload.
if "missing-encoding" not in SKIP:
    ENC_CALL_RX = re.compile(r"\bCSV\.(?:foreach|read|table)\s*\(")
    for p in PATHS:
        try: src = open(p, encoding="utf-8", errors="replace").read().splitlines()
        except OSError: continue
        for i, line in enumerate(src, 1):
            if is_comment(line): continue
            if not ENC_CALL_RX.search(line): continue
            # join the call's continuation lines (until the args close) to look
            # for encoding: even when options span lines.
            blob = " ".join(src[i-1:i+2])
            if re.search(r"\bencoding\s*:", blob): continue
            report("missing-encoding", p, i, line,
                   'add encoding: "bom|utf-8" to strip a leading BOM (else the '
                   "first header reads \"\\uFEFFid\") and avoid invalid-byte crashes "
                   "on non-UTF-8 uploads.", heur=True)

# ── no-row-reporting: create!/save!/update! inside a CSV row-loop block with NO
#    surrounding transaction (in the enclosing method) AND no per-row error
#    accumulation (rescue / errors << ...) in the block. => first bad row aborts
#    the import, earlier rows half-committed, user told nothing useful.
#    Walks the loop block by INDENTATION; does NOT follow calls into helper
#    methods (a loop body that only calls import_row(row) is not flagged).
if "no-row-reporting" not in SKIP:
    # opener: CSV.foreach/parse/read/table(...) <do |row|>  — multiline block.
    LOOP_OPEN = re.compile(r"\bCSV\.(?:foreach|parse|read|table)\b.*\bdo\b\s*\|")
    # single-line block form: CSV.foreach(f) { |r| Model.create!(...) }
    LOOP_INLINE = re.compile(r"\bCSV\.(?:foreach|parse|read|table)\b.*\{.*\|.*\|")
    ERRACC_RX = re.compile(
        r"\brescue\b"
        r"|(?:errors?|failures?|skipped|invalid|context\.fail)\b.*(?:<<|\.push|=)"
        r"|<<\s*\{")

    def enclosing_method_has_transaction(src, loop_idx, loop_indent):
        """Nearest `def` above the loop at a lower indent, through its `end`."""
        start = None
        for k in range(loop_idx, -1, -1):
            ln = src[k]
            s = ln.strip()
            if s.startswith("def ") and (len(ln) - len(ln.lstrip())) < loop_indent:
                start = k; break
        if start is None: return False
        def_indent = len(src[start]) - len(src[start].lstrip())
        for k in range(start+1, len(src)):
            ln = src[k]
            if not ln.strip(): continue
            ind = len(ln) - len(ln.lstrip())
            if ind <= def_indent and ln.strip().startswith("end"):
                end = k; break
        else:
            end = len(src)-1
        return any("transaction" in src[k] for k in range(start, end+1))

    def block_body(src, start_idx, opener_indent):
        """Lines of the do..end block after start_idx until the dedented `end`."""
        body = []
        for j in range(start_idx, len(src)):
            ln = src[j]
            if not ln.strip(): body.append(ln); continue
            ind = len(ln) - len(ln.lstrip())
            if ind <= opener_indent and ln.strip().startswith("end"):
                break
            body.append(ln)
        return body

    for p in PATHS:
        try: src = open(p, encoding="utf-8", errors="replace").read().splitlines()
        except OSError: continue
        for i, line in enumerate(src):
            if is_comment(line): continue
            opener_indent = len(line) - len(line.lstrip())

            if LOOP_OPEN.search(line):
                body = block_body(src, i+1, opener_indent)
            elif LOOP_INLINE.search(line):
                body = [line]                      # whole block on one line
            else:
                continue

            bang_line = None
            for off, bl in enumerate(body):
                if is_comment(bl): continue
                if BANG_RX.search(bl):
                    bang_line = (i + 1 + off) if LOOP_OPEN.search(line) else (i)
                    bang_text = bl
                    break
            if bang_line is None: continue

            blob = "\n".join(body)
            if ERRACC_RX.search(blob): continue                       # has error reporting
            if "transaction" in blob: continue                        # transaction inside loop
            if enclosing_method_has_transaction(src, i, opener_indent): continue

            report("no-row-reporting", p, bang_line + 1, bang_text,
                   "wrap each row in a transaction and rescue ActiveRecord::"
                   "RecordInvalid per row — collect {line:, errors:} and report all "
                   "failures, don't abort on the first. See references/csv-io-guide.md.")

# ── summary
print()
total = high + heuristic
if total == 0:
    print("✅ CSV import looks safe — no footguns found")
else:
    print(f"❌ {high} footgun(s), {heuristic} heuristic — see references/csv-io-guide.md")
sys.exit(1 if high or (STRICT and heuristic) else 0)
PY
