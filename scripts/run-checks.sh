#!/usr/bin/env bash
# run-checks.sh — run the deterministic Rails checkers against an app, with a
# two-tier posture:
#   GATE     checkers (block: non-zero exit if any finds something)
#   ADVISORY checkers (report-only: printed, never affect exit)
#
# The GATE set is the dimensions a target currently passes clean; ADVISORY is the
# known-debt dimensions. Move a checker GATE->nothing or ADVISORY->GATE per target
# by editing the two arrays below, or override per-run with env (see CONFIG).
#
# Usage:   run-checks.sh <rails-app-dir>            # defaults to .
# Exit:    0 = no GATE findings, 1 = a GATE checker found something, 2 = setup error.
#
# Checker scripts are resolved from the INSTALLED plugin caches (latest version),
# or override with CHECKERS_HOTWIRE / CHECKERS_DTERAILS pointing at a skills/ dir.
set -uo pipefail
APP="${1:-.}"
[ -d "$APP/app" ] || { echo "run-checks: '$APP' has no app/ — point me at a Rails app root" >&2; exit 2; }

# --- locate the two plugins' skills/ dirs (latest installed version, or env override) ---
cache="$HOME/.claude/plugins/cache"
HOTWIRE="${CHECKERS_HOTWIRE:-$(ls -d "$cache"/hotwire-rails-toolkit-marketplace/hotwire-rails-toolkit/*/skills 2>/dev/null | sort -V | tail -1)}"
DTERAILS="${CHECKERS_DTERAILS:-$(ls -d "$cache"/dte-rails-toolkit-marketplace/dte-rails-toolkit/*/skills 2>/dev/null | sort -V | tail -1)}"

# --- CONFIG: which checker runs in which tier. "label|script-path" ---
# Defaults reflect what miela_app passes clean today (gate) vs known debt (advisory).
GATE=(
  "turbo-streams|$HOTWIRE/turbo-streams-patterns/scripts/lint_turbo_streams.sh"
  "turbo-frames|$HOTWIRE/turbo-frames-patterns/scripts/lint_turbo_frames.sh"
  "turbo-morphing|$HOTWIRE/turbo-morphing/scripts/lint_morphing.sh"
  "cable-security|$DTERAILS/cable-stream-security/scripts/lint_cable_security.sh"
  "test-smells|$DTERAILS/rails-test-smell-checker/scripts/lint_test_smells.sh"
)
ADVISORY=(
  "stimulus|$HOTWIRE/stimulus-patterns/scripts/lint_stimulus.sh"
  "layer-boundary|$DTERAILS/layer-boundary-lint/scripts/lint_layer_boundaries.sh"
  "n1-guardrail|$DTERAILS/rails-n1-guardrail-check/scripts/lint_n1_guardrails.sh"
  "csv-io|$DTERAILS/rails-csv-io/scripts/lint_csv_io.sh"
)

run_one() { # label script
  local label="$1" script="$2"
  if [ ! -f "$script" ]; then echo "  ?? $label — checker not found ($script) — skipped"; return 3; fi
  bash "$script" "$APP" >/tmp/rc-out 2>&1; local rc=$?
  if [ "$rc" -eq 0 ]; then echo "  ✓ $label — clean"; else echo "  ✗ $label — findings:"; sed 's/^/      /' /tmp/rc-out | grep -E '❌|⚠️|HIGH|HEUR|bad|warn' | head -20; fi
  return $rc
}

gate_fail=0
echo "== Rails checks: $APP =="
[ -d "${HOTWIRE:-/nonexistent}" ]  || echo "  (hotwire-rails-toolkit not installed — its checkers will be skipped)"
[ -d "${DTERAILS:-/nonexistent}" ] || echo "  (dte-rails-toolkit not installed — its checkers will be skipped)"

echo; echo "-- GATE (blocking) --"
for entry in "${GATE[@]}"; do run_one "${entry%%|*}" "${entry#*|}" || { [ $? -ne 3 ] && gate_fail=1; }; done

echo; echo "-- ADVISORY (report-only, never blocks) --"
for entry in "${ADVISORY[@]}"; do run_one "${entry%%|*}" "${entry#*|}" || true; done

echo
if [ "$gate_fail" -eq 0 ]; then echo "✅ GATE clean"; else echo "❌ GATE findings above — fix before merge (advisory items are informational)"; fi
exit "$gate_fail"
