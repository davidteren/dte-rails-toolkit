---
name: cable-stream-security
description: Deterministic websocket / Turbo-Stream HARDENING checker for any ActionCable or Turbo Streams Rails app — flags the security failures that produce no error: a channel that streams without authorizing the subscriber (broadcast eavesdropping), `constantize`/`safe_constantize` on a client-supplied params/data string (arbitrary class load / RCE-ish), Action Cable request-forgery protection disabled in a non-dev env (CSWSH), and — as caveated heuristics — a missing `allowed_request_origins` allowlist or a CSP with no `connect-src`. Stack-agnostic (NOT tied to StimulusReflex). Use as a cheap pre-pass before a security review, when auditing websocket code, or to gate these in CI. Emits file:line + the rule + the fix.
---

# cable-stream-security

A runnable grep-based gate for the **mechanically-detectable** websocket
hardening failures in an ActionCable / Turbo-Streams app. These produce no
runtime error — the socket works and the stream broadcasts; it just leaks to the
wrong subscriber, loads an attacker-named class, or accepts a connection from any
origin.

Full per-rule rationale and fixes: [`references/cable-security-guide.md`](references/cable-security-guide.md).

Stack-agnostic: it does not care whether you use StimulusReflex, CableReady, or
plain Hotwire — it checks the **transport-level** security every ActionCable +
Turbo Streams app shares.

## When to use

- As a **pre-pass before** `security-review` / `dte-deep-reviewer` — surface the
  greppable websocket holes with file:line first (cheap, reproducible), then let
  the LLM lenses handle the semantic ones.
- Auditing websocket / Turbo-Stream code, or gating these in CI.
- Specifically when you suspect: a channel streaming without authorizing the
  subscriber, a `constantize` on client input, forgery protection turned off, or
  a CSP/origin gap.

## The rules

| Label | Flags | Severity |
|---|---|---|
| `unauthorized-subscription` | `stream_from`/`stream_for` in a custom channel with no `reject`/identity/ownership guard | HIGH |
| `client-constantize` | `(safe_)constantize` on a `params[]` / `data[]` / `dataset` value | HIGH |
| `forgery-protection-disabled` | `action_cable.disable_request_forgery_protection = true` in a non-dev env | HIGH |
| `origin-allowlist` | cable in use, no `allowed_request_origins` set anywhere | HEURISTIC |
| `csp-connect-src` | active CSP + cable in use, no `connect-src` directive | HEURISTIC |

The two HEURISTIC rules are **env-dependent** (origins/CSP can come from ENV, a
proxy, or `default-src`; Rails already defaults cable to same-origin) — so they
are caveated and never fail CI without `--strict`.

The origin/CSP rules only run when Action Cable is **actually in use** — a custom
channel, a `turbo_stream_from` view, or a JS consumer. The default `config/cable.yml`
that every Rails app ships does **not** count (firing on it would be a mass false
positive).

## How to run

```bash
scripts/lint_cable_security.sh path/to/rails-app     # defaults to .
scripts/lint_cable_security.sh . --strict            # HEURISTIC findings fail too
```

- `--strict` — HEURISTIC findings also fail the exit code.
- Exit: `0` no HIGH findings, `1` HIGH (or HEURISTIC under `--strict`), `2` bad usage.
- Needs `python3` (used for the channel block walk, not a Ruby load).

## Ceiling

Heuristic **path-scoped grep + indentation walk, not a Ruby/JS parser**. It scans
file paths + line text; it does not load code or resolve constants.

- `unauthorized-subscription` decides "authorized" from the presence of an
  identity/guard token (`current_*`, `reject`, `policy`, `owner`, `verified`,
  `signed`, …) anywhere in the channel file — a guard reached through an unusual
  helper can be missed (false negative), and a `reject` with no obvious predicate
  is **demoted to HEURISTIC** rather than passed or hard-failed.
- `client-constantize` is single-line: `params[:x].classify.constantize` is
  caught, a multi-line build is not. A value that's allowlisted *before*
  constantize on the same line may still flag — open the file and confirm.
- `origin-allowlist` / `csp-connect-src` are inherently env-dependent (see above)
  — treat them as review nudges, not findings.

This complements `hotwire-rails-toolkit/turbo-streams-patterns`, whose lint also
checks custom-channel authorization and additionally checks `Turbo::StreamsChannel`
signed stream-name parity. This is the security-suite copy of the channel-auth
check and needs no Hotwire plugin installed; run either. Treat every flag as
"open the file and confirm", not as proof — a clean run is a **gate, not a
proof**, and complements, not replaces, an LLM security review.

## Verified

- **miela_app** (Rails 8): clean / not-applicable, truthfully. It has no custom
  Action Cable channels, no `turbo_stream_from`, no JS consumer, no `constantize`,
  and its CSP is fully commented out — so cable is correctly reported "not in use"
  and every rule is N/A or clean. Manually confirmed each absence (no
  `app/channels/`, no `constantize` in `app`/`lib`, CSP initializer entirely
  commented). Zero false positives — notably, the default `config/cable.yml`
  (solid_cable) did **not** trip the origin/CSP rules.
- **Synthetic break**: a temp app with `app/channels/foo_channel.rb` doing
  `stream_from "x"` with no reject, and a controller doing
  `params[:klass].constantize` — both flagged HIGH, exit 1; cleaned up.
