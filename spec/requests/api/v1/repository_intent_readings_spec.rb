# frozen_string_literal: true

require "rails_helper"

# The `latest_run.intent_readings` block on `GET /api/v1/repository` — how much of a run SpecGuard
# can actually READ, which until SPGD-711 no surface answered and every surface claimed to.
#
# == The claim this key exists to replace
#
# The endpoint served `total_specs`, `annotated_specs` and `annotated_ratio`; the dashboard rendered
# the subtraction as "Not visible to SpecGuard" and the MCP bridge told an agent, in those words,
# that it was the count of the tests SpecGuard CANNOT SEE. The subtraction is exact and the sentence
# was false. A test called `Invoice#finalize locks the line items` has an entity, an action and a
# behavior in the description this platform already receives, already stores and already ranks three
# other panels by — so on a suite that has never been annotated, the "invisible" figure is the whole
# suite and almost all of it is readable.
#
# So the three states are served, unconditionally, and this file pins what each of them means.
#
# == Its own file, and the fixtures are the argument
#
# Every example here needs a run whose descriptions have a KNOWN mix of derivable and underivable
# shapes — which no other spec on this endpoint wants, since to every one of them a description is a
# string to echo. `repository_unannotated_examples_spec.rb` needs a mixed ANNOTATION status for the
# same structural reason and states the precedent.
#
# The payload goes through `Ingest::Payload` rather than being hand-written, on that file's rule and
# for a sharper reason here: `annotated_specs_count` is DERIVED from the same `status` strings the
# rows are written from, and the load-bearing claim of this whole change is that NOTHING here can
# move that counter. A fixture that assigned it by hand could not assert that.
RSpec.describe "GET /api/v1/repository — latest_run.intent_readings", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def latest_run(**) = get_repository(**)["latest_run"]

  def readings(**) = get_repository(**).dig("latest_run", "intent_readings")

  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }.merge(attrs.deep_stringify_keys)
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
  end

  def separate_repository(full_name)
    uid = (@separate_uid = (@separate_uid || 2001) + 1).to_s

    create_repository(user: create_user(github_uid: uid, github_handle: "octo-#{uid}"),
                      github_full_name: full_name)
  end

  # ONE annotated example, TWO whose descriptions derive, ONE whose description does not — four
  # rows, four distinct figures, so no two keys of this block can be confused for each other and
  # none of them is `total_specs`.
  let!(:test_run) do
    ingest(repository,
           [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4,
                           name: "Invoice#finalize locks the line items once finalized"),
            unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 9,
                             name: "Order#settle clears the outstanding balance"),
            unannotated_spec(file_path: "spec/services/pricing_spec.rb", line_number: 12,
                             name: "Pricing::Tier#apply rounds to the currency unit"),
            # An entity and a behavior with no action between them — the ordinary shape that does not
            # derive, and the ONLY row on this run any "cannot see" language may describe.
            unannotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 3,
                             name: "Checkout rejects an expired card")])
  end

  describe "a run whose descriptions mostly derive" do
    # AC. The four figures, on a fixture where every one of them differs from every other.
    # @intent: { entity: "intent_readings", action: "split the run three ways", behavior: "one authored, two derived and one unreadable example are counted separately with the recorded population served beside them, four rows yielding four distinct figures", layer: "request" }
    it "splits the run three ways and carries the population they were counted from" do
      expect(readings).to eq("authored" => 1, "derived" => 2, "unreadable" => 1, "recorded" => 4)
    end

    # The key set as this block's stated subject, on the pattern every contract example on this
    # endpoint follows: a guard whose subject IS the key set survives a fixture whose numbers change,
    # and says out loud what a new key owes this block before it ships.
    # @intent: { entity: "intent_readings", action: "pin the key set", behavior: "the block carries authored, derived, unreadable and recorded and nothing else - no ratio and no coverage label rides beside them", layer: "request" }
    it "serves exactly the intent_readings keys this contract pins" do
      served = readings

      expect(served.keys).to contain_exactly("authored", "derived", "unreadable", "recorded")
      # Operands and never a fraction — the rule every rollup on this endpoint is served under. A
      # `readable_ratio` here would be the second coverage percentage on one block, and a client
      # reading it beside `annotated_ratio` would have two adoption metrics and no way to choose.
      expect(served).not_to have_key("readable_ratio")
      expect(served).not_to have_key("coverage_label")
    end

    # The three states PARTITION the population — no row counted twice, no row uncounted. This is
    # what makes them safe to render side by side, and it is a property of the SQL `CASE` rather than
    # of the fixture: a `WHEN` that overlapped, or an `ELSE` that dropped a row, breaks it.
    # @intent: { entity: "intent_readings", action: "partition the population", behavior: "the three states partition the recorded rows so their counts sum to recorded, with no row counted twice and none left out", layer: "request" }
    it "splits the recorded population exactly, with nothing counted twice and nothing left out" do
      served = readings

      expect(served["authored"] + served["derived"] + served["unreadable"]).to eq(served["recorded"])
    end

    # ⭐ THE KEY IS UNGATED, unlike every drill-in on this endpoint. A correction a client has to opt
    # into leaves that client reading the subtraction, which is the state this change exists to end.
    # @intent: { entity: "intent_readings", action: "serve unconditionally", behavior: "the block is ungated - present on a plain request and identical whether or not the unannotated_examples parameter is sent", layer: "request" }
    it "is served on every request, with no flag to pass" do
      expect(get_repository["latest_run"]).to have_key("intent_readings")
      expect(readings).not_to be_nil
      # And it does not turn on the ask that opens the two unannotated blocks, which is the parameter
      # an agent would most plausibly assume it rides.
      expect(readings(query: { unannotated_examples: "true" })).to eq(readings)
    end
  end

  # ⭐⭐ THE ASSERTION THE WHOLE CHANGE STANDS OR FALLS ON.
  #
  # "How much of this suite has a human-written intent" must answer exactly as it did before, off the
  # run's own counters, or the product's adoption metric has been quietly redefined. `authored` is
  # the same predicate over a possibly different population and is NOT that figure — it is here so
  # the three states sum to `recorded`.
  describe "what the correction did NOT change" do
    # @intent: { entity: "annotated_specs", action: "preserve the adoption metric", behavior: "the adoption figures still answer from the run counters - total four, annotated one, ratio a quarter - derived from the payload statuses rather than the new readings", layer: "request" }
    it "leaves annotated_specs and annotated_ratio reading the run's own counters" do
      run = latest_run

      expect(run["total_specs"]).to eq(4)
      expect(run["annotated_specs"]).to eq(1)
      expect(run["annotated_ratio"]).to eq(0.25)
      # Derived from the payload's own statuses, so this is the derivation and not a number the
      # fixture typed.
      expect(test_run.reload.annotated_specs_count).to eq(1)
    end

    # THE COUNTERS AND THE ROWS ARE DIFFERENT POPULATIONS, which is why `recorded` rides back with
    # the three states instead of a client dividing by `total_specs`. A run reporting totals for more
    # examples than it sent detail for is the ordinary shape of a client mid-integration.
    # @intent: { entity: "intent_readings", action: "count detail rows", behavior: "recorded counts per-example detail rows only, so a run reporting four thousand totals over one sent row still reads derived one and recorded one", layer: "request" }
    it "counts the rows it has rather than the suite size the run reported" do
      partial = separate_repository("acme/totals-exceed-rows")
      ingest(partial,
             [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 9,
                               name: "Order#settle clears the outstanding balance")],
             total_specs_count: 4_000)
      key = partial.api_keys.create!

      expect(readings(key: key)).to eq("authored" => 0, "derived" => 1, "unreadable" => 0,
                                       "recorded" => 1)
      expect(latest_run(key: key)["total_specs"]).to eq(1)
    end
  end

  # ⭐ THE FAILURE MODE THE TICKET NAMES BY NAME: a scanner that falls over classifies a whole run
  # unannotated and the dashboard reads 0%. Those rows still carry perfectly readable descriptions,
  # so this block reports them as DERIVED — and a derived reading must never be able to make that run
  # look like a healthy suite.
  #
  # It cannot, and the reason is structural rather than a matter of wording: nothing in this change
  # touches `annotated_specs_count`, which is derived at ingest from the `status` the client sent. So
  # the scanner-failure run and a legitimately all-derived run are told apart by the same figure that
  # told them apart before — and both are reported honestly, which is the point.
  describe "a run whose scanner failed and sent everything as unannotated" do
    # @intent: { entity: "intent_readings", action: "report a scanner failure", behavior: "a scanner failure that sends every example unannotated reads derived two and recorded two while annotated_specs stays zero and the ratio stays zero percent", layer: "request" }
    it "reads as fully derived and still reads as zero percent annotated" do
      broken = separate_repository("acme/scanner-fell-over")
      ingest(broken,
             [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 9,
                               name: "Order#settle clears the outstanding balance"),
              unannotated_spec(file_path: "spec/models/refund_spec.rb", line_number: 3,
                               name: "Refund#issue returns the money to the payer")])
      key = broken.api_keys.create!

      expect(readings(key: key)).to eq("authored" => 0, "derived" => 2, "unreadable" => 0,
                                       "recorded" => 2)
      expect(latest_run(key: key)["annotated_ratio"]).to eq(0.0)
      expect(latest_run(key: key)["annotated_specs"]).to eq(0)
    end
  end

  # A run that stored no per-example rows — ingested before those rows existed, or from a client
  # sending only totals. Three zeros AND `recorded: 0`, which is the pair that separates "nobody sent
  # the detail" from "nothing is readable". Three zeros alone cannot, and the block is deliberately
  # NOT `null` here: a null would say "you did not ask", and there is nothing to ask.
  describe "a run that recorded no per-example rows" do
    # @intent: { entity: "intent_readings", action: "answer four zeros", behavior: "a run with totals but no detail rows serves four zero figures rather than null, so nobody-sent-detail stays distinguishable from nothing-is-readable", layer: "request" }
    it "answers with four zeros rather than a null, so the absence is readable as one" do
      bare = separate_repository("acme/totals-only")
      create_test_run(repository: bare, commit_sha: "norows711001", total_specs_count: 900,
                      annotated_specs_count: 300)
      key = bare.api_keys.create!

      expect(readings(key: key)).to eq("authored" => 0, "derived" => 0, "unreadable" => 0,
                                       "recorded" => 0)
      # And the counters still answer, which is what makes the pair readable: 300 of 900 annotated,
      # and nothing said about how much of the rest can be read.
      expect(latest_run(key: key)["annotated_specs"]).to eq(300)
    end
  end

  # A repository whose CI has never reported has no run to describe, and the whole `latest_run` block
  # is null — this key does not survive it as four zeros, which would be a measurement invented out
  # of a repository's silence.
  describe "a repository with no run at all" do
    # @intent: { entity: "intent_readings", action: "omit without a run", behavior: "a repository with no ingested run nulls the whole latest_run block, and the readings do not survive as invented zeros", layer: "request" }
    it "has no block, because it has no run" do
      fresh = separate_repository("acme/never-ingested")

      expect(latest_run(key: fresh.api_keys.create!)).to be_nil
    end
  end
end
