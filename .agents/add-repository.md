# Runbook — add a repository to the SpecGuard platform

**Executed:** 2026-08-19, for `yatfa-ai/specguard`.
**Result:** repository `#4`, API key `#4`, verified with a live `HTTP 200` against the public API.

> ⚠️ **Superseded by `POST /api/v1/repositories`**, shipped as **SPGD-756** (`772fb4f`, merged
> 2026-08-19) — the day before this runbook itself merged. That endpoint is the supported way for
> an agent to register a repository, and unlike sections 3 and 4 below it **keeps** the GitHub
> ownership check. Reach for it first; §7 gives its contract, its precondition, and the two places
> it diverges from what this runbook asked of it. Sections 3 and 4 are the **fallback** for when
> that path is unavailable — see §2 for exactly when that is.

This file is kept because it is a dated record of a procedure that actually ran, which is what
`.agents/` is for. Read §3 and §4 as history plus a fallback, not as the current path.

---

## 1. What "adding a repository" actually is

Two rows. That is the whole operation.

```
repositories   github_full_name, name, user_id
api_keys       repository_id, name, token_digest, created_by_user_id
```

`name` is derived from `github_full_name` by a `before_validation` callback, and
`github_full_name` is normalised by another — so **create through the model, never with raw SQL**,
or you get a row the application cannot render.

`token_digest` is a SHA-256. The raw token exists only in memory during the create, is readable
once through `ApiKey#raw_token`, and is never persisted. There is no recovery: a lost token is
replaced by revoking the key and minting another, not by looking it up.

## 2. The normal path, and when it is not available

A person registers a repository in the web UI at `/repositories/new`. The picker lists their GitHub
repositories and the server verifies ownership with GitHub before saving.

An agent or a script registers a repository with `POST /api/v1/repositories`, authenticated by a
user-scoped `sgu_` key. It has no browser session and therefore no GitHub token of its own, so it
does not ask GitHub live; it redeems the **registration grant** recorded the last time that person
viewed their repository list in a browser. That is the API path's precondition, not a gap in it —
§7 states it in full.

**Prefer one of those two paths.** Both perform a real ownership check; this runbook does not.

Fall back to this runbook only when neither is available — that is, when all of the following hold:

- no browser session, so `/repositories/new` is out of reach;
- no usable `sgu_` key, or the person has no grant on file / their grant has aged out, so
  `POST /api/v1/repositories` refuses; and
- the registration still must be scripted or replayed.

If the API path refuses for a reason a person can clear — signing in and opening their repository
list refreshes the grant — clear it and use the API path. That is a supported registration; this
one is not.

> ⚠️ **This procedure bypasses the GitHub ownership check.** It writes the row that the check would
> have gated. Only run it for a repository the target user genuinely administers and that appears in
> their own picker — verify that in the UI first if there is any doubt. It grants no access to
> GitHub and reads no code; what it creates is a SpecGuard-side record and a credential that can
> post telemetry to it.

## 3. Register the repository and issue its key

Runs against the deployed application, so model callbacks, validations and uniqueness all apply.

Set these two, then run the block verbatim:

```bash
FULL_NAME="yatfa-ai/specguard"   # the repository to register
OWNER_ID=1                       # users.id of the person who will own it
KEY_NAME="Local agent / CI"      # names the client this key is for — one key per client
KEY_FILE=~/.specguard/specguard.key
```

Find the owner's id first if you do not know it:

```bash
kubectl exec deploy/specguard-web -- bin/rails runner \
  'User.find_each { |u| puts "#{u.id}  @#{u.github_handle}  #{u.email}" }'
```

```bash
mkdir -p "$(dirname "$KEY_FILE")" && umask 077
kubectl exec deploy/specguard-web -- bin/rails runner "
  user = User.find(${OWNER_ID})
  repo = Repository.where('LOWER(github_full_name) = ?', '${FULL_NAME}'.downcase).first
  repo ||= user.repositories.create!(github_full_name: '${FULL_NAME}')
  key = repo.api_keys.find_by(name: '${KEY_NAME}')
  key ||= repo.api_keys.create!(name: '${KEY_NAME}', created_by_user: user)
  print key.raw_token.to_s
" > "$KEY_FILE" 2>/tmp/sg-register-err.txt
chmod 600 "$KEY_FILE"
```

