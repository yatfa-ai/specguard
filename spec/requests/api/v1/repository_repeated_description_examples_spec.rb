# frozen_string_literal: true

require "rails_helper"

# The `latest_run.repeated_description_examples` block on `GET /api/v1/repository` — ONE repeated
# description, opened, and the agent-readable twin of the "Examples under this description" panel
# `repositories#show` renders under `?repeated_description=`.
#
# THE THIRD DRILL-IN AND THE ONE THAT LEAVES THE LADDER. Its two sibling files
# — `repository_spec_directory_files_spec.rb` and `repository_spec_file_examples_spec.rb` — pin the
# middle and bottom rungs of area → file → example, which are three grains of the same question:
# where does the code LIVE. This block answers a different one. `latest_run.repeated_descriptions`
# reports that a description is carried by four examples costing six seconds between them and names
# the files they ran in, and `files_seen` is where it stops: a string array a client can read and
# cannot act on.
#
# The fixture below is built so that every substitute already on the endpoint visibly fails:
#
#   - `latest_run.slowest_examples` is the run-wide top ten, and here those ten are every row of
#     `spec/requests/checkout_spec.rb` — not one member of the opened group.
#   - `latest_run.spec_file_examples` over each path in `files_seen` is N unrelated lists, each
#     capped by DURATION, and here the group's own rows are outranked inside their own files by
#     examples that have nothing to do with the description.
#   - `latest_run.repeated_descriptions` names the group and its files and lists no member of it.
#
# Its own file, on the precedent both sibling drill-in specs state: every example here needs a
# fixture in which the opened GROUP spans two files and is not the run's slowest anything, under a
# query parameter no other block on this endpoint reads, while every block in
# `repository_latest_run_spec.rb` is a fact about one run served on every request.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never inserted
# by hand — the rule every sibling here states, and for the same reason: an untimed example is
# `result&.run_time` coming back nil on a real client, two examples sharing a description in one run
# is what the recorder produces from a table-driven loop, and a shared example group is a real
# payload's `file_path` and `spec_file_path` disagreeing.
RSpec.describe "GET /api/v1/repository — latest_run.repeated_description_examples", type: :request do
  # Signed in as well as keyed, because one example reads the HTML panel and the JSON block off the
  # same run and compares them row for row. The owner is the same user on both surfaces, so the two
  # cannot be looking at two repositories.
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  # `query:` rather than a `repeated_description:` keyword, so an example can send the shapes a real
  # client's malformed query string parses into — an Array, a nested hash — the same way it sends a
  # description.
  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def block(**) = get_repository(**).dig("latest_run", "repeated_description_examples")

  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `name:`, `duration:` and `outcome:` are passed at every call site, nils
  # included — the description IS the subject of this block, and an untimed member is the state
  # several assertions below turn on, while the shared builder defaults all three to a value a real
  # client does not always send.
  #
  # Every keyword goes THROUGH the shared builder rather than over the top of its result: that
  # builder derives `id` and `spec_file_path` from the `file_path` it was called with, so a
  # `file_path` merged in afterwards leaves an example claiming one file and filed under another.
  def example_spec(file_path:, line_number:, duration:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration, **attrs)
  end

  # The fixture names are METHODS and deliberately not constants: a constant assigned inside an
  # `RSpec.describe` block opens no constant scope and lands on `Object`, where a sibling spec file
  # assigning the same name would decide the value BOTH files read at run time.
  def order_spec = "spec/models/order_spec.rb"

  def refund_spec = "spec/requests/refunds_spec.rb"

  def billable_shared = "spec/support/shared_examples/billable.rb"

  # The description this whole file opens, and every disagreement between its four rows is
  # load-bearing:
  #
  #   - Four examples, THREE of them timed, so `recorded_count` and `timed_count` are different
  #     figures and a serializer serving either twice under two names is red.
  #   - They span TWO spec files, which is the shape no rung of area → file → example can hold: this
  #     group is not inside any one file, and following `files_seen` into `?spec_file=` opens two
  #     lists neither of which is it.
  #   - One row is a SHARED EXAMPLE GROUP: its `file_path` is the group's file and its
  #     `spec_file_path` is the file that ran it, and the two disagree — the row that fails a
  #     serializer serving one path under both names.
  #   - One row is UNTIMED and `pending`, so `duration_seconds` must arrive as `null` rather than as
  #     `0.0`, and it sorts to the END of the list rather than to the head of it.
  #   - The outcomes are three different words, so a block serving a constant is red.
  def looped = "settles the balance"

  # A second repeated description to be wrong about, and a unique one so `HAVING COUNT(*) > 1` in the
  # ranking above has something real to exclude.
  def other = "refuses a negative quantity"

  # The run-wide slowest ten, and every one of them is in ANOTHER file under ANOTHER description: ten
  # examples at 8.1s and up, against the opened group's heaviest at 4.0s. So `slowest_examples` holds
  # not one member of the group, and a client that tried to reach this list by filtering that ranking
  # gets nothing at all — the non-derivability this key exists for, made visible in the response
  # itself.
  def checkout_examples
    Array.new(SpecObservation::SLOWEST_LIMIT) do |index|
      example_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 100 + index,
                   duration: 9.0 - (index * 0.1), outcome: "passed",
                   name: "Checkout step #{index}")
    end
  end

  let!(:test_run) do
    ingest(repository,
           [example_spec(file_path: order_spec, line_number: 4, duration: 4.0, outcome: "passed",
                         name: looped),
            example_spec(file_path: order_spec, line_number: 12, duration: 1.5, outcome: "failed",
                         name: looped),
            # The shared example group: DEFINED in `billable.rb`, RUN by `refunds_spec.rb` — which is
            # also what makes this group span two files.
            example_spec(file_path: billable_shared, spec_file_path: refund_spec, line_number: 7,
                         duration: 0.5, outcome: "passed", name: looped),
            example_spec(file_path: order_spec, line_number: 20, duration: nil, outcome: "pending",
                         name: looped),
            # A second repeated description in the SAME file, heavier than every member of the opened
            # group — so `?spec_file=` over the group's own file ranks these above its rows, and a
            # block fed by that key would answer with them.
            example_spec(file_path: order_spec, line_number: 30, duration: 7.0, outcome: "passed",
                         name: other),
            example_spec(file_path: order_spec, line_number: 31, duration: 6.5, outcome: "passed",
                         name: other),
            # A description carried by exactly one example, which the ranking above excludes and this
            # drill-in must still be able to open.
            example_spec(file_path: order_spec, line_number: 40, duration: 1.0, outcome: "passed",
                         name: "is valid with a customer"),
            *checkout_examples])
  end

  describe "a description that was asked for" do
    # AC2. The block exists, its rows carry the six operands the endpoint's other two per-example
    # blocks already serve, and the GROUP's two population figures sit beside them. The array is
    # asserted as a SEQUENCE — `eq`, not `match_array` — because "slowest first, untimed last" is
    # half of what this key promises, and the untimed row's position is the half a set comparison
    # drops.
    it "lists that description's examples slowest-first, untimed last, with what each row is" do
      expect(block(query: { repeated_description: looped })).to eq(
        "name" => looped,
        "rows" => [
          { "name" => looped, "file_path" => order_spec, "line_number" => 4,
            "spec_file_path" => order_spec, "duration_seconds" => 4.0, "outcome" => "passed" },
          { "name" => looped, "file_path" => order_spec, "line_number" => 12,
            "spec_file_path" => order_spec, "duration_seconds" => 1.5, "outcome" => "failed" },
          { "name" => looped, "file_path" => billable_shared, "line_number" => 7,
            "spec_file_path" => refund_spec, "duration_seconds" => 0.5, "outcome" => "passed" },
          { "name" => looped, "file_path" => order_spec, "line_number" => 20,
            "spec_file_path" => order_spec, "duration_seconds" => nil, "outcome" => "pending" }
        ],
        "recorded_count" => 4,
        "timed_count" => 3,
        "limit" => SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT
      )
    end

    # AC5. The sub-block's own key set, stated as its subject rather than pinned as a side effect of
    # the `eq` above — the pattern both sibling drill-in contracts set, and for the same reason: a
    # guard whose stated subject IS the key set survives a fixture whose numbers change, and says out
    # loud what a new key owes this block before it ships.
    it "serves exactly the repeated_description_examples keys this contract pins" do
      served = block(query: { repeated_description: looped })

      expect(served.keys)
        .to contain_exactly("name", "rows", "recorded_count", "timed_count", "limit")
      expect(served["rows"].first.keys)
        .to contain_exactly("name", "file_path", "line_number", "spec_file_path",
                            "duration_seconds", "outcome")
    end

    # AC5 again, and the assertion neither block's own contract can make alone: this endpoint now has
    # THREE per-example blocks describing the same rows of the same table, and a client that learned
    # to read one must not have to learn a second shape to read the others. Read off the RESPONSE, so
    # it is the endpoint's own blocks agreeing rather than three hand-written lists agreeing with
    # each other.
    it "serves the same per-example row shape as both of the endpoint's other example blocks" do
      body = get_repository(query: { repeated_description: looped,
                                     spec_file: order_spec })["latest_run"]

      shape = body.dig("repeated_description_examples", "rows").first.keys

      expect(body.dig("slowest_examples", "rows").first.keys).to contain_exactly(*shape)
      expect(body.dig("spec_file_examples", "rows").first.keys).to contain_exactly(*shape)
    end

    # THE assertion that fails the moment this block is fed by any per-example surface already here.
    # Every figure is taken off the RESPONSE: the run-wide slowest ten hold no member of the group,
    # the by-file drill-in over the group's own file ranks a different description above its rows,
    # and the ranking this drills out of names the files without listing anything in them.
    it "lists examples no other block on this endpoint can be filtered down to" do
      body = get_repository(query: { repeated_description: looped,
                                     spec_file: order_spec })["latest_run"]

      expect(body.dig("slowest_examples", "rows").map { it["name"] }).not_to include(looped)
      expect(body.dig("slowest_examples", "rows").map { it["spec_file_path"] })
        .to all(eq("spec/requests/checkout_spec.rb"))
      # The group's own file, opened: its heaviest rows are the OTHER description's, so a client
      # following `files_seen` into `?spec_file=` reads a list this group's members do not head.
      expect(body.dig("spec_file_examples", "rows").first["name"]).to eq(other)
      # And the ranking above names the two files and lists no row of either.
      group = body.dig("repeated_descriptions", "rows").find { it["name"] == looped }
      expect(group["files_seen"]).to contain_exactly(order_spec, refund_spec)
      expect(group).not_to have_key("rows")
      # Which is the whole point: the block below IS those rows.
      expect(body.dig("repeated_description_examples", "rows").length).to eq(group["recorded_count"])
    end

    # The grain no rung of area → file → example can hold. This group is not inside any one file, so
    # there is no `?spec_file=` ask that returns it and no `?spec_directory=` ask either — the two
    # files sit in different areas.
    it "lists a group whose members span two files and two areas" do
      served = block(query: { repeated_description: looped })

      expect(served["rows"].map { it["spec_file_path"] })
        .to contain_exactly(order_spec, order_spec, order_spec, refund_spec)
      expect(served["rows"].map { it["spec_file_path"] }.uniq.length).to eq(2)
    end

    # The row that separates "the file an example is IN" from "the file that RAN it". A serializer
    # serving one path under both names satisfies every other example in this file and fails here.
    it "names the definition site and the including file apart, for a shared example group" do
      shared = block(query: { repeated_description: looped })["rows"].find { it["line_number"] == 7 }

      expect(shared["file_path"]).to eq(billable_shared)
      expect(shared["spec_file_path"]).to eq(refund_spec)
      expect(shared["file_path"]).not_to eq(shared["spec_file_path"])
    end

    # The untimed row is LISTED rather than excluded, and its nil is served as one. A `0.0` here
    # would assert an example that cost nothing, which is a measurement nobody took — and at this
    # grain that row is often exactly the row a reader came for, because a test that never ran is one
    # way three examples come to say the same thing.
    it "serves a null duration for an example that reported none, never a zero" do
      rows = block(query: { repeated_description: looped })["rows"]

      expect(rows.last["duration_seconds"]).to be_nil
      expect(rows.last["outcome"]).to eq("pending")
      expect(rows.map { it["duration_seconds"] }).to eq([4.0, 1.5, 0.5, nil])
    end

    # The block's standing rule, asserted over the whole serialized sub-block rather than per key:
    # `SpecObservation#duration_label`, `#outcome_label` and
    # `RepeatedDescriptionExamples#coverage_label` are each one call away in the object this reads
    # from, and any of them would still satisfy the assertions above if the fixture's values happened
    # to render similarly.
    it "serves numbers and words, never the panel's labels" do
      served = block(query: { repeated_description: looped })

      expect(served.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(served["rows"].map { it["duration_seconds"] }).to all(be_a(Float).or(be_nil))
      expect(served["rows"].map { it["line_number"] }).to all(be_a(Integer))
      expect(served["recorded_count"]).to be_a(Integer)
      expect(served["timed_count"]).to be_a(Integer)
    end

    # OPERANDS, NOT PREDICATES. The object answers `#truncated?`, `#complete?`, `#any_timed?` and
    # `#lists_untimed?`, and each is a COMPARISON between two figures this block already serves. A
    # client words them; the endpoint does not ship the comparison instead of the numbers.
    it "ships no caption predicate a client can compute from the operands" do
      served = block(query: { repeated_description: looped })

      expect(served.keys).not_to include("truncated", "complete", "any_timed", "lists_untimed",
                                         "untimed_count", "coverage_label")
      # And every one of them IS reachable from what was served, which is what makes the absence a
      # choice rather than a gap.
      expect(served["recorded_count"] > served["rows"].length).to be(false)
      expect(served["recorded_count"] - served["timed_count"]).to eq(1)
    end

    # A description carried by exactly ONE example is excluded from the ranking above by
    # `HAVING COUNT(*) > 1` and is still an ordinary ask here: the parameter is a description, not a
    # row of that ranking, and a reader who types one gets the answer rather than an empty block.
    it "opens a description the ranking above excludes" do
      served = block(query: { repeated_description: "is valid with a customer" })

      expect(served["rows"].map { it["line_number"] }).to eq([40])
      expect(served["recorded_count"]).to eq(1)
      expect(get_repository.dig("latest_run", "repeated_descriptions", "rows").map { it["name"] })
        .not_to include("is valid with a customer")
    end
  end

  # AC1/AC3. The distinction this key must not collapse, and it now shares it with two siblings on
  # this block: the five rollups are served unconditionally and gate on `#recorded?`, while these
  # three answer a question the CLIENT asked. Copying that gate here would spell "you did not ask"
  # and "the description you asked about has no rows" the same way — the collapse
  # `serialized_history` already refuses for an unknown `?branch=`, where the ask is RESTATED beside
  # a zero rather than answered with somebody else's rows.
  describe "the two ways this key can be empty" do
    it "is null — with the key present — when no description was asked for" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to have_key("repeated_description_examples")
      expect(body.dig("latest_run", "repeated_description_examples")).to be_nil
      # The rest of `latest_run` is untouched by the absence: this key is added BESIDE the eight
      # blocks that were there before it, never in place of any of them.
      expect(body.dig("latest_run", "slowest_examples", "rows").length)
        .to eq(SpecObservation::SLOWEST_LIMIT)
      expect(body.dig("latest_run", "repeated_descriptions", "rows")).to be_present
    end

    # AC3. A description the run recorded nothing under is an ordinary answer and never an error: the
    # ask is restated, the list is empty, both counts are an honest zero, and the status is 200.
    it "is a present block with no rows, naming the description, when the run recorded none" do
      served = block(query: { repeated_description: "reconciles the ledger" })

      expect(response).to have_http_status(:ok)
      expect(served).to eq("name" => "reconciles the ledger", "rows" => [],
                           "recorded_count" => 0, "timed_count" => 0,
                           "limit" => SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent, because the second never wears the
    # first's spelling.
    it "spells the two differently, so a client can tell which one it got" do
      expect(block).to be_nil
      expect(block(query: { repeated_description: "reconciles the ledger" })).not_to be_nil
      expect(block(query: { repeated_description: "reconciles the ledger" })["name"])
        .to eq("reconciles the ledger")
    end

    # A near miss is one of the ordinary ways to arrive at the empty answer — a test renamed since, a
    # description reworded, a stale bookmark — and none of them is an error or a prefix match onto
    # the description it nearly is.
    it "answers a reworded description with the empty block rather than an error or a prefix match" do
      served = block(query: { repeated_description: "settles the balances" })

      expect(response).to have_http_status(:ok)
      expect(served["rows"]).to eq([])
      expect(served["name"]).to eq("settles the balances")
    end

    # There is no `latest_run` at all for a repository whose CI has never reported, so the ask cannot
    # conjure one — the rule the whole block follows, restated here because this is one of the three
    # keys on it a client can ask for by name.
    it "serves no block at all when CI has never reported" do
      silent = create_repository(user: @user, github_full_name: "acme/never-ran")

      body = get_repository(key: silent.api_keys.create!, query: { repeated_description: looped })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC4. The shapes a query string can legally parse into that are NOT a description, pinned once for
  # every surface in `spec/support/shared_examples/malformed_repeated_description_param.rb`. This one
  # reaches `where(name: …)` on a plain text column, where an Array does not raise at all: it becomes
  # an `IN` list and answers about SEVERAL descriptions under a `name` restating one — and at this
  # grain the wrong answer is particularly hard to catch, because a list of examples carrying two
  # different descriptions looks exactly like the repetition the block exists to show.
  describe "a repeated-description parameter that is not a description" do
    # The NO-ASK answer specifically, and not merely a 200 — the shared example's own comment
    # requires it, because a guard that swallowed every value would answer 200 on all three shapes
    # too.
    def expect_repeated_description_param_treated_as_no_ask(query)
      expect(block(query: query)).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed repeated-description parameter as no ask"

    # THE positive path, beside the group, which is what separates "the guard read the parameter"
    # from "the endpoint ignores this parameter entirely".
    it "honours a repeated_description that IS a description" do
      expect(block(query: { repeated_description: looped })["rows"].length).to eq(4)
    end

    # An empty ask is no ask, not a comparison against the empty string. `spec_observations.name` is
    # NULLABLE — which is why the ranking above excludes unnamed rows in SQL — so without `.presence`
    # an empty ask would become `WHERE name = ''`, a query for a description no row can carry and
    # therefore a block guaranteed to be empty. That is a worse answer than not opening one.
    it "treats an empty repeated_description as no ask" do
      expect(block(query: { repeated_description: "" })).to be_nil
    end
  end

  # AC1/AC2. The cost, and the axis this key shares with its two drill-in siblings: the rollups issue
  # their reads unconditionally, so `#recorded?` is an answer DERIVED from a read that was paid for
  # anyway. Here the gate is the ASK and it is decided before any query is issued, so a client that
  # never sends the parameter pays nothing at all for the key's existence.
  describe "what the drill-in costs the endpoint" do
    it "adds exactly one query when asked, and none when not" do
      # Warmed first, on the precedent the sibling cost blocks set: the very first request of an
      # example pays for state a second one does not — an API key's first use is recorded — and a
      # baseline taken over it would be measuring the warm-up rather than the block.
      get_repository
      baseline = count_queries { get_repository }

      expect(count_queries { get_repository(query: { repeated_description: looped }) })
        .to eq(baseline + 1)
      # The empty answer costs the same one: the read is what DISCOVERS that the run recorded nothing
      # under the description, so there is no cheaper way to ask and no gate in front of it to add.
      expect(count_queries { get_repository(query: { repeated_description: "reconciles the ledger" }) })
        .to eq(baseline + 1)
      # And a malformed shape is no ask, which means it is also no query — the guard sits in front of
      # the read rather than inside it.
      expect(count_queries { get_repository(query: { repeated_description: [looped] }) })
        .to eq(baseline)
    end

    # AC1/AC2 as a CLASSIFIED bound rather than a counted one, so "one more query" cannot be
    # satisfied by a different grain reading twice while this one reads none.
    # `repeated_description_examples_grain_reads` and the partition it belongs to come from
    # spec/support/observation_grain_reads.rb, which is also where the argument for matching every
    # grain POSITIVELY is made — and where this grain's pattern is separated from the per-example
    # ranking's and the file drill-in's, both of which also rank this table by duration.
    it "reads spec_observations once for its own grain, and leaves every other grain alone" do
      area, file, example, description, flakiness, growth, directory_files, file_examples,
        repeated_description_examples =
        observation_reads_by_grain { get_repository(query: { repeated_description: looped }) }

      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length, directory_files.length, file_examples.length,
              repeated_description_examples.length])
        .to eq([1, 1, 2, 2, 0, 0, 0, 0, 1])
      # And the classified reads are ALL of them — the assertion no per-grain count can make, because
      # a read matching no grain's pattern is invisible to every one of them.
      expect(observation_reads { get_repository(query: { repeated_description: looped }) }.length)
        .to eq(classified_observation_reads { get_repository(query: { repeated_description: looped }) })
      expect(observation_reads { get_repository(query: { repeated_description: looped }) }.length)
        .to eq(7)
      # Six without the ask — the total `repository_latest_run_spec.rb` pins for this endpoint,
      # restated here as the thing this slice did NOT change, and asserted against THIS grain rather
      # than against a bare total.
      expect(observation_reads { get_repository }.length).to eq(6)
      expect(repeated_description_examples_grain_reads { get_repository }).to be_empty
    end

    # The three drill-ins compose without any of them being classified as another — the pairing that
    # the partition's own separation of these patterns exists to make assertable, and the shape no
    # single-ask block above can speak for. Nine reads: the six, plus one per ask.
    it "keeps the three drill-ins in their own grains when all are asked for at once" do
      query = { repeated_description: looped, spec_file: order_spec, spec_directory: "spec/models" }

      _area, _file, _example, _description, _flakiness, _growth, directory_files, file_examples,
        repeated_description_examples = observation_reads_by_grain { get_repository(query: query) }

      expect([directory_files.length, file_examples.length,
              repeated_description_examples.length]).to eq([1, 1, 1])
      # And the classified reads are ALL of them — asserted HERE most of all. This fixture runs the
      # MOST GRAINS NON-ZERO of any in the suite — SEVEN of the nine at once — so it is where a
      # cross-grain misclassification is most observable. That is the measure under which it leads,
      # and naming it matters because the other one disagrees: by TOTAL reads the single-ask blocks
      # in `repository_unstable_tests_spec.rb` and `repository_directory_growth_spec.rb` issue 11 and
      # 10 against the 9 below. The `eq([1, 1, 1])` above covers the three drill-ins alone — the
      # other six grains are destructured to `_` deliberately — and the bare `9` below is exactly the
      # total that spec/support/observation_grain_reads.rb argues cannot tell "one aggregate per
      # grain" from "one grain reading twice". Without this line a read adopted into another grain,
      # or matching no grain at all, is invisible to every assertion here.
      expect(observation_reads { get_repository(query: query) }.length)
        .to eq(classified_observation_reads { get_repository(query: query) })
      expect(observation_reads { get_repository(query: query) }.length).to eq(9)
    end

    # The suite-size axis, and the one that decides whether this key is affordable at the roadmap's
    # 20,000-example design point: the read is bounded by the size of the GROUP within one run and
    # capped, so a group of 4 and one of 300 cost the same single query. A serializer that fetched
    # the run's rows and filtered them in Ruby reads as more here and as more again as the suite
    # grows.
    it "reads it once however many examples the description carries" do
      big = create_repository(user: @user, github_full_name: "acme/wide-group")
      ingest(big, Array.new(300) do |index|
        example_spec(file_path: order_spec, line_number: index + 1, duration: 0.5,
                     outcome: "passed", name: looped)
      end)
      key = big.api_keys.create!

      get_repository(key: key)
      baseline = count_queries { get_repository(key: key) }

      expect(count_queries { get_repository(key: key, query: { repeated_description: looped }) })
        .to eq(baseline + 1)
      expect(block(key: key, query: { repeated_description: looped })["recorded_count"]).to eq(300)
    end
  end

  # AC6. The list is capped by its OWN constant — not the by-file drill-in's fifty and not the
  # by-area one's twenty-five — and a capped list that does not disclose its cap is the lie
  # `RepeatedDescriptionExamples#truncated?` refuses on the panel. The GROUP's population has to come
  # from the read's windows rather than from the rows on hand, which are the truncated figure.
  describe "a description carrying more examples than the limit" do
    # 30 recorded, 27 of them timed, against a cap of 25 — so BOTH population figures exceed
    # `rows.size` and neither can be the page's figure wearing the group's name. The three untimed
    # rows sort last and are cut off the page entirely, which is the shape that makes the second
    # figure independent of the first rather than a copy of it.
    let(:capped) do
      repo = create_repository(user: @user, github_full_name: "acme/capped-group")
      ingest(repo, Array.new(30) do |index|
        example_spec(file_path: order_spec, line_number: index + 1,
                     duration: index < 27 ? (index + 1) * 0.5 : nil,
                     outcome: "passed", name: looped)
      end)
      repo
    end

    it "serves the limit's worth of rows, and says how many examples the description carries" do
      served = block(key: capped.api_keys.create!, query: { repeated_description: looped })

      expect(served["rows"].length).to eq(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
      expect(served["limit"]).to eq(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
      # Counted over the GROUP and not over the page, which on a truncated group are different
      # populations — and BOTH figures are larger than the page, so neither can have been folded out
      # of the serialized rows.
      expect(served["recorded_count"]).to eq(30)
      expect(served["timed_count"]).to eq(27)
      expect(served["recorded_count"]).to be > served["rows"].length
      expect(served["timed_count"]).to be > served["rows"].length
      # Every row on the page is timed, so the untimed three are not merely at the end of the list —
      # they are off it entirely, which is the case a client folding `rows` would report as zero.
      expect(served["rows"].map { it["duration_seconds"] }).to all(be_a(Float))
    end

    # `REPEATED_DESCRIPTION_EXAMPLES_LIMIT` is its own constant and the neighbouring caps are
    # different numbers, so a serializer that reached for either would still serve a
    # plausible-looking page. Asserted as an inequality between the constants rather than against the
    # literal 25, which is the form that stays true if the cap is ever retuned.
    it "is capped by this grain's own constant, not by a neighbouring one" do
      expect(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
        .not_to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      expect(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
        .not_to eq(SpecObservation::SLOWEST_LIMIT)
      expect(block(key: capped.api_keys.create!,
                   query: { repeated_description: looped })["rows"].length)
        .to eq(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
    end
  end

  # A group with rows and no timings is a LIST with no ranking — the examples exist, they ran or
  # failed to, and their sites and outcomes are most of what a reader came here for. What a client
  # must not receive is a `0.0` for a duration nobody measured.
  describe "a description none of whose examples were timed" do
    let(:untimed) do
      repo = create_repository(user: @user, github_full_name: "acme/untimed-group")
      ingest(repo, [example_spec(file_path: order_spec, line_number: 1, duration: nil,
                                 outcome: "pending", name: looped),
                    example_spec(file_path: refund_spec, line_number: 2, duration: nil,
                                 outcome: nil, name: looped)])
      repo
    end

    it "serves null durations rather than zeros, and says the group timed nothing" do
      served = block(key: untimed.api_keys.create!, query: { repeated_description: looped })

      expect(served["rows"].map { it["duration_seconds"] }).to eq([nil, nil])
      expect(served["recorded_count"]).to eq(2)
      expect(served["timed_count"]).to eq(0)
      expect(served.to_json).not_to include("0.0")
      # An outcome the client never sent is a null too, and specifically not the "not reported" the
      # panel prints in its place.
      expect(served["rows"].map { it["outcome"] }).to eq(["pending", nil])
      expect(served.to_json).not_to include("not reported")
    end
  end

  # AC7. `latest_run` is never re-anchored by `?branch=` — *"every request; only `history`
  # narrows"* — so the four asks compose without interacting: the drill-in always describes the
  # newest run, exactly as the panel does, while `history` narrows around it and the two path
  # drill-ins answer for their own grains.
  describe "composing with a branch ask, an area ask and a file ask" do
    let!(:other_branch_run) do
      ingest(repository,
             [example_spec(file_path: order_spec, line_number: 1, duration: 4.0, outcome: "passed",
                           name: looped),
              example_spec(file_path: refund_spec, line_number: 2, duration: 1.0, outcome: "passed",
                           name: looped),
              example_spec(file_path: "spec/models/audit_spec.rb", line_number: 3, duration: 1.0,
                           outcome: "passed", name: "Audit records the change")],
             commit_sha: "feedfacecafe0002", branch: "feature/x")
    end

    it "describes the latest run under a branch ask, and narrows history independently" do
      body = get_repository(query: { repeated_description: looped, branch: "main" })

      # The newest run is the `feature/x` one, and that is the run the drill-in describes even though
      # the window was narrowed to `main` — the surprise `serialized_latest_run` states plainly
      # rather than hides.
      expect(body.dig("latest_run", "commit_sha")).to eq("feedfacecafe0002")
      expect(body.dig("latest_run", "repeated_description_examples", "rows").map { it["line_number"] })
        .to eq([1, 2])
      expect(body.dig("history_window", "branch")).to eq("main")
      expect(body["history"].map { it["commit_sha"] }).to eq(["feedfacecafe0001"])
    end

    it "serves the same drill-in with and without the branch ask" do
      with_branch = block(query: { repeated_description: looped, branch: "main" })

      expect(with_branch).to eq(block(query: { repeated_description: looped }))
      expect(with_branch["rows"].length).to eq(2)
    end

    # The three drill-ins are three keys with three answers on one response, and none touches
    # another: the area key still lists the area's FILES, the file key the file's EXAMPLES, and this
    # one the description's — across both files, which is the answer neither of the other two can
    # give.
    it "answers all three drill-ins at once without any narrowing another" do
      body = get_repository(query: { repeated_description: looped, spec_file: order_spec,
                                     spec_directory: "spec/models" })

      expect(body.dig("latest_run", "repeated_description_examples", "name")).to eq(looped)
      expect(body.dig("latest_run", "spec_file_examples", "path")).to eq(order_spec)
      expect(body.dig("latest_run", "spec_directory_files", "path")).to eq("spec/models")
      # The description's list is NOT narrowed to the file that was opened beside it.
      expect(body.dig("latest_run", "repeated_description_examples", "rows")
                 .map { it["spec_file_path"] })
        .to contain_exactly(order_spec, refund_spec)
      expect(body.dig("latest_run", "spec_file_examples", "rows").map { it["spec_file_path"] })
        .to all(eq(order_spec))
      # And each is identical to what it serves when it is the only ask on the request.
      expect(body.dig("latest_run", "repeated_description_examples"))
        .to eq(block(query: { repeated_description: looped }))
    end
  end

  # The API and the dashboard cannot list different examples for the same repository, the same run
  # and the same description. Read off the RENDERED PAGE and off the object the page assigns — never
  # off a second hand-written query, which would only compare the endpoint against itself.
  describe "against what repositories#show renders for the same description" do
    def panel_rows
      panel = Capybara.string(response.body).find("#repeated-description-examples")
      panel.all("tbody tr").map do |row|
        ran_in, defined_at, duration, outcome = row.all("td").map { it.text.gsub(/\s+/, " ").strip }

        { "ran_in" => ran_in, "defined_at" => defined_at,
          "duration" => duration, "outcome" => outcome }
      end
    end

    # The ORDER is asserted as a sequence, because that is the half a `match_array` would drop and
    # the half the `NULLS LAST` in the read exists to get right. Every figure comes off the object
    # rather than off the fixture's numbers: two independent hand-written expectations would both
    # still pass if the endpoint started reading a different run or a different description.
    it "serves the same rows, in the same order, that the panel renders from" do
      served = block(query: { repeated_description: looped })
      shown = RepeatedDescriptionExamples.for(repository.latest_test_run, looped)

      expect(served["name"]).to eq(shown.name)
      expect(served["rows"].map { it["name"] }).to eq(shown.rows.map(&:name))
      expect(served["rows"].map { it["file_path"] }).to eq(shown.rows.map(&:file_path))
      expect(served["rows"].map { it["line_number"] }).to eq(shown.rows.map(&:line_number))
      expect(served["rows"].map { it["spec_file_path"] }).to eq(shown.rows.map(&:spec_file_path))
      expect(served["rows"].map { it["duration_seconds"] }).to eq(shown.rows.map(&:duration_seconds))
      expect(served["rows"].map { it["outcome"] }).to eq(shown.rows.map(&:outcome))
      expect(served["recorded_count"]).to eq(shown.recorded_count)
      expect(served["timed_count"]).to eq(shown.timed_count)
    end

    # And the same comparison against the PAGE, which is the surface a reader actually holds. The
    # page prints the labels and the block serves the operands, so both readings are assembled here
    # — the duration through `SpecObservation.humanized_duration`, the seam every grain on that page
    # renders through, rather than through a hand-rolled `"%.2fs"` that would be a second definition
    # of the spelling.
    it "names the same examples, with the same operands, as the panel prints" do
      served = block(query: { repeated_description: looped })
      get repository_path(repository, repeated_description: looped)

      expect(panel_rows).to eq(
        served["rows"].map do |row|
          { "ran_in" => row["spec_file_path"] || "not reported",
            "defined_at" => "#{row["file_path"]}:#{row["line_number"]}",
            "duration" => SpecObservation.humanized_duration(row["duration_seconds"]),
            "outcome" => row["outcome"] || "not reported" }
        end
      )
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(panel_rows.length).to eq(4)
      # And the label vocabulary the JSON block refuses IS what this data makes the panel print, so
      # the "numbers and words, never labels" example above is refusing something real.
      expect(panel_rows.map { it["duration"] }).to include("not reported", "4.00s")
    end
  end
end
