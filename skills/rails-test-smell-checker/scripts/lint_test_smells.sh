#!/usr/bin/env bash
# Lint Rails test suites for smells that make tests flaky, slow, or unable to
# catch a real bug. Reads BOTH Minitest (test/**/*_test.rb) and RSpec
# (spec/**/*_spec.rb). This is a CHECKER, not a test-writer — it never edits
# tests; it points at file:line and names the smell.
#
# It complements dte-test-auditor (an LLM judge): this is the fast, no-LLM,
# CI-gateable pass. Use --json to emit findings the auditor can consume.
#
# Usage:  lint_test_smells.sh <rails-app-dir>   # defaults to .
#         lint_test_smells.sh <dir> --json      # machine-readable findings
#         lint_test_smells.sh <dir> --strict    # also exit non-zero on heuristics
# Exit:   0 = no HIGH-confidence findings, 1 = HIGH findings (or heuristics under
#         --strict), 2 = bad usage / no python3.
# CEILING: line-oriented regex + indentation-based block matching, NOT a Ruby
#   parser. It assumes rubocop-style consistent indentation. It deliberately
#   under-reports (conservative) — false positives are the worse failure here,
#   so ambiguous smells are emitted as HEURISTIC (caveated), never HIGH.
set -uo pipefail
command -v python3 >/dev/null || { echo "needs python3" >&2; exit 2; }

ROOT="."
JSON=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --json)   JSON=1 ;;
    --strict) STRICT=1 ;;
    *)        ROOT="$arg" ;;
  esac
done

python3 - "$ROOT" "$JSON" "$STRICT" <<'PY'
import os, re, sys, glob, json

ROOT   = sys.argv[1]
JSON   = sys.argv[2] == "1"
STRICT = sys.argv[3] == "1"

# Collect test files: Minitest + RSpec.
files = []
for pat in ("test/**/*_test.rb", "spec/**/*_spec.rb"):
    files += glob.glob(os.path.join(ROOT, pat), recursive=True)
files = sorted(set(files))

if not files:
    msg = "no test/**/*_test.rb or spec/**/*_spec.rb files found under " + ROOT
    if JSON:
        print(json.dumps({"findings": [], "note": msg}))
    else:
        print(msg, file=sys.stderr)
    sys.exit(2)

findings = []  # each: {severity, rule, file, line, message}
def add(sev, rule, f, line, msg):
    findings.append({"severity": sev, "rule": rule,
                     "file": os.path.relpath(f, ROOT), "line": line, "message": msg})

def is_system_or_feature(path, text):
    p = path.replace("\\", "/")
    if "/system/" in p or p.endswith("_system_test.rb"):
        return True
    if "/spec/system/" in p or "/spec/features/" in p or "/features/" in p:
        return True
    # RSpec metadata
    if re.search(r'type:\s*:(system|feature)', text):
        return True
    return False

def block_len(lines, idx):
    # Length (in lines, inclusive) of a do...end block opened on lines[idx],
    # found by the next line at the SAME indentation that is exactly `end`.
    # Robust for rubocop-formatted code; ceiling: relies on consistent indent.
    indent = len(lines[idx]) - len(lines[idx].lstrip())
    for j in range(idx + 1, len(lines)):
        s = lines[j].strip()
        ind = len(lines[j]) - len(lines[j].lstrip())
        if s == "end" and ind == indent:
            return j - idx + 1
    return 0

SETUP_BLOCK_THRESHOLD = 25   # lines; thoughtbot Mystery Guest heuristic
LET_BANG_THRESHOLD     = 5   # count of let! in a file

# Suite-wide: does any test file reference an external HTTP client?
HTTP_RE = re.compile(r'\b(Net::HTTP|Faraday|HTTParty|RestClient)\b|require\s+["\']open-uri["\']|\bURI\.open\b')
http_hits = []  # (file, line)

# Suite-wide: is a no-real-connections guard configured anywhere in the suite?
# Satisfied by an explicit disable_net_connect!, by loading WebMock at all
# (requiring webmock/minitest disables net connect BY DEFAULT — flagging its
# absence here would be a false positive), or by any VCR config.
GUARD_RE = re.compile(r'disable_net_connect!|require\s+["\']webmock|WebMock\.|require\s+["\']vcr["\']|VCR\.')
guard_present = False

