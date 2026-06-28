# Layer-boundary rules — what each flag means and how to fix it

Grounded in palkan's *Layered Design for Ruby on Rails Applications* (the four
architecture layers + four layering rules; the Current-attributes checklist,
p.82). The `layered-rails` plugin documents these as prose; this linter is the
deterministic gate. Each rule below names the **failure that produces no
error** — the code runs fine and leaks structure instead.

The four layers (inbound → domain → data → infrastructure) have one direction of
dependency: upper layers may know about lower ones, never the reverse. Most rules
here catch a *reverse* dependency or a layer doing another layer's job.

## Contents

- `current-in-models`, `request-in-domain`, `query-in-controller`, `io-in-callback`,
  `current-write-location` (hard rules) · `skip-action`, `current-attr-count` (advisory) · Running

---

## `current-in-models` — `Current.<attr>` read inside `app/models/**`  (hard)

**What:** a model reads request-global state via `Current` (e.g.
`Current.user`, `Current.session`).

**Why:** `Current` (`ActiveSupport::CurrentAttributes`) is request-global,
set by the inbound layer. A model that reads it has a hidden dependency on
"who's making the request" — it can't be reasoned about, tested, or reused
from a job/console/import without first priming global state. The book's rule:
**never read `Current` from models** (read it only in a small set of upper
layers). Models should receive what they need as arguments.

**Fix:** pass the value in. `def deactivate(by:)` instead of reaching for
`Current.user` inside the model. Set it from the controller/interactor that
*does* legitimately see `Current`.

---

## `request-in-domain` — `request.` / `params[...]` / `params.permit|require` in `app/services/**` or `app/interactors/**`  (hard)

**What:** a domain object touches the HTTP request or controller params.

**Why:** the request and `params` belong to the inbound (controller) layer. A
service/interactor that reaches for them is a reverse dependency — the domain
now can't run from a job, a rake task, or a test without faking a request. The
book calls this out directly (`param :request` / `request.` inside services).

**Fix:** extract the primitives in the controller and pass them as explicit
arguments/keywords. `Charge.call(amount: params[:amount], token: ...)` — the
interactor sees plain values, never the request.

> Only the **bare** Rails request object is flagged. `PaperTrail.request`,
> `foo.request`, `something.params[...]` (method calls on other receivers) are
> not — they aren't the HTTP request.

---

## `query-in-controller` — `.where(` / `.order(` / `.joins(` / `.pluck(` in `app/controllers/**` or `app/views/**`  (hard)

**What:** query-building happens in a controller action or an ERB template.

**Why:** queries are data-layer knowledge. Built inline in a controller/view,
they can't be named, reused, unit-tested, or optimized in one place; the same
filter gets re-written across actions, and views fire queries during render
(often N+1). The book pushes query construction into **scopes, query objects,
or model methods**.

**Fix:** move it behind a named scope or a query object —
`scope :active, -> { where(active: true) }`, or `OrdersQuery.new.recent`. The
controller calls the name; the view receives a ready relation/collection.

---

## `io-in-callback` — `deliver_later` / `deliver_now` / `Net::HTTP` / `Faraday` / `HTTParty` / `RestClient` inside an `after_*` model callback  (hard)

**What:** a model's `after_create` / `after_save` / `after_commit` / … (inline
block, or a method it references) sends mail or makes an outbound HTTP call.

**Why:** these are **operation** callbacks — the lowest-scoring kind in the
book's 5→1 callback scale. They couple persistence to side effects that fire on
every save (including imports, bulk updates, console fixes, and tests), can't be
opted out of, run inside or around the DB transaction (so a slow/failed HTTP
call can hold or roll back the transaction), and hide the side effect from the
caller. The book's rule: **extract operation callbacks** out of the model.

**Fix:** move the side effect to the caller that performed the action — an
interactor/service that saves *and then* notifies — or enqueue a job explicitly
from there. Reserve callbacks for transformers/normalizers, not operations.

---

## `current-write-location` — `Current.<attr> =` outside `app/controllers`, `app/jobs`, `app/channels`, `app/middleware`  (hard)

**What:** something writes `Current` from a layer that isn't an inbound entry
point (e.g. a presenter, model, or service).

**Why:** Current-attributes rule (3): **write only in inbound layers**. Writes
scattered across the app make "what is `Current.user` right now?" unanswerable
and order-dependent. Entry points (controllers, jobs, channels, middleware) own
the request/execution context; everyone else reads (sparingly) or receives
arguments.

**Fix:** set `Current` once, at the boundary (a controller `before_action`, a
job's setup, middleware). Lower layers take the value as an argument.

---

## `skip-action` — `skip_before_action` / `skip_after_action` / `skip_around_action`  (advisory)

**What:** a controller skips an inherited filter.

**Why:** the book flags skip-callbacks as a **hidden-dependency smell**: the
behavior of a controller now depends on a negation declared elsewhere in the
ancestry, so reading the class top-to-bottom no longer tells you what runs.
Advisory — sometimes legitimate (a public endpoint skipping auth) — but worth a
second look, and a candidate for restructuring the filter so the skip isn't
needed.

**Fix where it's a smell:** prefer composing filters so the common case opts
*in*, rather than a broad filter everyone must opt *out* of.

---

## `current-attr-count` — `Current` declares more than `CURRENT_ATTR_MAX` (default 7) attributes  (advisory)

**What:** the `Current` model has grown a large attribute list.

**Why:** Current-attributes rule (1): **keep `#attributes` minimal**. Every
attribute is a piece of global state that any reader can depend on; a fat
`Current` becomes a god-object of ambient context and makes execution
order/clearing fragile.

**Fix:** keep only the few cross-cutting essentials (current user/session/account,
request id, locale). Pass everything else explicitly. Raise the threshold via
`CURRENT_ATTR_MAX` if your app has a deliberate, reviewed reason.

---

## Running

```bash
scripts/lint_layer_boundaries.sh path/to/rails-app
SKIP="skip-action,query-in-controller" scripts/lint_layer_boundaries.sh .
CURRENT_ATTR_MAX=10 STRICT=1 scripts/lint_layer_boundaries.sh .
```

`STRICT=1` makes advisory findings fail the exit code too. This is a
deterministic pre-pass — it finds the *greppable* violations cheaply and
reproducibly. The semantic ones (anemic models, callback scoring, code-slicing
concerns, god objects) still need the LLM `layered-rails-reviewer` /
`dte-arc-review`.
