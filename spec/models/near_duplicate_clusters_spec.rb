# frozen_string_literal: true

require "rails_helper"

# The similarity numbers in this file are a LEXICAL provider's, measured rather than assumed —
# `include_context "with lexical embeddings"` installs `LexicalEmbeddingProvider` (spec support), so
# every threshold assertion here is against vectors with the property the constant was chosen from.
# Under the suite's default stub two different strings are near-orthogonal however alike they read,
# and every one of these examples would pass or fail for reasons that have nothing to do with
# clustering.
#
# ⚠️ **This is no longer the provider production runs.** Since 2026-08-17 that is
# `EmbeddingGenerator::VoyageProvider`, which reads meaning; `NearDuplicateClusters::SIMILARITY` is
# uncalibrated for it and says so. These examples therefore pin this object's LOGIC — how it forms,
# ranks, partitions and truncates clusters at a given floor — and not the floor's correctness. The
# REWORDED pair below is the one that shows the gap: invisible to a lexical engine at 0.28, and
# exactly the kind a semantic one is built to find.
#
#   Checkout rejects an expired card / … expired card outright               0.89
#   Checkout rejects an expired card / … expired credit card                 0.90
#   Checkout rejects an expired card / … expired card when the card is expired  0.80
#   Checkout rejects an expired card / Checkout returns 402 payment required 0.28
#   Checkout rejects an expired card / Shipping calculates a delivery estimate  0.04
#
# Re-derived at DIMENSIONS = 1024; they were 0.89 / 0.90 / 0.80 / 0.31 / 0.05 at 1536, which moved
# no verdict against the 0.85 floor. Re-derive any of them with:
#   ruby -e 'require "./spec/support/lexical_embeddings"; ...'
RSpec.describe NearDuplicateClusters do
  include_context "with lexical embeddings"

  # 0.89 apart — inside the 0.88–0.95 band that must resolve to TWO identities and still be
  # reportable here as two redundant tests.
  EXPIRED = "Checkout rejects an expired card"
  OUTRIGHT = "Checkout rejects an expired card outright"
  CREDIT = "Checkout rejects an expired credit card"
  # 0.80 — the measured "lexically similar but DIFFERENT test" mark the threshold sits above.
  RESTATED = "Checkout rejects an expired card when the card is expired"
  # 0.28 — the pair a lexical engine cannot see, and the whole reason the shipped provider is not one.
  REWORDED = "Checkout returns 402 payment required"
  UNRELATED = "Shipping calculates a delivery estimate"

  let(:repository) { create_repository }
  let(:run) { create_test_run(repository: repository) }

  def identity(text, source: "name", line: 1, path: "spec/models/checkout_spec.rb")
    create_spec_identity(repository: repository, text: text, signal_source: source,
                         file_path: path, line_number: line)
  end

  # One example that resolved to `identity`. `name` is settable apart from the identity's text so a
  # caller can model the case the whole object exists for: several examples whose `full_description`
  # is VERBATIM identical, which the unique key collapses onto one identity row.
  def observe(identity, duration: 0.5, test_run: run, name: identity.text)
    @sequence = @sequence.to_i + 1
    SpecObservation.create!(
      repository: repository, test_run: test_run, spec_identity: identity,
      example_id: "./#{identity.file_path}[1:#{@sequence}]",
      file_path: identity.file_path, spec_file_path: identity.file_path,
      line_number: @sequence, name: name, status: "unannotated",
      outcome: "passed", duration_seconds: duration
    )
  end

  describe "the threshold, which is its own constant" do
    # SPGD-369's criterion 9, and the reason it is an inequality rather than a literal: what has to
    # hold is the ORDERING. Matching strictly above clustering is what lets a pair that merely reads
    # alike resolve to two identities AND be reported here; fold the two together and the finding
    # and both histories go at once.
    it "sits strictly below the identity-matching threshold" do
      expect(described_class::SIMILARITY).to be < SpecIdentity::MATCH_SIMILARITY
    end

    # Bounded from below by the measured "lexically similar but DIFFERENT test" mark, and from above
    # by the measured singular→plural mark — the band the class comment derives the value inside.
    #
    # ⚠️ Whose calibration: that band is the RETIRED feature-hashing provider's table, the one the
    # class comment's own ⚠️ paragraph flags as measured on the provider dropped on 2026-08-17. It
    # is NOT `EmbeddingGenerator::VoyageProvider`'s, which has never been calibrated against these
    # pairs. So the bounds are kept as-is deliberately: they pin where 0.85 sits inside the window
    # it was actually chosen in, which is a fact about how the constant was derived. They do not
    # claim that window is the right one for the provider running today, and they must not be
    # widened to accommodate one — re-deriving the band needs a measurement this repo does not have.
    it "sits inside the band the provider's own calibration leaves open" do
      expect(described_class::SIMILARITY).to be > 0.80
      expect(described_class::SIMILARITY).to be <= 0.89
    end

    it "is not a second name for either of SpecIdentity's constants" do
      expect(described_class::SIMILARITY).not_to eq(SpecIdentity::MATCH_SIMILARITY)
      expect(described_class::DISTANCE).not_to eq(SpecIdentity::MATCH_DISTANCE)
    end

    it "expresses the distance the pgvector operator wants, derived rather than restated" do
      expect(described_class::DISTANCE).to eq(1 - described_class::SIMILARITY)
    end

    # The constant this slice is forbidden to move. Pinned HERE as well as in spec_identity_spec.rb
    # because this is the file whose author is holding both numbers at once.
    it "leaves the matching threshold where it was" do
      expect(SpecIdentity::MATCH_SIMILARITY).to eq(0.95)
    end
  end

  describe "a near-duplicate pair" do
    # SPGD-369 criterion 1.
    it "comes back as one cluster of two members" do
      identity(EXPIRED, line: 3)
      identity(OUTRIGHT, line: 9)

      clusters = described_class.for(repository).clusters

      expect(clusters.size).to eq(1)
      expect(clusters.first.member_count).to eq(2)
      expect(clusters.first.members.map(&:text)).to contain_exactly(EXPIRED, OUTRIGHT)
    end

    # The grain of the MEMBERSHIP is the repository. `SpecObservation.repeated_descriptions_in` is
    # scoped to one run and could never see this: the two tests never ran together.
    it "clusters across runs, because identity outlives the run that observed it" do
      first = create_test_run(repository: repository, commit_sha: "aaaa1111")
      second = create_test_run(repository: repository, commit_sha: "bbbb2222")
      observe(identity(EXPIRED, line: 3), test_run: first)
      observe(identity(OUTRIGHT, line: 9), test_run: second)

      result = described_class.for(repository)
      cluster = result.clusters.first

      expect(result.clusters.size).to eq(1)
      expect(cluster.member_count).to eq(2)

      # …and the grain of the WEIGHT is one run. The member the newest run never observed stays in
      # the cluster at zero examples and is disclosed, rather than being dropped from the group or
      # quietly added into a total that would then describe no run at all.
      expect(result.weighed_run).to eq(second)
      expect(cluster.example_count).to eq(1)
      expect(cluster.members.reject(&:observed?).map(&:text)).to eq([ EXPIRED ])
      expect(cluster).to be_unobserved_members
    end

    # The lower edge of the band. 0.80 is where "a different test" starts, per the provider's own
    # calibration, and the threshold clears it by more than the hashing error the audit measured.
    it "leaves a merely lexically-similar pair alone" do
      identity(EXPIRED, line: 3)
      identity(RESTATED, line: 9)

      expect(described_class.for(repository).clusters).to be_empty
    end
  end

  # SPGD-369 criterion 2 — the ⭐ one. The unique `(repository_id, text_digest)` key collapses the
  # loop's three verbatim-identical descriptions onto ONE identity row, so an implementation that
  # counted identity rows would report this as a single test with nothing to cluster it with.
  describe "a table-driven loop, whose examples share one description verbatim" do
    before do
      loop_identity = identity(EXPIRED, line: 3)
      3.times { observe(loop_identity, duration: 1.0) }
      observe(identity(OUTRIGHT, line: 9), duration: 5.0)
    end

    it "is one identity row, which is the premise this whole object is shaped around" do
      expect(repository.spec_identities.count).to eq(2)
      expect(repository.spec_observations.count).to eq(4)
    end

    it "weighs the loop at three examples, not at one" do
      cluster = described_class.for(repository).clusters.first
      loop_member = cluster.members.find { |member| member.text == EXPIRED }

      expect(loop_member.example_count).to eq(3)
    end

    it "reports the cluster's weight in examples and its size in texts, as two numbers" do
      cluster = described_class.for(repository).clusters.first

      expect(cluster.member_count).to eq(2)
      expect(cluster.example_count).to eq(4)
    end

    it "sums the wall clock over the examples rather than over the identities" do
      cluster = described_class.for(repository).clusters.first

      expect(cluster.total_seconds).to eq(8.0)
      expect(cluster.coverage_label).to eq("4 of 4")
    end
  end

  # The reading that separates "the examples this suite contains" from "the rows this repository has
  # accumulated". One ingest cannot tell the two apart — every figure agrees at a history of one —
  # so the flagship fixture above is run forward ten times and asked for the same numbers.
  #
  # Unscoped, the weight lateral counts one row per *(test × every run it was ever observed in)*:
  # this suite would report 40 examples and 80 seconds for four tests, and the ranking above would
  # order clusters by how long they have existed rather than by what they cost.
  describe "a suite that has been ingested many times over" do
    let(:ingests) { 10 }

    before do
      loop_identity = identity(EXPIRED, line: 3)
      partner = identity(OUTRIGHT, line: 9)

      ingests.times do |index|
        ingest = create_test_run(repository: repository, commit_sha: format("%08x", index))
        3.times { observe(loop_identity, duration: 1.0, test_run: ingest) }
        observe(partner, duration: 5.0, test_run: ingest)
      end
    end

    it "weighs the four tests the suite holds, not the forty rows the ingests wrote" do
      expect(repository.spec_observations.count).to eq(40)

      cluster = described_class.for(repository).clusters.first

      expect(cluster.member_count).to eq(2)
      expect(cluster.example_count).to eq(4)
      expect(cluster.total_seconds).to eq(8.0)
      expect(cluster.coverage_label).to eq("4 of 4")
    end

    # Every figure on the object counted over the run the weights were summed in — the property the
    # class comment claims for itself, and the one that fails if the caption is read repository-wide
    # while the list is read per-run.
    it "counts its captions over the same run it weighed" do
      result = described_class.for(repository)

      expect(result.weighed_run).to eq(repository.latest_test_run)
      expect(result).to be_weighed
      expect(result.recorded_count).to eq(4)
      expect(result.clustered_example_count).to eq(4)
      expect(result.coverage_label).to eq("4 of 4")
    end

    # The run is a parameter rather than a fact about the newest ingest, so a surface can weigh the
    # same clusters against the run its reader is looking at.
    it "weighs the same clusters against whatever run it is handed" do
      first = repository.test_runs.order(:id).first

      result = described_class.for(repository, run: first)

      expect(result.weighed_run).to eq(first)
      expect(result.clusters.first.example_count).to eq(4)
      expect(result.clusters.first.total_seconds).to eq(8.0)
    end
  end

  # SPGD-369 criterion 3.
  describe "identical and near-identical duplicates together" do
    before do
      verbatim = identity(EXPIRED, line: 3)
      2.times { observe(verbatim, duration: 1.0) }
      observe(identity(OUTRIGHT, line: 9), duration: 1.0)
      observe(identity(CREDIT, line: 15), duration: 1.0)
    end

    it "represents both, and keeps the two counts apart" do
      result = described_class.for(repository)
      cluster = result.clusters.first

      expect(result.cluster_count).to eq(1)
      expect(cluster.member_count).to eq(3)
      expect(cluster.example_count).to eq(4)
    end

    it "says the same two numbers over the whole clustered population" do
      result = described_class.for(repository)

      expect(result.clustered_identity_count).to eq(3)
      expect(result.clustered_example_count).to eq(4)
    end
  end

  # SPGD-369 criterion 4. There is no `@intent` anywhere in this fixture — every identity is
  # name-derived, which is what a suite with zero annotation produces on the ingest path.
  describe "a repository with no annotation at all" do
    it "clusters anyway, because a name is a signal" do
      identity(EXPIRED, line: 3)
      identity(OUTRIGHT, line: 9)

      result = described_class.for(repository)

      expect(result.name_identity_count).to eq(2)
      expect(result.intent_identity_count).to be_zero
      expect(result.clusters.size).to eq(1)
      expect(result.clusters.first).to be_from_name
    end
  end

  # SPGD-369 criterion 5. An intent-derived text is a joined triple and a name-derived one is human
  # prose; `Ingest::SpecSignal` is explicit that they are not the same evidence.
  describe "the signal_source partition" do
    it "refuses to merge an intent-derived and a name-derived test, however close they score" do
      identity(EXPIRED, source: "name", line: 3)
      identity(OUTRIGHT, source: "intent", line: 9)

      expect(described_class.for(repository).clusters).to be_empty
    end

    it "clusters the identical pair once they share a source — so it is the partition doing it" do
      identity(EXPIRED, source: "name", line: 3)
      identity(OUTRIGHT, source: "name", line: 9)

      expect(described_class.for(repository).clusters.size).to eq(1)
    end

    it "states which source each cluster was found in" do
      identity(EXPIRED, source: "intent", line: 3)
      identity(OUTRIGHT, source: "intent", line: 9)

      cluster = described_class.for(repository).clusters.first

      expect(cluster.signal_source).to eq("intent")
      expect(cluster).to be_from_intent
      expect(cluster).not_to be_from_name
    end
  end

  # SPGD-369 criterion 6. The engine reads vocabulary, not meaning, and the object says so rather
  # than letting a confident cluster count stand for the whole of a suite's duplication.
  describe "two tests that duplicate each other in different words" do
    it "does not cluster them, at 0.31" do
      identity(EXPIRED, line: 3)
      identity(REWORDED, line: 9)

      expect(described_class.for(repository).clusters).to be_empty
    end

    it "carries the limitation on the object rather than in a comment" do
      expect(described_class.for(repository).similarity_basis).to eq("semantic similarity, not exact wording")
    end

    it "states the floor it searched at, so a reader is not left to assume one" do
      expect(described_class.for(repository).similarity_floor).to eq(described_class::SIMILARITY)
    end
  end

  # SPGD-369 criterion 7.
  describe "the ranking" do
    it "is by summed wall clock, never by member count" do
      cheap = identity(EXPIRED, line: 3)
      cheap_partner = identity(OUTRIGHT, line: 9)
      cheap_third = identity(CREDIT, line: 15)
      [ cheap, cheap_partner, cheap_third ].each { |member| observe(member, duration: 0.1) }

      dear = identity("Refund reverses a captured charge", line: 30)
      dear_partner = identity("Refund reverses a captured charges", line: 36)
      [ dear, dear_partner ].each { |member| observe(member, duration: 20.0) }

      clusters = described_class.for(repository).clusters

      expect(clusters.map(&:member_count)).to eq([ 2, 3 ])
      expect(clusters.first.total_seconds).to eq(40.0)
      # `be_within` rather than the literal sum of three 0.1s: what the ranking rests on is that the
      # cheap cluster totals about a third of a second, not which IEEE-754 representation of it the
      # addition happened to land on.
      expect(clusters.last.total_seconds).to be_within(0.001).of(0.3)
    end

    it "puts a cluster nobody timed last, never first" do
      untimed = identity(EXPIRED, line: 3)
      untimed_partner = identity(OUTRIGHT, line: 9)
      [ untimed, untimed_partner ].each { |member| observe(member, duration: nil) }

      timed = identity("Refund reverses a captured charge", line: 30)
      timed_partner = identity("Refund reverses a captured charges", line: 36)
      [ timed, timed_partner ].each { |member| observe(member, duration: 0.01) }

      clusters = described_class.for(repository).clusters

      expect(clusters.first.total_seconds).to be_present
      expect(clusters.last.total_seconds).to be_nil
      expect(clusters.last).not_to be_timed
      expect(clusters.last.duration_label).to eq("not reported")
    end

    it "orders members inside a cluster by the same rule" do
      observe(identity(EXPIRED, line: 3), duration: 0.5)
      observe(identity(OUTRIGHT, line: 9), duration: 9.0)

      cluster = described_class.for(repository).clusters.first

      expect(cluster.members.map(&:text)).to eq([ OUTRIGHT, EXPIRED ])
    end
  end

  describe "what it says about itself when the list is empty" do
    # The Vacuous Green split: three different facts, three different answers, and only the first
    # two are silence.
    it "distinguishes a repository that ingested nothing from one whose tests are all distinct" do
      empty = described_class.for(repository)

      expect(empty).not_to be_recorded
      expect(empty).not_to be_clusterable
      expect(empty).not_to be_any

      observe(identity(EXPIRED, line: 3))
      observe(identity(UNRELATED, line: 9, path: "spec/models/shipping_spec.rb"))
      distinct = described_class.for(repository)

      expect(distinct).to be_recorded
      expect(distinct).to be_clusterable
      expect(distinct).not_to be_any
    end

    # A repository whose ingests wrote identities but whose runs are all gone — or which has not
    # been ingested at all — has nothing to weigh clusters in. It says so, rather than presenting a
    # cluster at zero examples as a cluster that costs nothing.
    it "says there was no run to weigh against, rather than reporting a weightless finding" do
      identity(EXPIRED, line: 3)
      identity(OUTRIGHT, line: 9)

      result = described_class.for(repository)

      expect(result).not_to be_weighed
      expect(result.weighed_run).to be_nil
      expect(result).not_to be_recorded
      expect(result).to be_clusterable
      expect(result.clusters.first.example_count).to be_zero
      expect(result.clusters.first).to be_unobserved_members
    end

    # An observation that reached no identity is excluded structurally — there is nothing to cluster
    # it by — so no window over the pair read could ever have counted it.
    it "answers separately for the examples that reached no identity" do
      observe(identity(EXPIRED, line: 3))
      SpecObservation.create!(
        repository: repository, test_run: run, example_id: "./spec/mystery_spec.rb[1:1]",
        file_path: "spec/mystery_spec.rb", spec_file_path: "spec/mystery_spec.rb",
        line_number: 1, name: nil, status: "unannotated"
      )

      result = described_class.for(repository)

      expect(result.recorded_count).to eq(2)
      expect(result.unresolved_count).to eq(1)
      expect(result).to be_excluded_unresolved_rows
    end

    it "does not mention the exclusion on an ordinary repository" do
      observe(identity(EXPIRED, line: 3))

      expect(described_class.for(repository)).not_to be_excluded_unresolved_rows
    end

    # Counted repository-wide this figure could only ever grow: SPGD-367 leaves a failed embed's
    # `spec_identity_id` NULL forever, so a suite whose every current test resolves cleanly would go
    # on reporting exclusions from runs long past. Counted in the weighed run, it says what THIS run
    # could not read — which is the only population the weights beside it were summed over.
    it "does not carry a past run's unresolved rows into this run's caption" do
      old = create_test_run(repository: repository, commit_sha: "0dd0dd00")
      SpecObservation.create!(
        repository: repository, test_run: old, example_id: "./spec/models/old_spec.rb[1:1]",
        file_path: "spec/models/old_spec.rb", spec_file_path: "spec/models/old_spec.rb",
        line_number: 1, name: nil, status: "unannotated"
      )
      observe(identity(EXPIRED, line: 3))

      result = described_class.for(repository)

      expect(result.weighed_run).to eq(run)
      expect(result.recorded_count).to eq(1)
      expect(result.unresolved_count).to be_zero
      expect(result).not_to be_excluded_unresolved_rows
    end
  end

  describe "coverage, counted off the population it was summed over" do
    before do
      observe(identity(EXPIRED, line: 3), duration: 1.0)
      observe(identity(OUTRIGHT, line: 9), duration: nil)
      identity(UNRELATED, line: 20, path: "spec/models/shipping_spec.rb")
    end

    it "states how much of the embedded population clustered at all" do
      result = described_class.for(repository)

      expect(result.identity_count).to eq(3)
      expect(result.clustered_identity_count).to eq(2)
      expect(result.identity_coverage_label).to eq("2 of 3")
    end

    it "states how many of the clustered examples were timed" do
      result = described_class.for(repository)

      expect(result.coverage_label).to eq("1 of 2")
      expect(result).to be_any_timed
      expect(result).not_to be_complete
    end

    it "is complete only when every clustered example reported a timing" do
      SpecObservation.where(duration_seconds: nil).update_all(duration_seconds: 2.0)

      expect(described_class.for(repository)).to be_complete
    end

    # An identity outlives the runs that observed it, so a deleted test keeps its row. It weighs
    # nothing, and a member list that did not say so would look like a member that ran.
    #
    # The distribution is deliberately UNEVEN — one member carrying two examples, one carrying none
    # — because that is the shape a summed count cannot see. `example_count` here EQUALS
    # `member_count` while a member nothing resolved to sits in the list, so the assertion below
    # fails against any arithmetic answer and passes only against a per-member one. An EVEN fixture
    # is the one that flatters the wrong implementation, and this object's flagship scenario, a
    # table-driven loop, is uneven by construction.
    it "keeps an identity nothing resolved to visible, at zero examples" do
      expect(described_class.for(repository).clusters.first).not_to be_unobserved_members

      identity(CREDIT, line: 15)
      observe(SpecIdentity.find_by!(text: EXPIRED), duration: 1.0)

      cluster = described_class.for(repository).clusters.first

      expect(cluster.example_count).to eq(cluster.member_count)
      expect(cluster.members.reject(&:observed?).map(&:text)).to eq([ CREDIT ])
      expect(cluster).to be_unobserved_members
    end
  end

  # The state above, extended from ONE member to every member of every cluster — and the reason
  # `#complete?` cannot guard on `#any?`. `any?` is a statement about identities; the equality it
  # guards is over examples, and once the weighed run observed neither population the second is
  # empty while the first is not.
  #
  # This is ordinary rather than pathological, which is what makes it worth an example: membership
  # spans runs, so a cluster found from older runs survives into a run that never observed it — a
  # branch run, a subset run, or the in-flight window of a sharded one, which `latest_test_run`
  # picks up the instant its first shard lands.
  describe "a cluster the weighed run never observed" do
    let(:newest) { create_test_run(repository: repository, commit_sha: "beef0001") }

    before do
      observe(identity(EXPIRED, line: 3), duration: 1.0)
      observe(identity(OUTRIGHT, line: 9), duration: 2.0)
      # A newer run carrying an unrelated spec file and nothing from the cluster above.
      observe(identity(UNRELATED, line: 20, path: "spec/models/shipping_spec.rb"),
              test_run: newest, duration: 3.0)
    end

    it "still holds the cluster, because membership spans runs" do
      result = described_class.for(repository, run: newest)

      expect(result.clusters.size).to eq(1)
      expect(result.clusters.first.member_count).to eq(2)
      expect(result).to be_any
    end

    it "weighs it at nothing and says its members went unobserved" do
      cluster = described_class.for(repository, run: newest).clusters.first

      expect(cluster.example_count).to be_zero
      expect(cluster).not_to be_timed
      expect(cluster.members.reject(&:observed?).map(&:text)).to contain_exactly(EXPIRED, OUTRIGHT)
      expect(cluster).to be_unobserved_members
    end

    # ⛔ The assertion the guard exists for. Every operand of the equality is 0 here, so `0 == 0`
    # holds and the OLD guard — `any?`, true because the cluster is right there — let it through:
    # a panel told "not reported", "0 of 0" and "complete" in one breath. Revert the guard to `any?`
    # and this example goes red, which is the only thing that makes it load-bearing.
    it "does not call the coverage complete over a population it never read" do
      result = described_class.for(repository, run: newest)

      expect(result).to be_any
      expect(result.coverage_label).to eq("0 of 0")
      expect(result).not_to be_any_timed
      expect(result).not_to be_complete
    end

    # The same object weighed against the run that DID observe the members: the clusters are the
    # same clusters, and only now is completeness a claim about something.
    it "is complete again when weighed against the run that observed them" do
      result = described_class.for(repository, run: run)

      expect(result.clusters.size).to eq(1)
      expect(result.coverage_label).to eq("2 of 2")
      expect(result).to be_complete
    end
  end

  # The reviewer's non-blocking note, taken: the clustering half is tenant-safe by construction
  # (`n.repository_id = ?`, bound to this repository and pinned above), but `identity_presence_in`
  # has no tenant predicate, so a foreign run would caption this repository's clusters with
  # another's row count.
  describe "a weighed run from the wrong repository" do
    let(:other) do
      create_repository(user: create_user(github_uid: "4004", github_handle: "elsewhere"),
                        github_full_name: "acme/elsewhere")
    end

    it "is refused rather than captioned with the other tenant's rows" do
      observe(identity(EXPIRED, line: 3))
      foreign = create_test_run(repository: other, commit_sha: "f0re1980")

      expect { described_class.for(repository, run: foreign) }
        .to raise_error(ArgumentError, /belongs to repository/)
    end

    # `nil` is the documented "this repository has never ingested" case and is NOT the error case.
    it "still answers for a repository with no run at all" do
      identity(EXPIRED, line: 3)

      result = described_class.for(repository, run: nil)

      expect(result).not_to be_weighed
      expect(result).not_to be_recorded
      expect(result.recorded_count).to be_zero
    end
  end

  describe "truncation, which the caption has to say rather than imply" do
    it "counts every cluster it found, not the ones that fit" do
      # Three pairs drawn from three disjoint vocabularies. Measured: 0.91–0.99 within a pair,
      # 0.04–0.07 across any two of them — so this is three clusters and not one, which is what a
      # truncation assertion needs it to be. Numbering one base text three times would not do it:
      # "Report 1 …" and "Report 2 …" score 0.99 against each other and merge.
      [ [ "Invoice finalize locks the line items", "Invoice finalize locks the line item" ],
        [ "Shipping calculates a delivery estimate", "Shipping calculates delivery estimates" ],
        [ "Session expires after thirty idle minutes", "Session expires after thirty idle minute" ] ]
        .each_with_index do |(left, right), index|
          identity(left, line: (index * 10) + 1, path: "spec/models/g#{index}_spec.rb")
          identity(right, line: (index * 10) + 2, path: "spec/models/g#{index}_spec.rb")
        end

      result = described_class.for(repository, limit: 1)

      expect(result.clusters.size).to eq(1)
      expect(result.cluster_count).to eq(3)
      expect(result).to be_truncated
    end

    it "is not truncated when the whole finding fits" do
      identity(EXPIRED, line: 3)
      identity(OUTRIGHT, line: 9)

      expect(described_class.for(repository)).not_to be_truncated
    end
  end

  describe "the per-row neighbour cap, which is disclosed rather than silent" do
    # Six mutually near-identical texts with `neighbours: 2` — every member's list is full, so
    # edges were certainly cut. Single linkage still recovers the group; the disclosure is what
    # says the group might have been larger still.
    it "counts the identities whose neighbour list was full" do
      6.times { |index| identity("Ledger posts entry number #{index}", line: index + 1) }

      result = described_class.for(repository, neighbours: 2)

      expect(result).to be_saturated
      expect(result.saturated_identity_count).to be_positive
      expect(result.clusters.first).to be_saturated
    end

    it "says nothing about saturation when no list was full" do
      identity(EXPIRED, line: 3)
      identity(OUTRIGHT, line: 9)

      expect(described_class.for(repository)).not_to be_saturated
    end

    # Single linkage: membership is transitive while similarity is not, so the two ends of a chain
    # can sit further apart than the threshold. The range is what makes that visible on the row.
    it "reports the tightest and loosest edge inside a cluster" do
      identity(EXPIRED, line: 3)
      identity(OUTRIGHT, line: 9)
      identity(CREDIT, line: 15)

      strongest, weakest = described_class.for(repository).clusters.first.similarity_range

      expect(strongest).to be >= weakest
      expect(weakest).to be >= described_class::SIMILARITY
      expect(strongest).to be < SpecIdentity::MATCH_SIMILARITY
    end
  end

  describe "the tenant boundary" do
    it "does not let a cluster cross repositories" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other")
      identity(EXPIRED, line: 3)
      create_spec_identity(repository: other, text: OUTRIGHT, signal_source: "name",
                           file_path: "spec/models/checkout_spec.rb", line_number: 9)

      expect(described_class.for(repository).clusters).to be_empty
      expect(described_class.for(other).clusters).to be_empty
    end
  end

  it "returns no verdict about any of it" do
    expect(described_class.instance_methods).not_to include(:redundant?)
    expect(described_class::Cluster.instance_methods).not_to include(:redundant?, :duplicate?)
  end

  # SPGD-369 criterion 8. The only examples that need a populated table: a planner given four rows
  # scans them outright, and an EXPLAIN over that says nothing about any index.
  describe "what it costs on a suite at a meaningful fraction of the design point" do
    let(:identities) { 3_000 }

    # The `ANALYZE` in the `before` below reaches past the per-example rollback. This puts back
    # what it perturbs — see the mechanism, and the measured numbers, in the support file.
    restores_relation_statistics_for "spec_identities", "spec_observations"

    before do
      seed(repository, identities)
      # A second tenant, so `repository_id` is a real narrowing rather than the whole table — the
      # shape production has, and the one that decides the OUTER access path.
      seed(create_repository(user: create_user(github_uid: "3003", github_handle: "neighbour"),
                             github_full_name: "acme/neighbour"), identities)
      # ⭐ And a crowd of small ones, which is what decides the INNER access path. See the helper.
      seed_tiny_tenants
      seed_observations(repository)
      # Without stats the planner works off hard-coded defaults and its choice says nothing about
      # the data. `ANALYZE` is legal inside the transaction the suite wraps each example in — but
      # legality is not containment, and the difference is the whole point: `pg_statistic` is
      # written transactionally and does roll back, while `pg_class.reltuples`/`relpages` — for
      # both tables and for every index on them — are written in place by `heap_inplace_update()`
      # and survive the rollback. Without the declaration above, this example group would leave the
      # catalog claiming ~6,500 identities in a table that is empty again, and every plan-asserting
      # example that ran before autovacuum corrected it would plan against that phantom.
      ActiveRecord::Base.connection.execute("ANALYZE spec_identities")
      ActiveRecord::Base.connection.execute("ANALYZE spec_observations")
    end

    # Vectors built in SQL rather than through `EmbeddingGenerator`: 6,000 embeddings round-tripped
    # through ActiveRecord is minutes, and what this example needs from them is a populated HNSW
    # index, not meaning.
    #
    # `sin(g * … + i * …)` rather than `random()`, and the `g` is load-bearing. A subquery that
    # mentions no outer column is uncorrelated, so Postgres hoists it into an InitPlan and evaluates
    # it ONCE — every row then gets the same vector, every pair sits at cosine 1.0, and the read
    # comes back with `identities × k` rows in a table where nothing was supposed to match. That
    # silently turns a scale example into a worst-case example; referencing `g` is what makes each
    # row's vector its own.
    def seed(target, count)
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO spec_identities (repository_id, text, text_digest, signal_source, embedding,
                                     file_path, line_number, created_at, updated_at)
        SELECT #{target.id}, 'example ' || g,
               md5(#{target.id}::text || g::text) || md5(g::text), 'name',
               (SELECT ARRAY(SELECT sin((g * 12.9898) + (i * 78.233))
                             FROM generate_series(1, 1024) i))::halfvec,
               'spec/models/a_spec.rb', g, now(), now()
        FROM generate_series(1, #{count}) g
      SQL
    end

    # One example per seeded identity, so the member-weight lateral has a populated table to reach
    # through its index. Against an EMPTY `spec_observations` the planner sequentially scans it
    # whatever the query says, and the assertion about that join would be green for the one reason
    # that has nothing to do with the join.
    def seed_observations(target)
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO spec_observations (repository_id, test_run_id, spec_identity_id, example_id,
                                       file_path, spec_file_path, line_number, name, status,
                                       outcome, duration_seconds, created_at, updated_at)
        SELECT #{target.id}, #{run.id}, i.id, './spec/models/a_spec.rb[1:' || i.line_number || ']',
               i.file_path, i.file_path, i.line_number, i.text, 'unannotated', 'passed', 0.1,
               now(), now()
        FROM spec_identities i
        WHERE i.repository_id = #{target.id}
      SQL
    end

    # ⭐ A hundred small tenants, and they are the difference between this block passing on a broken
    # read and catching it. **This fixture shipped with two tenants, and QA found the quadratic plan
    # on a running application anyway** — the examples below were green against a read that took
    # 68 seconds in production.
    #
    # The reason is that the planner's estimate for the inner `repository_id` predicate is
    # `total_rows / ndistinct(repository_id)`, and nothing else. At two tenants of 3,000 that is
    # 6,000 / 2 = 3,000, which is the true sibling count — the estimate is ACCURATE by arithmetic
    # accident, the sort path is correctly priced as expensive, and the index wins for a reason the
    # production table does not supply. Production has many repositories, most of them small; there
    # the same division reads 6,500 / 102 = 64 against an actual 2,999, and the sort path wins.
    #
    # So the crowd is the fixture's whole point, and it is built to be cheap rather than realistic:
    # 100 tenants × 5 identities is 500 more vector rows, and it moves `ndistinct` from 2 to 102,
    # which is the only property the estimate reads. Deleting these rows to "speed up the fixture"
    # restores a two-tenant table and with it a green suite over the plan this block exists to
    # refuse.
    TINY_TENANTS = 100
    TINY_TENANT_SIZE = 5

    def seed_tiny_tenants
      connection = ActiveRecord::Base.connection
      connection.execute(<<~SQL.squish)
        INSERT INTO repositories (user_id, name, github_full_name, created_at, updated_at)
        SELECT #{repository.user_id}, 'tiny-' || t, 'acme/tiny-' || t, now(), now()
        FROM generate_series(1, #{TINY_TENANTS}) t
      SQL
      connection.execute(<<~SQL.squish)
        INSERT INTO spec_identities (repository_id, text, text_digest, signal_source, embedding,
                                     file_path, line_number, created_at, updated_at)
        SELECT r.id, 'tiny ' || r.id || ' ' || g,
               md5(r.id::text || g::text) || md5(g::text), 'name',
               (SELECT ARRAY(SELECT sin((r.id * 3.7) + (g * 12.9898) + (i * 78.233))
                             FROM generate_series(1, 1024) i))::halfvec,
               'spec/models/tiny_spec.rb', g, now(), now()
        FROM repositories r
        CROSS JOIN generate_series(1, #{TINY_TENANT_SIZE}) g
        WHERE r.github_full_name LIKE 'acme/tiny-%'
      SQL
    end

    # The SQL the read ACTUALLY runs, captured off the wire rather than hand-written here — a copy
    # is a second definition of the query, free to go on passing after the first one changes. No
    # `unprepared_statement` needed: the statement is built through `sanitize_sql_array`, so it
    # already carries its own literals.
    def captured_sql
      captured = nil
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        captured ||= payload[:sql] if payload[:sql].to_s.include?("CROSS JOIN LATERAL")
      end
      yield

      captured
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # EXPLAINed under an operator price this helper sets ITSELF rather than under whatever the read
    # left behind — which is now nothing, because `near_duplicate_pairs_in` restores the previous
    # price before it returns. Setting it here rather than borrowing the read's is what makes these
    # plans statements about the query: the price binds to the transaction rather than to the block
    # that issued it, so a plan taken on the read's leftovers would be resting on the suite's
    # transaction strategy instead of on the code.
    #
    # And it puts the price back, for the same reason the read does. This helper would otherwise be
    # the one thing in the file that leaves a 1024× operator price set on the example's transaction,
    # twenty lines above the example that exists to prove nothing does.
    def plan_for_actual_sql(&)
      sql = captured_sql(&)
      connection = ActiveRecord::Base.connection
      previous = connection.select_value("SHOW cpu_operator_cost")
      connection.execute("SET LOCAL cpu_operator_cost = #{SpecIdentity::VECTOR_OPERATOR_COST}")
      connection.select_values("EXPLAIN #{sql}").join("\n")
    ensure
      connection.execute("SET LOCAL cpu_operator_cost = #{previous}") if previous
    end

    it "answers each identity's neighbour question off the HNSW index" do
      plan = plan_for_actual_sql { described_class.for(repository) }

      expect(plan).to include("index_spec_identities_on_embedding")
      expect(plan).to match(/Order By: \(embedding <=> /)
    end

    # The assertion that carries the criterion's reach. The inner relation is the one that would go
    # quadratic: reached any other way, every identity compares itself against every sibling, which
    # is the 199,990,000-pair census SPGD-252 needed sixteen forked workers to finish.
    #
    # Both spellings of the quadratic plan are refused, and the second is the one worth naming: a
    # scan of `index_spec_identities_on_repository_id` that sorts what it finds LOOKS like an index
    # scan in the plan and IS an all-pairs join in the profile. Refusing only `Seq Scan` would pass
    # over the shape this read most plausibly regresses into.
    it "never walks one identity's siblings to find its neighbours" do
      plan = plan_for_actual_sql { described_class.for(repository) }

      expect(plan).not_to match(/Seq Scan on spec_identities n\b/)
      expect(plan).not_to match(/index_spec_identities_on_repository_id on spec_identities n\b/)
    end

    # == Why there is no negative control here, and where the necessity evidence lives instead
    #
    # The obvious companion to the examples above is "and WITHOUT the corrected price the planner
    # does not choose the index". It was written, and it is deliberately gone: **it asserts that
    # Postgres makes a mistake, which is not a property of this code.**
    #
    # A first pass pinned WHICH wrong plan the mis-priced planner reaches for; that failed one
    # full-suite run in three under `config.order = :random`. Relaxing it to the weaker claim — that
    # the unpriced plan simply does not use `index_spec_identities_on_embedding` — did not fix it.
    # Measured on this branch, same fixture, same 3,000-identity scale:
    #
    #   full suite, seeds 1 and 4242            unpriced plan declines the index   (example passed)
    #   full suite, seeds 31337 and 777         unpriced plan USES the index       (example failed)
    #   this file in isolation                  declines                           (example passed)
    #   standalone runner, faithful fixture     USES, before AND after VACUUM FULL (would fail)
    #
    # Both directions observed, from a query that never changed. Given a false price the planner is
    # entitled to any plan its current statistics make look cheapest, and the vector index is
    # sometimes still it — cheap for the wrong reason, and slow for the reason
    # {SpecIdentity::VECTOR_OPERATOR_COST} documents. An example that flips on resident statistics
    # can only fail for reasons that are not about `near_duplicate_pairs_in`, which is the whole
    # objection to the version before it.
    #
    # The necessity claim is not lost, it is carried by the thing that can actually carry it: the
    # recorded benchmark on that constant — **69.06s against 1.07s** for the identical statement and
    # identical rows at 3,000 identities. A wall-clock measurement is a statement about what the
    # plans COST, and it stays true whichever plan the mis-priced planner happens to pick. What the
    # suite pins is what this code does: under the corrected price the neighbour question is
    # answered off the HNSW index, and neither spelling of the quadratic scan appears.

    # The seed side is a different question from the neighbour side, and only the neighbour side is
    # the quadratic one. This repository's own rows are the population being reported on, so they
    # are all visited by construction — what matters is that the OTHER tenant's are not.
    it "visits only this repository's identities to seed the search" do
      plan = plan_for_actual_sql { described_class.for(repository) }

      expect(plan).to match(/spec_identities a/)
      expect(plan).not_to match(/Seq Scan on spec_identities a\b/)
    end

    # ⭐ The member-weight join, at scale. It is the one join a later reader is most likely to think
    # is decorative, and re-expanding a cluster's weight through a sequential scan of every
    # observation in the database is how it would come to look expensive enough to remove.
    it "re-expands member weight through the by-identity index" do
      plan = plan_for_actual_sql { described_class.for(repository) }

      expect(plan).to include("index_spec_observations_on_spec_identity_id")
      expect(plan).not_to match(/Seq Scan on spec_observations o\b/)
    end

    it "asks a fixed number of questions however large the suite is" do
      small = create_repository(user: create_user(github_uid: "4004", github_handle: "small"),
                                github_full_name: "acme/small")
      create_test_run(repository: small, commit_sha: "0000ffff")
      create_spec_identity(repository: small, text: EXPIRED, file_path: "spec/a_spec.rb",
                           line_number: 1)

      expect(count_queries { described_class.for(repository) })
        .to eq(count_queries { described_class.for(small) })
    end

    # Eight, and each of them named: the run to weigh in, the price to be restored, the correction,
    # the recall directive, the pair read, the restore, the identity population, and the observation
    # presence. A bare total cannot tell "one read per question" from "one question read twice", so
    # the number is asserted next to the list it stands for. Four of the eight are planner/recall
    # directives and their bookends, and none of them depends on how much the repository holds.
    it "reads spec_identities twice and spec_observations once, whatever it finds" do
      statements = executed_sql { described_class.for(repository) }

      expect(statements.size).to eq(8)
      expect(statements.grep(/FROM "test_runs"/).size).to eq(1)
      expect(statements.grep(/SHOW cpu_operator_cost/).size).to eq(1)
      expect(statements.grep(/set_config\('cpu_operator_cost'/).size).to eq(2)
      expect(statements.grep(/SET LOCAL hnsw\.iterative_scan/i).size).to eq(1)
      expect(statements.grep(/CROSS JOIN LATERAL/).size).to eq(1)
      expect(statements.grep(/FROM "spec_identities"/).size).to eq(1)
      expect(statements.grep(/FROM "spec_observations"/).size).to eq(1)
    end

    # The corrected price is a fact about ONE statement, and it binds to the transaction rather than
    # to the block that asked for it. This example runs inside the suite's per-example transaction,
    # so it IS the nested case: a caller who wrapped this read in a transaction of their own and
    # went on running unrelated queries under a 1024× operator price they never asked for.
    it "puts the operator price back for whoever called it" do
      cost = -> { ActiveRecord::Base.connection.select_value("SHOW cpu_operator_cost") }
      before = cost.call

      described_class.for(repository)

      expect(cost.call).to eq(before)
      expect(before).not_to eq(SpecIdentity::VECTOR_OPERATOR_COST.to_s)
    end
  end
end
