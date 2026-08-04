# Client Gem: `specguard-rspec`

The client lives in its own repository (`specguard-rspec`) and ships two independent tools that
share one dependency: the [OpenTestIntent](02-open-test-intent-protocol.md) annotation format.

- **`specguard-lint`** — a CLI that validates annotations in changed spec files. Can block CI.
- **`SpecGuard::RSpecFormatter`** — an RSpec formatter that ships run telemetry to `/api/v1/ingest`.
  Never blocks.

They are decoupled: a team can adopt the linter without the formatter, or vice versa.

## Installation

```ruby
# Gemfile
group :test do
  gem "specguard-rspec", require: false
end
```

```ruby
# spec/spec_helper.rb (or rails_helper)
require "specguard/rspec_formatter"

RSpec.configure do |config|
  config.add_formatter(SpecGuard::RSpecFormatter)   # runs alongside your usual formatter
end
```

The formatter is **additive** — it does not replace `progress` or `documentation`; RSpec supports
multiple formatters, and SpecGuard's only writes the JSONL payload and POSTs it.

---

## 1. CLI linter — `bin/specguard-lint`

### What it does

1. Determines the set of `*_spec.rb` files to check:
   - if `--changed` is passed → only files in the current diff (via `git diff --name-only`);
   - otherwise → every `*_spec.rb` under the current directory.
2. Scans each file for `# @intent:` lines.
3. Parses the JSON object and validates it against the
   [OpenTestIntent JSON Schema](02-open-test-intent-protocol.md#3-json-schema-validation-contract).
4. Exits `0` if all annotations are valid (or absent — missing annotations are **not** an error).
   Exits `1` on the first invalid annotation, printing the file, line, and schema violation.

### Usage

```bash
# validate annotations in the current diff only (CI mode)
bundle exec specguard-lint --changed

# validate every spec file in the repo (one-off audit)
bundle exec specguard-lint
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All annotations valid, or no annotations found |
| `1` | One or more annotations are malformed (schema-invalid, truncated, bad enum) |
| `2` | CLI misuse (bad flags, not a git repo with `--changed`, etc.) |

### Design rule: lint, don't require

The linter validates the **shape** of annotations. It never fails on a *missing* annotation,
because forcing 100% annotation would block adoption. Teams that want a hard floor can add a
separate check (e.g. an annotated-ratio gate) once they're ready — that is a policy choice, not a
linter behavior.

---

## 2. RSpec formatter — `SpecGuard::RSpecFormatter`

### What it does

Hooks into RSpec's formatter lifecycle. At the end of the run (`close`), it assembles the run
metadata + per-example data and POSTs it to `/api/v1/ingest`.

### Payload it builds

For each example, the formatter records:

- `file_path`, `line_number` — from RSpec's example metadata.
- `status` — `annotated` if an `@intent:` comment is found on the line above (or same line as)
  the example; otherwise `unannotated`.
- `intent` — the parsed annotation object when `annotated`, else `null`.

It wraps these in the run envelope (`commit_sha` from `$GIT_SHA`/CI env, `branch`,
`duration_seconds`) described in the [API reference](04-api-reference.md#post-apiv1ingest).

### Annotation discovery

The formatter reads the spec **source file** to find annotations, because RSpec's example
metadata does not carry arbitrary preceding comments. The lookup is:

1. Take the example's `line_number`.
2. Look at that line and the line immediately above it for a `# @intent:` token.
3. Parse and attach; if none found, mark the example `unannotated`.

This is intentionally simple — one line of lookback. Multi-line annotations are not supported in
v1 (the protocol is single-line by design).

### Configuration

```ruby
SpecGuard::RSpecFormatter.configure do |c|
  c.endpoint   = ENV.fetch("SPECGUARD_ENDPOINT")   # e.g. https://specguard.example.com
  c.api_key    = ENV.fetch("SPECGUARD_API_KEY")    # sg_live_...
  c.commit_sha = ENV["CI_COMMIT_SHA"]
  c.branch     = ENV["CI_COMMIT_BRANCH"]
  c.timeout    = 10          # seconds; ingest is async, don't block CI
end
```

### Failure mode: never block CI

The formatter is telemetry. If the endpoint is unreachable, the API key is wrong, or the request
times out, it **logs a warning to stderr and exits silently** — it never fails the test run. This
is a hard contract: a telemetry outage must not turn a green CI run red. The only way SpecGuard
blocks CI is the linter, and only for malformed annotations.

### Local file fallback

When `SPECGUARD_API_KEY` is unset (e.g. local dev), the formatter writes the payload to
`log/test_results.jsonl` instead of POSTing. This lets developers inspect what *would* be sent,
and supports a future "replay from file" ingestion path.
