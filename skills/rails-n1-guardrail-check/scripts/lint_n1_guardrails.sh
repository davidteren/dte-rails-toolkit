#!/usr/bin/env bash
# Assert a Rails app's N+1 DEFENSES exist, and flag two narrow, deterministic
# N+1 anti-patterns. This is NOT a general static N+1 detector — Bullet,
# Prosopite, and strict_loading do that at runtime with fingerprints, and a
# grep-based detector is strictly worse. This checker only (1) verifies a
# guardrail is wired up at all, and (2) flags the two N+1 shapes that ARE
# greppable with high confidence. Each finding prints  file:line + rule + fix.
#
# Rules (all individually skippable via SKIP="rule-a,rule-b ..."):
#   no-n1-guardrail            no strict_loading config AND no prosopite/bullet/
#                              n_plus_one_control gem wired — N+1s pass CI silently  (advisory)
#   count-in-view              recv.assoc.count inside app/views/** — a COUNT query
#                              per render; use counter_cache + .size                 (HIGH)
#   count-in-loop              recv.assoc.count inside an .each/.map block — a COUNT
#                              query per iteration; counter_cache + .size            (HIGH)
#   relation-breaker-in-loop   recv.assoc.order(/.where(/.pluck( inside a loop — a
#                              new query per row that silently defeats an eager-load (HEURISTIC)
#
# Usage:  lint_n1_guardrails.sh <rails-app-dir>     # defaults to .
#         lint_n1_guardrails.sh <dir> --strict      # heuristic + advisory also fail
# Env:    SKIP="count-in-view,..."  to turn rules off.
# Exit:   0 = clean (no HIGH), 1 = HIGH findings (or any finding under --strict),
#         2 = bad usage / no python3.
#
# This is a deterministic PRE-PASS. It complements — does not replace — the
# runtime N+1 gems (Prosopite/Bullet/strict_loading) and the LLM perf reviewers
# (dte-perf, performance-reviewer), which catch the N+1s this can't see at rest.
#
# CEILING: heuristic line + indentation scan, NOT a Ruby/ERB parser. It does not
# load code, resolve constants, or know which methods are real associations vs
# plain Ruby collections. It targets the `recv.assoc.count` / `recv.assoc.order(`
# SHAPES inside views and .each/.map blocks (found by indentation). Whole-line and
# ERB (`<%# %>`) comments are skipped; a pattern inside a string can still match.
# Treat every flag as "open the file and confirm", not as proof.
set -uo pipefail
command -v python3 >/dev/null || { echo "needs python3" >&2; exit 2; }

ROOT="."
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *)        ROOT="$arg" ;;
  esac
done
[ -d "$ROOT/app" ] || { echo "no app/ dir under $ROOT — not a Rails app root" >&2; exit 2; }

SKIP="${SKIP:-}" STRICT="$STRICT" python3 - "$ROOT" <<'PY'
import os, re, sys, glob

ROOT   = sys.argv[1]
SKIP   = set(s.strip() for s in os.environ.get("SKIP","").replace(","," ").split() if s.strip())
STRICT = os.environ.get("STRICT","0") not in ("0","","false","no")

high = 0       # HIGH findings -> exit 1
soft = 0       # HEURISTIC + advisory -> exit 1 only under --strict

def rel(p): return os.path.relpath(p, ROOT)

def report(sev, rule, path, lineno, text, fix):
    global high, soft
    icon = "❌" if sev == "HIGH" else ("⚠️ " if sev == "HEURISTIC" else "ℹ️ ")
    print(f"  {icon} [{sev}/{rule}] {rel(path)}:{lineno}")
    if text: print(f"        {text.strip()}")
    print(f"        fix: {fix}")
    if sev == "HIGH": high += 1
    else:             soft += 1

def read(p):
    try: return open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError: return []

def is_comment(line):
    s = line.lstrip()
    return s.startswith("#") or s.startswith("<%#") or s.startswith("<%-#")

# ── shapes we flag (narrow on purpose) ────────────────────────────────────────
# A COUNT-per-row: recv.assoc.count  (a dotted chain, so `Post.count` (one query)
# and bare `@items.count` (an Array) are NOT matched — only `x.assoc.count`).
COUNT_RX  = re.compile(r"\.(\w+)\.count\b")
# A relation-builder chained on an association: recv.assoc.order(/.where(/.pluck(
# — each issues a NEW query per row, silently ignoring an eager-load.
BREAK_RX  = re.compile(r"\.(\w+)\.(?:order|where|pluck)\(")
# Pre-`.count` identifiers that are common in-memory (non-AR) receivers — skip.
COUNT_SKIP = {"errors", "flash", "params", "session", "cookies", "headers",
              "keys", "values", "chars", "bytes", "lines", "digits", "to_a",
              # Enumerable transformers — `.uniq.count` etc. is an in-memory Array count
              "uniq", "map", "select", "reject", "flatten", "compact", "sort",
              "sort_by", "collect", "flat_map", "take", "drop", "group_by",
              "partition", "zip", "tally", "each"}
# Pre-`order/where/pluck` words that are themselves relation methods, not an
# association leaf — `scope.distinct.pluck` is a relation chain, not an N+1.
BREAK_SKIP = {"distinct", "all", "none", "reorder", "unscoped", "scoped",
              "references", "includes", "preload", "eager_load", "joins",
              "group", "having", "limit", "offset", "where", "order", "pluck"}