for f in files:
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    lines = text.split("\n")
    sysf = is_system_or_feature(f, text)

    if GUARD_RE.search(text):
        guard_present = True

    let_bang = 0
    for i, raw in enumerate(lines, start=1):
        line = raw.strip()
        if line.startswith("#"):           # skip whole-line comments
            continue

        # collect HTTP refs (for the suite-level guard check)
        if HTTP_RE.search(line):
            http_hits.append((f, i))

        # --- HIGH 1: sleep in a feature/system test (flaky by construction) ---
        if sysf and re.match(r'sleep(\s|\()', line):
            add("HIGH", "sleep-in-feature",
                f, i, "`sleep` in a system/feature test is flaky by construction "
                "— wait on a condition (auto-waiting matcher) instead: " + line)

        # --- HIGH 3: stubbing the System Under Test ---
        if re.search(r'allow\(\s*(described_class|subject)\b', line):
            add("HIGH", "stub-the-sut",
                f, i, "stubbing the object under test (allow(subject/described_class)) "
                "— you're asserting against your own stub; extract the collaborator instead: " + line)
        if re.search(r'expect\(\s*(described_class|subject)\s*\)\.to\s+receive', line):
            add("HIGH", "stub-the-sut",
                f, i, "setting a message expectation on the SUT (expect(subject/described_class).to receive) "
                "— test behaviour, not the SUT's own internals: " + line)

        # --- HIGH 4: boolean predicate inside an assertion (can't fail meaningfully) ---
        if re.search(r'has_(css|content|selector|text|link|button|field|xpath|table|title|current_path)\?', line) \
           and re.search(r'\b(expect\(|assert|refute|should)\b', line):
            add("HIGH", "predicate-in-assertion",
                f, i, "`.has_*?` returns a boolean and does NOT retry — wrapped in an "
                "assertion it can pass on a slow page. Use the auto-waiting matcher "
                "(have_css / have_content / assert_selector): " + line)

        # --- HEURISTIC 6: tautological equality (expectation == itself) ---
        m = re.search(r'expect\(\s*(.+?)\s*\)\.to\s+eq[\s(]+(.+?)\)?\s*$', line)
        if m and m.group(1) and m.group(1) == m.group(2).rstrip(")").strip():
            add("HEURISTIC", "tautological-eq",
                f, i, "both sides of this `eq` are textually identical — the assertion "
                "is green even when the value is wrong. Assert the expected literal: " + line)
        m = re.search(r'assert_equal\s+(.+?)\s*,\s*(.+?)\s*$', line)
        if m and m.group(1) == m.group(2):
            add("HEURISTIC", "tautological-eq",
                f, i, "assert_equal with both arguments identical — cannot catch a "
                "regression. Assert the expected literal: " + line)

        # --- HEURISTIC 5b: eager let! count (RSpec Mystery Guest) ---
        if re.match(r'let!\(', line):
            let_bang += 1

    # --- HEURISTIC 5a: oversized setup/before block (Mystery Guest) ---
    for i, raw in enumerate(lines):
        s = raw.strip()
        if re.match(r'(setup|before)(\(.*\))?\s+do$', s) or s == "def setup":
            n = block_len(lines, i)
            if n > SETUP_BLOCK_THRESHOLD:
                add("HEURISTIC", "mystery-guest",
                    f, i + 1, f"{s} block is {n} lines — large shared setup hides what "
                    "each test actually depends on (Mystery Guest). Prefer per-test plain "
                    "Ruby setup methods over heavy shared setup.")

    if let_bang >= LET_BANG_THRESHOLD:
        add("HEURISTIC", "mystery-guest",
            f, 1, f"{let_bang} `let!` definitions in this file — eager blocks run for "
            "every example and hide each test's real dependencies (Mystery Guest).")

# --- HIGH 2: external HTTP referenced but no suite-wide guard ---
if http_hits and not guard_present:
    f, line = http_hits[0]
    add("HIGH", "missing-net-guard",
        f, line, "the suite references an external HTTP client but no WebMock/VCR "
        "guard is configured (no `require \"webmock\"`, `disable_net_connect!`, or VCR "
        "config found) — tests can hit live APIs. Add `require \"webmock/minitest\"` "
        f"(or VCR) to your test helper. First HTTP ref here; {len(http_hits)} total.")

highs      = [x for x in findings if x["severity"] == "HIGH"]
heuristics = [x for x in findings if x["severity"] == "HEURISTIC"]

if JSON:
    print(json.dumps({"root": ROOT, "files_scanned": len(files),
                      "high": len(highs), "heuristic": len(heuristics),
                      "findings": findings}, indent=2))
else:
    print(f"Scanned {len(files)} test file(s) under {ROOT}")
    if not findings:
        print("  ✓ no test smells found")
    for x in findings:
        icon = "❌" if x["severity"] == "HIGH" else "⚠️ "
        print(f"  {icon} [{x['severity']}/{x['rule']}] {x['file']}:{x['line']}")
        print(f"        {x['message']}")
    print()
    print(f"HIGH: {len(highs)}   HEURISTIC: {len(heuristics)}")
    print("HEURISTIC findings are caveated — review before acting; they do not fail "
          "CI unless --strict. See references/test-smells-guide.md")
    print("✅ no high-confidence smells" if not highs else "❌ high-confidence smells above")

sys.exit(1 if highs or (STRICT and heuristics) else 0)
PY
