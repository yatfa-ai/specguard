# frozen_string_literal: true

require "rails_helper"

# `declared_intent` on the three per-example blocks of `GET /api/v1/repository` — `slowest_examples`,
# `spec_file_examples` and `repeated_description_examples` (SPGD-1665). The API twin of what
# `_authored_intent.html.erb` prints in the three browser panels (SPGD-1657): the `@intent` the
# AUTHOR declared for an annotated example, as `{ entity, action, behavior }`, or `null`.
#
# ⭐ DECLARED ONLY. The field is reserved for the author's word. An unannotated row whose name WOULD
# derive an intent (a `Class#method behavior` shape) still serves `null` here — its guess lives on
# `unannotated_examples#derived_intent`, a different key on a different block. The negative example
# is written first for that reason.
#
# Its own file because every example needs one fixture holding annotated, unannotated-but-derivable,
# partially annotated and empty-string rows in ONE file under ONE repeated description, so all three
# blocks can be asked for at once and read off a single response. Rows are written by
# `Ingest::RunRecorder`, as every sibling does, never inserted by hand.
RSpec.describe "GET /api/v1/repository — declared_intent on the per-example blocks", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(query: {})
    get "/api/v1/repository", params: query,
                              headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def ingest(repo, specs)
    Ingest::RunRecorder.record(
      repo,
      { commit_sha: "feedfacecafe0001", branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  def order_spec = "spec/models/order_spec.rb"

  # A real `Class#method behavior` description: `DerivedIntent` reads an entity, an action and a
  # behavior out of it, so an UNANNOTATED row carrying it is the one a serializer that fell back to
  # `derived_intent` would visibly serve a guess for.
  def derivable = "Invoice#finalize locks the line items once the invoice is finalized"

  def ask = { spec_file: order_spec, repeated_description: derivable }

  let!(:test_run) do
    ingest(repository,
           [
             # 1. ANNOTATED, all three parts, and it shares `derivable` with row 2 so the repeated
             #    description group holds declared and undeclared members.
             annotated_spec(file_path: order_spec, line_number: 4, duration: 9.0, name: derivable,
                            entity: "Invoice", action: "finalize",
                            behavior: "locks the line items once the invoice is finalized"),
             # 2. UNANNOTATED with a derivable name — the negative.
             unannotated_spec(file_path: order_spec, line_number: 12, duration: 8.0, name: derivable),
             # 3. ANNOTATED with only a behavior: parts are independent. (Rows 3 and 4 carry the same
             #    description as 1 and 2 — a name is not an intent — so all three blocks list them.)
             annotated_spec(file_path: order_spec, line_number: 20, duration: 7.0,
                            name: derivable, entity: nil, action: nil,
                            behavior: "refunding twice leaves the balance unchanged"),
             # 4. ANNOTATED, then its three columns blanked to "" below.
             annotated_spec(file_path: order_spec, line_number: 30, duration: 6.0,
                            name: derivable),
             # 5. UNANNOTATED, underivable name.
             unannotated_spec(file_path: order_spec, line_number: 40, duration: 5.0,
                              name: "something unreadable")
           ])
  end

  before do
    SpecObservation.where(line_number: 30).update_all(intent_entity: "", intent_action: "",
                                                      intent_behavior: "")
  end

  def row_for(block, line_number)
    block["rows"].find { it["line_number"] == line_number }
  end

  let(:latest_run) { get_repository(query: ask)["latest_run"] }
  let(:blocks) do
    %w[slowest_examples spec_file_examples repeated_description_examples].index_with { latest_run[it] }
  end

  describe "an unannotated row" do
    # @intent: { entity: "declared_intent", action: "withhold guesses", behavior: "an unannotated row serves null declared_intent and never its derived reading, even when its name would derive one", layer: "request" }
    it "serves null declared_intent and no derived guess, even for a derivable name" do
      unannotated = SpecObservation.find_by!(line_number: 12)
      expect(unannotated.derived_intent).not_to be_nil # the premise: a guess exists to leak

      blocks.each_value do |block|
        row = row_for(block, 12)
        expect(row).to have_key("declared_intent")
        expect(row["declared_intent"]).to be_nil
      end
      expect(row_for(blocks["slowest_examples"], 40)["declared_intent"]).to be_nil
    end
  end

  describe "an annotated row" do
    # @intent: { entity: "declared_intent", action: "serve the declaration", behavior: "an annotated row serves its entity, action and behavior as the author declared them", layer: "request" }
    it "serves all three declared parts on every block" do
      blocks.each_value do |block|
        expect(row_for(block, 4)["declared_intent"]).to eq(
          "entity" => "Invoice", "action" => "finalize",
          "behavior" => "locks the line items once the invoice is finalized"
        )
      end
    end

    # @intent: { entity: "declared_intent", action: "keep parts independent", behavior: "a row declaring only a behavior serves nil entity and action inside a non-nil object", layer: "request" }
    it "serves nil parts inside a non-nil object when only a behavior was declared" do
      blocks.each_value do |block|
        expect(row_for(block, 20)["declared_intent"]).to eq(
          "entity" => nil, "action" => nil,
          "behavior" => "refunding twice leaves the balance unchanged"
        )
      end
    end

    # @intent: { entity: "declared_intent", action: "never serve empty strings", behavior: "empty-string intent columns serve a nil declared_intent rather than blank values", layer: "request" }
    it "serves nil, never empty strings, when the stored columns are blank" do
      expect(SpecObservation.find_by!(line_number: 30).intent_entity).to eq("")

      blocks.each_value { |block| expect(row_for(block, 30)["declared_intent"]).to be_nil }
    end
  end

  describe "across the three blocks" do
    # @intent: { entity: "declared_intent", action: "agree across blocks", behavior: "all three per-example blocks serve identical row key sets including declared_intent", layer: "request" }
    it "serves identical row key sets, declared_intent included" do
      key_sets = blocks.values.map { |block| block["rows"].flat_map(&:keys).uniq.sort }

      expect(key_sets.uniq.length).to eq(1)
      expect(key_sets.first).to include("declared_intent")
      blocks.each_value do |block|
        expect(block["rows"]).to all(satisfy { it.keys.sort == key_sets.first })
      end
    end

    # @intent: { entity: "declared_intent", action: "mirror stored columns", behavior: "declared_intent equals the stored intent columns element-wise for the rows the panels render", layer: "request" }
    it "equals the stored columns for the same rows the panels render" do
      run = repository.latest_test_run
      sources = {
        "slowest_examples" => SlowestExamples.for(run).rows,
        "spec_file_examples" => SpecFileExamples.for(run, order_spec).rows,
        "repeated_description_examples" => RepeatedDescriptionExamples.for(run, derivable).rows
      }

      sources.each do |name, rows|
        expected = rows.map do |observation|
          parts = { "entity" => observation.intent_entity.presence,
                    "action" => observation.intent_action.presence,
                    "behavior" => observation.intent_behavior.presence }
          parts.values.any? ? parts : nil
        end

        expect(blocks[name]["rows"].map { it["declared_intent"] }).to eq(expected)
      end
    end
  end

  describe "unannotated_examples" do
    # @intent: { entity: "declared_intent", action: "leave unannotated_examples alone", behavior: "unannotated_examples rows keep reading and derived_intent and gain no declared_intent", layer: "request" }
    it "keeps its own row shape and gains no declared_intent" do
      rows = get_repository(query: { unannotated_examples: "true" })
             .dig("latest_run", "unannotated_examples", "rows")

      expect(rows).not_to be_empty
      rows.each do |row|
        expect(row.keys).to contain_exactly("name", "file_path", "line_number", "spec_file_path",
                                            "reading", "derived_intent")
      end
    end
  end
end
