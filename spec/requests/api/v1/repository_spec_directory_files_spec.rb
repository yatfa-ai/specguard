# frozen_string_literal: true

require "rails_helper"

# The `latest_run.spec_directory_files` block on `GET /api/v1/repository` — ONE area of the by-area
# rollup, opened, and the agent-readable twin of the "Spec files in this directory" panel
# `repositories#show` renders under `?spec_directory=`.
#
# THE MIDDLE RUNG, and the move an agent holding every other key on this endpoint could not make.
# `latest_run.spec_directories` names the ten areas the run spent its wall clock in and stops;
# `latest_run.spec_files` is a capped ten of the run's own heaviest FILES, which is not the same
# list under another name — `SpecDirectoryDurations`' comment states the arithmetic, *"a directory
# holding forty files at two seconds each is eighty seconds of the run with not one of its rows in
# that list"* — and `latest_run.slowest_examples` reaches a test to open only for the ten examples
# that are slowest RUN-WIDE. So for every area that is heavy through many ordinary files, the
# sentence `serialized_slowest_examples` opens with — *"an agent that has learned `spec/models/`
# cost ninety seconds has no way to get from there to a test to open"* — was still true. The
# fixture below is built so that this file's examples FAIL under a client that tries to derive this
# block from the two rollups beside it.
#
# Its own file, beside `repository_directory_growth_spec.rb` and `repository_unstable_tests_spec.rb`
# and on the precedent both of them state: every example here needs a fixture whose heavy AREA holds
# none of the run's heavy FILES, and needs it under a query parameter no other block on this
# endpoint reads, while every block in `repository_latest_run_spec.rb` is a fact about one run
# served on every request.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never
# inserted by hand — the rule both sibling files state, and for the same reason: an untimed example
# is `result&.run_time` coming back nil on a real client, and an area is the parent directory of the
# `spec_file_path` a real payload carried.
RSpec.describe "GET /api/v1/repository — latest_run.spec_directory_files", type: :request do
  # Signed in as well as keyed, because one example reads the HTML panel and the JSON block off the
  # same run and compares them figure for figure. The owner is the same user on both surfaces, so
  # the two cannot be looking at two repositories.
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  # `query:` rather than a `spec_directory:` keyword, so an example can send the shapes a real
  # client's malformed query string parses into — an Array, a nested hash — the same way it sends a
  # path.
  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def block(**) = get_repository(**).dig("latest_run", "spec_directory_files")

  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `duration:` is passed at every call site, nils included — an untimed
  # example is the state two of the blocks below turn on, and the shared builder defaults it to a
  # number.
  def example_spec(file_path:, duration:, line_number:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration).merge(attrs)
  end

  # THE fixture, and every disagreement in it is load-bearing:
  #
  #   - `spec/models` is the heaviest AREA at 10.5s and holds NONE of the run's heaviest files. The
  #     heaviest FILE in the run is `spec/requests/checkout_spec.rb` at 9.0s, in a lighter area — so
  #     a client that tried to reach this list by filtering `spec_files` by parent directory reads
  #     the wrong file first, which is the non-derivability this key exists for.
  #   - `spec/models/user_spec.rb` carries TWO examples and only ONE timing, so the area's
  #     `recorded_count` and `timed_count` differ and a serializer that served either twice under
  #     two names is red.
  #   - `spec/models/orders` is a NESTED area with its own rows, so an equality narrow and a prefix
  #     `LIKE` return different lists here.
  #   - The area's example count (4) is not its file count (3), and neither is `rows.size` on a
  #     truncated area — the population figures are asserted apart from the page's below.
  let!(:test_run) do
    ingest(repository,
           [example_spec(file_path: "spec/models/refund_spec.rb", duration: 5.0, line_number: 1),
            example_spec(file_path: "spec/models/order_spec.rb", duration: 3.5, line_number: 2),
            example_spec(file_path: "spec/models/user_spec.rb", duration: 2.0, line_number: 3),
            example_spec(file_path: "spec/models/user_spec.rb", duration: nil, line_number: 4),
            example_spec(file_path: "spec/models/orders/refund_spec.rb", duration: 2.5, line_number: 5),
            example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 6)])
  end

  describe "an area that was asked for" do
    # AC1. The block exists, its rows carry the four operands rather than a path and a number, and
    # the area's own three figures sit beside them. The array is asserted as a SEQUENCE — `eq`, not
    # `match_array` — because "heaviest first" is half of what this key promises.
    # @intent: { entity: "spec_directory_files", action: "list the area files heaviest first", behavior: "the block serves files ordered by summed seconds with per-file recorded and timed counts and the area own population figures", layer: "request" }
    it "lists that area's spec files heaviest-first, with what each total was summed over" do
      expect(block(query: { spec_directory: "spec/models" })).to eq(
        "path" => "spec/models",
        "rows" => [
          { "path" => "spec/models/refund_spec.rb", "total_seconds" => 5.0,
            "recorded_count" => 1, "timed_count" => 1 },
          { "path" => "spec/models/order_spec.rb", "total_seconds" => 3.5,
            "recorded_count" => 1, "timed_count" => 1 },
          { "path" => "spec/models/user_spec.rb", "total_seconds" => 2.0,
            "recorded_count" => 2, "timed_count" => 1 }
        ],
        "file_count" => 3,
        "recorded_count" => 4,
        "timed_count" => 3,
        "limit" => SpecObservation::SPEC_DIRECTORY_FILES_LIMIT
      )
    end

    # The sub-block's own key set, stated as its subject rather than pinned as a side effect of the
    # `eq` above — the pattern the by-area rollup's contract example sets, and for the same reason:
    # a guard whose stated subject IS the key set survives a fixture whose numbers change, and says
    # out loud what a new key owes this block before it ships.
    # @intent: { entity: "spec_directory_files", action: "pin the key set", behavior: "the block and its rows serve exactly the contract keys named, so any new key owes this block a stated reason", layer: "request" }
    it "serves exactly the spec_directory_files keys this contract pins" do
      served = block(query: { spec_directory: "spec/models" })

      expect(served.keys)
        .to contain_exactly("path", "rows", "file_count", "recorded_count", "timed_count", "limit")
      expect(served["rows"].first.keys)
        .to contain_exactly("path", "total_seconds", "recorded_count", "timed_count")
    end

    # THE assertion that fails the moment this block is fed by the by-file rollup instead of its own
    # read. Every figure is taken off the RESPONSE, so it is the endpoint's own three blocks
    # disagreeing: the heaviest file in the run belongs to no row here, and the file this list heads
    # with is not the file that ranking heads with.
    # @intent: { entity: "spec_directory_files", action: "differ from the run-wide file ranking", behavior: "the heaviest file run-wide is absent here and this list heads with another file, proving the block is not the by-file rollup filtered", layer: "request" }
    it "lists files the run-wide by-file ranking heads with something else" do
      body = get_repository(query: { spec_directory: "spec/models" })["latest_run"]

      expect(body.dig("spec_files", "rows").first["path"]).to eq("spec/requests/checkout_spec.rb")
      expect(body.dig("spec_directory_files", "rows").first["path"]).to eq("spec/models/refund_spec.rb")
      expect(body.dig("spec_directory_files", "rows").map { it["path"] })
        .not_to include("spec/requests/checkout_spec.rb")
      # And the area this opens is the heaviest AREA while holding no file as heavy as the heaviest
      # FILE — the shape that makes this rung necessary rather than convenient.
      expect(body.dig("spec_directories", "rows").first["path"]).to eq("spec/models")
      expect(body.dig("spec_directory_files", "rows").map { it["total_seconds"] }).to all(be < 9.0)
    end

    # AC2's other half: the area's population figures are counted over the AREA and are not the
    # page's. `recorded_count` counts an example the list's own rows do not distinguish, and
    # `timed_count` is smaller than it — a serializer folding the serialized rows to re-derive
    # either would be computing the page's figure under the area's name.
    # @intent: { entity: "spec_directory_files", action: "count the area population", behavior: "recorded_count and timed_count are counted over the area examples and can both differ from the listed rows length", layer: "request" }
    it "counts the area's examples, not the listed files' rows" do
      served = block(query: { spec_directory: "spec/models" })

      expect(served["recorded_count"]).to eq(4)
      expect(served["recorded_count"]).to be > served["rows"].length
      expect(served["timed_count"]).to eq(3)
      expect(served["timed_count"]).to be < served["recorded_count"]
    end

    # The block's standing rule, asserted over the whole serialized sub-block rather than per key:
    # `Row#duration_label` and `Row#coverage_label` are one call away in the presenter this reads
    # from, and either would still satisfy the assertions above if the fixture's numbers happened to
    # render similarly.
    # @intent: { entity: "spec_directory_files", action: "serve numbers never labels", behavior: "no serialized value is a duration or coverage string the panel would print; totals are floats or null and counts integers", layer: "request" }
    it "serves numbers, never the panel's labels" do
      served = block(query: { spec_directory: "spec/models" })

      expect(served.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(served["rows"].map { it["total_seconds"] }).to all(be_a(Float).or(be_nil))
      expect(served["rows"].map { it["recorded_count"] }).to all(be_a(Integer))
      expect(served["rows"].map { it["timed_count"] }).to all(be_a(Integer))
    end
  end

  # AC7. The area is compared for EQUALITY at one depth, exactly as the rollup it opens out of
  # groups at one depth — a prefix `LIKE` would gather the nested area in, double-count its rows
  # against that rollup, and re-open a drill-down TREE that is a different feature.
  describe "the depth an area is read at" do
    # @intent: { entity: "spec_directory_files", action: "compare the area by equality", behavior: "a nested area under the asked directory contributes no rows to its ancestor because the narrow is exact rather than a prefix match", layer: "request" }
    it "gathers no nested area into its ancestor" do
      expect(block(query: { spec_directory: "spec/models" })["rows"].map { it["path"] })
        .to eq(["spec/models/refund_spec.rb", "spec/models/order_spec.rb", "spec/models/user_spec.rb"])
      expect(block(query: { spec_directory: "spec/models" })["file_count"]).to eq(3)
    end

    # @intent: { entity: "spec_directory_files", action: "answer the nested area itself", behavior: "asking for the nested directory serves its own files under its own name with its own counts", layer: "request" }
    it "answers for the nested area under its own name" do
      served = block(query: { spec_directory: "spec/models/orders" })

      expect(served["rows"].map { it["path"] }).to eq(["spec/models/orders/refund_spec.rb"])
      expect(served["file_count"]).to eq(1)
    end

    # The area a `spec_directories` row is NAMED by is computed by the same expression this read
    # narrows on, so every path a client can take out of that rollup is a path this key can answer —
    # including the one the rollup spells `.`.
    # @intent: { entity: "spec_directory_files", action: "answer the repository root", behavior: "the dot spelling the rollup names top-level files with is itself an answerable ask, so every rollup path leads somewhere", layer: "request" }
    it "answers for the repository root under the name the rollup gives it" do
      root = create_repository(user: @user, github_full_name: "acme/root-files")
      ingest(root, [example_spec(file_path: "smoke_spec.rb", duration: 3.0, line_number: 1),
                    example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 2)])
      key = root.api_keys.create!

      expect(get_repository(key: key).dig("latest_run", "spec_directories", "rows").map { it["path"] })
        .to include(".")
      expect(block(key: key, query: { spec_directory: "." })["rows"].map { it["path"] })
        .to eq(["smoke_spec.rb"])
    end
  end

  # AC3. The distinction this key must not collapse, and it shares it with two siblings on this
  # block: the five rollups are served unconditionally and gate on `#recorded?`, while these three
  # answer a question the CLIENT asked. Copying that gate would spell "you did not ask" and "the
  # area you asked about has no rows" the same way — the collapse `serialized_history` already
  # refuses for an unknown `?branch=`, where the ask is RESTATED beside a zero rather than answered
  # with somebody else's rows.
  describe "the two ways this key can be empty" do
    # @intent: { entity: "spec_directory_files", action: "spell an unasked block as null", behavior: "with no spec_directory parameter the key is present but null while the rest of latest_run is untouched", layer: "request" }
    it "is null — with the key present — when no area was asked for" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to have_key("spec_directory_files")
      expect(body.dig("latest_run", "spec_directory_files")).to be_nil
      # The rest of `latest_run` is untouched by the absence: this key is added BESIDE the five
      # blocks that were there before it, never in place of any of them.
      expect(body.dig("latest_run", "spec_directories", "rows").length).to eq(3)
    end

    # @intent: { entity: "spec_directory_files", action: "answer an empty area with a block", behavior: "an area with no recorded rows yields a present block with zero counts naming the asked path, not an error", layer: "request" }
    it "is a present block with no rows, naming the area, when the run recorded nothing there" do
      served = block(query: { spec_directory: "spec/ghosts" })

      expect(response).to have_http_status(:ok)
      expect(served).to eq("path" => "spec/ghosts", "rows" => [], "file_count" => 0,
                           "recorded_count" => 0, "timed_count" => 0,
                           "limit" => SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent, because the second never wears the
    # first's spelling.
    # @intent: { entity: "spec_directory_files", action: "distinguish the two empty answers", behavior: "null versus a present empty block keeps no-ask separable from asked-but-empty without the client remembering its request", layer: "request" }
    it "spells the two differently, so a client can tell which one it got" do
      expect(block).to be_nil
      expect(block(query: { spec_directory: "spec/ghosts" })).not_to be_nil
      expect(block(query: { spec_directory: "spec/ghosts" })["path"]).to eq("spec/ghosts")
    end

    # A near miss is one of the ordinary ways to arrive at the empty answer — a stale bookmark, a
    # directory renamed since, a typed path with a character missing — and none of them is an error.
    # @intent: { entity: "spec_directory_files", action: "answer a typo with the empty block", behavior: "a near-miss path gets the empty block naming it rather than a prefix match, an error, or somebody else rows", layer: "request" }
    it "answers a typo with the empty block rather than an error or a prefix match" do
      served = block(query: { spec_directory: "spec/model" })

      expect(response).to have_http_status(:ok)
      expect(served["rows"]).to eq([])
      expect(served["path"]).to eq("spec/model")
    end

    # There is no `latest_run` at all for a repository whose CI has never reported, so the ask
    # cannot conjure one — the rule the whole block follows, restated here because this is one of
    # the three keys on it a client can ask for by name.
    # @intent: { entity: "spec_directory_files", action: "stay null for a silent repository", behavior: "a repository CI never reported on has no latest_run at all, so the ask cannot conjure one", layer: "request" }
    it "serves no block at all when CI has never reported" do
      silent = create_repository(user: @user, github_full_name: "acme/never-ran")

      body = get_repository(key: silent.api_keys.create!, query: { spec_directory: "spec/models" })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC4. The shapes a query string can legally parse into that are NOT a path, pinned once for every
  # surface in `spec/support/shared_examples/malformed_spec_directory_param.rb`. This one reaches a
  # SQL EQUALITY comparison, where an Array does not raise: it becomes an `IN` list and answers a
  # question nobody asked, under a `path` naming one directory.
  describe "a spec-directory parameter that is not a path" do
    # The NO-ASK answer specifically, and not merely a 200 — the shared example's own comment
    # requires it, because a guard that swallowed every value would answer 200 on all three shapes
    # too.
    def expect_spec_directory_param_treated_as_no_ask(query)
      expect(block(query: query)).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed spec-directory parameter as no ask"

    # THE positive path, beside the group, which is what separates "the guard read the parameter"
    # from "the endpoint ignores this parameter entirely".
    # @intent: { entity: "spec_directory_files", action: "honour a well-formed path", behavior: "a genuine directory string serves that area rows, separating a reading guard from a parameter the endpoint ignores", layer: "request" }
    it "honours a spec_directory that IS a path" do
      expect(block(query: { spec_directory: "spec/models" })["rows"].length).to eq(3)
    end

    # An empty ask is no ask, not a comparison against the empty string: `DIRECTORY_EXPRESSION`
    # coalesces a path with no separator to `.`, so no row's area can be blank and an empty ask
    # would open a block guaranteed to hold nothing.
    # @intent: { entity: "spec_directory_files", action: "treat an empty path as no ask", behavior: "an empty spec_directory strips to no ask rather than opening a block no row could ever match", layer: "request" }
    it "treats an empty spec_directory as no ask" do
      expect(block(query: { spec_directory: "" })).to be_nil
    end
  end

  # AC5. The cost, and the one axis on which this key differs from every other block on
  # `latest_run`: those issue their reads unconditionally, so `#recorded?` is an answer DERIVED from
  # a read that was paid for anyway. Here the gate is the ASK and it is decided before any query is
  # issued, so a client that never sends the parameter pays nothing at all for the key's existence.
  describe "what the drill-in costs the endpoint" do
    # @intent: { entity: "spec_directory_files", action: "cost one query when asked", behavior: "the ask adds exactly one query over baseline, the empty answer costs the same one, and a malformed shape costs none", layer: "request" }
    it "adds exactly one query when asked, and none when not" do
      # Warmed first, on the precedent the sibling cost blocks set: the very first request of an
      # example pays for state a second one does not — an API key's first use is recorded — and a
      # baseline taken over it would be measuring the warm-up rather than the block.
      get_repository
      baseline = count_queries { get_repository }

      expect(count_queries { get_repository(query: { spec_directory: "spec/models" }) })
        .to eq(baseline + 1)
      # The empty answer costs the same one: the read is what DISCOVERS that the area has no rows,
      # so there is no cheaper way to ask and no gate in front of it to add.
      expect(count_queries { get_repository(query: { spec_directory: "spec/ghosts" }) })
        .to eq(baseline + 1)
      # And a malformed shape is no ask, which means it is also no query — the guard sits in front
      # of the read rather than inside it.
      expect(count_queries { get_repository(query: { spec_directory: ["spec/models"] }) })
        .to eq(baseline)
    end

    # The same bound classified rather than counted, so "one more query" cannot be satisfied by a
    # different grain reading twice while this one reads none. `directory_files_grain_reads` and the
    # partition it belongs to come from spec/support/observation_grain_reads.rb, which is also where
    # the argument for matching every grain POSITIVELY is made — and where this grain's pattern is
    # separated from the by-file rollup's, which groups the same column and ranks the same way.
    # @intent: { entity: "spec_directory_files", action: "read its own grain once", behavior: "the classified partition accounts for every observation read and the drill-in adds exactly one directory-files read only when asked", layer: "request" }
    it "reads spec_observations once for its own grain, and leaves every other grain alone" do
      area, file, example, description, flakiness, growth, directory_files =
        observation_reads_by_grain { get_repository(query: { spec_directory: "spec/models" }) }

      expect([area.length, file.length, example.length, description.length,
              flakiness.length, growth.length, directory_files.length]).to eq([1, 1, 2, 2, 0, 0, 1])
      # And the classified reads are ALL of them — the assertion no per-grain count can make,
      # because a read matching no grain's pattern is invisible to every one of them.
      expect(observation_reads { get_repository(query: { spec_directory: "spec/models" }) }.length)
        .to eq(classified_observation_reads { get_repository(query: { spec_directory: "spec/models" }) })
      # ⭐ ONE MORE SINCE SPGD-711 — `latest_run.intent_readings`, an aggregate over the anchored
      # run's rows splitting them into authored, derived and unreadable. It is the only UNGATED
      # addition this endpoint has taken: every drill-in here costs nothing until a client asks, and
      # this is served on every response, because a correction a client has to opt into leaves it
      # reading `total_specs - annotated_specs` as the count of what SpecGuard cannot see. It lands
      # in its own grain (`AS run_authored_count`) and touches none of the figures above.
      expect(observation_reads { get_repository(query: { spec_directory: "spec/models" }) }.length).to eq(8)
      # Seven without the ask — the total `repository_latest_run_spec.rb` pins for this endpoint,
      # restated here as the thing this slice did NOT change.
      expect(observation_reads { get_repository }.length).to eq(7)
      expect(directory_files_grain_reads { get_repository }).to be_empty
    end

    # The suite-size axis, and the one that decides whether this key is affordable at the roadmap's
    # 20,000-example design point: the read is bounded by the size of the AREA and capped, so an
    # area of 4 files and one of 200 cost the same single query. A serializer that fetched the rows
    # and grouped them in Ruby, or that took a second pass for `file_count`, reads as more here and
    # as more again as the suite grows.
    # @intent: { entity: "spec_directory_files", action: "stay flat as the area widens", behavior: "an area of two hundred files costs the same single read as one of four because the query is bounded and capped", layer: "request" }
    it "reads it once however many files the area holds" do
      big = create_repository(user: @user, github_full_name: "acme/wide-area")
      ingest(big, Array.new(200) do |index|
        example_spec(file_path: "spec/models/thing_#{index}_spec.rb", duration: 0.5, line_number: index + 1)
      end)
      key = big.api_keys.create!

      expect(directory_files_grain_reads { get_repository(key: key, query: { spec_directory: "spec/models" }) }
               .length).to eq(1)
      expect(block(key: key, query: { spec_directory: "spec/models" })["file_count"]).to eq(200)
    end
  end

  # The list is capped by its OWN constant — not the by-file rollup's ten and not the by-file
  # drill-down's fifty — and a capped list that does not disclose its cap is the lie
  # `SpecDirectoryFiles#truncated?` refuses one rung up. The area's population has to come from the
  # read's window rather than from the rows on hand, which are the truncated figure.
  describe "an area holding more files than the limit" do
    let(:capped) do
      repo = create_repository(user: @user, github_full_name: "acme/capped-area")
      ingest(repo, Array.new(27) do |index|
        example_spec(file_path: "spec/models/thing_#{index}_spec.rb", duration: index + 1.0,
                     line_number: index + 1)
      end)
      repo
    end

    # @intent: { entity: "spec_directory_files", action: "disclose a truncated area", behavior: "an area past the limit serves the limit rows but reports the true file and recorded counts beside the limit", layer: "request" }
    it "serves the limit's worth of rows, and says how many files the area holds" do
      served = block(key: capped.api_keys.create!, query: { spec_directory: "spec/models" })

      expect(served["rows"].length).to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
      expect(served["file_count"]).to eq(27)
      expect(served["file_count"]).to be > served["rows"].length
      # Counted over the AREA and not over the page, which on a truncated area are different
      # populations: 27 examples recorded, 25 rows shown.
      expect(served["recorded_count"]).to eq(27)
      expect(served["limit"]).to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
    end
  end

  # An area with rows and no timings is a LIST with no ranking — the files exist and their example
  # counts are worth reading, and what a client must not receive is a `0.0` for a total nobody
  # measured.
  describe "an area none of whose examples were timed" do
    let(:untimed) do
      repo = create_repository(user: @user, github_full_name: "acme/untimed-area")
      ingest(repo, [example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 1),
                    example_spec(file_path: "spec/models/refund_spec.rb", duration: nil, line_number: 2)])
      repo
    end

    # @intent: { entity: "spec_directory_files", action: "serve null totals when untimed", behavior: "an area with no timings serves null total_seconds and a zero timed_count rather than zeros nobody measured", layer: "request" }
    it "serves null totals rather than zeros, and says the area timed nothing" do
      served = block(key: untimed.api_keys.create!, query: { spec_directory: "spec/models" })

      expect(served["rows"].map { it["total_seconds"] }).to eq([nil, nil])
      expect(served["rows"].map { it["recorded_count"] }).to eq([1, 1])
      expect(served["recorded_count"]).to eq(2)
      expect(served["timed_count"]).to eq(0)
      expect(served.to_json).not_to include("0.0")
    end
  end

  # AC6. `latest_run` is never re-anchored by `?branch=` — *"every request; only `history`
  # narrows"* — so the two parameters compose without interacting: the drill-in always describes the
  # newest run, exactly as the panel does, while `history` narrows around it.
  describe "composing with a branch ask" do
    let!(:other_branch_run) do
      ingest(repository,
             [example_spec(file_path: "spec/models/refund_spec.rb", duration: 1.0, line_number: 1),
              example_spec(file_path: "spec/models/audit_spec.rb", duration: 4.0, line_number: 2)],
             commit_sha: "feedfacecafe0002", branch: "feature/x")
    end

    # @intent: { entity: "spec_directory_files", action: "compose with a branch ask", behavior: "the drill-in keeps describing the newest run whatever branch the window was narrowed to, while history narrows independently", layer: "request" }
    it "describes the latest run under a branch ask, and narrows history independently" do
      body = get_repository(query: { spec_directory: "spec/models", branch: "main" })

      # The newest run is the `feature/x` one, and that is the run the drill-in describes even
      # though the window was narrowed to `main` — the surprise `serialized_latest_run` states
      # plainly rather than hides.
      expect(body.dig("latest_run", "commit_sha")).to eq("feedfacecafe0002")
      expect(body.dig("latest_run", "spec_directory_files", "rows").map { it["path"] })
        .to eq(["spec/models/audit_spec.rb", "spec/models/refund_spec.rb"])
      expect(body.dig("history_window", "branch")).to eq("main")
      expect(body["history"].map { it["commit_sha"] }).to eq(["feedfacecafe0001"])
    end

    # @intent: { entity: "spec_directory_files", action: "ignore the branch for its own answer", behavior: "the block is identical with and without the branch ask because latest_run is never re-anchored", layer: "request" }
    it "serves the same drill-in with and without the branch ask" do
      with_branch = block(query: { spec_directory: "spec/models", branch: "main" })

      expect(with_branch).to eq(block(query: { spec_directory: "spec/models" }))
      expect(with_branch["rows"].length).to eq(2)
    end
  end

  # AC2. The API and the dashboard cannot name different figures for the same repository, the same
  # run and the same area. Read off the RENDERED PAGE and off the presenter the page assigns —
  # never off a second hand-written query, which would only compare the endpoint against itself.
  describe "against what repositories#show renders for the same area" do
    def panel_rows
      panel = Capybara.string(response.body).find("#spec-directory-files")
      panel.all("tbody tr").map do |row|
        path, coverage, duration = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

        { "path" => path, "coverage" => coverage, "duration" => duration }
      end
    end

    # The ORDER is asserted as a sequence, because that is the half a `match_array` would drop and
    # the half the `NULLS LAST` in the aggregate exists to get right. Every figure comes off the
    # presenter rather than off the fixture's numbers: two independent hand-written expectations
    # would both still pass if the endpoint started reading a different run or a different area.
    # @intent: { entity: "spec_directory_files", action: "match the presenter the panel uses", behavior: "the serialized rows equal the presenter figures the repositories#show panel renders from for the same run and area", layer: "request" }
    it "serves the same rows, in the same order, that the panel renders from" do
      served = block(query: { spec_directory: "spec/models" })
      shown = SpecDirectoryFiles.for(repository.latest_test_run, "spec/models")

      expect(served["path"]).to eq(shown.path)
      expect(served["rows"].map { it["path"] }).to eq(shown.rows.map(&:path))
      expect(served["rows"].map { it["total_seconds"] }).to eq(shown.rows.map(&:total_seconds))
      expect(served["rows"].map { it["recorded_count"] }).to eq(shown.rows.map(&:recorded_count))
      expect(served["rows"].map { it["timed_count"] }).to eq(shown.rows.map(&:timed_count))
      expect(served["file_count"]).to eq(shown.file_count)
      expect(served["recorded_count"]).to eq(shown.recorded_count)
      expect(served["timed_count"]).to eq(shown.timed_count)
    end

    # And the same comparison against the PAGE, which is the surface a reader actually holds. The
    # page prints the labels and the block serves the operands, so both readings are assembled here
    # — the duration through `SpecObservation.humanized_duration`, the seam every grain on that page
    # renders through, rather than through a hand-rolled `"%.2fs"` that would be a second definition
    # of the spelling.
    # @intent: { entity: "spec_directory_files", action: "match the rendered page", behavior: "the panel prints labels built from the same operands the block serves, so both surfaces name the same files in the same order", layer: "request" }
    it "names the same files, with the same operands, as the panel prints" do
      served = block(query: { spec_directory: "spec/models" })
      get repository_path(repository, spec_directory: "spec/models")

      expect(panel_rows).to eq(
        served["rows"].map do |row|
          { "path" => row["path"],
            "coverage" => "#{row["timed_count"]} of #{row["recorded_count"]}",
            "duration" => SpecObservation.humanized_duration(row["total_seconds"]) }
        end
      )
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(panel_rows.length).to eq(3)
      # And the label vocabulary the JSON block refuses IS what this data makes the panel print, so
      # the "numbers, never labels" example above is refusing something real.
      expect(panel_rows.map { it["coverage"] }).to include("1 of 2")
      expect(panel_rows.map { it["duration"] }).to include("5.00s")
    end
  end
end
