# Cable / Turbo-Stream security rules — what each flag means and how to fix it

Grounded in the websocket-security gap identified in the *StimulusReflex
Patterns* review (`dte-skills:Books/learnings/stimulus-reflex-patterns.md`, the
"Net-new gaps" section): signed stream identifiers, rejecting unauthorized
subscriptions, `allowed_request_origins`, CSP `connect-src`, never
`constantize`-ing client strings, and signed GlobalIDs. The StimulusReflex stack
is superseded, but **every one of these is stack-agnostic** — it protects any
ActionCable / Turbo-Streams app just as much, which is why it outlives the book's
framework.

Each rule names a **failure that produces no error**: the websocket works, the
stream broadcasts, nothing raises — it just leaks to the wrong subscriber, loads
an attacker's class, or accepts a connection from any origin.

This complements `hotwire-rails-toolkit/turbo-streams-patterns`, whose lint also
checks custom-channel authorization; this is the security-suite copy and needs no
Hotwire plugin installed. It does **not** re-check `Turbo::StreamsChannel` signed
stream-name parity — that stays in the Hotwire checker.

## Contents

- `unauthorized-subscription` (HIGH), `client-constantize` (HIGH),
  `forgery-protection-disabled` (HIGH) · `origin-allowlist` (HEURISTIC),
  `csp-connect-src` (HEURISTIC) · Deliberately not flagged · Running

---

## `unauthorized-subscription` — `stream_from`/`stream_for` with no auth guard  (HIGH)

**What:** a custom channel (`app/channels/**`, excluding the `ApplicationCable`
base) calls `stream_from` / `stream_for` but the file shows no authorization —
no `reject`, no scoping to a verified identity (`current_user`), no policy or
ownership check.

**Why:** ActionCable broadcasts go to **every** subscriber of a stream name. If
any connection can subscribe — e.g. `stream_from "messages:#{params[:room]}"`
with no check — a client can subscribe to *another* user's stream name and
receive their broadcasts. The transport encrypts nothing at the app layer; the
stream name is the only gate. Stream names are often derived from plaintext,
guessable resource ids (`dom_id`), so "they won't know the name" is not a
defense.

**Fix:** authorize the subscriber.

- Scope to the connection's **verified identity** — `stream_for current_user`,
  or `stream_from "notifications:#{current_user.id}"`. The connection is
  authenticated in `ApplicationCable::Connection` via `identified_by` +
  `reject_unauthorized_connection`; the channel then streams only that identity's
  data.
- Or authorize explicitly and `reject` otherwise:

  ```ruby
  def subscribed
    record = Project.find_by(id: params[:id])
    return reject unless record && Pundit.policy(current_user, record).show?
    stream_for record
  end
  ```

- For broadcasts where the **name itself** must be unguessable, sign it
  (`MessageVerifier` / signed GlobalIDs / `to_sgid`) and verify on subscribe —
  see also the Hotwire checker for `Turbo::StreamsChannel` signed names.

> Demoted to HEURISTIC when the channel **does** call `reject` but the scan sees
> no obvious predicate — `reject` might be guarding correctly through a helper
> the grep can't follow. Confirm by hand.

---

## `client-constantize` — `(safe_)constantize` on a `params[]`/`data[]` value  (HIGH)

**What:** a line applies `constantize` or `safe_constantize` to a client-supplied
string — a controller `params[...]`, a channel `received(data)` `data[...]`, or
an element `dataset` value forwarded to the server.

**Why:** `"User".constantize` resolves *any* loaded constant by name. Fed an
attacker-controlled string, it loads an arbitrary class — a step toward RCE,
information disclosure, or instantiating something dangerous. `safe_constantize`
is **not** safe here: "safe" only means it returns `nil` instead of raising for an
unknown name; it still happily resolves any *real* class the attacker names.

**Fix:** never constantize a client string directly. Map the input through a
**server-side allowlist**:

