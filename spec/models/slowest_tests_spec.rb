# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlowestTests do
  let(:repository) { create_repository }
  # OLDEST FIRST, as `Repository#suite_size_trajectory` hands its window over — so `runs.last` is
  # the anchor, and a spec that reversed this would be asserting against a partition nobody makes.
  let(:runs) { (1..4).map { |i| create_test_run(repository: repository, commit_sha: "sha#{i}", branch: "main") } }
  let(:anchor) { runs.last }

  # One identity per durable test, each with its own text so the unique `(repository_id,
  # text_digest)` is satisfied. Nothing under test reads `embedding` — resolution is
  # `Ingest::IdentityResolver`'s and is asserted there — so these are the rows the resolver WOULD
  # have written, seeded directly.
  def identity(text) = create_spec_identity(repository: repository, text: text)

  def observe(run, spec_identity:, name:, path:, line: 1, duration: 1.0, example: name)
    repository.spec_observations.create!(
      test_run: run, spec_identity: spec_identity, name: name, spec_file_path: path, file_path: path,
      line_number: line, duration_seconds: duration, outcome: "passed", status: "unannotated",
      example_id: "./#{path}[1:#{example}]"
    )
  end

  describe "the ranking it builds" do
    let(:steady) { identity("Invoice finalize locks the line items") }
    let(:moved) { identity("Checkout rejects an expired card") }
    let(:renamed) { identity("Report exports the quarterly totals") }
    let(:looped) { identity("Currency converts each supported code") }
    let(:untimed) { identity("Webhook replays a failed delivery") }
    let(:deleted) { identity("Legacy importer parses the old format") }

    before do
      runs.each_with_index do |run, index|
        observe(run, spec_identity: steady, name: "steady", path: "spec/steady_spec.rb", duration: 1.0)
        # ⭐ THE MOVED TEST: a different file AND a different line on either side of the window.
        observe(run, spec_identity: moved, name: "moved",
                path: index < 2 ? "spec/before_spec.rb" : "spec/after_spec.rb",
                line: index < 2 ? 10 : 400, duration: 3.0)
        # The same test, reworded midway — an edit that starts a fresh history under any key but this
        # one, and which `UnstableTests`' `GROUP BY name` structurally cannot survive.
        observe(run, spec_identity: renamed,
                name: index < 2 ? "exports quarterly totals" : "exports the quarterly totals",
                path: "spec/report_spec.rb", duration: 2.0)
        # A table-driven loop: two examples per run under ONE identity, which is what the unique text
        # digest and the resolver's cosine-1.0 match agree on.
        2.times do |case_index|
          observe(run, spec_identity: looped, name: "looped", path: "spec/currency_spec.rb",
                  line: case_index, duration: 0.5, example: "looped-#{case_index}")
        end
        observe(run, spec_identity: untimed, name: "untimed", path: "spec/webhook_spec.rb",
                duration: nil)
      end

      # Present in the window's first two runs and gone by the anchor — a deleted test, and the one
      # the ⭐ partition excludes however slow it was.
      runs.first(2).each do |run|
        observe(run, spec_identity: deleted, name: "deleted", path: "spec/legacy_spec.rb", duration: 99.0)
      end

      # One row of the anchor that never reached an identity.
      repository.spec_observations.create!(
        test_run: anchor, name: "unresolved", spec_file_path: "spec/pending_spec.rb",
        file_path: "spec/pending_spec.rb", line_number: 1, duration_seconds: 4.0, outcome: "passed",
        status: "unannotated", example_id: "./spec/pending_spec.rb[1:1]"
      )
    end

    subject(:ranking) { described_class.for(repository, runs, branch: "main") }

    # @intent: { entity: "SlowestTests", action: "rank by summed wall clock", behavior: "identities are ordered by total seconds across the window with the untimed one last rather than first", layer: "unit" }
    it "ranks the window's tests by the wall clock they cost across it, slowest first" do
      expect(ranking.rows.map(&:spec_identity_id))
        .to eq([moved.id, renamed.id, looped.id, steady.id, untimed.id])
    end

    # ⭐ THE MOVED-TEST GUARANTEE at the grain a reader sees it. The test changed both halves of the
    # `file_path:line_number` coordinate midway through the window and is ONE row totalling all four
    # runs — 12 seconds, not two rows of 6. Under any positional key this is the head of the list
    # split in half and neither half at the head.
    # @intent: { entity: "SlowestTests", action: "sum a moved test", behavior: "a test that changed file and line midway is one row totalling all four runs and is flagged moved with both files listed", layer: "unit" }
    it "keeps a moved test's history together and sums it" do
      row = ranking.rows.first

      expect(row.spec_identity_id).to eq(moved.id)
      expect(row.total_seconds).to be_within(0.0001).of(12.0)
      expect(row.run_count).to eq(4)
      expect(row.moved?).to be true
      expect(row.files_seen).to eq(["spec/after_spec.rb", "spec/before_spec.rb"])
    end

    # The same guarantee on the other axis, and the one `UnstableTests` cannot make: grouped on
    # `name`, a reworded test is two tests and its runtime history starts over.
    # @intent: { entity: "SlowestTests", action: "sum a reworded test", behavior: "a test renamed midway keeps one history totalling both spellings and is flagged renamed rather than moved", layer: "unit" }
    it "keeps a reworded test's history together and says it was reworded" do
      row = ranking.rows.find { |candidate| candidate.spec_identity_id == renamed.id }

      expect(row.total_seconds).to be_within(0.0001).of(8.0)
      expect(row.renamed?).to be true
      expect(row.descriptions).to eq(["exports quarterly totals", "exports the quarterly totals"])
      expect(row.moved?).to be false
    end

    # Eight rows across four runs, which is the pair that separates "slow in four runs" from "run
    # twice in each of two" — and the reason the total alone cannot be attributed.
    # @intent: { entity: "SlowestTests", action: "distinguish repetition from spread", behavior: "recorded_count versus run_count separates a test run twice per run from one run once across more runs", layer: "unit" }
    it "tells a test that ran repeatedly within a run from one that ran in more runs" do
      looped_row = ranking.rows.find { |row| row.spec_identity_id == looped.id }
      steady_row = ranking.rows.find { |row| row.spec_identity_id == steady.id }

      expect([looped_row.recorded_count, looped_row.run_count]).to eq([8, 4])
      expect(looped_row.repeated_within_run?).to be true
      expect([steady_row.recorded_count, steady_row.run_count]).to eq([4, 4])
      expect(steady_row.repeated_within_run?).to be false
    end

    # Equal totals, and the tiebreak is the row count — so a repository whose tests total alike has
    # one stable order rather than one the planner picks afresh per request.
    # @intent: { entity: "SlowestTests", action: "break ties by row count", behavior: "equal totals order deterministically by recorded row count instead of the planner's choice", layer: "unit" }
    it "breaks a tie on equal totals rather than leaving the order to the planner" do
      looped_row, steady_row = ranking.rows.values_at(2, 3)

      expect(looped_row.total_seconds).to be_within(0.0001).of(steady_row.total_seconds)
      expect(looped_row.spec_identity_id).to eq(looped.id)
    end

    # ⭐ A test nothing timed sorts LAST and says "not reported" — never `0.00s`, which would be a
    # measurement invented out of silence, and never the head of the list, which is where a naive
    # `DESC` would put it in Postgres.
    # @intent: { entity: "SlowestTests", action: "sort untimed last", behavior: "a test with no timed rows sorts last and renders not reported rather than a zero duration", layer: "unit" }
    it "puts a test nothing timed at the end and refuses to render it as a zero" do
      row = ranking.rows.last

      expect(row.spec_identity_id).to eq(untimed.id)
      expect(row.total_seconds).to be_nil
      expect(row.timed?).to be false
      expect(row.duration_label).to eq("not reported")
      expect(row.coverage_label).to eq("0 of 4")
    end

    # ⭐ THE PARTITION. The deleted test cost 99 seconds a run — far more than anything in the list —
    # and is absent, because it is not in the suite being asked about. `#anchor_run` is what names
    # the run that decided so.
    # @intent: { entity: "SlowestTests", action: "rank only the anchor suite", behavior: "a test absent from the anchor run is excluded no matter how slow it was in earlier runs of the window", layer: "unit" }
    it "ranks the anchor run's suite and not every test the window ever saw" do
      expect(ranking.rows.map(&:spec_identity_id)).not_to include(deleted.id)
      expect(ranking.anchor_run).to eq(anchor)
      expect(ranking.run_count).to eq(4)
      expect(ranking.branch).to eq("main")
    end

    # The fourth state, and the ONLY one whose empty list a reader may take as "nothing was slow" —
    # which is why it is named rather than inferred. The three above are all `rows.empty?` too, and
    # a surface that branched on `any?` alone would render the same blank panel for all four.
    # @intent: { entity: "SlowestTests", action: "name the ranked state", behavior: "a fully ranked ranking reports state ranked with recorded and resolved both true", layer: "unit" }
    it "names itself ranked, the one state an empty list could be read from" do
      expect(ranking.state).to eq(:ranked)
      expect(ranking.recorded?).to be true
      expect(ranking.resolved?).to be true
    end

    # The window and nothing wider: a fifth run outside it holds the same tests and must not be
    # summed into their totals.
    # @intent: { entity: "SlowestTests", action: "sum only the given window", behavior: "narrowing the run list halves the totals and the run count to the window actually asked about", layer: "unit" }
    it "sums only the runs of the window it was given" do
      narrowed = described_class.for(repository, runs.last(2), branch: "main")

      expect(narrowed.rows.first.total_seconds).to be_within(0.0001).of(6.0)
      expect(narrowed.run_count).to eq(2)
    end

    # What a single row says about its OWN history, as against what the object above says about the
    # population. These render on the same line of the panel and each answers a question the summed
    # total cannot.
    describe "what each row says about its own history" do
      # A test added midway through the window: present in the anchor, so it ranks, but with a
      # history shorter than the window it is being reported over. Seeded HERE rather than in the
      # outer block because it moves the anchor's row counts, which the disclosure examples below
      # pin exactly.
      let(:late) { identity("Search reindexes the changed documents") }

      before do
        runs.last(2).each do |run|
          observe(run, spec_identity: late, name: "late", path: "spec/search_spec.rb", duration: 5.0)
        end
      end

      # ⭐ 60 seconds is one minute-long test or sixty runs of a cheap one, and the ordering — which
      # is on the SUM — cannot tell them apart. `#slowest_label` is what separates them: the moved
      # test totals 12s across four 3s runs, the looped one totals 4s across eight 0.5s ones, and
      # the two sit four rows apart in a list that says nothing about the difference without this.
      # @intent: { entity: "SlowestTests", action: "state the longest single run", behavior: "slowest_label beside the total separates one long run from many cheap ones the sum cannot distinguish", layer: "unit" }
      it "states the single longest run beside the total, which the ordering cannot" do
        moved_row = ranking.rows.find { |row| row.spec_identity_id == moved.id }
        looped_row = ranking.rows.find { |row| row.spec_identity_id == looped.id }

        expect([moved_row.duration_label, moved_row.slowest_label]).to eq(["12.00s", "3.00s"])
        expect([looped_row.duration_label, looped_row.slowest_label]).to eq(["4.00s", "0.50s"])
      end

      # The same nil hazard `#duration_label` is tested for one method over, at the other aggregate:
      # an untimed group's `MAX` is SQL NULL, and rendering it as `0.00s` would report a measurement
      # invented out of silence — the single fastest test in the suite, from rows nothing timed.
      # @intent: { entity: "SlowestTests", action: "refuse a zero longest run", behavior: "an untimed test's longest run renders not reported rather than 0.00s", layer: "unit" }
      it "refuses to render an untimed test's longest run as a zero" do
        row = ranking.rows.find { |candidate| candidate.spec_identity_id == untimed.id }

        expect(row.slowest_seconds).to be_nil
        expect(row.slowest_label).to eq("not reported")
      end

      # Rows of a test's own history that carried no duration, and so are not in its total — the
      # per-row half of the disclosure the object makes for the anchor.
      # @intent: { entity: "SlowestTests", action: "count untimed own rows", behavior: "each row reports how many of its own observations carried no duration, excluded from its total", layer: "unit" }
      it "counts the rows of its own history that carried no timing" do
        untimed_row = ranking.rows.find { |row| row.spec_identity_id == untimed.id }
        moved_row = ranking.rows.find { |row| row.spec_identity_id == moved.id }

        expect([untimed_row.recorded_count, untimed_row.timed_count]).to eq([4, 0])
        expect(untimed_row.untimed_count).to eq(4)
        expect(moved_row.untimed_count).to eq(0)
      end

      # ⭐ How much of the window this test was seen in — 2 of 4 for one added midway, which is the
      # figure that keeps its 10 seconds from being read against the same denominator as a test that
      # ran throughout.
      # @intent: { entity: "SlowestTests", action: "state window appearance", behavior: "the appearance label shows how many of the window's runs the test was seen in", layer: "unit" }
      it "states how much of the window it appeared in" do
        late_row = ranking.rows.find { |row| row.spec_identity_id == late.id }
        steady_row = ranking.rows.find { |row| row.spec_identity_id == steady.id }

        expect(late_row.run_count).to eq(2)
        expect(late_row.appearance_label(ranking.run_count)).to eq("2 of 4")
        expect(steady_row.appearance_label(ranking.run_count)).to eq("4 of 4")
      end

      # The denominator is the CALLER'S, and this is the signature a caller can get wrong. A row does
      # not know the window it is being reported over — holding one would be the second, drifting
      # spelling of the window that the class comment refuses — so the parameter is what it renders,
      # and passing a different one changes the label rather than being quietly ignored.
      # @intent: { entity: "SlowestTests", action: "take the window parameter", behavior: "the appearance denominator is the caller's argument, so a different window changes the label rather than being ignored", layer: "unit" }
      it "takes the window it renders against rather than holding one of its own" do
        late_row = ranking.rows.find { |row| row.spec_identity_id == late.id }

        expect(late_row.appearance_label(30)).to eq("2 of 30")
      end
    end

    describe "what it discloses about the population it ranked" do
      # Seven rows in the anchor, six of them resolved, five of those timed. The fraction's halves
      # come back from one read of the run the ranking was drawn from, spelled through the one seam
      # every single-sided coverage label on this application goes through.
      # @intent: { entity: "SlowestTests", action: "state timing coverage", behavior: "the coverage label reports timed rows over resolved rows of the ranked anchor with the untimed remainder counted", layer: "unit" }
      it "states the timing coverage of the rows it ranked" do
        expect(ranking.coverage_label).to eq("5 of 6")
        expect([ranking.resolved_count, ranking.timed_count]).to eq([6, 5])
        expect(ranking.untimed_count).to eq(1)
        expect(ranking.complete?).to be false
      end

      # @intent: { entity: "SlowestTests", action: "disclose unresolved exclusions", behavior: "anchor rows with no durable identity are counted and excluded from the ranking with the exclusion flagged", layer: "unit" }
      it "counts the anchor's rows that carried no durable identity, and says it excluded them" do
        expect(ranking.recorded_count).to eq(7)
        expect(ranking.unresolved_count).to eq(1)
        expect(ranking.excluded_unresolved_rows?).to be true
      end

      # ⚠️ THE SPGD-367 MONOTONICITY TRAP, refused. A failed embed's `spec_identity_id` stays NULL
      # forever, so an exclusion count taken repository-wide grows without bound as history
      # accumulates — a suite whose every current test resolves cleanly would go on reporting
      # exclusions from runs long past. The count is over the run this ranking was actually drawn
      # from, so eighty stale unresolved rows outside the window change it by nothing.
      # @intent: { entity: "SlowestTests", action: "scope exclusions to the run", behavior: "stale unresolved rows on runs outside the window never change the unresolved count", layer: "unit" }
      it "counts exclusions over the run it read and never over the repository" do
        stale = create_test_run(repository: repository, commit_sha: "ancient", branch: "main")
        80.times do |index|
          repository.spec_observations.create!(
            test_run: stale, name: "ancient #{index}", spec_file_path: "spec/old_spec.rb",
            file_path: "spec/old_spec.rb", line_number: index, duration_seconds: 1.0,
            outcome: "passed", status: "unannotated", example_id: "./spec/old_spec.rb[1:#{index}]"
          )
        end

        expect(described_class.for(repository, runs, branch: "main").unresolved_count).to eq(1)
      end

      # A capped list that does not disclose its cap is read as the whole story.
      # @intent: { entity: "SlowestTests", action: "disclose the cap", behavior: "a limit reports truncated with the candidate and unexamined identity counts so the list is not read as complete", layer: "unit" }
      it "discloses the identities the cap kept it from examining" do
        capped = described_class.for(repository, runs, branch: "main", limit: 2)

        expect(capped.rows.map(&:spec_identity_id)).to eq([moved.id, renamed.id])
        expect(capped.truncated?).to be true
        expect(capped.candidate_count).to eq(5)
        expect(capped.unexamined_count).to eq(3)
      end

      # @intent: { entity: "SlowestTests", action: "report no truncation when complete", behavior: "an uncapped ranking reports not truncated and zero unexamined identities", layer: "unit" }
      it "reports no truncation when every identity of the anchor was examined" do
        expect(ranking.truncated?).to be false
        expect(ranking.unexamined_count).to eq(0)
      end

      # Three statements for the whole panel — a gate, a candidate step and a composition — and none
      # of them grows with the size of the suite or the length of the window.
      # @intent: { entity: "SlowestTests", action: "bound the reads", behavior: "building the ranking costs exactly three queries regardless of suite size or window length", layer: "unit" }
      it "costs three bounded reads" do
        expect(count_queries { described_class.for(repository, runs, branch: "main").rows }).to eq(3)
      end
    end
  end

  # ⭐ The three empty lists, and why they must never be one blank panel. Only the last of them may
  # be read as "nothing in this suite is slow".
  describe "the states an empty ranking can be in" do
    subject(:ranking) { described_class.for(repository, runs, branch: "main") }

    context "when the window holds no runs at all" do
      # @intent: { entity: "SlowestTests", action: "answer an empty window free", behavior: "a window with no runs builds the object with zero queries, state no_runs, and nil rather than zero counts", layer: "unit" }
      it "answers without asking the database anything, and reports no figure it did not read" do
        repository # materialised before the measurement, so the count is this object's and not the fixture's
        empty = nil
        expect(count_queries { empty = described_class.for(repository, [], branch: "main") }).to eq(0)

        expect(empty.any?).to be false
        expect(empty.recorded?).to be false
        expect(empty.resolved?).to be false
        expect(empty.anchor_run).to be_nil
        # The state SAYS which of the four this is, rather than leaving a caller to reassemble it
        # from the three predicates above in the right order.
        expect(empty.state).to eq(:no_runs)
        # `nil` and never `0`: a zero here is an exclusion count nothing measured, indistinguishable
        # on the wire from a window measured to have excluded nothing.
        expect([empty.recorded_count, empty.unresolved_count, empty.candidate_count,
                empty.resolved_count, empty.timed_count]).to all(be_nil)
      end
    end

    context "when the anchor run wrote no per-example rows" do
      # The window is materialised here rather than lazily inside the measurement below, so what is
      # counted is this object's reads and not the fixture's inserts.
      before { runs }

      # @intent: { entity: "SlowestTests", action: "distinguish unrecorded from empty", behavior: "an anchor run with no per-example rows reports state unrecorded with zero counts rather than nothing slow", layer: "unit" }
      it "says the suite has no grain at this depth rather than that nothing was slow" do
        expect(ranking.recorded?).to be false
        expect(ranking.resolved?).to be false
        expect(ranking.any?).to be false
        expect([ranking.recorded_count, ranking.unresolved_count]).to eq([0, 0])
        expect(ranking.excluded_unresolved_rows?).to be false
        # Distinct from `:no_runs` above: there IS a run and it was read, and "this repository's CI
        # has never sent per-example detail" is a different thing to go and fix than "no runs yet".
        expect(ranking.state).to eq(:unrecorded)
      end

      # The gate is asked first and on its own, so a window with nothing to rank costs ONE read.
      # @intent: { entity: "SlowestTests", action: "stop after the gate", behavior: "a window whose anchor recorded nothing costs one query before the candidate step is skipped", layer: "unit" }
      it "stops after the gate" do
        expect(count_queries { described_class.for(repository, runs, branch: "main").rows }).to eq(1)
      end
    end

    # ⭐ THE VACUOUS GREEN CASE. `Ingest::IdentityResolutionJob` runs asynchronously and the ingest
    # controller's own header says every reader of the embeddings trails a run that just landed, so
    # this is the ORDINARY state for the seconds after an ingest — and served as an empty list it
    # reads as "nothing in this suite is slow".
    context "when the anchor run's rows have not been resolved to identities yet" do
      before do
        runs.each_with_index do |run, index|
          repository.spec_observations.create!(
            test_run: run, name: "pending #{index}", spec_file_path: "spec/pending_spec.rb",
            file_path: "spec/pending_spec.rb", line_number: 1, duration_seconds: 9.0,
            outcome: "passed", status: "unannotated", example_id: "./spec/pending_spec.rb[1:#{index}]"
          )
        end
      end

      # @intent: { entity: "SlowestTests", action: "distinguish unresolved from empty", behavior: "rows recorded but unresolved report state unresolved with the exclusion flagged rather than rendering as an empty suite", layer: "unit" }
      it "reports rows recorded and none of them resolved, distinguishably from an empty suite" do
        expect(ranking.recorded?).to be true
        expect(ranking.resolved?).to be false
        expect(ranking.any?).to be false
        expect(ranking.recorded_count).to eq(1)
        expect(ranking.unresolved_count).to eq(1)
        expect(ranking.excluded_unresolved_rows?).to be true
        # ⭐ The state a surface must never render as an empty ranking — named, so it can be `case`d
        # on rather than inferred from `recorded? && !resolved?`.
        expect(ranking.state).to eq(:unresolved)
      end

      # Every figure the candidate step would have produced is absent rather than zeroed — the step
      # never ran, and a `0` for the timing coverage of a ranking that does not exist is a
      # measurement invented out of a return statement.
      # @intent: { entity: "SlowestTests", action: "omit unmeasured figures", behavior: "candidate, resolved and timed counts are nil rather than zeroed when the candidate step never ran", layer: "unit" }
      it "reports no figure the candidate step never measured" do
        expect([ranking.candidate_count, ranking.resolved_count, ranking.timed_count]).to all(be_nil)
        expect(ranking.truncated?).to be false
      end

      # @intent: { entity: "SlowestTests", action: "stop after the gate", behavior: "the unresolved gate costs one query before the candidate step is skipped", layer: "unit" }
      it "stops after the gate" do
        expect(count_queries { described_class.for(repository, runs, branch: "main").rows }).to eq(1)
      end
    end
  end

  # The caption half of this object has no structural tenant protection —
  # `SpecObservation.identity_presence_in` is `where(test_run_id:)` with no `repository_id`
  # predicate — so a foreign anchor would put another tenant's row counts beside this one's list.
  # {NearDuplicateClusters} checks its own weighed run for exactly this, and this is the same read.
  describe "the tenant boundary" do
    # @intent: { entity: "SlowestTests", action: "refuse a foreign anchor", behavior: "a window anchored on another repository's run raises ArgumentError naming the owning repository", layer: "unit" }
    it "refuses a window anchored on another repository's run" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other")
      foreign = create_test_run(repository: other, commit_sha: "foreign", branch: "main")

      expect { described_class.for(repository, [foreign], branch: "main") }
        .to raise_error(ArgumentError, /belongs to repository #{other.id}, not #{repository.id}/)
    end
  end
end
