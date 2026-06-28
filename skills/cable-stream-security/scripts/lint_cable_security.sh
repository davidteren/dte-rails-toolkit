#!/usr/bin/env bash
# Harden an ActionCable / Turbo-Stream app against the websocket failure classes
# that produce NO error: anyone can subscribe to a stream (eavesdropping), a
# client-supplied string is constantize'd (arbitrary class load / RCE-ish),
# cross-site websocket hijacking (CSWSH) via missing origin checks, and a CSP
# that forgot the websocket endpoint. Each finding prints file:line + the rule.
#
# Stack-agnostic: helps ANY ActionCable + Turbo Streams app, not just StimulusReflex.
#
# Rules:
#   unauthorized-subscription   stream_from/stream_for in a custom channel with no
#                               reject/identity guard (eavesdropping)           HIGH
#                               (reject present but no obvious predicate -> HEURISTIC)
#   client-constantize          (safe_)constantize on a params[]/data[] value   HIGH
#   forgery-protection-disabled action_cable.disable_request_forgery_protection
#                               = true in a non-dev env                          HIGH
#   origin-allowlist            cable in use, no allowed_request_origins set      HEURISTIC
#   csp-connect-src             active CSP + cable in use, no connect-src         HEURISTIC
#
# Usage:  lint_cable_security.sh <rails-app-dir>   # defaults to .
#         lint_cable_security.sh <dir> --strict    # also fail on HEURISTIC findings
# Exit:   0 = no HIGH findings, 1 = HIGH (or HEURISTIC under --strict), 2 = bad usage.
#
# CEILING: heuristic path-scoped grep + indentation block walk, NOT a Ruby/JS parser.
# It scans paths + line text; it does not load code or resolve constants. The two
# env-dependent rules (origin-allowlist, csp-connect-src) are HEURISTIC by nature —
# origins/CSP can be set via ENV, a proxy, or inherited from default-src, and Rails
# already defaults Action Cable to same-origin — so they never fail CI without
# --strict. Cross-references hotwire-rails-toolkit/turbo-streams-patterns, whose
# lint also checks custom-channel authorization; run either, this one is the
# security-suite copy and does not need the Hotwire plugin installed.
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

STRICT="$STRICT" python3 - "$ROOT" <<'PY'
import os, re, sys, glob

ROOT   = sys.argv[1]
STRICT = os.environ.get("STRICT","0") not in ("0","","false","no")

findings = []  # {sev, rule, file, line, msg}
def add(sev, rule, path, line, msg):
    findings.append({"sev": sev, "rule": rule,
                     "file": os.path.relpath(path, ROOT), "line": line, "msg": msg})

def rb(*subdirs):
    out = []
    for d in subdirs:
        out += glob.glob(os.path.join(ROOT, d, "**", "*.rb"), recursive=True)
    return sorted(set(out))
def read(p):
    try: return open(p, encoding="utf-8", errors="replace").read()
    except OSError: return ""
def is_comment(line): return line.lstrip().startswith("#")

# ── "Is Action Cable / Turbo Streams actually in use?" ──────────────────────
# Deliberately NOT keyed on config/cable.yml — every Rails app ships one, so
# firing on its mere presence would be a mass false positive. We require a real
# usage signal: a custom channel, a turbo_stream_from in a view, or a JS consumer.
CHANNEL_FILES = [p for p in rb("app/channels")
                 if "application_cable" not in p.replace("\\", "/")]
def views():
    out = []
    for ext in ("erb", "haml", "slim"):
        out += glob.glob(os.path.join(ROOT, "app/views", "**", "*." + ext), recursive=True)
    return out
def js_files():
    out = []
    for ext in ("js", "ts"):
        out += glob.glob(os.path.join(ROOT, "app/javascript", "**", "*." + ext), recursive=True)
    return sorted(set(out))

turbo_stream_from = any(
    re.search(r'\bturbo_stream_from\b|\bturbo_cable_stream_source\b', read(v)) for v in views())
js_consumer = any(
    re.search(r'@rails/actioncable|createConsumer|\bActionCable\b', read(j)) for j in js_files())
CABLE_IN_USE = bool(CHANNEL_FILES) or turbo_stream_from or js_consumer

# ── Rule 1: unauthorized-subscription ───────────────────────────────────────
# A custom channel that streams without authorizing the subscriber lets any
# connection eavesdrop on the broadcast. Authorized = it rejects unverified subs
# OR scopes the stream to a verified identity / ownership guard.
STREAM_RX = re.compile(r'\bstream_(?:from|for)\b')
PREDICATE_RX = re.compile(
    r'\breject\b|current_\w+|\bverified\b|verified_stream_name|signed|\bpolicy\b|'
    r'\bauthoriz|\bcan_\w+|\bowner|\baccessible|\bPundit\b|\bfind_by\b|policy_scope')
REJECT_RX = re.compile(r'\breject\b')
for c in CHANNEL_FILES:
    src = read(c).splitlines()
    stream_lines = [(i + 1, ln) for i, ln in enumerate(src)
                    if STREAM_RX.search(ln) and not is_comment(ln)]
    if not stream_lines:
        continue
    body = "\n".join(ln for ln in src if not is_comment(ln))
    has_predicate = bool(PREDICATE_RX.search(body))
    has_reject    = bool(REJECT_RX.search(body))
    base = os.path.basename(c)
    if has_predicate:
        continue  # scoped to a verified identity or guarded by reject + a check
    ln0, txt0 = stream_lines[0]
    if has_reject:
        add("HEURISTIC", "unauthorized-subscription", c, ln0,
            f"{base} calls reject() but no obvious ownership/identity predicate "
            f"(current_*, policy, owner, verified, signed) — confirm reject actually "
            f"gates the subscriber: {txt0.strip()}")
    else:
        add("HIGH", "unauthorized-subscription", c, ln0,
            f"{base} streams with NO authorization — any connection can subscribe and "
            f"eavesdrop on this broadcast. Scope the stream to a verified identity "
            f"(stream_for current_user) or reject() unauthorized subscribers: {txt0.strip()}")