```ruby
ALLOWED = { "post" => Post, "comment" => Comment }.freeze
klass = ALLOWED.fetch(params[:type])   # raises on anything not allowlisted
```

If you genuinely need dynamic classes, sign the value server-side (a signed
GlobalID — `to_sgid` / `GlobalID::Locator.locate_signed`) so the client can't
forge it.

---

## `forgery-protection-disabled` — `disable_request_forgery_protection = true` in a non-dev env  (HIGH)

**What:** `config.action_cable.disable_request_forgery_protection = true` is set
in a non-dev environment (production, staging) or an initializer.

**Why:** ActionCable checks the `Origin` header against the allowed origins on
every handshake. Disabling that check is **Cross-Site WebSocket Hijacking
(CSWSH)**: any malicious page a logged-in user visits can open a websocket to
your app *with the user's cookies* and read/drive their streams. There is no
same-origin policy on websockets — this header check is the defense.

**Fix:** delete the line. If you need cross-origin cable (a separate cable host),
set an explicit `config.action_cable.allowed_request_origins` allowlist instead
of turning the check off. Dev/test may toggle it freely (those files are not
flagged).

---

## `origin-allowlist` — cable in use, no `allowed_request_origins` set  (HEURISTIC)

**What:** Action Cable / Turbo Streams is in use (a custom channel, a
`turbo_stream_from` view, or a JS consumer) but no config file sets
`config.action_cable.allowed_request_origins`.

**Why / the caveat:** missing this is **usually fine** — Rails defaults Action
Cable to **same-origin only**, so the common deployment is already protected.
This is a review nudge, not a vulnerability by itself. It matters when you
terminate cable on a **different host** (you then need an explicit allowlist), or
when origins are injected via ENV that this static scan can't see. Heuristic by
nature — it never fails CI without `--strict`.

**Fix when it applies:** set an explicit allowlist (strings or regexps):

```ruby
config.action_cable.allowed_request_origins = [ "https://app.example.com", %r{https://.*\.example\.com} ]
```

---

## `csp-connect-src` — active CSP, cable in use, no `connect-src`  (HEURISTIC)

**What:** an **active** (non-commented) `content_security_policy do …` block
exists, Action Cable is in use, but the policy declares no `connect_src`.

**Why / the caveat:** `connect-src` is the CSP directive that governs websocket
(`ws:`/`wss:`) connections. With a CSP active and no `connect-src`, the websocket
falls back to `default-src` — which may already cover it (then this is a
non-issue) or may block it (then cable silently fails to connect). Because it
depends on `default-src` and your cable host, it's heuristic.

**Fix:** be explicit about where the socket may connect:

```ruby
policy.connect_src :self, "wss://app.example.com"
```

---

## Deliberately NOT flagged

- **Plaintext resource ids in stream names / `data-*` attributes.** `dom_id`-style
  plaintext ids are standard, correct Rails — flagging them would false-positive
  on nearly every Turbo app. A plaintext id is only a problem *combined with* a
  missing subscription guard, which is exactly what `unauthorized-subscription`
  already catches. Sign the stream name only when the name must be unguessable.
- **Client-side (JS) `constantize`.** `constantize` is a server-side Ruby method;
  there is nothing meaningful to grep for it in JS, and attempting to would
  false-positive. The real RCE surface is the server constantizing the value the
  client sent — covered by `client-constantize` on the Ruby side.
- **Socket/port-exhaustion DoS.** Not statically detectable without runtime/infra
  context.

These stay with the LLM reviewers (`dte-deep-reviewer`, `security-review`), which
can read intent.

## Running

```bash
scripts/lint_cable_security.sh path/to/rails-app     # defaults to .
scripts/lint_cable_security.sh . --strict            # HEURISTIC findings fail too
```

Exit: `0` no HIGH findings, `1` HIGH (or HEURISTIC under `--strict`), `2` bad
usage / no `python3`. A clean run is a **gate, not a proof** — this is a
deterministic pre-pass that complements, never replaces, an LLM security review.
