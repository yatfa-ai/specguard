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

  # The RANKING above the worklist, served from the same ask. `debt_map` rather than `map`, which
  # would shadow `Enumerable#map` on the example instance for every later reader of this file.
  def debt_map(**) = get_repository(**).dig("latest_run", "unannotated_directories")

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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "list unannotated examples", behavior: "the worklist comes back in definition file order and every row carries enough locating detail to open the source", layer: "request" }
    it "lists the run's unannotated examples in file order, with enough to open each one" do
      expect(block(query: ask)).to eq(
        "spec_file" => nil,
        "spec_directory" => nil,
        "rows" => [
          { "name" => "behaves like a billable charges once",
            "file_path" => "spec/support/shared_examples/billable.rb",
            "line_number" => 7, "spec_file_path" => target_file,
            "reading" => "unreadable", "derived_intent" => nil },
          { "name" => "Pricing rounds to the currency unit", "file_path" => other_file,
            "line_number" => 9, "spec_file_path" => other_file,
            "reading" => "unreadable", "derived_intent" => nil },
          { "name" => "Pricing applies the volume tier", "file_path" => other_file,
            "line_number" => 40, "spec_file_path" => other_file,
            "reading" => "unreadable", "derived_intent" => nil }
        ],
        "recorded_count" => 3,
        "derived_count" => 0,
        "unreadable_count" => 3,
        "limit" => SpecObservation::UNANNOTATED_EXAMPLES_LIMIT
      )
    end

    # The sub-block's own key set, stated as its subject rather than pinned as a side effect of the
    # `eq` above — the pattern every sibling drill-in's contract example sets, and for the same
    # reason: a guard whose stated subject IS the key set survives a fixture whose numbers change,
    # and says out loud what a new key owes this block before it ships.
    #
    # AC7 IS THE SECOND HALF OF THIS EXAMPLE. The three per-example blocks on this endpoint agree on
    # SEVEN fields and this one serves SIX, which is a difference asserted rather than structural —
    # exactly as their agreement is. The two sets are not nested: this block withholds three of
    # theirs and carries two — `reading` and `derived_intent` (SPGD-711) — that none of them serves.
    # Their own `contain_exactly`s go red if one of theirs is dropped
    # to match this; this one goes red if `duration_seconds`, `outcome` or `intent_layer` is added
    # here to match them. Both directions are pinned, in the two places that own them.
    #
    # `intent_layer` is the third withheld field (SPGD-851) and the one whose absence is STRUCTURAL
    # rather than editorial: this block's population is by definition the rows that declared no
    # layer, so the key could only ever be null here.
    #
    # `spec_file` and `spec_directory` are in the key set on EVERY call, `null` when they were not
    # sent — the no-ask spelling the whole endpoint uses, and the reason a client can reconcile
    # `recorded_count` against `total_specs - annotated_specs` without knowing what it sent: the two
    # keys say whether the count is the run's.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "pin the response shape", behavior: "the block exposes only the contracted unannotated_examples keys and never leaks the richer per-example structure behind it", layer: "request" }
    it "serves exactly the unannotated_examples keys this contract pins, and not the per-example shape" do
      served = block(query: ask)

      expect(served.keys)
        .to contain_exactly("spec_file", "spec_directory", "rows", "recorded_count", "derived_count",
                            "unreadable_count", "limit")
      expect(served["rows"].first.keys)
        .to contain_exactly("name", "file_path", "line_number", "spec_file_path", "reading",
                            "derived_intent")
      # Not the other blocks' seven-field per-example shape, and specifically not by accident: the
      # endpoint's other per-example block is on the same response and DOES carry all three.
      expect(served["rows"].first).not_to have_key("duration_seconds")
      expect(served["rows"].first).not_to have_key("outcome")
      expect(served["rows"].first).not_to have_key("intent_layer")
      expect(latest_run(query: ask).dig("slowest_examples", "rows").first)
        .to include("duration_seconds", "outcome", "intent_layer")
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "reconcile counters", behavior: "the row count off a single response equals the run annotation counters, proving the page and the counters describe the same population", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "count beyond the cap", behavior: "the disclosed population total covers the whole run even when pagination truncated the rows actually served", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "exclude annotated rows", behavior: "no example carrying an annotation appears anywhere in the served worklist", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "report shared example sites", behavior: "a row generated from a shared example group reports the defining file separately from the file that included it", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "serve raw figures", behavior: "counts and status words are returned directly, with no panel labels or comparison verdicts mixed into the payload", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "order untimed rows", behavior: "an example with no duration sorts by its location fields rather than by a missing cost", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "keep pages stable", behavior: "asking again for the same run yields an identical page, so the listing is deterministic across calls", layer: "request" }
    it "returns the same page twice for the same run" do
      expect(block(query: ask)).to eq(block(query: ask))
    end
  end

  # ⭐ THE WORKLIST POINTED AT WHERE THE WORK IS. The flag alone answers the whole run in one order,
  # capped — a list with no way to choose a place in it, which for a team adopting SpecGuard on the
  # module they are actually touching means annotating every alphabetically-earlier example first, a
  # hundred at a time, each batch costing a CI run and a re-ingest. `?spec_file=` and
  # `?spec_directory=` are the two parameters that already narrow every other per-example question on
  # this endpoint, and sending either alongside the flag narrows this population to it.
  #
  # THE POPULATION, NOT ONLY THE ROWS, which is what every example here asserts BOTH halves of: the
  # window rides the WHERE, so `recorded_count` narrows for free — and a serializer that had narrowed
  # the rows and left the count at the run's would pass any rows-only assertion while telling a client
  # its file holds three times the work it does.
  describe "a worklist narrowed to one file or one area" do
    let(:models_area) { "spec/models" }
    let(:services_area) { "spec/services" }

    # AC2. The file rung. `other_file` holds TWO of the run's three unannotated examples, so a block
    # that had ignored the narrowing returns a superset that still looks like a list of unannotated
    # examples — and the count is what separates the two beyond doubt.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "narrow by file", behavior: "sending the file filter shrinks both rows and total to that one file, and the filter value is echoed back to the client", layer: "request" }
    it "narrows the rows AND the count to one file, and echoes the file it narrowed by" do
      served = block(query: ask.merge(spec_file: other_file))

      expect(served["rows"].map { it["name"] })
        .to eq(["Pricing rounds to the currency unit", "Pricing applies the volume tier"])
      expect(served["recorded_count"]).to eq(2)
      expect(served["spec_file"]).to eq(other_file)
      expect(served["spec_directory"]).to be_nil
      # The whole-run answer on the same fixture is strictly larger, so the narrow is a predicate
      # doing work rather than a fixture with one file in it.
      expect(block(query: ask)["recorded_count"]).to eq(3)
    end

    # The narrowing is by the file that RAN the example, not the file it is DEFINED in — the same
    # `spec_file_path` the rows are ordered by and that `?spec_file=` means everywhere else here. The
    # shared example group is the row that can tell those apart: asking for `order_spec.rb` finds it,
    # and asking for the `spec/support/` helper it is written in does not.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "narrow on run location", behavior: "the file filter matches where the example executed, not the shared file where it was defined", layer: "request" }
    it "narrows by the file that RAN the example, not the file it is defined in" do
      by_running_file = block(query: ask.merge(spec_file: target_file))

      expect(by_running_file["rows"].map { it["name"] }).to eq(["behaves like a billable charges once"])
      expect(by_running_file["recorded_count"]).to eq(1)
      expect(by_running_file["rows"].first["file_path"])
        .to eq("spec/support/shared_examples/billable.rb")
      # And the definition site is not the ask that finds it, which is the half a serializer narrowing
      # on `file_path` would get backwards.
      expect(block(query: ask.merge(spec_file: "spec/support/shared_examples/billable.rb"))["rows"])
        .to be_empty
    end

    # AC3. The area rung, by `DIRECTORY_EXPRESSION` equality. `spec/models` and `spec/services` each
    # hold part of this run's unannotated population, so each ask excludes the other's rows.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "narrow by area", behavior: "the area filter restricts rows and total to one directory and restates the chosen area in the response", layer: "request" }
    it "narrows the rows AND the count to one area, and echoes the area it narrowed by" do
      models = block(query: ask.merge(spec_directory: models_area))
      services = block(query: ask.merge(spec_directory: services_area))

      expect(models["rows"].map { it["spec_file_path"] }).to eq([target_file])
      expect(models["recorded_count"]).to eq(1)
      expect(models["spec_directory"]).to eq(models_area)
      expect(models["spec_file"]).to be_nil

      expect(services["rows"].map { it["spec_file_path"] }).to eq([other_file, other_file])
      expect(services["recorded_count"]).to eq(2)
      # The two partition the run's population between them, which no single-area assertion can say.
      expect(models["recorded_count"] + services["recorded_count"])
        .to eq(block(query: ask)["recorded_count"])
    end

    # ⭐ AC3, THE PREFIX TRAP — the one assertion a flat fixture cannot make, which is why this
    # example builds a repository with a SUBDIRECTORY in it. `DIRECTORY_EXPRESSION` is the IMMEDIATE
    # PARENT of the including file compared for EQUALITY: `spec/models/orders` is its own area, not
    # part of `spec/models`. A `LIKE 'spec/models%'` written to make "the whole subtree" work returns
    # both rows here and would be a fifth directory semantics on this table.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "treat areas as exact", behavior: "a subdirectory is excluded by its parent filter because an area is the immediate parent directory, never a path prefix", layer: "request" }
    it "excludes a SUBDIRECTORY's rows, because an area is the immediate parent and not a prefix" do
      nested = separate_repository("acme/nested-areas")
      ingest(nested,
             [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 3,
                               name: "Order totals the line items"),
              unannotated_spec(file_path: "spec/models/orders/refund_spec.rb", line_number: 5,
                               name: "Refund reverses the charge")])
      key = nested.api_keys.create!

      parent = block(key: key, query: ask.merge(spec_directory: "spec/models"))
      child = block(key: key, query: ask.merge(spec_directory: "spec/models/orders"))

      expect(parent["rows"].map { it["spec_file_path"] }).to eq(["spec/models/order_spec.rb"])
      expect(parent["recorded_count"]).to eq(1)
      # The subtree row EXISTS, is unannotated, and is reachable under its OWN area — so its absence
      # above is the equality doing work rather than an empty fixture.
      expect(child["rows"].map { it["spec_file_path"] }).to eq(["spec/models/orders/refund_spec.rb"])
      expect(child["recorded_count"]).to eq(1)
      expect(block(key: key, query: ask)["recorded_count"]).to eq(2)
    end

    # AC4. Both together AND, with no precedence rule: a coherent pair is the intersection.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "intersect filters", behavior: "file and area sent together intersect their row sets and totals, and both filter values are echoed", layer: "request" }
    it "intersects the two when both are sent, and echoes both" do
      served = block(query: ask.merge(spec_file: other_file, spec_directory: services_area))

      expect(served["rows"].map { it["name"] })
        .to eq(["Pricing rounds to the currency unit", "Pricing applies the volume tier"])
      expect(served["recorded_count"]).to eq(2)
      expect(served["spec_file"]).to eq(other_file)
      expect(served["spec_directory"]).to eq(services_area)
    end

    # AC4, the half a precedence rule would have broken. A file outside the area named is an empty
    # INTERSECTION — 200, both narrowings echoed — rather than one parameter silently winning and the
    # other being dropped, which is the failure a client could not see from the body.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "answer empty intersection", behavior: "contradictory filter values still return 200 with zero rows while restating both narrowings", layer: "request" }
    it "answers a contradictory pair with no rows, both narrowings restated, and a 200" do
      served = block(query: ask.merge(spec_file: other_file, spec_directory: models_area))

      expect(response).to have_http_status(:ok)
      expect(served["rows"]).to eq([])
      expect(served["recorded_count"]).to eq(0)
      expect(served["spec_file"]).to eq(other_file)
      expect(served["spec_directory"]).to eq(models_area)
      # Each half of the pair is non-empty on its own, so the emptiness is the AND rather than either
      # parameter being wrong.
      expect(block(query: ask.merge(spec_file: other_file))["recorded_count"]).to eq(2)
      expect(block(query: ask.merge(spec_directory: models_area))["recorded_count"]).to eq(1)
    end

    # AC5. A path this run recorded nothing for is an ordinary answer, not a malformed request — the
    # answer `repository_spec_file_examples_spec.rb` fixed for the rung below and this inherits
    # verbatim: 200, the ask restated, `rows: []`, honest zeroes. Never a 404, and specifically never
    # a prefix match onto the neighbour the typo was nearly spelled as.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "reject unknown paths", behavior: "a mistyped path yields the plain empty block instead of an error or an unintended prefix match", layer: "request" }
    it "answers a typo with the empty block rather than an error or a prefix match" do
      typo_file = block(query: ask.merge(spec_file: "spec/services/pricing_spec.rbx"))
      typo_area = block(query: ask.merge(spec_directory: "spec/serv"))

      expect(response).to have_http_status(:ok)
      expect(typo_file).to eq("spec_file" => "spec/services/pricing_spec.rbx", "spec_directory" => nil,
                              "rows" => [], "recorded_count" => 0, "derived_count" => 0,
                              "unreadable_count" => 0,
                              "limit" => SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      expect(typo_area["rows"]).to eq([])
      expect(typo_area["recorded_count"]).to eq(0)
      expect(typo_area["spec_directory"]).to eq("spec/serv")
    end

    # AC5, the reason the block needs no field to separate "no such path" from "fully annotated": the
    # SAME RESPONSE BODY already carries the sibling block both parameters open. `spec_file` is the
    # ANNOTATED file here — it has rows, and none of them unannotated — so a client reads "the file
    # exists and there is nothing left to do" off two counts it already has. The typo reads zero on
    # both, which is the other sentence.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "signal empty versus unknown", behavior: "a distinguishable absent value lets clients tell an unknown file from a fully annotated one without a new field", layer: "request" }
    it "lets a client separate an unknown path from a fully-annotated one, with no new field" do
      done = latest_run(query: ask.merge(spec_file: annotated_file))
      missing = latest_run(query: ask.merge(spec_file: "spec/models/nope_spec.rb"))

      expect(done.dig("spec_file_examples", "recorded_count")).to eq(2)
      expect(done.dig("unannotated_examples", "recorded_count")).to eq(0)

      expect(missing.dig("spec_file_examples", "recorded_count")).to eq(0)
      expect(missing.dig("unannotated_examples", "recorded_count")).to eq(0)
    end

    # AC6. The narrowing parameters are the flag's modifiers, never its trigger. Sent WITHOUT it the
    # block stays `null` — and they still open their own blocks, which is the half that proves the
    # parameters were read at all rather than the request having been ignored.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "gate the block on flag", behavior: "the block stays null when a narrowing is sent without the flag that asks for it", layer: "request" }
    it "leaves the block null when a narrowing arrives without the flag" do
      run = latest_run(query: { spec_file: other_file, spec_directory: services_area })

      expect(run).to have_key("unannotated_examples")
      expect(run["unannotated_examples"]).to be_nil
      expect(run.dig("spec_file_examples", "path")).to eq(other_file)
      expect(run.dig("spec_directory_files", "path")).to eq(services_area)
    end

    # AC7. The echo is the value AS THE SERVER READ IT, which for a shape that is not a String is no
    # value at all — the guards these two parameters already ship reject an Array, a nested hash and a
    # blank before any of them reaches SQL. So a malformed narrowing is not a narrowing: the block is
    # the WHOLE RUN with both keys `null`, never the raw parameter echoed back and never an `IN` list
    # under a key naming one file.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "sanitize bad filters", behavior: "malformed or blank narrowing values are treated as absent and echoed back as null, never reflected raw", layer: "request" }
    it "treats a malformed or blank narrowing as no narrowing, and echoes null rather than the raw parameter" do
      [{ spec_file: [other_file] }, { spec_file: { path: other_file } }, { spec_file: "" },
       { spec_directory: [services_area] }, { spec_directory: "" }].each do |malformed|
        served = block(query: ask.merge(malformed))

        expect(response).to have_http_status(:ok)
        expect(served["recorded_count"]).to eq(3)
        expect(served["rows"].length).to eq(3)
        expect([served["spec_file"], served["spec_directory"]]).to eq([nil, nil])
      end
    end

    # AC8. The cap fires WITHIN the narrowed population, and `recorded_count` is that population's —
    # the same window/limit separation the whole-run block pins, asserted again one narrowing down,
    # because a serializer could have narrowed the rows and counted the page.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "cap narrowed results", behavior: "the narrowing respects the page cap while the total keeps counting the full narrowed population behind it", layer: "request" }
    it "caps the narrowed page and still counts the narrowed population behind it" do
      big = separate_repository("acme/one-heavy-area")
      over = SpecObservation::UNANNOTATED_EXAMPLES_LIMIT + 25
      ingest(big, Array.new(over) do |index|
        unannotated_spec(file_path: "spec/models/thing_spec.rb", line_number: index + 1,
                         name: "Thing #{index} does its job")
      end + [unannotated_spec(file_path: "spec/services/elsewhere_spec.rb", line_number: 1,
                              name: "Elsewhere is not in that file")])
      key = big.api_keys.create!
      served = block(key: key, query: ask.merge(spec_file: "spec/models/thing_spec.rb"))

      expect(served["rows"].length).to eq(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      expect(served["recorded_count"]).to eq(over)
      expect(served["limit"]).to eq(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      # The narrowed count is the FILE's rather than the run's, which the extra row makes visible.
      expect(block(key: key, query: ask)["recorded_count"]).to eq(over + 1)
    end

    # The narrowed WORKLIST is still ONE query and still this block's own grain: the narrowing is a
    # predicate on the read the flag already pays for, not a second read — and it must not be
    # classified as the file drill-in whose predicate it now shares.
    #
    # The ASK costs TWO, and the second one is the map. It is a constant of the ask rather than of the
    # narrowing — `unannotated_directories` is whole-run and is built the same way under every shape of
    # this parameter — which is what this example pins by taking the SAME `+2` the un-narrowed cost
    # block takes: a map that had grown a second read under a narrowing, or that had been skipped when
    # one arrived, is a different number here.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "bound queries under narrowing", behavior: "narrowed requests add exactly two queries, one per block, each charged to its own grain", layer: "request" }
    it "adds exactly two queries when narrowed — one per block — each in its own grain" do
      query = ask.merge(spec_file: other_file, spec_directory: services_area)

      get_repository(query: { spec_file: other_file, spec_directory: services_area })
      baseline = count_queries { get_repository(query: { spec_file: other_file, spec_directory: services_area }) }

      expect(count_queries { get_repository(query: query) }).to eq(baseline + 2)
      expect(unannotated_examples_grain_reads { get_repository(query: query) }.length).to eq(1)
      expect(unannotated_directories_grain_reads { get_repository(query: query) }.length).to eq(1)
      expect(observation_reads { get_repository(query: query) }.length)
        .to eq(classified_observation_reads { get_repository(query: query) })
    end

    # And the narrowing composes with the parameter that re-anchors the run, which is the ordinary
    # use rather than the exotic one: "what is still unannotated in the module I am touching, as of
    # the commit I pushed".
    # @intent: { entity: "repository unannotated_examples endpoint", action: "compose with commit_sha", behavior: "the narrowing composes with the run selector so both name the same run being narrowed within", layer: "request" }
    it "composes with ?commit_sha=, which names the run it narrowed within" do
      ingest(repository,
             [unannotated_spec(file_path: other_file, line_number: 9,
                               name: "Pricing rounds to the currency unit")],
             commit_sha: "feedfacecafe0002")
      query = ask.merge(spec_file: other_file, commit_sha: "feedfacecafe0001")

      expect(block(query: query)["recorded_count"]).to eq(2)
      expect(block(query: ask.merge(spec_file: other_file))["recorded_count"]).to eq(1)
      expect(get_repository(query: query).dig("run_anchor", "commit_sha")).to eq("feedfacecafe0001")
    end
  end

  # ⭐ THE RANKING ABOVE THE WORKLIST — `latest_run.unannotated_directories`, served from the SAME
  # `?unannotated_examples=` ask and the rung `UnannotatedExamples` concedes in its own header it
  # never had ("There is no ranking here and nothing to pick").
  #
  # The block above narrows on `?spec_file=` / `?spec_directory=`, which helps exactly the client that
  # already knows which area to name. The three area/file rollups this endpoint serves rank by
  # DURATION and their coverage is TIMING coverage, so none of them could tell it. These examples pin
  # the four things that make this key an answer rather than a second list: the ORDER, the CAP and its
  # disclosure, the whole-run SCOPE under a narrowing, and the area semantics it inherits.
  describe "the ranking that says WHERE the annotation debt is" do
    # The fixture's two areas carry different debt and are not in alphabetical agreement with it:
    # `spec/services` holds two unannotated of two recorded, `spec/models` one of three. So the head
    # row is NOT by path, not by `recorded_count`, and not by the insertion order — every one of those
    # alternatives produces a different first row here.
    #
    # ⚠️ IT DOES NOT DISCRIMINATE THE LEAD TERM, and says so rather than implying it does. This
    # comment used to read "the ranking is by `unannotated_count DESC`"; SPGD-711 put
    # `unreadable_count DESC` in front of that, and in this fixture the two agree — `spec/services`
    # leads on unreadable (2 to 1) as well as on debt (2 to 1), so the row order below is green under
    # either term. The example after this one is the one that pulls them apart, in both directions.
    # @intent: { entity: "repository unannotated_directories ranking", action: "rank areas", behavior: "the ranking ships the two operands per area rather than a precomputed fraction, so a client can redo the arithmetic", layer: "request" }
    it "ranks the areas, and ships the operands rather than a fraction" do
      expect(debt_map(query: ask)).to eq(
        "rows" => [
          { "path" => "spec/services", "unannotated_count" => 2, "recorded_count" => 2,
            "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 2 },
          { "path" => "spec/models", "unannotated_count" => 1, "recorded_count" => 3,
            "authored_count" => 2, "derived_count" => 0, "unreadable_count" => 1 }
        ],
        "directory_count" => 2,
        "limit" => SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT
      )
    end

    # ⭐ THE LEAD TERM, pulled apart from the one it replaced, in BOTH directions — and the API needs
    # its own because `specguard-mcp` states this row order to agents as contract
    # ("ranked `unreadable_count` DESC, then `unannotated_count` DESC"). The dashboard pins the same
    # rule at `spec/requests/repository_unannotated_directories_spec.rb`; the read is shared, so this
    # is the endpoint's copy of the claim it publishes rather than a second implementation.
    #
    # Both halves put the expected head row LAST alphabetically, so `path ASC` cannot produce either
    # answer and the count terms are what is under test.
    # @intent: { entity: "repository unannotated_directories ranking", action: "lead on unreadable areas", behavior: "areas that cannot be read sort first and debt is used as the tie-breaking signal when nothing is unreadable", layer: "request" }
    it "leads on the areas it cannot read, and falls back to debt where none is dark" do
      dark = separate_repository("acme/one-dark-area")
      ingest(dark,
             # Three times the debt, and SpecGuard reads every one of them.
             [unannotated_spec(file_path: "spec/alpha/ledger_post_spec.rb", line_number: 1,
                               name: "Ledger#post records the journal entry"),
              unannotated_spec(file_path: "spec/alpha/ledger_void_spec.rb", line_number: 2,
                               name: "Ledger#void reverses the journal entry"),
              unannotated_spec(file_path: "spec/alpha/ledger_close_spec.rb", line_number: 3,
                               name: "Ledger#close seals the accounting period"),
              # One unannotated row, and nothing to read it by.
              unannotated_spec(file_path: "spec/zulu/sweep_spec.rb", line_number: 4,
                               name: "the nightly sweep runs")])

      rows = debt_map(key: dark.api_keys.create!, query: ask)["rows"]

      # `spec/alpha` carries three of the four unannotated rows and is second: under the ranking this
      # example replaced it led, and the one area SpecGuard can say nothing about was below it.
      expect(rows.map { it["path"] }).to eq(["spec/zulu", "spec/alpha"])
      expect(rows.map { it["unannotated_count"] }).to eq([1, 3])
      expect(rows.map { it["unreadable_count"] }).to eq([1, 0])

      # The other direction: with nothing dark anywhere, the debt ranking is intact underneath as the
      # tiebreak, so the area carrying the most unannotated rows leads exactly as it did before.
      readable = separate_repository("acme/nothing-dark")
      ingest(readable,
             [unannotated_spec(file_path: "spec/alpha/ledger_post_spec.rb", line_number: 1,
                               name: "Ledger#post records the journal entry"),
              unannotated_spec(file_path: "spec/zulu/refund_issue_spec.rb", line_number: 2,
                               name: "Refund#issue returns the money to the payer"),
              unannotated_spec(file_path: "spec/zulu/refund_void_spec.rb", line_number: 3,
                               name: "Refund#void reverses the settled refund")])

      rows = debt_map(key: readable.api_keys.create!, query: ask)["rows"]

      expect(rows.map { it["path"] }).to eq(["spec/zulu", "spec/alpha"])
      expect(rows.map { it["unreadable_count"] }).to eq([0, 0])
      expect(rows.map { it["unannotated_count"] }).to eq([2, 1])
    end

    # The sub-block's own key set as its stated subject, on the pattern every contract example in this
    # file follows. `recorded_count` is the AREA's whole population and never its unannotated rows
    # again under a second name — a read that had narrowed on `status` instead of FILTERing inside the
    # aggregate returns `2, 2` and `1, 1` here, a fraction that is 100% on every row and no operand
    # at all. That is the discriminating half of this example.
    # @intent: { entity: "repository unannotated_directories ranking", action: "pin the block shape", behavior: "the ranking block serves exactly the contracted unannotated_directories keys and nothing more", layer: "request" }
    it "serves exactly the unannotated_directories keys this contract pins" do
      served = debt_map(query: ask)

      expect(served.keys).to contain_exactly("rows", "directory_count", "limit")
      expect(served["rows"].first.keys)
        .to contain_exactly("path", "unannotated_count", "recorded_count", "authored_count",
                            "derived_count", "unreadable_count")
      # The three readings partition the area's whole population, which is what makes them safe to
      # render side by side: a row whose parts did not sum to `recorded_count` would be a panel
      # showing three columns of a four-way split.
      expect(served["rows"]).to all(satisfy do |row|
        row["authored_count"] + row["derived_count"] + row["unreadable_count"] == row["recorded_count"]
      end)
      # And `unannotated_count` is exactly the two non-authored readings — the identity that lets this
      # key keep its old meaning while the new ones split it.
      expect(served["rows"]).to all(satisfy do |row|
        row["derived_count"] + row["unreadable_count"] == row["unannotated_count"]
      end)
      # The denominators are the areas' OWN populations, taken off the same response: the two
      # `recorded_count`s sum to the run's `total_specs`, which they cannot do if the aggregate was
      # counting unannotated rows twice.
      expect(served["rows"].sum { it["recorded_count"] }).to eq(latest_run(query: ask)["total_specs"])
      # No fraction, no label, no verdict — the rule every rollup on this endpoint is served under.
      expect(served["rows"].first).not_to have_key("coverage_label")
    end

    # The LAST tiebreak, which the cap makes load-bearing rather than tidy: two areas tying on BOTH
    # counts must come back in the same order on two identical asks, or a client comparing the ranking
    # across requests reads a re-shuffle as a change in the suite. The fixture below ties on both —
    # one unannotated row each, every one of them unreadable — so neither count term orders it and
    # `path ASC` is what is under test. Two count terms are still not a total order and Postgres is
    # under no obligation to be stable.
    # @intent: { entity: "repository unannotated_directories ranking", action: "tie-break deterministically", behavior: "equal ranking values break on path ascending so identical requests return the same ordering", layer: "request" }
    it "breaks a tie on path ASC, so two identical asks return the same order" do
      tied = separate_repository("acme/tied-areas")
      ingest(tied,
             [unannotated_spec(file_path: "spec/zebra/z_spec.rb", line_number: 1, name: "Zebra one"),
              unannotated_spec(file_path: "spec/alpha/a_spec.rb", line_number: 1, name: "Alpha one"),
              unannotated_spec(file_path: "spec/middle/m_spec.rb", line_number: 1, name: "Middle one")])
      key = tied.api_keys.create!

      paths = debt_map(key: key, query: ask)["rows"].map { it["path"] }

      expect(paths).to eq(["spec/alpha", "spec/middle", "spec/zebra"])
      expect(debt_map(key: key, query: ask)["rows"].map { it["path"] }).to eq(paths)
    end

    # The cap and its disclosure, which are one fact: a capped list whose own length is the only thing
    # describing it is a truncated list silently wearing the shape of a complete one. `directory_count`
    # is a `COUNT(*) OVER ()` evaluated after the WHERE and before the LIMIT, so it counts the areas
    # the RUN touched rather than the rows that fit on the page.
    #
    # Its own constant, asserted as such: a serializer reusing `HEAVIEST_DIRECTORIES_LIMIT` would pass
    # a bare `10` here and go red on the day either constant moved, which is the coupling the model's
    # constants block exists to refuse.
    # @intent: { entity: "repository unannotated_directories ranking", action: "disclose the cap", behavior: "the ranking honours its own limit and reports how many areas the run touched overall", layer: "request" }
    it "caps the ranking at its own limit and discloses how many areas the run touched" do
      wide = separate_repository("acme/many-areas")
      areas = SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT + 3
      ingest(wide, Array.new(areas) do |index|
        # Debt DESCENDS with the index, so the areas that survive the cap are a genuine head of the
        # ranking rather than whichever ten the scan happened to reach first.
        Array.new(areas - index) do |row|
          unannotated_spec(file_path: "spec/area_#{format('%02d', index)}/thing_spec.rb",
                           line_number: row + 1, name: "Area #{index} row #{row}")
        end
      end.flatten)
      key = wide.api_keys.create!
      served = debt_map(key: key, query: ask)

      expect(served["rows"].length).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      expect(served["directory_count"]).to eq(areas)
      expect(served["limit"]).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      # The head of the ranking, not an arbitrary ten: the heaviest-debt area leads and the three
      # lightest are the ones the cap cut.
      expect(served["rows"].first["path"]).to eq("spec/area_00")
      expect(served["rows"].map { it["path"] }).not_to include("spec/area_12")
      # And the disclosure is what says so — the sentence a client writes instead of comparing the
      # list's length against a limit it cannot see.
      expect(served["directory_count"]).to be > served["rows"].length
    end

    # ⭐⭐ THE LOAD-BEARING SCOPE DECISION, and the assertion the whole rung stands on. The map is
    # WHOLE-RUN even under a narrowing, where its sibling `recorded_count` is NOT — the one place on
    # this endpoint where two keys of ONE block are deliberately scoped differently.
    #
    # A map that narrowed to the area the client had already picked would answer nothing: one row,
    # echoing the parameter back. The map is the thing a client picks a narrowing FROM, so it has to
    # keep describing the run the client is choosing within — which is what makes "annotate the worst
    # area, re-ask, annotate the next" a loop rather than a dead end.
    #
    # Both halves are asserted in one example on purpose. A serializer that narrowed the map passes an
    # assertion about the worklist alone; a serializer that stopped narrowing the WORKLIST — undoing
    # SPGD-608 — passes an assertion about the map alone. Only the two together pin the disagreement,
    # which is the thing `serialized_unannotated_directories` carries a comment about.
    # @intent: { entity: "repository unannotated_directories ranking", action: "keep map totals whole-run", behavior: "the map block stays whole-run under a narrowing while the worklist count narrows with the filter", layer: "request" }
    it "stays whole-run under a narrowing, while the worklist's own count narrows" do
      narrowed = ask.merge(spec_directory: "spec/services")
      run = latest_run(query: narrowed)

      # The worklist narrowed: two of the run's three unannotated examples, and it says what by.
      expect(run.dig("unannotated_examples", "recorded_count")).to eq(2)
      expect(run.dig("unannotated_examples", "spec_directory")).to eq("spec/services")
      # The map did NOT: both areas are still ranked, including the one the client narrowed AWAY from.
      expect(run.dig("unannotated_directories", "rows").map { it["path"] })
        .to eq(["spec/services", "spec/models"])
      expect(run.dig("unannotated_directories", "directory_count")).to eq(2)
      # Byte-identical to the un-narrowed ask, which is the strongest form of "the narrowing does not
      # reach it" — stronger than counting its rows, since a map that narrowed and then re-widened by
      # some other route would still differ somewhere in here.
      expect(run["unannotated_directories"]).to eq(debt_map(query: ask))
      # The same under `?spec_file=`, which is the narrower of the two rungs and the likelier one to
      # leak into a read that shares its request.
      expect(debt_map(query: ask.merge(spec_file: other_file))).to eq(debt_map(query: ask))
    end

    # The consequence of the paragraph above, stated as the arithmetic a client actually performs:
    # under a narrowing the two keys DO NOT sum to each other, and neither is wrong. This is pinned
    # rather than left to a comment because it is the reading a client is most likely to get backwards
    # — and because a future edit that "fixed" the disagreement would break this example rather than
    # silently making one of the two figures mean something else.
    # @intent: { entity: "repository unannotated_directories ranking", action: "skip narrowed reconciliation", behavior: "the narrowed worklist count is deliberately not reconciled against the whole-run map", layer: "request" }
    it "does not reconcile the narrowed worklist count against the whole-run map, and should not" do
      run = latest_run(query: ask.merge(spec_directory: "spec/services"))
      map_total = run.dig("unannotated_directories", "rows").sum { it["unannotated_count"] }

      expect(run.dig("unannotated_examples", "recorded_count")).to eq(2)
      expect(map_total).to eq(3)
      # Un-narrowed, on an untruncated map, they DO agree — which is what makes the disagreement above
      # a property of the narrowing rather than of the map being wrong.
      expect(latest_run(query: ask).dig("unannotated_examples", "recorded_count")).to eq(map_total)
    end

    # `DIRECTORY_EXPRESSION` COALESCEs a top-level file's directory to `.` — what `Pathname#dirname`
    # calls it and what a reader recognises. Without the COALESCE the GROUP BY key is SQL NULL, which
    # reaches the client as an unnamed area it cannot pass back to `?spec_directory=`.
    # @intent: { entity: "repository unannotated_directories ranking", action: "name root areas", behavior: "a spec at repository root reports area dot rather than a null key", layer: "request" }
    it "names a root-level spec's area `.` rather than serving a null key" do
      rooted = separate_repository("acme/root-level-specs")
      ingest(rooted,
             [unannotated_spec(file_path: "smoke_spec.rb", line_number: 1, name: "Smoke boots"),
              unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 3,
                               name: "Order totals")])
      key = rooted.api_keys.create!

      expect(debt_map(key: key, query: ask)["rows"])
        .to eq([{ "path" => ".", "unannotated_count" => 1, "recorded_count" => 1,
                  "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 1 },
                { "path" => "spec/models", "unannotated_count" => 1, "recorded_count" => 1,
                  "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 1 }])
      # And it is a real path the client can hand straight back to the narrowing rung, which a null
      # key would not be — the round trip is the reason the COALESCE is there.
      expect(block(key: key, query: ask.merge(spec_directory: "."))["recorded_count"]).to eq(1)
    end

    # ⭐ THE PREFIX TRAP, at the grain that inherits it BY CONSTRUCTION rather than by a predicate —
    # which is exactly why it is pinned here. `spec/models/orders` is its OWN area, not part of
    # `spec/models`: the grouping is on the immediate parent, so a subtree is a separate row and its
    # rows are not rolled up into its parent's counts. Nothing in this read compares paths, so nobody
    # could break this with a bad `LIKE` — they would break it by "fixing" the map into a subtree
    # rollup, which reads as a tidier answer and is a fifth directory semantics on this table.
    # @intent: { entity: "repository unannotated_directories ranking", action: "row each subdirectory", behavior: "a nested directory gets its own ranking row instead of being folded into its parent, and a fully annotated area still appears with a zero so the listing covers every area the run touched", layer: "request" }
    it "gives a subdirectory its own row rather than rolling it into its parent" do
      nested = separate_repository("acme/nested-debt")
      ingest(nested,
             [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 3,
                               name: "Order totals the line items"),
              unannotated_spec(file_path: "spec/models/orders/refund_spec.rb", line_number: 5,
                               name: "Refund reverses the charge"),
              unannotated_spec(file_path: "spec/models/orders/discount_spec.rb", line_number: 5,
                               name: "Discount applies once")])
      key = nested.api_keys.create!
      served = debt_map(key: key, query: ask)

      expect(served["rows"])
        .to eq([{ "path" => "spec/models/orders", "unannotated_count" => 2, "recorded_count" => 2,
                  "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 2 },
                { "path" => "spec/models", "unannotated_count" => 1, "recorded_count" => 1,
                  "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 1 }])
      # Two areas, not one — the disclosure agrees with the rows, so a subtree rollup could not hide
      # in the count either.
      expect(served["directory_count"]).to eq(2)
      # And the ranking's own semantics match the narrowing rung's, which is what lets a client take a
      # path off this list and hand it straight to `?spec_directory=` and get that area's rows.
      expect(block(key: key, query: ask.merge(spec_directory: "spec/models"))["recorded_count"])
        .to eq(1)
    end

    # A fully-annotated area is a ROW carrying a zero, never an omission — the state the metric exists
    # to reach, and the same argument `UnannotatedExamples` makes for its own empty read. It sorts
    # last by construction, so on any run with more areas than the cap it is cut and never seen; on a
    # small run it is listed, and listed is correct. `directory_count` counts it either way, which is
    # what keeps this key's disclosure describing the same population `spec_directories` does.
    # @intent: { entity: "repository unannotated_directories ranking", action: "include clean areas", behavior: "a fully annotated area still appears with a zero so the listing covers every area the run touched", layer: "request" }
    it "lists a fully-annotated area with a zero rather than dropping it from the run's areas" do
      mixed = separate_repository("acme/one-area-done")
      ingest(mixed,
             [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
              unannotated_spec(file_path: "spec/services/pricing_spec.rb", line_number: 9,
                               name: "Pricing rounds")])
      key = mixed.api_keys.create!
      served = debt_map(key: key, query: ask)

      expect(served["rows"])
        .to eq([{ "path" => "spec/services", "unannotated_count" => 1, "recorded_count" => 1,
                  "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 1 },
                { "path" => "spec/models", "unannotated_count" => 0, "recorded_count" => 1,
                  "authored_count" => 1, "derived_count" => 0, "unreadable_count" => 0 }])
      expect(served["directory_count"]).to eq(2)
    end

    # The no-ask spelling, and the rule it pins: THE GATE IS THE ASK. This key rides
    # `?unannotated_examples=` rather than a parameter of its own, so a client that never asks gets
    # the key present and `null` — never an empty block, and never a row it did not pay for. The
    # cost block above asserts the other half, that the absent key is also an absent query.
    # @intent: { entity: "repository unannotated_examples map block", action: "omit the map by default", behavior: "the map key is present but null when the requesting flag was not sent", layer: "request" }
    it "is null — with the key present — when the flag was not sent" do
      body = get_repository

      expect(body["latest_run"]).to have_key("unannotated_directories")
      expect(body.dig("latest_run", "unannotated_directories")).to be_nil
      # And a malformed flag is no ask at all, the same answer the worklist gives it.
      expect(debt_map(query: { unannotated_examples: ["true"] })).to be_nil
      # The sibling rollup that is NOT behind this gate is unaffected, which is what says the gate is
      # this key's rather than the endpoint's.
      expect(body.dig("latest_run", "spec_directories", "rows")).to be_present
    end

    # THE OTHER WAY THIS KEY IS NULL, and the one the flag cannot explain: a run that recorded no
    # per-example rows AT ALL has no per-area grain to rank, which is `UnannotatedDirectories#recorded?`
    # rather than the gate the example above pins. The whole pre-SPGD-255 corpus is that run, plus
    # every client that sends no per-example detail.
    #
    # BOTH HALVES IN ONE EXAMPLE, on the same reasoning as the scope-disagreement pin further up: this
    # is the second place these two keys of one block answer differently, and only the pair says which
    # difference is being asserted. The sibling's `recorded_count: 0` is ambiguous by construction, and
    # this `null` is what discriminates it — so the second half below reaches the SAME zero from a run
    # that did record rows and gets the map PRESENT. That is the discrimination the null buys, and it
    # is why a serializer "fixing" this disagreement into `rows: []` would be taking something away.
    # @intent: { entity: "repository unannotated worklist and map", action: "separate map from worklist", behavior: "a run with no per-example rows leaves the map null while the worklist still answers with its own block, and the worklist block is null with its key present whenever the client did not ask for it", layer: "request" }
    it "is null for a run with no per-example rows, while the worklist answers with a block" do
      bare = separate_repository("acme/no-observations")
      create_test_run(repository: bare, commit_sha: "norows000623", duration_seconds: 42.5)
      run = latest_run(key: bare.api_keys.create!, query: ask)

      # Asserted as the REASON rather than the null alone — the rule the sibling blocks' own bare-run
      # examples state: a hard-coded `be_nil` here keeps passing if the guard stops being `#recorded?`
      # and becomes something else that happens to be false on this fixture.
      expect(bare.latest_test_run.spec_observations).to be_empty
      expect(run).to have_key("unannotated_directories")
      expect(run["unannotated_directories"]).to be_nil
      # The disagreement itself: the worklist answered the SAME run, under the SAME ask, with a block.
      expect(run["unannotated_examples"]).not_to be_nil
      expect(run.dig("unannotated_examples", "recorded_count")).to eq(0)

      # And the same zero from a run that recorded rows and has nothing left to annotate — map
      # present. The two keys read TOGETHER separate "nothing left to do" from "nothing was recorded";
      # neither key separates them alone, which is the whole of why the two nulls are spelled apart.
      done = separate_repository("acme/annotated-not-bare")
      ingest(done, [annotated_spec(file_path: annotated_file, line_number: 4)])
      done_run = latest_run(key: done.api_keys.create!, query: ask)

      expect(done_run.dig("unannotated_examples", "recorded_count")).to eq(0)
      expect(done_run["unannotated_directories"]).not_to be_nil
      expect(done_run.dig("unannotated_directories", "rows"))
        .to eq([{ "path" => "spec/models", "unannotated_count" => 0, "recorded_count" => 1,
                  "authored_count" => 1, "derived_count" => 0, "unreadable_count" => 0 }])
    end
  end

  # AC3. The distinction this key must not collapse — and the sharpest instance of it on the block,
  # because the empty answer here is not a stale bookmark or a deleted file but the STATE THE METRIC
  # EXISTS TO REACH.
  describe "the two ways this key can be empty" do
    # @intent: { entity: "repository unannotated_examples drill-ins", action: "distinguish block spellings", behavior: "the two drill-in flags are spelled differently in the response so a client can tell which block it received, and the worklist block is null with its key present whenever the client did not ask for it", layer: "request" }
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
    # @intent: { entity: "repository unannotated_directories worklist", action: "serve empty when clean", behavior: "a fully annotated run yields a present block with zero rows rather than a null block", layer: "request" }
    it "is a present block with no rows when the run is fully annotated" do
      done = separate_repository("acme/fully-annotated")
      ingest(done, [annotated_spec(file_path: annotated_file, line_number: 4),
                    annotated_spec(file_path: annotated_file, line_number: 30, entity: "Invoice")])
      key = done.api_keys.create!

      expect(block(key: key, query: ask))
        .to eq("spec_file" => nil, "spec_directory" => nil, "rows" => [], "recorded_count" => 0,
               "derived_count" => 0, "unreadable_count" => 0,
               "limit" => SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      expect(response).to have_http_status(:ok)
      # And the run really is fully annotated, so the zero is the success state rather than an empty
      # fixture — the reconciliation of AC2 read from the other end.
      expect(latest_run(key: key, query: ask)["annotated_ratio"]).to eq(1.0)
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent.
    # @intent: { entity: "repository unannotated_examples drill-ins", action: "distinguish block spellings", behavior: "the two drill-in flags are spelled differently in the response so a client can tell which block it received, and a call with no run selector describes the repository newest run", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples drill-ins", action: "omit block without CI", behavior: "when CI has never reported, the block is served not at all rather than as an empty shell", layer: "request" }
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

    # @intent: { entity: "GET /api/v1/repository", action: "default to newest run", behavior: "a call with no run selector describes the repository newest run", layer: "request" }
    it "describes the repository's newest run on a default call" do
      served = block(query: ask)

      expect(served["recorded_count"]).to eq(1)
      expect(served["rows"].map { it["name"] }).to eq(["Refund is idempotent"])
      expect(get_repository(query: ask).dig("run_anchor", "commit_sha")).to eq("feedfacecafe0002")
    end

    # @intent: { entity: "GET /api/v1/repository", action: "select run by commit", behavior: "the commit_sha parameter moves the drill-ins to the named run like the other run-grain selectors", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples flag", action: "accept string values", behavior: "an unannotated_examples parameter supplied as a string is honoured rather than rejected", layer: "request" }
    it "honours an unannotated_examples that IS a string" do
      expect(block(query: ask)["rows"].length).to eq(3)
    end

    # An empty ask is no ask: `?unannotated_examples=` is what a browser sends for an unfilled form
    # field and what a client building a query string off a nil variable sends, and an ask has to be
    # affirmative rather than merely present in the URL.
    # @intent: { entity: "repository unannotated_examples flag", action: "ignore empty values", behavior: "an empty unannotated_examples parameter is treated as no ask and no block is opened", layer: "request" }
    it "treats an empty unannotated_examples as no ask" do
      expect(block(query: { unannotated_examples: "" })).to be_nil
    end

    # ⭐ THE VALUE IS NOT READ, AND THAT INCLUDES `false`. What is tested is that the client NAMED the
    # parameter — the alternative, a truthiness vocabulary, would be a third line of guard no sibling
    # has and would spell "a word you do not recognise" and "a shape that is not a String" the same
    # way. A client that does not want the block omits the parameter, which is how it declines the
    # other six. Pinned so a later reader does not "fix" this into a boolean cast.
    # @intent: { entity: "repository unannotated_examples flag", action: "open on any non-blank", behavior: "any non-blank string opens the block, including the literal word false", layer: "request" }
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
    # @intent: { entity: "repository unannotated_examples endpoint", action: "charge queries only when asked", behavior: "exactly two queries are added when the blocks are requested and none when they are not", layer: "request" }
    it "adds exactly two queries when asked — the worklist and the map — and none when not" do
      # Warmed first, on the precedent every sibling cost block sets: the very first request of an
      # example pays for state a second one does not — an API key's first use is recorded — and a
      # baseline taken over it would be measuring the warm-up rather than the block.
      get_repository
      baseline = count_queries { get_repository }

      # TWO, not one, and the second is the RANKING the worklist sits under — served from this same
      # flag rather than from a parameter of its own, which is the whole reason the number moved. The
      # rule the figure pins is unchanged and is the one that matters: the gate is the ASK, decided
      # before any read, so a client that never sends the flag pays for NEITHER block.
      expect(count_queries { get_repository(query: ask) }).to eq(baseline + 2)
      # And a malformed shape is no ask, which means it is also no query — the guard sits in front of
      # both reads rather than inside either.
      expect(count_queries { get_repository(query: { unannotated_examples: ["true"] }) })
        .to eq(baseline)
    end

    # The same bound classified rather than counted, so "two more queries" cannot be satisfied by a
    # different grain reading twice while these two read none. `unannotated_examples_grain_reads`,
    # `unannotated_directories_grain_reads` and the partition they belong to come from
    # spec/support/observation_grain_reads.rb, which is also where the argument for matching every
    # grain POSITIVELY is made — and where the debt ranking's separation from the two OTHER reads
    # that group by the same directory expression is argued.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "read once per block", behavior: "spec_observations is read once per served block and no other query grain is disturbed", layer: "request" }
    it "reads spec_observations once per block it serves, and leaves every other grain alone" do
      area, file, example, description, flakiness, growth, directory_files, file_examples,
        description_examples, _dfg, _rtg, _dfrtg, unstable_test_runs, unannotated, debt, readings =
        observation_reads_by_grain { get_repository(query: ask) }

      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length, directory_files.length, file_examples.length,
              description_examples.length, unstable_test_runs.length, unannotated.length,
              debt.length])
        .to eq([1, 1, 2, 2, 0, 0, 0, 0, 0, 0, 1, 1])
      # ⭐ AND THE RUN-GRAIN READINGS, WHICH IS THE ONE GRAIN HERE THAT IS NOT BEHIND AN ASK.
      # `latest_run.intent_readings` is served on every request, because a correction a client has to
      # opt into leaves that client reading the subtraction the whole key exists to replace. So it is
      # ONE read whether or not the flag was sent, and the two totals below carry it.
      expect(readings.length).to eq(1)
      expect(run_readings_grain_reads { get_repository }.length).to eq(1)
      # ⭐ THE AREA GRAIN IS STILL ONE. The debt ranking GROUPS BY the same `DIRECTORY_EXPRESSION`
      # the by-wall-clock area rollup does — the one expression on this table that cannot be
      # un-shared — so a partition that told them apart by their grouping would count this read
      # twice and the by-duration rollup's own pin would read `2`. They are separated on what they
      # RANK BY, and this is the assertion that says the separation held.
      expect(area.length).to eq(1)
      # And the classified reads are ALL of them — the assertion no per-grain count can make, because
      # a read matching no grain's pattern is invisible to every one of them.
      expect(observation_reads { get_repository(query: ask) }.length)
        .to eq(classified_observation_reads { get_repository(query: ask) })
      expect(observation_reads { get_repository(query: ask) }.length).to eq(9)
      # Seven without the ask — the total `repository_latest_run_spec.rb` pins for this endpoint,
      # restated here as the thing this slice did NOT change. It went from six to seven when
      # `intent_readings` landed, which is the ONE ungated read this file's slice added.
      expect(observation_reads { get_repository }.length).to eq(7)
      expect(unannotated_examples_grain_reads { get_repository }).to be_empty
      expect(unannotated_directories_grain_reads { get_repository }).to be_empty
    end

    # The drill-ins compose without either being classified as the other — this one against the
    # bottom rung of the area → file → example ladder, which is the sibling whose read also lists this
    # table's rows with a window count riding on them.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "keep drill-in grains apart", behavior: "asking for both drill-ins at once still reads each block in its own separate grain", layer: "request" }
    it "keeps the two drill-ins in their own grains when both are asked for at once" do
      query = ask.merge(spec_file: other_file)

      grains = observation_reads_by_grain { get_repository(query: query) }

      expect([grains[7].length, grains[13].length, grains[14].length, grains[15].length])
        .to eq([1, 1, 1, 1])
      expect(observation_reads { get_repository(query: query) }.length)
        .to eq(classified_observation_reads { get_repository(query: query) })
      expect(observation_reads { get_repository(query: query) }.length).to eq(10)
    end

    # The suite-size axis, and the one that decides whether this key is affordable at the roadmap's
    # 20,000-example design point: BOTH reads are bounded by the size of the RUN and capped, so the
    # just-installed repository whose every example is unannotated costs the same two queries as this
    # file's five-row fixture. A serializer that fetched the rows and counted them in Ruby, or that
    # took a second pass for either population, reads as more here and as more again as the suite
    # grows. The map is the one to watch: it is a GROUPED AGGREGATE over the whole run rather than a
    # capped scan, and its cap cuts the GROUPS rather than the rows it aggregates.
    # @intent: { entity: "repository unannotated_examples endpoint", action: "stay flat in block cost", behavior: "each block is read exactly once regardless of how many unannotated examples the run holds", layer: "request" }
    it "reads each block once however many unannotated examples the run holds" do
      big = separate_repository("acme/wide-run")
      ingest(big, Array.new(400) do |index|
        unannotated_spec(file_path: "spec/models/thing_#{format('%03d', index)}_spec.rb",
                         line_number: index + 1, duration: 0.1, outcome: "passed",
                         name: "Thing #{index} does its job")
      end)
      key = big.api_keys.create!

      get_repository(key: key)
      baseline = count_queries { get_repository(key: key) }

      expect(count_queries { get_repository(key: key, query: ask) }).to eq(baseline + 2)
      expect(block(key: key, query: ask)["recorded_count"]).to eq(400)
      expect(block(key: key, query: ask)["rows"].length)
        .to eq(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      # The 400 examples sit in ONE area, so the map is one row carrying all of them — the grouped
      # read is bounded by the run's DIRECTORIES where the worklist is bounded by its rows.
      expect(debt_map(key: key, query: ask)["rows"])
        .to eq([{ "path" => "spec/models", "unannotated_count" => 400, "recorded_count" => 400,
                  "authored_count" => 0, "derived_count" => 0, "unreadable_count" => 400 }])
    end
  end
end
