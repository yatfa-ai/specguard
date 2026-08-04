# OpenTestIntent Protocol

The **OpenTestIntent** protocol is a tiny, language-agnostic annotation that declares *what a
test verifies*. It is "open" because any tool — not just SpecGuard — can read it. The canonical schema
and this specification live in the **`open-test-intent`** repository (vendor-neutral); SpecGuard
is the reference implementation and first consumer.

A test that carries an `@intent` is **annotated**; one that doesn't is **unannotated**. Both are
ingested (so the annotated ratio is measurable), but only annotated tests participate in
duplicate detection.

## 1. Annotation syntax

An annotation is a single comment line immediately above (or on the same line as) the test,
prefixed `@intent:` and followed by a JSON object:

```ruby
# @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
it "rejects checkout on an expired card" do
  # ...
end
```

The JSON keys are whitespace-tolerant and may use single or double quotes. The linter normalizes
before validating.

### Equivalent forms

All of the following parse to the same intent and are valid:

```ruby
# @intent: { "entity": "Order", "action": "checkout", "behavior": "returns 402 payment required on expired card", "layer": "request" }
# @intent: { entity: 'Order', action: 'checkout', behavior: 'returns 402 payment required on expired card', layer: 'request' }
# @intent: {entity:"Order",action:"checkout",behavior:"returns 402 payment required on expired card",layer:"request"}
```

## 2. Fields

| Field | Type | Required | Constraint | Purpose |
|---|---|---|---|---|
| `entity` | string | yes | `minLength: 2` | Subject under test, capitalized noun (`Order`, `CheckoutService`) |
| `action` | string | yes | `minLength: 2` | Operation/scenario (`checkout`, `apply_discount`) |
| `behavior` | string | yes | `minLength: 15` | One-sentence expected outcome in plain language |
| `layer` | enum | yes | `unit` \| `integration` \| `request` \| `system` | Test level |
| `preconditions` | string[] | no | — | Named setup assumptions (`["user is logged in", "cart is non-empty"]`) |

### Field guidelines

- **`entity`** is the coarse grouping key for duplicate detection. Pick the *domain* noun, not
  the *implementation* noun: `Order`, not `OrderPolicy` or `OrdersController`. Keep entity names
  stable — changing `User` to `Account` fragments history.
- **`behavior`** is the only free-text field that feeds the embedding. Write it as a complete,
  behavior-focused sentence: *"returns 402 payment required on expired card"*. The more
  semantic content it carries (not just "works", "is valid"), the better duplicate detection works.
- **`layer`** is the axis duplication lives across. Be honest — a model-level spec is `unit`,
  a full-stack spec hitting a route and the DB is `request` (Rails) / `integration` (generic),
  a browser-driving spec is `system`.
- **`preconditions`** is optional metadata for humans and future tooling; it is **not** embedded.

## 3. JSON Schema (validation contract)

This is the canonical schema the linter validates against. A repo can pin a specific draft by
serving its own `$id`; SpecGuard ships with draft-07.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://specguard.dev/schemas/open-test-intent.v1.json",
  "title": "OpenTestIntent v1",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "entity":        { "type": "string", "minLength": 2 },
    "action":        { "type": "string", "minLength": 2 },
    "behavior":      { "type": "string", "minLength": 15 },
    "layer":         { "type": "string", "enum": ["unit", "integration", "request", "system"] },
    "preconditions": { "type": "array", "items": { "type": "string" } }
  },
  "required": ["entity", "action", "behavior", "layer"]
}
```

`additionalProperties: false` means typos like `{ entiity: ... }` fail loudly instead of being
silently dropped.

## 4. Worked examples (by layer)

```ruby
# spec/models/order_spec.rb
# @intent: { entity: "Order", action: "total", behavior: "sums line item prices after applying the active discount", layer: "unit" }
describe Order, "#total" do ... end

# spec/services/billing/checkout_service_spec.rb
# @intent: { entity: "CheckoutService", action: "checkout", behavior: "rejects the transaction on an expired card and emits a payment_failed event", layer: "unit" }
describe CheckoutService, "#checkout" do ... end

# spec/requests/orders_spec.rb
# @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
describe "POST /orders/checkout" do ... end

# spec/system/checkout_flow_spec.rb
# @intent: { entity: "Order", action: "checkout", behavior: "shows a payment error card and keeps the cart intact when the saved card is expired", layer: "system" }
describe "expired-card checkout flow" do ... end
```

Notice the first three all describe *aspects* of expired-card checkout across layers — exactly
the overlap SpecGuard is built to surface. With these annotations present, an agent calling
`/check-intent` for a *fourth* expired-card test gets told: *"already covered at unit, request,
and system — don't add another."*

## 5. Versioning

- This is **OpenTestIntent v1**. The schema URL ends in `.v1.json`.
- Breaking changes (renamed/removed fields, narrowed enums) bump to `v2` and ship a new schema
  `$id`. SpecGuard keeps accepting the prior version for one release cycle.
- Additive changes (a new optional field like `preconditions`) do **not** bump the major version;
  `additionalProperties: false` means a v1 linter rejects unknown keys, so additions are still
  an explicit, versioned choice — not silent forward-compatibility.

## 6. What is intentionally *not* in the protocol

- **No assertions, no code.** The annotation describes intent, not implementation. It never
  contains `expect(...)` or test bodies.
- **No framework coupling.** Nothing in the schema assumes RSpec, Minitest, or a specific
  language. The `specguard-rspec` gem is one client; a `specguard-pytest` could exist.
- **No pass/fail.** Whether a test passed is telemetry about a *run*, not a property of the
  *intent*. It lives on `TestRun`, not in the annotation.
