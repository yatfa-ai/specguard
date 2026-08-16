# frozen_string_literal: true

require "rails_helper"

# The `latest_run.unannotated_examples` block on `GET /api/v1/repository` — the rows behind the
# product's stated primary adoption metric, and the one figure on either surface that could be
# reported and not opened.
#
# THE RUNG `annotated_ratio` NEVER HAD. `repositories#show` renders "Not visible to SpecGuard" over
# `total_specs - annotated_specs` and prints *"SpecGuard cannot see the other N tests"*; this endpoint
# served `total_specs`, `annotated_specs` and `annotated_ratio` and could not name ONE of the tests
# those three are about. Every other ranking here has a drill-down — `?spec_directory=` → files,
# `?spec_file=` → examples, `?repeated_description=` → examples, `?unstable_test=` → runs — and
# annotation coverage was the sole exception, which is what the fixture below is built to make
# visible: the run it ingests carries a KNOWN annotated/unannotated mix, so the block's own
# `recorded_count` can be reconciled against the block's own two counters in the same response body.
#
# Its own file, beside `repository_spec_file_examples_spec.rb` and on the precedent that file and
# `repository_unstable_tests_spec.rb` both state: every example here needs a fixture with a MIXED
# annotation status — which no other spec on this endpoint wants, since `annotated_specs_count` is a
# single integer to every one of them — and needs it under a query parameter no other block reads,
# while every block in `repository_latest_run_spec.rb` is a fact about one run served on every request.
#
# THE ROWS AND THE COUNTERS BOTH COME OFF `Ingest::Payload`, never hand-written — the rule every
# sibling here states about the rows, with one extra edge that makes it load-bearing rather than
# tidy on this file. `annotated_specs_count` is DERIVED by `Payload#test_run_attributes` from the same
# `status` strings `Ingest::ObservationRecorder` writes onto the rows, so a fixture that had passed
# the counters in by hand — as the siblings do, which costs them nothing — could make the headline and
# the list agree, or disagree, by assignment. It would then be pinning a number this file typed rather
# than the derivation AC2 is about. So the helper below builds the real payload, refuses to proceed if
# it would not have been accepted, and hands `RunRecorder` what the ingest controller hands it.
RSpec.describe "GET /api/v1/repository — latest_run.unannotated_examples", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  # `query:` rather than a keyword, so an example can send the shapes a real client's malformed query
  # string parses into — an Array, a nested hash — the same way it sends the flag.
  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def latest_run(**) = get_repository(**)["latest_run"]

  def block(**) = get_repository(**).dig("latest_run", "unannotated_examples")

  # The ask, spelled the way the endpoint documents it. Every example that opens the block goes
  # through this rather than restating the string, so the parameter's NAME has one owner here.
  #
  # A `let` rather than a constant, like the three paths further down, and deliberately: a constant
  # assigned inside an `RSpec.describe` block is assigned on `Object` rather than on the example
  # group, so a `TARGET_FILE` here and the one in `repository_spec_file_examples_spec.rb` would be
  # one constant reassigned — a warning today, and one file silently reading the other's path the
  # day the two want different ones.
  let(:ask) { { unannotated_examples: "true" } }

  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }.merge(attrs.deep_stringify_keys)
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
  end

  # A second repository under its own owner, for the examples that need a run this file's `let!` did
  # not write. `github_uid` is unique on `User`, so each one gets its own.
  def separate_repository(full_name)
    uid = (@separate_uid = (@separate_uid || 1001) + 1).to_s

    create_repository(user: create_user(github_uid: uid, github_handle: "octo-#{uid}"),
                      github_full_name: full_name)
  end

  # Two ANNOTATED examples and three UNANNOTATED ones, and every disagreement in the five is
  # load-bearing:
  #
  #   - The mix is 2/5, so `recorded_count` (3) is not `total_specs` (5), is not `annotated_specs`
  #     (2), and is not the length of any other list on the response. A block serving any of those
  #     under this name is red.
  #   - The three unannotated rows are spread over TWO files with the second file's two rows out of
  #     line order in the delivery, so the ordering assertion is about the read rather than about
  #     insertion order.
  #   - One unannotated row is a SHARED EXAMPLE GROUP: its `file_path` is the group's file and its
  #     `spec_file_path` is the file that ran it. It is the row that fails a serializer serving one
  #     path under both names — and here that failure would send a reader to a `spec/support/` helper
  #     to annotate a test that is not in it.
  #   - One unannotated row is UNTIMED and `pending`, which is the shape this population is
  #     disproportionately made of (a test that never ran is one way an example goes unannotated) and
  #     the reason the ordering is file-navigable rather than by duration. It sorts by its PATH like
  #     every other row rather than to the end of the list.
  let(:annotated_file) { "spec/models/invoice_spec.rb" }
  let(:target_file) { "spec/models/order_spec.rb" }
  let(:other_file) { "spec/services/pricing_spec.rb" }

  let!(:test_run) do
    ingest(repository,
           [annotated_spec(file_path: annotated_file, line_number: 4,
                           name: "Invoice finalize locks the line items"),
            annotated_spec(file_path: annotated_file, line_number: 30, entity: "Invoice",
                           name: "Invoice finalize stamps the finalized_at"),
            # Deliberately delivered line 40 BEFORE line 9, so the ordering below is the read's.
            unannotated_spec(file_path: other_file, line_number: 40, duration: nil,
                             outcome: "pending", name: "Pricing applies the volume tier"),
            unannotated_spec(file_path: other_file, line_number: 9, duration: 0.8,
                             outcome: "passed", name: "Pricing rounds to the currency unit"),
            # The shared example group: DEFINED in `billable.rb`, RUN by `order_spec.rb`.
            unannotated_spec(file_path: "spec/support/shared_examples/billable.rb",
                             spec_file_path: target_file, line_number: 7, duration: 0.5,
                             outcome: "passed", name: "behaves like a billable charges once")])
  end

  describe "a run whose annotation coverage was asked about" do
    # AC1. The block exists, and every row carries enough to OPEN THE FILE — which is the whole
    # difference between this and the subtraction it replaces. The array is asserted as a SEQUENCE
    # (`eq`, not `match_array`) because a stable, file-navigable order is half of what this key
    # promises: the cap fires as the normal case on this population, so a reader annotating the first
    # hundred and asking again must not be handed a re-shuffled hundred.
    it "lists the run's unannotated examples in file order, with enough to open each one" do
      expect(block(query: ask)).to eq(
        "rows" => [
          { "name" => "behaves like a billable charges once",
            "file_path" => "spec/support/shared_examples/billable.rb",
            "line_number" => 7, "spec_file_path" => target_file },
          { "name" => "Pricing rounds to the currency unit", "file_path" => other_file,
            "line_number" => 9, "spec_file_path" => other_file },
          { "name" => "Pricing applies the volume tier", "file_path" => other_file,
            "line_number" => 40, "spec_file_path" => other_file }
        ],
        "recorded_count" => 3,
        "limit" => SpecObservation::UNANNOTATED_EXAMPLES_LIMIT
      )
    end

    # The sub-block's own key set, stated as its subject rather than pinned as a side effect of the
    # `eq` above — the pattern every sibling drill-in's contract example sets, and for the same
    # reason: a guard whose stated subject IS the key set survives a fixture whose numbers change,
    # and says out loud what a new key owes this block before it ships.
    #
    # AC7 IS THE SECOND HALF OF THIS EXAMPLE. The three per-example blocks on this endpoint agree on
    # SIX fields and this one serves FOUR, which is a difference asserted rather than structural —
    # exactly as their agreement is. Their own `contain_exactly`s go red if one of theirs is dropped
    # to match this; this one goes red if `duration_seconds` or `outcome` is added here to match them.
    # Both directions are pinned, in the two places that own them.
    it "serves exactly the unannotated_examples keys this contract pins, and not the six-field shape" do
      served = block(query: ask)

      expect(served.keys).to contain_exactly("rows", "recorded_count", "limit")
      expect(served["rows"].first.keys)
        .to contain_exactly("name", "file_path", "line_number", "spec_file_path")
      # Not the six-field per-example shape, and specifically not by accident: the endpoint's other
      # per-example block is on the same response and DOES carry both.
      expect(served["rows"].first).not_to have_key("duration_seconds")
      expect(served["rows"].first).not_to have_key("outcome")
      expect(latest_run(query: ask).dig("slowest_examples", "rows").first)
        .to include("duration_seconds", "outcome")
    end

    # ⭐ AC2. THE ASSERTION THIS WHOLE FILE EXISTS FOR. Every figure is taken off the SAME RESPONSE
    # BODY, so this is the endpoint reconciling with itself: `recorded_count` is a `WHERE status =
    # 'unannotated'` over the run's rows, and `total_specs - annotated_specs` is
    # `Ingest::Payload#annotated_specs` rejecting that same string on the way in. One derivation
    # evaluated twice, not two figures that agree today — which is the property that made this rung
    # possible with no migration and no new column.
    #
    # A serializer that counted the PAGE instead of the population would still pass here (3 rows, 3
    # counted); the truncation example below is what separates those two, and it is why both exist.
    it "reconciles its count with the run's own annotation counters, off one response" do
      run = latest_run(query: ask)

      expect(run["total_specs"]).to eq(5)
      expect(run["annotated_specs"]).to eq(2)
      expect(run.dig("unannotated_examples", "recorded_count"))
        .to eq(run["total_specs"] - run["annotated_specs"])
      # And the ratio the dashboard renders is about this same population, which is what makes the
      # reconciliation worth serving rather than merely true.
      expect(run["annotated_ratio"]).to eq(0.4)
    end

    # The other half of AC2, and the example a page-counting serializer dies on: `recorded_count` is a
    # window evaluated after the WHERE and before the LIMIT, so it describes the RUN's unannotated
    # population however few rows come back. This population is routinely the whole run — a repository
    # that has just installed the gem has `recorded_count == total_specs` on day one — so truncation
    # is the normal case here rather than the exotic one.
    it "counts the run's whole unannotated population, not the page the cap left" do
      big = separate_repository("acme/just-installed")
      over = SpecObservation::UNANNOTATED_EXAMPLES_LIMIT + 25
      ingest(big, Array.new(over) do |index|
        unannotated_spec(file_path: "spec/models/thing_#{format('%03d', index)}_spec.rb",
                         line_number: index + 1, duration: 0.1, outcome: "passed",
                         name: "Thing #{index} does its job")
      end)
      key = big.api_keys.create!
      served = block(key: key, query: ask)

      expect(served["rows"].length).to eq(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      expect(served["recorded_count"]).to eq(over)
      # The block ships the two numbers a "showing 100 of N" sentence is drawn from, never the
      # comparison between them.
      expect(served["recorded_count"]).to be > served["rows"].length
      # And on the repository this block exists for, the count IS the suite: nothing is annotated yet.
      expect(latest_run(key: key, query: ask)["total_specs"]).to eq(over)
    end

    # The annotated rows are not in the list, asserted against the response's own names rather than
    # against a count — a block that returned every row of the run would satisfy `recorded_count` if
    # the count were folded from the rows, and would fail here.
    it "lists no example that carries an annotation" do
      names = block(query: ask)["rows"].map { it["name"] }

      expect(names).not_to include("Invoice finalize locks the line items")
      expect(names).not_to include("Invoice finalize stamps the finalized_at")
      # And the annotated file's examples ARE on this run, which the endpoint's own per-file rollup
      # says — so their absence above is a predicate doing work rather than a fixture that is empty.
      expect(latest_run(query: ask).dig("spec_files", "rows").map { it["path"] })
        .to include(annotated_file)
    end

    # The row that separates "the file an example is IN" from "the file that RAN it". A serializer
    # serving one path under both names satisfies every count in this file and fails here — and on
    # THIS block the consequence is concrete: a reader sent to `spec/support/shared_examples/billable.rb`
    # to annotate a test would find the group, not the example that ran it.
    it "names the definition site and the including file apart, for a shared example group" do
      shared = block(query: ask)["rows"].find { it["line_number"] == 7 }

      expect(shared["file_path"]).to eq("spec/support/shared_examples/billable.rb")
      expect(shared["spec_file_path"]).to eq(target_file)
      expect(shared["file_path"]).not_to eq(shared["spec_file_path"])
    end

    # The block's standing rule, asserted over the whole serialized sub-block rather than per key:
    # `SpecObservation#duration_label` and `#outcome_label` are each one call away in the rows this
    # reads, and `recorded_count > rows.length` is one comparison away in the object it reads from.
    # This endpoint ships the operands and lets a client word it.
    it "serves numbers and words, never the panel's labels or its comparisons" do
      served = block(query: ask)

      expect(served.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(served).not_to have_key("truncated")
      expect(served["rows"].map { it["line_number"] }).to all(be_a(Integer))
      expect(served["recorded_count"]).to be_a(Integer)
    end

    # An untimed, never-run example is disproportionately what this population is made of, and it is
    # ordered by its PATH like every other row rather than shuffled to the end. That is the axis
    # decision `SpecObservation.unannotated_in` argues: the sibling drill-ins rank by duration because
    # a reader came to measure, and nobody arrives here for that.
    it "orders an untimed example by where it lives rather than by what it cost" do
      rows = block(query: ask)["rows"]

      expect(rows.map { it["name"] }.last).to eq("Pricing applies the volume tier")
      expect(rows.map { [it["spec_file_path"], it["line_number"]] })
        .to eq(rows.map { [it["spec_file_path"], it["line_number"]] }.sort)
    end

    # The same run asked twice returns the same page — which the cap makes load-bearing rather than
    # tidy: a reader who annotates the first hundred and asks again must be walking a list, not
    # re-rolling one. `spec_file_path`, `line_number` and `id` are each total where the pair before it
    # ties, so no tie is left for the planner to break afresh per request.
    it "returns the same page twice for the same run" do
      expect(block(query: ask)).to eq(block(query: ask))
    end
  end

  # AC3. The distinction this key must not collapse — and the sharpest instance of it on the block,
  # because the empty answer here is not a stale bookmark or a deleted file but the STATE THE METRIC
  # EXISTS TO REACH.
  describe "the two ways this key can be empty" do
    it "is null — with the key present — when the block was not asked for" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to have_key("unannotated_examples")
      expect(body.dig("latest_run", "unannotated_examples")).to be_nil
      # The rest of `latest_run` is untouched by the absence: this key is added BESIDE the blocks
      # that were there before it, never in place of any of them.
      expect(body.dig("latest_run", "spec_files", "rows")).to be_present
      expect(body.dig("latest_run", "annotated_specs")).to eq(2)
    end

    # AC3, the half that matters. A fully-annotated run gets the BLOCK — 200, `rows: []`,
    # `recorded_count: 0` — never a `null` and never a 404. Collapsing it into the no-ask spelling
    # would answer the best possible outcome with the one word reserved for "you did not ask", and a
    # client walking a repository to completion would watch the block vanish at the moment it
    # succeeded and be unable to tell that from its own parameter having been dropped.
    it "is a present block with no rows when the run is fully annotated" do
      done = separate_repository("acme/fully-annotated")
      ingest(done, [annotated_spec(file_path: annotated_file, line_number: 4),
                    annotated_spec(file_path: annotated_file, line_number: 30, entity: "Invoice")])
      key = done.api_keys.create!

      expect(block(key: key, query: ask))
        .to eq("rows" => [], "recorded_count" => 0,
               "limit" => SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      expect(response).to have_http_status(:ok)
      # And the run really is fully annotated, so the zero is the success state rather than an empty
      # fixture — the reconciliation of AC2 read from the other end.
      expect(latest_run(key: key, query: ask)["annotated_ratio"]).to eq(1.0)
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent.
    it "spells the two differently, so a client can tell which one it got" do
      done = separate_repository("acme/nothing-left")
      ingest(done, [annotated_spec(file_path: annotated_file, line_number: 4)])
      key = done.api_keys.create!

      expect(block(key: key)).to be_nil
      expect(block(key: key, query: ask)).not_to be_nil
      expect(block(key: key, query: ask)["recorded_count"]).to eq(0)
    end

    # There is no `latest_run` at all for a repository whose CI has never reported, so the ask cannot
    # conjure one — the rule the whole block follows, restated here because this is one of the keys on
    # it a client can ask for by name.
    it "serves no block at all when CI has never reported" do
      silent = separate_repository("acme/never-ran")

      body = get_repository(key: silent.api_keys.create!, query: ask)

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC4. `?commit_sha=` is the one parameter that RE-ANCHORS, and this drill-in moves with it without
  # reading it: both hang off the one `latest_test_run` memo. That matters more here than on the
  # siblings — "what is still unannotated" is the question an adopting repository asks after every
  # push, so asking it of an older commit is the ordinary use rather than the exotic one, and a block
  # that stayed on the newest run would report yesterday's progress as today's.
  describe "the run this block describes" do
    let!(:newer_run) do
      ingest(repository,
             [annotated_spec(file_path: annotated_file, line_number: 4),
              unannotated_spec(file_path: "spec/models/refund_spec.rb", line_number: 3,
                               duration: 0.2, outcome: "passed", name: "Refund is idempotent")],
             commit_sha: "feedfacecafe0002")
    end

    it "describes the repository's newest run on a default call" do
      served = block(query: ask)

      expect(served["recorded_count"]).to eq(1)
      expect(served["rows"].map { it["name"] }).to eq(["Refund is idempotent"])
      expect(get_repository(query: ask).dig("run_anchor", "commit_sha")).to eq("feedfacecafe0002")
    end

    it "moves to the run named by ?commit_sha= with the other run-grain drill-ins" do
      query = ask.merge(commit_sha: "feedfacecafe0001")
      served = block(query: query)

      expect(served["recorded_count"]).to eq(3)
      expect(served["rows"].map { it["name"] })
        .to eq(["behaves like a billable charges once", "Pricing rounds to the currency unit",
                "Pricing applies the volume tier"])
      # And the anchor says which run it moved to, so the rows are attributable rather than merely
      # different from the default call's.
      expect(get_repository(query: query).dig("run_anchor", "commit_sha")).to eq("feedfacecafe0001")
      expect(latest_run(query: query)["commit_sha"]).to eq("feedfacecafe0001")
    end
  end

  # AC5. The shapes a query string can legally parse into that are NOT a String, pinned once for every
  # surface in `spec/support/shared_examples/malformed_unannotated_examples_param.rb`. The hazard is
  # the MIRROR of every sibling's: this parameter reaches no SQL comparison, so an Array does not
  # return the wrong rows — it is truthy, so it returns rows AT ALL, plus the query that produced
  # them, on a query string the client never meant to send.
  describe "an unannotated-examples parameter that is not a string" do
    # The NO-ask answer specifically, and not merely a 200 — the shared example's own comment requires
    # it, and here it is the only thing that can be required: this parameter's "malformed" answer and
    # its "absent" answer are the same `null`, so nothing inside the shared group can tell a working
    # guard from an endpoint that ignores the parameter. The positive path beside it is what does.
    def expect_unannotated_examples_param_treated_as_no_ask(query)
      expect(block(query: query)).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed unannotated-examples parameter as no ask"

    # THE positive path, beside the group, which is what separates "the guard read the parameter" from
    # "the endpoint ignores this parameter entirely".
    it "honours an unannotated_examples that IS a string" do
      expect(block(query: ask)["rows"].length).to eq(3)
    end

    # An empty ask is no ask: `?unannotated_examples=` is what a browser sends for an unfilled form
    # field and what a client building a query string off a nil variable sends, and an ask has to be
    # affirmative rather than merely present in the URL.
    it "treats an empty unannotated_examples as no ask" do
      expect(block(query: { unannotated_examples: "" })).to be_nil
    end

    # ⭐ THE VALUE IS NOT READ, AND THAT INCLUDES `false`. What is tested is that the client NAMED the
    # parameter — the alternative, a truthiness vocabulary, would be a third line of guard no sibling
    # has and would spell "a word you do not recognise" and "a shape that is not a String" the same
    # way. A client that does not want the block omits the parameter, which is how it declines the
    # other six. Pinned so a later reader does not "fix" this into a boolean cast.
    it "opens the block for any non-blank string, the word false included" do
      expect(block(query: { unannotated_examples: "false" })).not_to be_nil
      expect(block(query: { unannotated_examples: "1" })["recorded_count"]).to eq(3)
      expect(block(query: { unannotated_examples: "yes please" })["recorded_count"]).to eq(3)
    end
  end

  # AC6 and the cost, on the axis this key shares with the four sibling drill-ins: the other blocks
  # issue their reads unconditionally, so their emptiness is DERIVED from a read paid for anyway. Here
  # the gate is the ask and it is decided before any query is issued, so a client that never sends the
  # parameter pays nothing at all for the key's existence.
  describe "what the drill-in costs the endpoint" do
    it "adds exactly one query when asked, and none when not" do
      # Warmed first, on the precedent every sibling cost block sets: the very first request of an
      # example pays for state a second one does not — an API key's first use is recorded — and a
      # baseline taken over it would be measuring the warm-up rather than the block.
      get_repository
      baseline = count_queries { get_repository }

      expect(count_queries { get_repository(query: ask) }).to eq(baseline + 1)
      # And a malformed shape is no ask, which means it is also no query — the guard sits in front of
      # the read rather than inside it.
      expect(count_queries { get_repository(query: { unannotated_examples: ["true"] }) })
        .to eq(baseline)
    end

    # The same bound classified rather than counted, so "one more query" cannot be satisfied by a
    # different grain reading twice while this one reads none. `unannotated_examples_grain_reads` and
    # the partition it belongs to come from spec/support/observation_grain_reads.rb, which is also
    # where the argument for matching every grain POSITIVELY is made — and where this grain's alias
    # match is separated from the three window pairs it shares a family with.
    it "reads spec_observations once for its own grain, and leaves every other grain alone" do
      area, file, example, description, flakiness, growth, directory_files, file_examples,
        description_examples, _dfg, _rtg, _dfrtg, unstable_test_runs, unannotated =
        observation_reads_by_grain { get_repository(query: ask) }

      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length, directory_files.length, file_examples.length,
              description_examples.length, unstable_test_runs.length, unannotated.length])
        .to eq([1, 1, 2, 2, 0, 0, 0, 0, 0, 0, 1])
      # And the classified reads are ALL of them — the assertion no per-grain count can make, because
      # a read matching no grain's pattern is invisible to every one of them.
      expect(observation_reads { get_repository(query: ask) }.length)
        .to eq(classified_observation_reads { get_repository(query: ask) })
      expect(observation_reads { get_repository(query: ask) }.length).to eq(7)
      # Six without the ask — the total `repository_latest_run_spec.rb` pins for this endpoint,
      # restated here as the thing this slice did NOT change.
      expect(observation_reads { get_repository }.length).to eq(6)
      expect(unannotated_examples_grain_reads { get_repository }).to be_empty
    end

    # The drill-ins compose without either being classified as the other — this one against the
    # bottom rung of the area → file → example ladder, which is the sibling whose read also lists this
    # table's rows with a window count riding on them.
    it "keeps the two drill-ins in their own grains when both are asked for at once" do
      query = ask.merge(spec_file: other_file)

      grains = observation_reads_by_grain { get_repository(query: query) }

      expect([grains[7].length, grains[13].length]).to eq([1, 1])
      expect(observation_reads { get_repository(query: query) }.length)
        .to eq(classified_observation_reads { get_repository(query: query) })
      expect(observation_reads { get_repository(query: query) }.length).to eq(8)
    end

    # The suite-size axis, and the one that decides whether this key is affordable at the roadmap's
    # 20,000-example design point: the read is bounded by the size of the RUN and capped, so the
    # just-installed repository whose every example is unannotated costs the same single query as this
    # file's five-row fixture. A serializer that fetched the rows and counted them in Ruby, or that
    # took a second pass for the population, reads as more here and as more again as the suite grows.
    it "reads it once however many unannotated examples the run holds" do
      big = separate_repository("acme/wide-run")
      ingest(big, Array.new(400) do |index|
        unannotated_spec(file_path: "spec/models/thing_#{format('%03d', index)}_spec.rb",
                         line_number: index + 1, duration: 0.1, outcome: "passed",
                         name: "Thing #{index} does its job")
      end)
      key = big.api_keys.create!

      get_repository(key: key)
      baseline = count_queries { get_repository(key: key) }

      expect(count_queries { get_repository(key: key, query: ask) }).to eq(baseline + 1)
      expect(block(key: key, query: ask)["recorded_count"]).to eq(400)
      expect(block(key: key, query: ask)["rows"].length)
        .to eq(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
    end
  end
end
