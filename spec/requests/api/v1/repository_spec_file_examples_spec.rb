# frozen_string_literal: true

require "rails_helper"

# The `latest_run.spec_file_examples` block on `GET /api/v1/repository` — ONE spec file, opened, and
# the agent-readable twin of the "Examples in this spec file" panel `repositories#show` renders
# under `?spec_file=`.
#
# THE BOTTOM RUNG of area → file → example, and the last move the ladder has. Its sibling file
# `repository_spec_directory_files_spec.rb` pins the middle rung and states why the top two could
# not reach it; this one is the same argument one grain further down. An agent that has walked
# `latest_run.spec_directories` into `spec/models/` and `?spec_directory=` into
# `spec/models/order_spec.rb — 340 examples, six minutes` has learned exactly which file to open and
# has nothing to open it with. Neither per-example block already on this endpoint answers it, and
# the fixture below is built so that BOTH substitutes visibly fail:
#
#   - `latest_run.slowest_examples` reaches this grain for the ten examples that are slowest
#     RUN-WIDE, and here those ten are every row of `spec/requests/checkout_spec.rb` — not one row
#     of the file this block opens.
#   - `latest_run.spec_files` is a capped ten RANKING of the run's heaviest files, which names the
#     file and says nothing about what is inside it.
#
# Its own file, beside `repository_spec_directory_files_spec.rb` and on the precedent that file and
# `repository_unstable_tests_spec.rb` both state: every example here needs a fixture whose opened
# FILE holds none of the run's slowest EXAMPLES, and needs it under a query parameter no other block
# on this endpoint reads, while every block in `repository_latest_run_spec.rb` is a fact about one
# run served on every request.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never
# inserted by hand — the rule every sibling here states, and for the same reason: an untimed example
# is `result&.run_time` coming back nil on a real client, and a shared example group is a real
# payload's `file_path` and `spec_file_path` disagreeing.
RSpec.describe "GET /api/v1/repository — latest_run.spec_file_examples", type: :request do
  # Signed in as well as keyed, because one example reads the HTML panel and the JSON block off the
  # same run and compares them row for row. The owner is the same user on both surfaces, so the two
  # cannot be looking at two repositories.
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  # `query:` rather than a `spec_file:` keyword, so an example can send the shapes a real client's
  # malformed query string parses into — an Array, a nested hash — the same way it sends a path.
  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def block(**) = get_repository(**).dig("latest_run", "spec_file_examples")

  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `duration:` and `outcome:` are passed at every call site, nils
  # included — an untimed example is the state two of the assertions below turn on, and the shared
  # builder defaults both to a value a real client does not always send.
  #
  # Every keyword goes THROUGH the shared builder rather than over the top of its result: that
  # builder derives `id` and `spec_file_path` from the `file_path` it was called with, so a
  # `file_path` merged in afterwards leaves an example claiming one file and filed under another.
  def example_spec(file_path:, line_number:, duration:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration, **attrs)
  end

  # The file this whole file opens, and every disagreement in its four rows is load-bearing:
  #
  #   - Four examples, THREE of them timed, so `recorded_count` and `timed_count` are different
  #     figures and a serializer serving either twice under two names is red.
  #   - One row is a SHARED EXAMPLE GROUP: its `file_path` is the group's file and its
  #     `spec_file_path` is this one. It is listed here because this file RAN it, and the two paths
  #     disagree — which is the row that fails a serializer serving one path under both names.
  #   - One row is UNTIMED and `pending`, so `duration_seconds` must arrive as `null` rather than as
  #     `0.0`, and it sorts to the END of the list rather than to the head of it.
  #   - The outcomes are three different words, so a block serving a constant is red.
  TARGET_FILE = "spec/models/order_spec.rb"

  # The run-wide slowest ten, and every one of them is in ANOTHER file: ten examples at 8.1s and up,
  # against the opened file's heaviest at 3.0s. So `slowest_examples` holds not one row of
  # `TARGET_FILE`, and a client that tried to reach this list by filtering that ranking gets nothing
  # at all — the non-derivability this key exists for, made visible in the response itself.
  def checkout_examples
    Array.new(SpecObservation::SLOWEST_LIMIT) do |index|
      example_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 100 + index,
                   duration: 9.0 - (index * 0.1), outcome: "passed",
                   name: "Checkout step #{index}")
    end
  end

  let!(:test_run) do
    ingest(repository,
           [example_spec(file_path: TARGET_FILE, line_number: 4, duration: 3.0, outcome: "passed",
                         name: "Order#total sums the line items"),
            example_spec(file_path: TARGET_FILE, line_number: 12, duration: 1.5, outcome: "failed",
                         name: "Order#total ignores voided lines"),
            # The shared example group: DEFINED in `billable.rb`, RUN by `order_spec.rb`.
            example_spec(file_path: "spec/support/shared_examples/billable.rb",
                         spec_file_path: TARGET_FILE, line_number: 7, duration: 0.5,
                         outcome: "passed", name: "behaves like a billable charges once"),
            example_spec(file_path: TARGET_FILE, line_number: 20, duration: nil, outcome: "pending",
                         name: "Order#refund is idempotent"),
            # A second file in the same area, so the block is proven to narrow to ONE file rather
            # than to the area the file sits in.
            example_spec(file_path: "spec/models/user_spec.rb", line_number: 30, duration: 2.0,
                         outcome: "passed", name: "User is valid with a handle"),
            *checkout_examples])
  end

  describe "a spec file that was asked for" do
    # AC1. The block exists, its rows carry the six operands the endpoint's other per-example block
    # already serves, and the FILE's two population figures sit beside them. The array is asserted
    # as a SEQUENCE — `eq`, not `match_array` — because "slowest first, untimed last" is half of
    # what this key promises, and the untimed row's position is the half a set comparison drops.
    it "lists that file's examples slowest-first, untimed last, with what each row is" do
      expect(block(query: { spec_file: TARGET_FILE })).to eq(
        "path" => TARGET_FILE,
        "rows" => [
          { "name" => "Order#total sums the line items", "file_path" => TARGET_FILE,
            "line_number" => 4, "spec_file_path" => TARGET_FILE,
            "duration_seconds" => 3.0, "outcome" => "passed" },
          { "name" => "Order#total ignores voided lines", "file_path" => TARGET_FILE,
            "line_number" => 12, "spec_file_path" => TARGET_FILE,
            "duration_seconds" => 1.5, "outcome" => "failed" },
          { "name" => "behaves like a billable charges once",
            "file_path" => "spec/support/shared_examples/billable.rb",
            "line_number" => 7, "spec_file_path" => TARGET_FILE,
            "duration_seconds" => 0.5, "outcome" => "passed" },
          { "name" => "Order#refund is idempotent", "file_path" => TARGET_FILE,
            "line_number" => 20, "spec_file_path" => TARGET_FILE,
            "duration_seconds" => nil, "outcome" => "pending" }
        ],
        "recorded_count" => 4,
        "timed_count" => 3,
        "limit" => SpecObservation::FILE_EXAMPLES_LIMIT
      )
    end

    # The sub-block's own key set, stated as its subject rather than pinned as a side effect of the
    # `eq` above — the pattern the sibling drill-in's contract example sets, and for the same
    # reason: a guard whose stated subject IS the key set survives a fixture whose numbers change,
    # and says out loud what a new key owes this block before it ships.
    it "serves exactly the spec_file_examples keys this contract pins" do
      served = block(query: { spec_file: TARGET_FILE })

      expect(served.keys)
        .to contain_exactly("path", "rows", "recorded_count", "timed_count", "limit")
      expect(served["rows"].first.keys)
        .to contain_exactly("name", "file_path", "line_number", "spec_file_path",
                            "duration_seconds", "outcome")
    end

    # `SlowestExamples` exposes a `reported_outcome_count` and `SpecFileExamples` does not, which is
    # a difference between two objects rather than a gap in this one. Named as its own example
    # because the tempting repair — folding the serialized rows to re-derive it — would compute the
    # PAGE's figure under the file's name, which is what every count on this block is arranged to
    # avoid. The `eq` above would go red on it too; this says WHY it must.
    it "invents no outcome-coverage figure the object it reads does not count" do
      expect(block(query: { spec_file: TARGET_FILE })).not_to have_key("reported_outcome_count")
      expect(SpecFileExamples.instance_methods).not_to include(:reported_outcome_count)
      # And the endpoint's other per-example block DOES serve one, so the absence above is a
      # difference between two populations rather than a key nobody got round to.
      expect(get_repository.dig("latest_run", "slowest_examples"))
        .to have_key("reported_outcome_count")
    end

    # THE assertion that fails the moment this block is fed by either per-example surface already
    # here. Every figure is taken off the RESPONSE, so it is the endpoint's own blocks disagreeing:
    # the run-wide slowest ten hold no row of the opened file, and the by-file ranking names the
    # file without listing anything inside it.
    it "lists examples the run-wide slowest ranking holds none of" do
      body = get_repository(query: { spec_file: TARGET_FILE })["latest_run"]

      expect(body.dig("slowest_examples", "rows").map { it["spec_file_path"] })
        .to all(eq("spec/requests/checkout_spec.rb"))
      expect(body.dig("slowest_examples", "rows").map { it["spec_file_path"] })
        .not_to include(TARGET_FILE)
      expect(body.dig("spec_file_examples", "rows").map { it["spec_file_path"] })
        .to all(eq(TARGET_FILE))
      # And the by-file rollup names the opened file without saying anything about its contents —
      # a ranking of files is not a listing of examples under another name.
      expect(body.dig("spec_files", "rows").map { it["path"] }).to include(TARGET_FILE)
      expect(body.dig("spec_files", "rows").first).not_to have_key("rows")
    end

    # The row that separates "the file an example is IN" from "the file that RAN it". A serializer
    # serving one path under both names satisfies every other example in this file and fails here.
    it "names the definition site and the including file apart, for a shared example group" do
      shared = block(query: { spec_file: TARGET_FILE })["rows"].find { it["line_number"] == 7 }

      expect(shared["file_path"]).to eq("spec/support/shared_examples/billable.rb")
      expect(shared["spec_file_path"]).to eq(TARGET_FILE)
      expect(shared["file_path"]).not_to eq(shared["spec_file_path"])
    end

    # The untimed row is LISTED rather than excluded, and its nil is served as one. A `0.0` here
    # would assert an example that cost nothing, which is a measurement nobody took — the same
    # distinction the "not reported" the panel prints exists to keep.
    it "serves a null duration for an example that reported none, never a zero" do
      rows = block(query: { spec_file: TARGET_FILE })["rows"]

      expect(rows.last["duration_seconds"]).to be_nil
      expect(rows.last["outcome"]).to eq("pending")
      expect(rows.map { it["duration_seconds"] }).to eq([3.0, 1.5, 0.5, nil])
    end

    # The block's standing rule, asserted over the whole serialized sub-block rather than per key:
    # `SpecObservation#duration_label`, `#outcome_label` and `SpecFileExamples#coverage_label` are
    # each one call away in the object this reads from, and any of them would still satisfy the
    # assertions above if the fixture's values happened to render similarly.
    it "serves numbers and words, never the panel's labels" do
      served = block(query: { spec_file: TARGET_FILE })

      expect(served.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(served["rows"].map { it["duration_seconds"] }).to all(be_a(Float).or(be_nil))
      expect(served["rows"].map { it["line_number"] }).to all(be_a(Integer))
      expect(served["recorded_count"]).to be_a(Integer)
      expect(served["timed_count"]).to be_a(Integer)
    end

    # ONE file, not the area it sits in — the rung above this one is a different key with a
    # different answer, and both are on the same response.
    it "narrows to the file asked for and not to its area" do
      body = get_repository(query: { spec_file: TARGET_FILE, spec_directory: "spec/models" })["latest_run"]

      expect(body.dig("spec_file_examples", "rows").map { it["name"] })
        .not_to include("User is valid with a handle")
      expect(body.dig("spec_directory_files", "rows").map { it["path"] })
        .to include(TARGET_FILE, "spec/models/user_spec.rb")
    end
  end

  # AC3. The distinction this key must not collapse, and it shares it with exactly two siblings on
  # this block: the other five are served unconditionally and gate on `#recorded?`, while these
  # three answer a question the CLIENT asked. Copying that gate here would spell "you did not ask"
  # and "the file you asked about has no rows" the same way — the collapse `serialized_history`
  # already refuses for an unknown `?branch=`, where the ask is RESTATED beside a zero rather than
  # answered with somebody else's rows.
  describe "the two ways this key can be empty" do
    it "is null — with the key present — when no file was asked for" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to have_key("spec_file_examples")
      expect(body.dig("latest_run", "spec_file_examples")).to be_nil
      # The rest of `latest_run` is untouched by the absence: this key is added BESIDE the six
      # blocks that were there before it, never in place of any of them.
      expect(body.dig("latest_run", "slowest_examples", "rows").length)
        .to eq(SpecObservation::SLOWEST_LIMIT)
      expect(body.dig("latest_run", "spec_files", "rows")).to be_present
    end

    # AC2. A file the run recorded nothing for is an ordinary answer and never an error: the ask is
    # restated, the list is empty, both counts are an honest zero, and the status is 200.
    it "is a present block with no rows, naming the file, when the run recorded nothing there" do
      served = block(query: { spec_file: "spec/models/ghost_spec.rb" })

      expect(response).to have_http_status(:ok)
      expect(served).to eq("path" => "spec/models/ghost_spec.rb", "rows" => [],
                           "recorded_count" => 0, "timed_count" => 0,
                           "limit" => SpecObservation::FILE_EXAMPLES_LIMIT)
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent, because the second never wears the
    # first's spelling.
    it "spells the two differently, so a client can tell which one it got" do
      expect(block).to be_nil
      expect(block(query: { spec_file: "spec/models/ghost_spec.rb" })).not_to be_nil
      expect(block(query: { spec_file: "spec/models/ghost_spec.rb" })["path"])
        .to eq("spec/models/ghost_spec.rb")
    end

    # A near miss is one of the ordinary ways to arrive at the empty answer — a stale bookmark, a
    # file renamed since, a typed path with a character missing — and none of them is an error or a
    # prefix match onto the neighbouring file.
    it "answers a typo with the empty block rather than an error or a prefix match" do
      served = block(query: { spec_file: "spec/models/order_spec" })

      expect(response).to have_http_status(:ok)
      expect(served["rows"]).to eq([])
      expect(served["path"]).to eq("spec/models/order_spec")
    end

    # There is no `latest_run` at all for a repository whose CI has never reported, so the ask
    # cannot conjure one — the rule the whole block follows, restated here because this is one of
    # the three keys on it a client can ask for by name.
    it "serves no block at all when CI has never reported" do
      silent = create_repository(user: @user, github_full_name: "acme/never-ran")

      body = get_repository(key: silent.api_keys.create!, query: { spec_file: TARGET_FILE })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC3. The shapes a query string can legally parse into that are NOT a path, pinned once for every
  # surface in `spec/support/shared_examples/malformed_spec_file_param.rb`. This one reaches
  # `where(spec_file_path: …)` on a plain string column, where an Array does not raise at all: it
  # becomes an `IN` list and answers a question nobody asked, under a `path` naming one file.
  describe "a spec-file parameter that is not a path" do
    # The NO-ASK answer specifically, and not merely a 200 — the shared example's own comment
    # requires it, because a guard that swallowed every value would answer 200 on all three shapes
    # too.
    def expect_spec_file_param_treated_as_no_ask(query)
      expect(block(query: query)).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed spec-file parameter as no ask"

    # THE positive path, beside the group, which is what separates "the guard read the parameter"
    # from "the endpoint ignores this parameter entirely".
    it "honours a spec_file that IS a path" do
      expect(block(query: { spec_file: TARGET_FILE })["rows"].length).to eq(4)
    end

    # An empty ask is no ask, not a comparison against the empty string: `spec_file_path` is NOT
    # NULL and `Ingest::ObservationRecorder#attributes` falls back to `file_path`, so no row can
    # carry a blank and an empty ask would open a block guaranteed to hold nothing.
    it "treats an empty spec_file as no ask" do
      expect(block(query: { spec_file: "" })).to be_nil
    end
  end

  # AC6. The cost, and the axis this key shares with exactly two siblings: the other blocks issue
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

      expect(count_queries { get_repository(query: { spec_file: TARGET_FILE }) }).to eq(baseline + 1)
      # The empty answer costs the same one: the read is what DISCOVERS that the file has no rows,
      # so there is no cheaper way to ask and no gate in front of it to add.
      expect(count_queries { get_repository(query: { spec_file: "spec/models/ghost_spec.rb" }) })
        .to eq(baseline + 1)
      # And a malformed shape is no ask, which means it is also no query — the guard sits in front
      # of the read rather than inside it.
      expect(count_queries { get_repository(query: { spec_file: [TARGET_FILE] }) }).to eq(baseline)
    end

    # The same bound classified rather than counted, so "one more query" cannot be satisfied by a
    # different grain reading twice while this one reads none. `file_examples_grain_reads` and the
    # partition it belongs to come from spec/support/observation_grain_reads.rb, which is also where
    # the argument for matching every grain POSITIVELY is made — and where this grain's pattern is
    # separated from the per-example ranking's, which also ranks this table by duration.
    it "reads spec_observations once for its own grain, and leaves every other grain alone" do
      area, file, example, description, flakiness, growth, directory_files, file_examples =
        observation_reads_by_grain { get_repository(query: { spec_file: TARGET_FILE }) }

      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length, directory_files.length, file_examples.length])
        .to eq([1, 1, 2, 2, 0, 0, 0, 1])
      # And the classified reads are ALL of them — the assertion no per-grain count can make,
      # because a read matching no grain's pattern is invisible to every one of them.
      expect(observation_reads { get_repository(query: { spec_file: TARGET_FILE }) }.length)
        .to eq(classified_observation_reads { get_repository(query: { spec_file: TARGET_FILE }) })
      expect(observation_reads { get_repository(query: { spec_file: TARGET_FILE }) }.length).to eq(7)
      # Six without the ask — the total `repository_latest_run_spec.rb` pins for this endpoint,
      # restated here as the thing this slice did NOT change.
      expect(observation_reads { get_repository }.length).to eq(6)
      expect(file_examples_grain_reads { get_repository }).to be_empty
    end

    # The two drill-ins compose without either being classified as the other — the pairing that the
    # partition's own separation of these patterns exists to make assertable, and the shape neither
    # single-ask block above can speak for. Eight reads: the six, plus one per ask.
    it "keeps the two drill-ins in their own grains when both are asked for at once" do
      query = { spec_file: TARGET_FILE, spec_directory: "spec/models" }

      _area, _file, _example, _description, _flakiness, _growth, directory_files, file_examples =
        observation_reads_by_grain { get_repository(query: query) }

      expect([directory_files.length, file_examples.length]).to eq([1, 1])
      # And the classified reads are ALL of them — asserted HERE most of all. This is the second
      # richest fixture in the suite, SIX of the nine grains non-zero at once, so it is where a
      # cross-grain misclassification is most observable. The `eq([1, 1])` above covers the two
      # drill-ins alone, and the bare `8` below is exactly the total that
      # spec/support/observation_grain_reads.rb argues cannot tell "one aggregate per grain" from "one
      # grain reading twice" — so without this line a read adopted into another grain, or matching no
      # grain at all, is invisible to every assertion in the example.
      expect(observation_reads { get_repository(query: query) }.length)
        .to eq(classified_observation_reads { get_repository(query: query) })
      expect(observation_reads { get_repository(query: query) }.length).to eq(8)
    end

    # The suite-size axis, and the one that decides whether this key is affordable at the roadmap's
    # 20,000-example design point: the read is bounded by the size of the FILE and capped, so a file
    # of 4 examples and one of 300 cost the same single query. A serializer that fetched the rows
    # and counted them in Ruby, or that took a second pass for the file's population, reads as more
    # here and as more again as the suite grows.
    it "reads it once however many examples the file holds" do
      big = create_repository(user: @user, github_full_name: "acme/wide-file")
      ingest(big, Array.new(300) do |index|
        example_spec(file_path: TARGET_FILE, line_number: index + 1, duration: 0.5,
                     outcome: "passed", name: "Order example #{index}")
      end)
      key = big.api_keys.create!

      get_repository(key: key)
      baseline = count_queries { get_repository(key: key) }

      expect(count_queries { get_repository(key: key, query: { spec_file: TARGET_FILE }) })
        .to eq(baseline + 1)
      expect(block(key: key, query: { spec_file: TARGET_FILE })["recorded_count"]).to eq(300)
    end
  end

  # AC4. The list is capped by its OWN constant — not the by-file rollup's ten and not the by-area
  # drill-down's twenty-five — and a capped list that does not disclose its cap is the lie
  # `SpecFileExamples#truncated?` refuses on the panel. The FILE's population has to come from the
  # read's windows rather than from the rows on hand, which are the truncated figure.
  describe "a file holding more examples than the limit" do
    # 57 recorded, 53 of them timed, against a cap of 50 — so BOTH population figures exceed
    # `rows.size` and neither can be the page's figure wearing the file's name. The four untimed
    # rows sort last and are cut off the page entirely, which is the shape that makes the second
    # figure independent of the first rather than a copy of it.
    let(:capped) do
      repo = create_repository(user: @user, github_full_name: "acme/capped-file")
      ingest(repo, Array.new(57) do |index|
        example_spec(file_path: TARGET_FILE, line_number: index + 1,
                     duration: index < 53 ? (index + 1) * 0.5 : nil,
                     outcome: "passed", name: "Order example #{index}")
      end)
      repo
    end

    it "serves the limit's worth of rows, and says how many examples the file holds" do
      served = block(key: capped.api_keys.create!, query: { spec_file: TARGET_FILE })

      expect(served["rows"].length).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      expect(served["limit"]).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      # Counted over the FILE and not over the page, which on a truncated file are different
      # populations — and BOTH figures are larger than the page, so neither can have been folded
      # out of the serialized rows.
      expect(served["recorded_count"]).to eq(57)
      expect(served["timed_count"]).to eq(53)
      expect(served["recorded_count"]).to be > served["rows"].length
      expect(served["timed_count"]).to be > served["rows"].length
    end

    # `FILE_EXAMPLES_LIMIT` is its own constant and the two neighbouring caps are different numbers,
    # so a serializer that reached for either would still serve a plausible-looking page. Asserted
    # as an inequality between the constants rather than against the literal 50, which is the form
    # that stays true if the cap is ever retuned.
    it "is capped by the file grain's own constant, not by a neighbouring one" do
      expect(SpecObservation::FILE_EXAMPLES_LIMIT)
        .not_to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
      expect(SpecObservation::FILE_EXAMPLES_LIMIT).not_to eq(SpecObservation::SLOWEST_LIMIT)
      expect(block(key: capped.api_keys.create!, query: { spec_file: TARGET_FILE })["rows"].length)
        .to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
    end
  end

  # A file with rows and no timings is a LIST with no ranking — the examples exist, they ran or
  # failed to, and their outcomes are what a reader has come for. What a client must not receive is
  # a `0.0` for a duration nobody measured.
  describe "a file none of whose examples were timed" do
    let(:untimed) do
      repo = create_repository(user: @user, github_full_name: "acme/untimed-file")
      ingest(repo, [example_spec(file_path: TARGET_FILE, line_number: 1, duration: nil,
                                 outcome: "pending", name: "Order#total sums the line items"),
                    example_spec(file_path: TARGET_FILE, line_number: 2, duration: nil,
                                 outcome: nil, name: "Order#refund is idempotent")])
      repo
    end

    it "serves null durations rather than zeros, and says the file timed nothing" do
      served = block(key: untimed.api_keys.create!, query: { spec_file: TARGET_FILE })

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

  # AC5. `latest_run` is never re-anchored by `?branch=` — *"every request; only `history`
  # narrows"* — so the three asks compose without interacting: the drill-in always describes the
  # newest run, exactly as the panel does, while `history` narrows around it and the area drill-in
  # answers for its own grain.
  describe "composing with a branch ask and an area ask" do
    let!(:other_branch_run) do
      ingest(repository,
             [example_spec(file_path: TARGET_FILE, line_number: 1, duration: 4.0,
                           outcome: "passed", name: "Order#total on the feature branch"),
              example_spec(file_path: "spec/models/audit_spec.rb", line_number: 2, duration: 1.0,
                           outcome: "passed", name: "Audit records the change")],
             commit_sha: "feedfacecafe0002", branch: "feature/x")
    end

    it "describes the latest run under a branch ask, and narrows history independently" do
      body = get_repository(query: { spec_file: TARGET_FILE, branch: "main" })

      # The newest run is the `feature/x` one, and that is the run the drill-in describes even
      # though the window was narrowed to `main` — the surprise `serialized_latest_run` states
      # plainly rather than hides.
      expect(body.dig("latest_run", "commit_sha")).to eq("feedfacecafe0002")
      expect(body.dig("latest_run", "spec_file_examples", "rows").map { it["name"] })
        .to eq(["Order#total on the feature branch"])
      expect(body.dig("history_window", "branch")).to eq("main")
      expect(body["history"].map { it["commit_sha"] }).to eq(["feedfacecafe0001"])
    end

    it "serves the same drill-in with and without the branch ask" do
      with_branch = block(query: { spec_file: TARGET_FILE, branch: "main" })

      expect(with_branch).to eq(block(query: { spec_file: TARGET_FILE }))
      expect(with_branch["rows"].length).to eq(1)
    end

    # The two drill-ins are two keys with two answers on one response, and neither touches the
    # other: the area key still lists the area's FILES while the file key lists the file's EXAMPLES.
    it "answers both drill-ins at once without either narrowing the other" do
      body = get_repository(query: { spec_file: TARGET_FILE, spec_directory: "spec/models" })

      expect(body.dig("latest_run", "spec_file_examples", "path")).to eq(TARGET_FILE)
      expect(body.dig("latest_run", "spec_directory_files", "path")).to eq("spec/models")
      expect(body.dig("latest_run", "spec_directory_files", "rows").map { it["path"] })
        .to eq([TARGET_FILE, "spec/models/audit_spec.rb"])
      # And each is identical to what it serves when it is the only ask on the request.
      expect(body.dig("latest_run", "spec_file_examples"))
        .to eq(block(query: { spec_file: TARGET_FILE }))
    end
  end

  # AC7. The API and the dashboard cannot list different examples for the same repository, the same
  # run and the same file. Read off the RENDERED PAGE and off the object the page assigns — never
  # off a second hand-written query, which would only compare the endpoint against itself.
  describe "against what repositories#show renders for the same file" do
    def panel_rows
      panel = Capybara.string(response.body).find("#spec-file-examples")
      panel.all("tbody tr").map do |row|
        test, duration, outcome = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

        { "test" => test, "duration" => duration, "outcome" => outcome }
      end
    end

    # The ORDER is asserted as a sequence, because that is the half a `match_array` would drop and
    # the half the `NULLS LAST` in the read exists to get right. Every figure comes off the object
    # rather than off the fixture's numbers: two independent hand-written expectations would both
    # still pass if the endpoint started reading a different run or a different file.
    it "serves the same rows, in the same order, that the panel renders from" do
      served = block(query: { spec_file: TARGET_FILE })
      shown = SpecFileExamples.for(repository.latest_test_run, TARGET_FILE)

      expect(served["path"]).to eq(shown.path)
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
      served = block(query: { spec_file: TARGET_FILE })
      get repository_path(repository, spec_file: TARGET_FILE)

      expect(panel_rows).to eq(
        served["rows"].map do |row|
          { "test" => "#{row["name"]} #{row["file_path"]}:#{row["line_number"]}",
            "duration" => SpecObservation.humanized_duration(row["duration_seconds"]),
            "outcome" => row["outcome"] || "not reported" }
        end
      )
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(panel_rows.length).to eq(4)
      # And the label vocabulary the JSON block refuses IS what this data makes the panel print, so
      # the "numbers and words, never labels" example above is refusing something real.
      expect(panel_rows.map { it["duration"] }).to include("not reported", "3.00s")
    end
  end
end