**Idempotent.** Both creates are find-or-create, so re-running changes nothing.

⚠️ **Re-running writes an EMPTY `$KEY_FILE`.** `raw_token` is populated only on the create that
minted it; a second run finds the existing key and prints nothing. That is correct — the token is
genuinely unrecoverable — but it will silently truncate a file that held a working key. Check the
size before trusting it, and if you need a fresh token, mint a *new named key* rather than re-running:

```bash
wc -c < "$KEY_FILE"   # expect 36: "sgk_" + 32 chars. 0 means nothing was minted this run.
cat /tmp/sg-register-err.txt   # stdout is the token, so errors are on stderr — check it on failure
```

The redirect is deliberate: **the token goes from the pod to a `600` file without passing through a
terminal, a scrollback or an agent's context.**

## 4. Verify

Confirm the rows, without touching the secret:

```bash
kubectl exec deploy/specguard-web -- bin/rails runner "
  r = Repository.find_by!(github_full_name: '${FULL_NAME}')
  puts \"repo ##{r.id}  #{r.github_full_name}  owner=@#{r.user.github_handle}\"
  r.api_keys.each { |k| puts \"  key ##{k.id} #{k.name.inspect} #{k.token_hint} last_used=#{k.last_used_at.inspect}\" }
"
```

Observed on 2026-08-19:

```
repo #4  full_name=yatfa-ai/specguard  name=specguard  owner=@rom4ik
  key #4 name="Local agent / CI" hint=sgk_…4eabf2 digest_len=64 last_used=nil
```

Then prove the credential works end to end, over the real public endpoint. **This is the step that
actually verifies the work** — the rows above only prove something was written.

```bash
K=$(cat "$KEY_FILE")
curl -s -o /tmp/sg-resp.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $K" https://specguard.yatfa.com/api/v1/repository
head -c 400 /tmp/sg-resp.json
```

Observed: `HTTP 200`, body naming `"full_name":"yatfa-ai/specguard"`, and `last_used_at` stamped on
the key by that very request — which is itself the proof the token authenticated rather than a
cached answer being served.

A `401` means the token is wrong or the file is empty. A `404` means the ingress host is wrong.

## 5. The last mile — wire CI

Registration does not make data appear. Until a run is posted the repository is an empty shell:
after this runbook, `yatfa-ai/specguard` has **0 test runs**.

In the target repository's `Gemfile`:

```ruby
group :test do
  gem "specguard-rspec", require: false
end
```

In `.rspec` (or the equivalent `RSpec.configure` block — the two are equivalent):

```
--require specguard/rspec/formatter
--format SpecGuard::RSpecFormatter
```

The formatter is **additive**: it runs alongside `progress` / `documentation` and leaves human
output byte-for-byte unchanged.

In CI, set the two variables the reporter needs:

| Variable | Value |
| --- | --- |
| `SPECGUARD_ENDPOINT` | `https://specguard.yatfa.com` |
| `SPECGUARD_API_KEY` | the contents of `$KEY_FILE` — as a CI secret, never committed |

Optional, and worth setting because they anchor a run to a commit:
`SPECGUARD_COMMIT_SHA`, `SPECGUARD_BRANCH`, `SPECGUARD_RUN_ID`, `SPECGUARD_SHARD_ID`.

Confirm by re-reading `GET /api/v1/repository` after the first CI run: `latest_run` stops being
empty.

