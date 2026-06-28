#!/usr/bin/env bash
# Lint a Rails app for layer-boundary violations from palkan's "Layered Design for
# Rails" — the failures that produce NO error at runtime but leak request-global
# state, push queries into the wrong layer, or hide work in model callbacks.
# Each finding prints  file:line  + the rule label that fired.
#
# Rules (all individually skippable via SKIP="rule-a,rule-b ..."):
#   current-in-models      Current.<attr> READ inside app/models/**            (hard)
#   request-in-domain      request./params[]/permit/require in services & interactors (hard)
#   query-in-controller    .where(/.order(/.joins(/.pluck( in controllers & views   (hard)
#   io-in-callback         deliver_*/Net::HTTP/Faraday/HTTParty/RestClient in an after_* callback (hard)
#   current-write-location Current.<attr> = OUTSIDE controllers/jobs/channels/middleware (hard)
#   skip-action            skip_before/after/around_action                     (advisory)
#   current-attr-count     Current declares > CURRENT_ATTR_MAX (default 7) attributes (advisory)
#
# Usage:  lint_layer_boundaries.sh <rails-app-dir>        # defaults to .
# Env:    SKIP="..."  CURRENT_ATTR_MAX=7  STRICT=1 (advisory findings also fail)
# Exit:   0 = clean, 1 = hard findings (or any finding with STRICT=1), 2 = bad usage.
#
# This is a deterministic PRE-PASS. It complements — does not replace — the LLM
# `layered-rails-reviewer` / `dte-arc-review`, which catch semantic violations.
#
# CEILING: heuristic path-scoped grep, NOT a Ruby parser. It scans file paths +
# line text; it does not load code or resolve constants. Pure comment lines are
# skipped, but a pattern inside a string or a trailing inline comment can still
# match (rare for these tokens). The io-in-callback rule walks blocks/methods by
# INDENTATION, so unconventional formatting can miss or over-reach. Treat every
# flag as "open the file and confirm", not as proof.
set -uo pipefail
command -v python3 >/dev/null || { echo "needs python3" >&2; exit 2; }

ROOT="${1:-.}"
[ -d "$ROOT/app" ] || { echo "no app/ dir under $ROOT — not a Rails app root" >&2; exit 2; }

SKIP="${SKIP:-}" CURRENT_ATTR_MAX="${CURRENT_ATTR_MAX:-7}" STRICT="${STRICT:-0}" \
python3 - "$ROOT" <<'PY'
import os, re, sys, glob

ROOT = sys.argv[1]
SKIP = set(s.strip() for s in os.environ.get("SKIP","").replace(","," ").split() if s.strip())
ATTR_MAX = int(os.environ.get("CURRENT_ATTR_MAX","7"))
STRICT = os.environ.get("STRICT","0") not in ("0","","false","no")

hard = 0      # hard violations -> exit 1
advisory = 0  # advisory -> printed, exit 1 only under STRICT

def rel(p): return os.path.relpath(p, ROOT)
def files(*subdirs):
    out = []
    for d in subdirs:
        out += sorted(glob.glob(os.path.join(ROOT, d, "**", "*.rb"), recursive=True))
    return out
def is_comment(line): return line.lstrip().startswith("#")

def report(label, path, lineno, text, advise=False):
    global hard, advisory
    tag = "ℹ️  advisory" if advise else "⚠️  violation"
    print(f"  {tag} [{label}] {rel(path)}:{lineno}")
    print(f"      {text.strip()}")
    if advise: advisory += 1
    else:      hard += 1

def scan_lines(paths, label, pattern, advise=False, skip_assignment=False):
    if label in SKIP: return
    rx = re.compile(pattern)
    for p in paths:
        try: src = open(p, encoding="utf-8", errors="replace").read().splitlines()
        except OSError: continue
        for i, line in enumerate(src, 1):
            if is_comment(line): continue
            m = rx.search(line)
            if not m: continue
            if skip_assignment:
                # tail after the match: a write is `Current.x =` (but not `==`)
                tail = line[m.end():].lstrip()
                if tail.startswith("=") and not tail.startswith("=="): continue
            report(label, p, i, line, advise)

# ── current-in-models: Current.<attr> READ inside models (writes -> current-write-location)
if "current-in-models" not in SKIP:
    models = [p for p in files("app/models") if os.path.basename(p) != "current.rb"]
    scan_lines(models, "current-in-models", r"\bCurrent\.\w+", skip_assignment=True)

