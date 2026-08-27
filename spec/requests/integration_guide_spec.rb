# frozen_string_literal: true

require "rails_helper"

# The public integration guide, and the one claim it makes that could otherwise only be asserted in
# prose: that a payload built strictly from what this page publishes is accepted by the endpoint.
#
# == Why the payload is read back off the RENDERED PAGE
#
# The obvious spec here posts `IntegrationGuideHelper::EXAMPLE_PAYLOAD` directly, and it would be
# worth very little: it would prove that a Ruby constant satisfies `Ingest::Payload`, while the
# thing a reader actually copies is the HTML. The two come apart the moment the template stops
# rendering that constant — an interpolation edited into a hand-written literal, a block that stops
# being emitted, an escaping change that turns `"` into something `JSON.parse` refuses. Every one of
# those leaves the constant valid and the *document* wrong, which is the failure this whole ticket
# exists to close.
#
# So the example below GETs the guide as a signed-out visitor, pulls the JSON out of the response
# body by element id, parses it, and POSTs the result to the live ingest endpoint. What is verified
# is the published document, against the server, end to end.
#
# The corollary is worth stating for whoever edits the guide next: if you change what the page
# publishes about the wire format, this file is where you find out whether the server agrees. Where
# the two disagree, the guide is wrong — the server is not adjusted to match a document.
RSpec.describe "The public integration guide", type: :request do
  # So this file names the endpoint the same single way the three view surfaces do. Asserting on a
  # locally re-spelled `root_url.sub(...)` would keep passing if the helper's own stripping broke,
  # which is exactly the drift the helper was extracted to prevent.
  include IntegrationGuideHelper

  # The `<code>` payload inside the wrapper div the template stamps the shared id onto. Scoped to
  # the wrapper rather than matched on the whole page because the guide renders many copyable
  # blocks and only this one is the fixture.
  def published_payload
    id = IntegrationGuideHelper::EXAMPLE_PAYLOAD_ELEMENT_ID
    node = Capybara.string(response.body).find(:css, "##{id} code")

    JSON.parse(node.text)
  end

  describe "reachability" do
    # The audience includes an agent handed nothing but the URL, so a redirect to sign-in is not a
    # degraded experience here — it is the guide failing to exist for the reader it is written for.
    it "renders for a visitor with no session at all" do
      get integration_guide_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Integration guide")
    end

    # `PagesController#home` redirects a signed-in visitor to their repositories. This action
    # deliberately does not, or the URL in the repository page's prompt block would work for an
    # agent and bounce the person who copied it.
    it "renders for a signed-in visitor too" do
      sign_in_via_github

      get integration_guide_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Integration guide")
    end
  end

  describe "the published wire contract" do
    let(:repository) { create_repository }
    let(:api_key) { repository.api_keys.create! }

    before { get integration_guide_path }

    it "publishes a payload the ingest endpoint accepts" do
      post "/api/v1/ingest",
           params: published_payload.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:accepted), -> {
        "the guide publishes a payload the endpoint refuses: #{response.parsed_body["details"].inspect}"
      }
    end

    # Not merely accepted — accepted as the guide says it will be. The 202 body is documented on the
    # page as carrying the run's totals and an annotated ratio as a 0–1 fraction, and the fixture is
    # deliberately one annotated example and one unannotated one so those numbers are not both
    # trivially zero or one.
    it "produces the run the guide says it will" do
      post "/api/v1/ingest",
           params: published_payload.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response.parsed_body).to include("total_specs" => 2, "annotated_specs" => 1,
                                              "annotated_ratio" => 0.5)
    end

    # The guide endorses `specs: []` ("An empty array is accepted") and separately documents the
    # shape of the 202. Those two statements have to hold TOGETHER, and in the first version of this
    # page they did not: `annotated_ratio` was published as "a 0–1 fraction" with no null case, while
    # `TestRun#annotated_fraction` deliberately returns nil on a zero denominator — so a reporter
    # built strictly from the published contract broke on the very run the page called fine.
    #
    # Asserted with `fetch` rather than `include`, because the bug being guarded is a null where a
    # number was promised: `include("annotated_ratio" => nil)` would also pass against a body that
    # omitted the key entirely, and the contract says it is present.
    it "answers the empty-specs run the page says is accepted, in the shape the page documents" do
      post "/api/v1/ingest",
           params: published_payload.merge("specs" => []).to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.fetch("total_specs")).to eq(0)
      expect(response.parsed_body.fetch("annotated_ratio")).to be_nil
    end

    # The three fields `Ingest::Payload` never validates and `Ingest::ObservationRecorder`
    # nonetheless consumes. A guide that quietly dropped them from its worked example would still
    # pass every assertion above — the endpoint accepts a payload without them — and would have lost
    # the one thing a reader cannot discover by probing the API. So they are pinned on the payload,
    # and their effect is pinned on the stored row.
    it "carries the three fields the request validator never mentions, and they land" do
      spec = published_payload["specs"].first
      expect(spec).to include("id", "spec_file_path", "outcome")

      post "/api/v1/ingest",
           params: published_payload.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      observation = SpecObservation.find_by(example_id: spec["id"])
      expect(observation).to be_present
      expect(observation.spec_file_path).to eq(spec["spec_file_path"])
      expect(observation.outcome).to eq(spec["outcome"])
    end

    # The guide's language-agnostic claim, made as an assertion rather than as a sentence: the
    # worked example is a Python suite, and it is accepted. An example whose paths all ended in
    # `_spec.rb` would teach the opposite of what the page says, and nothing would notice.
    it "works the claim that nothing in the path is Ruby-specific" do
      expect(published_payload["specs"].map { |spec| spec["file_path"] })
        .to all(end_with(".py"))
    end
  end

  describe "what the page must not stop saying" do
    before { get integration_guide_path }

    # The whole point of the document. The read endpoint is a connectivity check; the write endpoint
    # is the integration, and it is what was missing from every surface the product shipped before
    # this page existed.
    it "names the write endpoint" do
      expect(response.body).to include("#{integration_guide_endpoint}/api/v1/ingest")
    end

    it "covers the Ruby client, the linter, the annotation protocol and the MCP bridge" do
      text = Capybara.string(response.body).text.gsub(/\s+/, " ")

      expect(text).to include("specguard-rspec")
      expect(text).to include("SpecGuard::RSpecFormatter")
      expect(text).to include("specguard-lint")
      expect(text).to include("specguard-mcp")
      expect(text).to include("SPECGUARD_ENDPOINT")
      expect(text).to include("SPECGUARD_API_KEY")
    end

    # A companion to the response-shape example above, and the reason both exist. That one pins what
    # the SERVER does; this one pins that the PAGE still says so. Either alone permits the drift this
    # ticket's review caught — the server answering null while the document promises a fraction — and
    # only the pair closes it.
    it "tells the reader that annotated_ratio can be null" do
      text = Capybara.string(response.body).text.gsub(/\s+/, " ")

      expect(text).to match(/annotated_ratio.{0,120}null/m),
                      "the guide documents annotated_ratio without its null case"
    end

    # The mirror at `/schemas/open-test-intent.v1.json` exists for exactly one reader — the one on
    # SpecGuard's own documentation who wants the contract as a file rather than as HTML — and it
    # shipped with no page linking it, so the only way to reach it was to already know the URL. The
    # assertion is on the ANCHOR's href, not on the text: a sentence naming the path would read the
    # same to a human and still leave a non-Ruby adopter scraping JSON out of rendered markup.
    it "offers the schema as a downloadable document, not only as reproduced HTML" do
      page = Capybara.string(response.body)

      expect(page).to have_css("a[href='#{open_test_intent_schema_path}']"),
                      "the guide no longer links the schema mirror at " \
                      "#{open_test_intent_schema_path}; a reader wanting the machine-readable " \
                      "contract is back to scraping it out of this HTML"

      anchor_text = page.first("a[href='#{open_test_intent_schema_path}']").text.strip

      expect(anchor_text).not_to be_empty,
                                "the schema link renders with no text for a reader to click"
    end

    # Every field of the envelope and of a spec entry, so a reader never has to open server source.
    # Asserted as a set because the failure this guards against is a field going missing during an
    # edit, which no single-field assertion would catch.
    it "documents every field the endpoint reads" do
      text = Capybara.string(response.body).text

      %w[commit_sha branch ci_run_id shard_id duration_seconds specs
         file_path line_number status intent name duration id spec_file_path outcome
         entity action behavior layer preconditions].each do |field|
        expect(text).to include(field), "the guide no longer documents `#{field}`"
      end
    end
  end
end