> ⚠️ **This step requires a CI job that runs the suite, and a repository may not have one.**
> Checked for `yatfa-ai/specguard` on 2026-08-19: `.github/workflows/` contained only
> `release.yml`, the `Gemfile` had no `specguard-rspec`, and `.rspec` was just `--require
> spec_helper`. The suite ran through `bin/ci`, not through a GitHub Actions test job.
>
> Addressed on branch `spgd-ci-workflow` (unmerged at time of writing): `.github/workflows/ci.yml`
> runs `bin/ci` against a `pgvector/pgvector:pg16` service, and the gem is in the
> `:development, :test` group. Two traps that workflow had to close, both of the same shape — a
> dependency whose absence makes a step **skip silently instead of fail**, so the gate reports green
> having never run:
>
> - **Node.** `lint:stylesheet` without npm reported "npm is unavailable, so DaisyUI cannot be
>   resolved here" and passed, never comparing the committed CSS against its sources. That check no
>   longer exists: the stylesheet is now built from an npm-pinned toolchain and is not committed at
>   all, so there is nothing to be stale. Node is a hard requirement of the build instead of a
>   condition the check quietly tolerated.
> - **The browser.** `spec/support/system.rb` looks for `/usr/bin/chromium` and
>   `/usr/bin/chromedriver`; GitHub's runners ship `google-chrome` instead, and a missing browser
>   skips every system spec. `CHROMIUM_BINARY` / `CHROMEDRIVER_BINARY` exist for exactly this, and
>   the workflow resolves both and fails loudly if neither is found.
>
> Registration is complete and correct without any of this. A repository with no ingested run is a
> valid, empty repository — not a broken one.

## 6. Environment facts, as observed 2026-08-19

Record these because each one is a thing that will rot, and a later reader needs to know whether
this runbook was written against the same world they are in.

| Fact | Value |
| --- | --- |
| Cluster context | the shared cluster, bare `kubectl` |
| Public host | `specguard.yatfa.com` (ingress `specguard-ingress`, traefik) |
| Deployed image | `registry.tinkerai.win/specguard:sha-e47e4a5` |
| Workloads | `specguard-web`, `specguard-worker`; both take `envFrom: specguard-config, specguard-secret` |
| Repositories before / after | 1 (`yatfa-ai/yatfa`) → 2 |
| Users | one: `#1 @rom4ik` |

> ⚠️ **The deployed image is behind `origin/main`.** `GithubInstallation` does not exist in the
> running code, so prod still verifies ownership by the older OAuth path rather than by GitHub App
> installation. This does not affect the runbook — it writes rows directly — but any reasoning about
> the *verification* code must be done against the deployed tag, not against `main`.

## 7. What replaced this

`POST /api/v1/repositories`, shipped as **SPGD-756** (`772fb4f`, merged 2026-08-19) under the
**SPGD-750** roadmap. Sections 3 and 4 collapse into:

```
POST /api/v1/repositories   { "github_full_name": "yatfa-ai/specguard" }
  → 201, body carries the repository and its first ingest key, revealed once
```

Every clause of that is true of the shipped endpoint today: the body is top-level rather than
nested under a `repository` key, the success status is `201`, and the first ingest key is minted in
the same transaction and returned in that response.

**Precondition.** The endpoint authenticates a `sgu_` user key, and the ownership check it runs is
not a live call to GitHub — it redeems the `GithubRegistrationGrant` recorded when that person last
viewed their repository list in a browser. A grant older than `GithubRegistrationGrant::MAX_AGE`
(see the constant and the reasoning beside it in `app/models/github_registration_grant.rb`) is not
redeemable, and a person who has never opened SpecGuard in a browser has no grant at all. Both are
ordinary states with an ordinary fix — sign in and open the repository list — not reasons this
runbook must survive.

Two properties this runbook has that it asked the API to keep, and how they actually shipped:

1. **Idempotence** — this runbook's find-or-create means re-registering an already-registered
   repository is not an error and does not mint a second key. **The endpoint diverges.** A
   duplicate is refused with `400` and `has already been taken`, and there is no API path to mint a
   key over an existing repository, so a caller that loses its first key cannot recover through
   this endpoint. Recorded, not retracted: the property is still the one worth having.
2. **The ownership check comes back.** **Kept.** The endpoint verifies against the caller's grant
   before saving, so the GitHub conjunction this runbook bypasses is enforced on the supported
   path. Convenience is not a reason to ship the bypass.

And one this runbook does *not* have that it asked the API for: **the four distinct refusal
states** (`:not_installed`, `:not_in_installation`, `:not_administered`, `:not_authorized`)
reaching the caller as separate answers, since they are the difference between "install the App",
"ask an admin" and "re-authorise". **The endpoint diverges, deliberately.** All refusals — the
record's own validation failures and the ownership gate alike — collapse into a single `400`
response path, on the stated reasoning that a refusal is a refusal and the response should not
branch on which produced it. The messages still carry the detail; the *status* does not
distinguish. Recorded here because the difference between those answers is a real difference for
the caller, whatever the response shape does with it.