# ── request-in-domain: the request must not reach services / interactors
#    High-confidence access forms only: request.<x>, params[...], params.permit/require
# Match only the BARE Rails request object (request.foo), not `.request` chains on
# other receivers (e.g. PaperTrail.request — a gem's request store, not the HTTP request).
scan_lines(files("app/services", "app/interactors"), "request-in-domain",
           r"(?<![.:\w@$])request\.|(?<![.:\w@$])params\s*\[|(?<![.:\w@$])params\.(?:permit|require)\b")

# ── query-in-controller: query building belongs in models/scopes, not controllers/views
scan_lines(files("app/controllers") + sorted(
               glob.glob(os.path.join(ROOT, "app/views", "**", "*.erb"), recursive=True)),
           "query-in-controller", r"\.(?:where|order|joins|pluck)\(")

# ── skip-action: hidden-dependency smell (advisory)
scan_lines(files("app/controllers"), "skip-action",
           r"\bskip_(?:before|after|around)_action\b", advise=True)

# ── current-write-location: writes only in inbound layers
if "current-write-location" not in SKIP:
    allowed = ("app/controllers/", "app/jobs/", "app/channels/", "app/middleware/")
    write_paths = [p for p in files("app") if os.path.basename(p) != "current.rb"
                   and not rel(p).startswith(allowed)]
    scan_lines(write_paths, "current-write-location", r"\bCurrent\.\w+\s*=(?!=)")

# ── current-attr-count: keep Current small (advisory)
if "current-attr-count" not in SKIP:
    cur = os.path.join(ROOT, "app/models/current.rb")
    matches = glob.glob(os.path.join(ROOT, "app/**/current.rb"), recursive=True)
    cur = cur if os.path.exists(cur) else (matches[0] if matches else None)
    if cur:
        txt = open(cur, encoding="utf-8", errors="replace").read()
        if "CurrentAttributes" in txt:
            attrs = set()
            for m in re.finditer(r"\battribute\s+(.+)", txt):
                attrs.update(re.findall(r":(\w+)", m.group(1)))
            if len(attrs) > ATTR_MAX:
                report("current-attr-count", cur, 1,
                       f"Current declares {len(attrs)} attributes ({', '.join(sorted(attrs))}) "
                       f"> {ATTR_MAX} — keep Current minimal", advise=True)

# ── io-in-callback: mailer sends / outbound HTTP inside an after_* model callback
#    Walks the callback's block (inline do..end) or its referenced method by INDENTATION.
if "io-in-callback" not in SKIP:
    IO_RX = re.compile(r"\.deliver_(?:later|now)\b|\bNet::HTTP|\bFaraday\b|\bHTTParty\b|\bRestClient\b")
    CB_RX = re.compile(r"^(\s*)(after_(?:create|save|update|commit|destroy|validation|touch|initialize|find))\b(.*)$")
    DEF_RX = lambda name: re.compile(r"^(\s*)def\s+" + re.escape(name) + r"\b")
    for p in files("app/models"):
        src = open(p, encoding="utf-8", errors="replace").read().splitlines()
        n = len(src)

        def scan_block(start, indent, cb_line, cb_lineno):
            """Flag IO on lines after `start` until a line dedents to <= indent (the `end`)."""
            for j in range(start, n):
                ln = src[j]
                if not ln.strip(): continue
                cur_indent = len(ln) - len(ln.lstrip())
                stripped = ln.strip()
                if cur_indent <= indent and (stripped == "end" or stripped.startswith("end")):
                    return
                if is_comment(ln): continue
                if IO_RX.search(ln):
                    report("io-in-callback", p, j+1, f"{ln}   (in {cb_line.strip()} @ L{cb_lineno})")

        for i, line in enumerate(src):
            m = CB_RX.match(line)
            if not m: continue
            indent, _kw, rest = m.group(1), m.group(2), m.group(3)
            if re.search(r"\bdo\b\s*(\|.*\|)?\s*$", rest):           # inline block
                scan_block(i+1, len(indent), line, i+1)
            else:                                                    # symbol-referenced method(s)
                for name in re.findall(r":(\w+)", rest):
                    drx = DEF_RX(name)
                    for k in range(n):
                        dm = drx.match(src[k])
                        if dm:
                            scan_block(k+1, len(dm.group(1)), line, i+1)
                            break

# ── summary
print()
total = hard + advisory
if total == 0:
    print("✅ layer boundaries OK — no violations found")
else:
    print(f"❌ {hard} hard violation(s), {advisory} advisory — see references/layer-boundaries-guide.md")
sys.exit(1 if hard or (STRICT and advisory) else 0)
PY