# ── Rule 2: client-constantize ──────────────────────────────────────────────
# constantize / safe_constantize on a client-supplied string (params[] / data[]
# from a channel's received(data) / dataset value) loads an attacker-named class.
CONST_RX  = re.compile(r'\.(?:safe_)?constantize\b')
CLIENT_RX = re.compile(r'params\s*[\[.]|(?<![\w.])data\s*\[|(?<![\w.])data\.\w|\.dataset\.')
for p in rb("app", "lib"):
    for i, line in enumerate(read(p).splitlines(), 1):
        if is_comment(line): continue
        if CONST_RX.search(line) and CLIENT_RX.search(line):
            add("HIGH", "client-constantize", p, i,
                "constantize on a client-supplied string loads an arbitrary class "
                "(RCE-ish). Map the input through a server-side allowlist before "
                f"constantizing; never constantize params/data directly: {line.strip()}")

# ── Rule 3: forgery-protection-disabled ─────────────────────────────────────
# Turning off Action Cable's request-forgery (origin) check in a real env opens
# CSWSH. Dev/test toggling it is normal, so those files are excluded.
DISABLE_RX = re.compile(r'action_cable\.disable_request_forgery_protection\s*=\s*true')
cfg_envs = [p for p in glob.glob(os.path.join(ROOT, "config/environments/*.rb"))
            if os.path.basename(p) not in ("development.rb", "test.rb")]
cfg_inits = glob.glob(os.path.join(ROOT, "config/initializers/*.rb"))
for p in cfg_envs + cfg_inits + [os.path.join(ROOT, "config/application.rb")]:
    for i, line in enumerate(read(p).splitlines(), 1):
        if is_comment(line): continue
        if DISABLE_RX.search(line):
            add("HIGH", "forgery-protection-disabled", p, i,
                "Action Cable request-forgery protection disabled in a non-dev env — "
                "any origin can open a websocket (CSWSH). Remove this and rely on "
                f"allowed_request_origins instead: {line.strip()}")

# ── Rule 4: origin-allowlist (HEURISTIC) ────────────────────────────────────
# Cable in use but no allowed_request_origins anywhere. Caveat: Rails already
# defaults to SAME-ORIGIN, and origins may be set via ENV — so this is a review
# nudge, not a hard finding.
if CABLE_IN_USE:
    cfg_all = (glob.glob(os.path.join(ROOT, "config/**/*.rb"), recursive=True))
    has_origins = any(re.search(r'allowed_request_origins', read(p)) for p in cfg_all)
    if not has_origins:
        prod = os.path.join(ROOT, "config/environments/production.rb")
        where = prod if os.path.exists(prod) else os.path.join(ROOT, "config/application.rb")
        add("HEURISTIC", "origin-allowlist", where, 1,
            "Action Cable is in use but config.action_cable.allowed_request_origins is "
            "not set in any config file. Rails defaults to same-origin (usually safe); "
            "set an explicit allowlist if you terminate cable on a different host, and "
            "verify you are not relying on ENV-injected origins this scan can't see.")

# ── Rule 5: csp-connect-src (HEURISTIC) ─────────────────────────────────────
# An ACTIVE CSP (non-commented content_security_policy block) with cable in use
# but no connect-src may block the websocket — or rely on default-src. Heuristic.
if CABLE_IN_USE:
    csp_files = (glob.glob(os.path.join(ROOT, "config/initializers/*.rb"))
                 + glob.glob(os.path.join(ROOT, "config/environments/*.rb")))
    for p in csp_files:
        lines = read(p).splitlines()
        active = [i + 1 for i, ln in enumerate(lines)
                  if re.search(r'\bcontent_security_policy\s+do\b', ln) and not is_comment(ln)]
        if not active:
            continue
        active_body = "\n".join(ln for ln in lines if not is_comment(ln))
        if not re.search(r'\bconnect_src\b', active_body):
            add("HEURISTIC", "csp-connect-src", p, active[0],
                "an active Content-Security-Policy is set and Action Cable is in use, but "
                "the policy declares no connect-src. The websocket may be blocked — or "
                "covered by default-src. Add connect-src :self wss: (and your cable host) "
                "to be explicit.")
        break

# ── report ──────────────────────────────────────────────────────────────────
highs      = [x for x in findings if x["sev"] == "HIGH"]
heuristics = [x for x in findings if x["sev"] == "HEURISTIC"]

print(f"== cable-stream-security: {ROOT} ==")
print(f"   Action Cable / Turbo Streams in use: {'yes' if CABLE_IN_USE else 'no (origin/CSP rules N/A)'}")
if not findings:
    print("  ✅ no websocket hardening findings")
for x in findings:
    icon = "❌" if x["sev"] == "HIGH" else "⚠️ "
    print(f"  {icon} [{x['sev']}/{x['rule']}] {x['file']}:{x['line']}")
    print(f"        {x['msg']}")
print()
print(f"HIGH: {len(highs)}   HEURISTIC: {len(heuristics)}")
if heuristics:
    print("HEURISTIC findings are env-dependent — review, they don't fail CI without "
          "--strict. See references/cable-security-guide.md")
print("✅ no high-confidence findings" if not highs else "❌ high-confidence findings above")
sys.exit(1 if highs or (STRICT and heuristics) else 0)
PY
