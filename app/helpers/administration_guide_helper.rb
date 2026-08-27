# frozen_string_literal: true

# The payloads and snippets the public administration guide publishes.
#
# The reasoning is `IntegrationGuideHelper`'s, and it is deliberately not restated here in full —
# see that file for why copy-pasteable snippets are built at column 0 rather than indented into the
# ERB, and why the field tables stay in the template while the fixtures do not.
#
# What IS worth stating separately is what this page's fixture is a fixture OF. The integration
# guide's example is a request BODY whose acceptance is the claim. So is this one, and the same
# spec-side discipline applies: `spec/requests/administration_guide_spec.rb` reads
# {EXAMPLE_REQUEST_BODY} back off the *rendered page* — by {EXAMPLE_REQUEST_ELEMENT_ID} — and POSTs
# it to `/api/v1/repositories`. A page describing the registration request in prose would be an
# unverified second copy of the contract, which is precisely what that pattern exists to prevent.
#
# The seven-day bound is the other thing this file is careful about. It is published from
# `GithubRegistrationGrant::MAX_AGE` and is never typed as a numeral anywhere in the guide, so
# changing the constant changes the page.
module AdministrationGuideHelper
  # For `integration_guide_endpoint`, which `#administration_guide_endpoint` below delegates to.
  #
  # A view context has every helper module mixed in already, so this changes nothing about how the
  # page renders. It is here for the OTHER caller: a spec that includes this module to name the
  # endpoint the same way the page does gets the dependency with it, rather than a `NameError` that
  # invites re-spelling `root_url.sub(...)` locally — which is the exact drift
  # `integration_guide_endpoint` was extracted to prevent.
  include IntegrationGuideHelper

  # The element id the worked registration body is rendered under, and the handle the verification
  # spec finds it by. A constant for the same reason its sibling is one: the spec cannot then drift
  # from the template by a typo.
  EXAMPLE_REQUEST_ELEMENT_ID = "registration-example-request"

  # The element id the worked `201` body is rendered under.
  #
  # Same purpose as its sibling above, for the other half of the exchange: it lets the spec read the
  # published response back off the RENDERED page. That matters for the `hint`/`token` relationship
  # in particular — asserting it against {EXAMPLE_TOKEN} and {EXAMPLE_TOKEN_HINT} would prove two
  # constants relate correctly while the template published something else entirely, which is the
  # same "pin derived from what it pins" trap the request fixture is read off the page to avoid.
  EXAMPLE_RESPONSE_ELEMENT_ID = "registration-example-response"

  # The name used throughout the worked example.
  #
  # It is one constant rather than a string repeated across the request body, the curl snippet and
  # the response example, because those three are the SAME registration told three times and a page
  # that registered `acme/billing-service` and then showed a `201` for something else would be
  # teaching the reader to distrust the example. The verification spec builds the grant it seeds
  # from this value too — by reading it out of the rendered fixture — so the guide names the
  # repository and the spec follows, never the other way round.
  EXAMPLE_REPOSITORY_FULL_NAME = "acme/billing-service"

  # The complete registration request body, top-level rather than nested.
  #
  # That shape is the endpoint's, and it is deliberate on its side too — see
  # `Api::V1::UserRepositoriesController#create_params`: "what a caller writing curl by hand will
  # send". A guide that wrapped it in a `repository` key out of Rails habit would publish a body the
  # server ignores, producing a refusal whose message names the missing field and not the mistake.
  EXAMPLE_REQUEST_BODY = { "github_full_name" => EXAMPLE_REPOSITORY_FULL_NAME }.freeze

  # How long a grant may be redeemed for, as the page says it.
  #
  # `MAX_AGE.inspect` gives "7 days" for the current `7.days`, and gives a correct English phrase
  # for whatever it is changed to. The alternative — typing "seven days" into the template — is the
  # exact defect this ticket was written to close on the OTHER side of the system, where a
  # precondition lived only in the code that enforced it; reintroducing it as a hand-typed numeral
  # in the document that finally publishes it would be a poor trade.
  def administration_guide_grant_max_age = GithubRegistrationGrant::MAX_AGE.inspect

  def administration_guide_example_request = JSON.pretty_generate(EXAMPLE_REQUEST_BODY)

  # This installation's base URL, borrowed from the integration guide's helper rather than
  # re-derived. SpecGuard is self-hostable, so the endpoint is never a constant, and a second
  # `root_url.sub(...)` here would be a second chance to get the trailing-slash strip wrong — the
  # very drift that helper was extracted to prevent.
  def administration_guide_endpoint = integration_guide_endpoint

  def administration_guide_register_curl_snippet(endpoint)
    <<~SHELL.strip
      curl -sS -X POST #{endpoint}/api/v1/repositories \\
        -H "Authorization: Bearer $SPECGUARD_USER_KEY" \\
        -H "Content-Type: application/json" \\
        -d '#{EXAMPLE_REQUEST_BODY.to_json}'
    SHELL
  end

  def administration_guide_list_curl_snippet(endpoint)
    <<~SHELL.strip
      curl -sS #{endpoint}/api/v1/repositories \\
        -H "Authorization: Bearer $SPECGUARD_USER_KEY"
    SHELL
  end

  # The token shown in the worked `201`, and the source the `hint` beside it is DERIVED from.
  #
  # A constant because the two values must be computed from one string. They were once typed
  # independently, and the hint that resulted (`sgk_…gA1`) was the last three characters of THIS
  # token — which is neither what `ApiKey#token_hint` produces nor the right length, and, far worse,
  # made the hint a literal suffix of the credential printed directly above it. That is the exact
  # misreading `#administration_guide_example_response` says it chose the token format to avoid, and
  # it falsified the page's own sentence that the hint "is not the credential and cannot be used as
  # one". A reader who trusted the example over the paragraph would try to recognise a key by
  # comparing the hint to a stored token's tail, and would never match anything.
  EXAMPLE_TOKEN = "sgk_R0zVvQx7mK2pL9nT4wY6bJ8cH3dF5gA1"

  # The hint for {EXAMPLE_TOKEN}, produced by ASKING THE SERVER for one rather than by reproducing
  # how it makes them.
  #
  # The unsaved record is the whole point: `#token_hint` reads only `token_digest`, so handing it a
  # digest is enough to get the real answer without touching the database or needing a repository.
  #
  # This once reimplemented the method instead of calling it — `TOKEN_PREFIX + "…" + digest.last(6)`
  # — under a comment claiming it therefore could not drift. Half of that was true: both sides went
  # through `ApiKey.digest`, so a change of hash algorithm did carry over. The fragment length did
  # not, because the `6` was re-typed here. Changing `#token_hint` to `.last(8)` moved the server and
  # left the page publishing `sgk_…bec81d`, a hint the server can no longer produce, on a page whose
  # inherited charter is that where it and the server disagree, THE PAGE IS WRONG. Nothing reported
  # it, because the spec re-typed the same `6` and so agreed with this constant under every change to
  # the method and with the server under none. Calling the method closes both halves at once: there
  # is no second copy of the algorithm left to drift.
  EXAMPLE_TOKEN_HINT = ApiKey.new(token_digest: ApiKey.digest(EXAMPLE_TOKEN)).token_hint

  # The `201` body, shown in full.
  #
  # Illustrative rather than verified, and it is the ONE thing on this page that is — the values
  # cannot be a fixture because an id, a timestamp and a minted token do not exist until the request
  # is made. The KEYS are what a reader builds against, and those the spec does pin: it asserts the
  # real response carries exactly the structure shown here, so a field renamed on the server fails
  # the suite rather than silently outliving its documentation.
  #
  # The token is deliberately shown as a realistic-looking value rather than as `sgk_…`: a reader
  # scripting against this needs to see that the field carries the whole credential, and an ellipsis
  # invites the reading that it is a truncated hint like the `hint` field beside it.
  def administration_guide_example_response
    JSON.pretty_generate(
      "repository" => {
        "id" => 42,
        "full_name" => EXAMPLE_REPOSITORY_FULL_NAME,
        "name" => "billing-service",
        "registered_at" => "2026-01-15T09:24:11Z"
      },
      "api_key" => {
        "name" => Api::V1::UserRepositoriesController::FIRST_KEY_NAME,
        "token" => EXAMPLE_TOKEN,
        "hint" => EXAMPLE_TOKEN_HINT,
        "created_at" => "2026-01-15T09:24:11Z"
      }
    )
  end
end