LOOP_OPEN  = re.compile(r"\.(?:each|each_with_index|each_with_object|map|flat_map)\b.*\bdo\b")
END_RX     = re.compile(r"^(?:end\b|<%-?\s*end\s*-?%>)")

def loop_blocks(lines):
    """Yield (start_idx, end_idx_exclusive) for .each/.map do..end blocks, matching
    the closing `end` / `<% end %>` by indentation. Ceiling: relies on the opener
    and its `end` each living on their own line at consistent indentation."""
    for i, ln in enumerate(lines):
        if is_comment(ln) or not LOOP_OPEN.search(ln): continue
        indent = len(ln) - len(ln.lstrip())
        for j in range(i + 1, len(lines)):
            s = lines[j].strip()
            if END_RX.match(s) and (len(lines[j]) - len(lines[j].lstrip())) <= indent:
                yield (i + 1, j); break

def scan_count(path, lines, scope, rule):
    """Flag recv.assoc.count on the line indices in `scope`."""
    if rule in SKIP: return
    for idx in scope:
        ln = lines[idx]
        if is_comment(ln): continue
        m = COUNT_RX.search(ln)
        if not m or m.group(1) in COUNT_SKIP: continue
        # a block-form count (`.count { ... }` / `.count do`) is in-memory Enumerable, not SQL
        tail = ln[m.end():].lstrip()
        if tail.startswith("{") or tail.startswith("do"): continue
        report("HIGH", rule, path, idx + 1, ln,
               "this is a COUNT query every time. Add `counter_cache: true` (a "
               "`#{assoc}_count` column) and read `.size` — it uses the cache, the "
               "loaded records, or one COUNT, in that order.")

def scan_breaker(path, lines, scope):
    if "relation-breaker-in-loop" in SKIP: return
    for idx in scope:
        ln = lines[idx]
        if is_comment(ln): continue
        m = BREAK_RX.search(ln)
        if m and m.group(1) not in BREAK_SKIP:
            report("HEURISTIC", "relation-breaker-in-loop", path, idx + 1, ln,
                   "`.order/.where/.pluck` on an association inside a loop builds a "
                   "NEW query per row, ignoring any `includes`. Order/filter in Ruby "
                   "on the loaded records, or define a default-ordered/scoped "
                   "association and preload that.")

# ── rule: count-in-view (whole view file) + relation-breaker-in-loop (view loops)
for p in sorted(glob.glob(os.path.join(ROOT, "app/views", "**", "*"), recursive=True)):
    if not os.path.isfile(p): continue
    if not re.search(r"\.(erb|haml|slim)$", p): continue
    lines = read(p)
    scan_count(p, lines, range(len(lines)), "count-in-view")
    for s, e in loop_blocks(lines):
        scan_breaker(p, lines, range(s, e))

# ── rule: count-in-loop + relation-breaker-in-loop (ruby .each/.map blocks)
for p in sorted(glob.glob(os.path.join(ROOT, "app", "**", "*.rb"), recursive=True)):
    lines = read(p)
    for s, e in loop_blocks(lines):
        scan_count(p, lines, range(s, e), "count-in-loop")
        scan_breaker(p, lines, range(s, e))

# ── rule: no-n1-guardrail (one advisory if NOTHING is wired) ──────────────────
if "no-n1-guardrail" not in SKIP:
    guarded = False
    # (a) native strict_loading config
    for cfg in glob.glob(os.path.join(ROOT, "config", "**", "*.rb"), recursive=True):
        txt = "\n".join(read(cfg))
        if re.search(r"strict_loading_by_default|action_on_strict_loading_violation", txt):
            guarded = True; break
    # (b) a detection gem in the Gemfile, or set up in the test helper
    if not guarded:
        sources = [os.path.join(ROOT, f) for f in (
            "Gemfile", "test/test_helper.rb", "spec/rails_helper.rb", "spec/spec_helper.rb")]
        sources += glob.glob(os.path.join(ROOT, "config", "environments", "*.rb"))
        gem_rx = re.compile(r"\bprosopite\b|\bn_plus_one_control\b|\bbullet\b|"
                            r"\bProsopite\b|\bNPlusOneControl\b|\bBullet\b")
        for s in sources:
            if os.path.exists(s) and gem_rx.search("\n".join(read(s))):
                guarded = True; break
    if not guarded:
        report("ADVISORY", "no-n1-guardrail", os.path.join(ROOT, "Gemfile"), 1, "",
               "no N+1 guardrail wired (no strict_loading config, and no prosopite / "
               "bullet / n_plus_one_control gem) — N+1s will pass CI silently. Enable "
               "`config.active_record.strict_loading_by_default = true` (Rails ≥6.1) "
               "or add a detection gem + a test-suite gate.")

# ── summary ───────────────────────────────────────────────────────────────────
print()
if high == 0 and soft == 0:
    print("✅ N+1 guardrails OK — defenses wired, no flagged anti-patterns")
else:
    print(f"HIGH: {high}   HEURISTIC/ADVISORY: {soft}")
    print("HEURISTIC/ADVISORY findings are caveated — they do not fail CI unless "
          "--strict. See references/n1-guardrails-guide.md")
    print("✅ no HIGH findings" if high == 0 else "❌ HIGH findings above")
sys.exit(1 if high or (STRICT and soft) else 0)
PY
