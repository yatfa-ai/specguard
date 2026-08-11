# frozen_string_literal: true

# Which GROUPS of tests in ONE repository read alike enough to be worth a human's attention, ranked
# by the wall clock those groups cost between them — together with everything a surface listing
# them has to state before it is allowed to call any of it redundancy.
#
# The first read in this application whose grain is the REPOSITORY rather than a run or a window of
# runs. Every aggregate on {SpecObservation} takes a `test_run` or a list of run ids, so "which
# tests in this suite duplicate each other" was answerable nowhere: the nearest thing,
# `SpecObservation.repeated_descriptions_in`, is scoped to one run AND groups on `name`, which is
# byte-for-byte string equality. Suite-wide and near-duplicate were both missing, and they were
# missing independently. {SpecIdentity} is the substrate that makes both reachable — one row per
# test across every run, embedded on the ingest path whether or not the test carries an `@intent`,
# so a **zero-annotation** suite clusters exactly as well as an annotated one.
#
# == ⭐ Why a cluster's weight is counted in EXAMPLES and not in identity rows
#
# `spec_identities` has a UNIQUE `(repository_id, text_digest)` (db/schema.rb), and
# {Ingest::IdentityResolver} matches identical text at cosine 1.0 in any case. **Both mechanisms
# agree, and they agree on one identity for two verbatim-identical tests** — {SpecIdentity} states
# this about itself and hands the consequence to this object by name. A three-example table-driven
# loop, a shared example group, the same description in two files: one row, every time.
#
# So an implementation that clustered identity rows and counted them would ship a duplicate finder
# structurally blind to *exact* duplicates — the ones the already-shipped {RepeatedDescriptions}
# panel actually reports — and would report a suite's most-repeated tests as its least-repeated
# ones, with a member count of 1 and no cluster at all. Every figure on these rows is therefore
# re-expanded through `spec_observations.spec_identity_id` into the examples that resolved to each
# member: `#member_count` says how many distinct texts a cluster holds, `#example_count` says how
# many examples ran under them, and the two are deliberately different numbers that the surface has
# to print separately. `SpecIdentity.near_duplicate_pairs_in` carries the same warning at the join
# itself, because that is where it would be "simplified" away.
#
# == It presents, and does not judge
#
# {RepeatedDescriptions} states the rule and it is unchanged by the grain: a group of tests that
# read alike is evidence of repetition AND the ordinary shape of a table-driven loop, a shared
# example group, or two genuinely different assertions about one behaviour. Nothing in these rows
# decides which, and nothing here tries — the ranking says what it cost and where it lives, and no
# method on this object or its structs returns a verdict. There is no `#redundant?` here to be
# tempted by, for the same reason there is none there.
#
# == ⭐ What the similarity actually measures, which is less than the panel's name suggests
#
# **Lexical overlap, not meaning.** `EmbeddingGenerator::LocalProvider` — the shipped default, an
# owner decision — hashes words and character n-grams; it does not read. Its own documentation
# gives the pair, and it is measured rather than asserted: "Checkout rejects an expired card" and
# "Checkout returns 402 payment required" describe one behaviour and score **0.31**, far below any
# threshold this object could sanely carry. Two tests that duplicate each other in entirely
# different words are invisible here and always will be.
#
# That is a property of the engine, not a defect in it, and it is why `#similarity_basis` is a
# method rather than a footnote: a cluster count rendered without it is a confident number over a
# lexical sliver of the real duplication, which is the roadmap's *Vacuous Green* failure wearing a
# different spelling. The honest reading of an empty list here is "nothing was phrased alike",
# never "nothing is duplicated".
#
# == The partition is `signal_source`, and it is a partition rather than a caveat
#
# {Ingest::SpecSignal} is explicit that the two sources are *"not the same evidence"*: an
# intent-derived `text` is a joined triple, a name-derived one is human prose, and a cosine taken
# across those two genres compares vocabulary conventions as much as content. A consumer treating
# them alike would report a name-derived match with the same confidence as an intent-derived one
# and nothing downstream could tell them apart afterwards. So a cluster is formed WITHIN one source
# — the filter lives inside the LATERAL, so it shapes the search rather than trimming its result —
# and `Cluster#signal_source` says which, on every row.
#
# == Ranked by cost, never by group size
#
# An eight-member group costing two seconds matters less than a three-member group costing ninety.
# The ordering is the summed wall clock every duration rollup in this application ranks by, `NULLS
# LAST` included, because a group nobody timed must not head a list about what repetition costs.
#
# == The three silences, each said rather than dropped
#
# `SUM` skips NULLs, so every cluster states how many of its own examples reported a timing and the
# object states the same fraction over the whole clustered population. An identity nothing has
# resolved to yet contributes 0 examples rather than being dropped. And observations that reached
# no identity at all — no text to embed, or an embedding that failed — are excluded *structurally*
# rather than by a WHERE clause, so no window over the pair read could see them;
# `SpecObservation.identity_presence_in` is the second round trip that answers for them, and
# `#recorded_count` rides along with it because an empty ranking over a repository that ingested
# nothing and one over a suite whose every test reads differently are the same empty list, and only
# the first of them is silence.
class NearDuplicateClusters
  # **The clustering threshold: two tests are near-duplicates of each other at cosine ≥ 0.85.**
  #
  # Its own constant, deliberately, and it may not be folded into either number it sits between.
  #
  # == Not {SpecIdentity::MATCH_SIMILARITY}, which is 0.95
  #
  # That one asks "are these two observations the same test"; this one asks "are these two tests
  # redundant with each other". Same embedding, opposite questions — and the ordering between them
  # is load-bearing rather than incidental. Matching sits *strictly above* clustering so that a
  # pair which merely reads alike resolves to TWO identities and stays reportable here as two
  # redundant tests; a matching threshold at or below this one would weld those two histories
  # together and destroy the finding in the same stroke. {SpecIdentity} argues the same inequality
  # from its own side, and `spec/models/spec_identity_spec.rb` pins it as an inequality rather than
  # as a literal.
  #
  # == Not 0.88 / 0.75 either
  #
  # Those are the *SpecGuard — Duplicate-Detection Engine* design-doc numbers for an engine that was
  # never built. SPGD-11's own status banner: *"The 0.88/0.75 thresholds appear in no code and could
  # never have been measured — treat them as unvalidated guesses."* Inheriting a guess and calling
  # it a threshold is how a number acquires authority it never earned.
  #
  # == What this number IS derived from
  #
  # Two measurements, taken with the shipped provider, bounding the value from each side.
  #
  # **The band comes from the semantic calibration** recorded on {SpecIdentity}, re-derivable in
  # seconds because the pairs are named rather than the numbers merely asserted:
  #
  #   a corrected typo                                      0.95   ← must cluster
  #   one word appended to the description                  0.94   ← must cluster
  #   singular → plural                                     0.89   ← must cluster
  #   a lexically similar but DIFFERENT test                0.80   ← must NOT cluster
  #   the same behaviour reworded                           0.62   ← invisible to this engine
  #
  # So the threshold has to land strictly inside (0.80, 0.89]. That is a 0.09-wide window, and the
  # question is where in it.
  #
  # **The margin comes from `script/embedding_collision_audit.rb`**, which is the evidence
  # `EmbeddingGenerator::LocalProvider` says to read before choosing any similarity threshold, and
  # which re-derives itself on whatever corpus it is pointed at. Re-run for this slice against this
  # repository's own suite — `SIZE=1700 ruby script/embedding_collision_audit.rb spec`, 1,700 real
  # example names, a full census of all 1,444,150 pairs, each scored twice: once as the 1536-bucket
  # vector production stores, once in a collision-free space:
  #
  #   mean |hashed − exact| cosine error                    0.0196
  #   pairs whose error is under 0.05                       94.5%
  #   pairs whose error is under 0.1                        99.93%
  #   worst overstatement anywhere in the census            < 0.2
  #
  #   t         false matches   rate            spurious neighbours per test
  #   0.95      0               —               0.00
  #   0.90      10              1 in 144,415    0.01
  #   0.88      10              1 in 144,415    0.01
  #   0.85      25              1 in 57,766     0.03
  #   0.80      92              1 in 15,697     0.11
  #   0.75      171             1 in 8,445      0.20
  #
  # and — at every threshold from 0.75 to 0.95 — **zero** false matches involved a pair the
  # collision-free algorithm scores as unrelated. Hashing nudges near-misses across the line; it
  # does not invent resemblances. That is SPGD-252's finding at the full 20,000-name design point
  # reproduced at a tenth the scale, so the shape of the curve is the corpus's and not this
  # corpus's.
  #
  # 0.85 is where the two measurements meet. It clears the 0.80 "different test" mark by 0.05 —
  # 2.5× the mean hashing error, and past the point where 94.5% of the census's error lies — so a
  # different test does not walk across the line on noise. It sits 0.04 below the 0.89
  # singular→plural mark for the same reason in the other direction: at 0.88 the margin would be
  # 0.01, and two thirds of the census's pairs are perturbed by more than that, so a trivially
  # reworded duplicate would fall out of its own cluster on rounding. And it buys that symmetry for
  # 0.03 spurious neighbours per test against 0.11 at 0.80 — the point on the curve where the cost
  # starts climbing rather than the point after it has.
  #
  # The failure modes are not symmetric and the number is not centred blindly: a threshold set too
  # high silently under-reports, which this object discloses as coverage; one set too low fills a
  # review queue with unrelated pairs, which nothing downstream can undo. It errs high.
  SIMILARITY = 0.85

  # What the `<=>` operator in the pair read wants, which is a cosine *distance*. Derived rather
  # than written as 0.15 so the two can never disagree — {SpecIdentity::MATCH_DISTANCE} is spelled
  # the same way, one threshold over.
  DISTANCE = 1 - SIMILARITY

  # `k`: how many nearest neighbours each identity is asked for. The cap that makes the read linear
  # in the size of the suite instead of quadratic — 20,000 identities is 199,990,000 pairs, and
  # nothing that costs a census may sit behind a page view.
  #
  # Ten rather than one, because a duplicate GROUP is the unit and a pairwise nearest-neighbour is
  # not: the clusters are the connected components of the edges this returns, so a family of twelve
  # near-identical tests is recovered from each member's ten edges without any member needing to see
  # all eleven others. Ten rather than a hundred, because the audit above measures 0.03 spurious
  # neighbours per test at this threshold — real groups are small, and the tail past ten is
  # overwhelmingly a pathological suite rather than a finding.
  #
  # It is still a cap, and a cap that hides edges is a cap that can under-report a group. So
  # `#saturated_identity_count` counts the identities that came back with a full `k` of qualifying
  # neighbours and `#saturated?` says so on the object, rather than letting a truncated component
  # pass for a complete one.
  NEIGHBOURS = 10

  # How many clusters the ranking returns. Truncation is disclosed by `#truncated?` and
  # `#cluster_count`, which are counted over every cluster found rather than over the ones that fit.
  LIMIT = 10

  # What a cosine from the shipped provider is a measurement OF, stated on the object because a
  # cluster count rendered without it is a confident number over a lexical sliver — see the class
  # comment's ⭐ section, which names the measured 0.31 pair this misses.
  SIMILARITY_BASIS = "lexical overlap, not meaning"

  # @param repository [Repository] the grain. Never a run: identity spans runs by construction, and
  #   a per-run duplicate read is `RepeatedDescriptions`, which answers a different question.
  def self.for(repository, limit: LIMIT, similarity: SIMILARITY, neighbours: NEIGHBOURS)
    edges = SpecIdentity.near_duplicate_pairs_in(repository, similarity: similarity,
                                                             neighbours: neighbours)
    clusters = Assembly.new(edges, neighbours: neighbours).clusters

    new(clusters: clusters, limit: limit,
        population: SpecIdentity.clusterable_population_in(repository),
        presence: SpecObservation.identity_presence_in(repository))
  end

  def initialize(clusters:, limit:, population:, presence:)
    @all_clusters = clusters
    @limit = limit
    @population = population
    @presence = presence
  end

  # The ranking, costliest first. Never longer than the limit it was built with.
  #
  # Ordered by summed wall clock `DESC NULLS LAST` — the rule `RepeatedDescriptions` and
  # `SpecFileDurations` established, and the reason the sort key leads with a nil flag rather than
  # coercing a missing total to zero: a cluster nobody timed is not a cluster that cost nothing.
  # `example_count` breaks the tie and the members' own texts break that one, so a repository whose
  # clusters total equally has one stable order rather than one that changes per request.
  def clusters
    @clusters ||= @all_clusters.sort_by do |cluster|
      [ cluster.total_seconds.nil? ? 1 : 0, -(cluster.total_seconds || 0.0),
        -cluster.example_count, cluster.sort_key ]
    end.first(@limit)
  end

  # How many near-duplicate clusters this repository holds IN TOTAL — the denominator `clusters.size`
  # is not. The list is capped, so its own length answers "how many rows am I looking at" and
  # nothing else, and a caption built on it reads "10 clusters" over a suite that has eighty.
  def cluster_count = @all_clusters.size

  # How many distinct IDENTITIES those clusters cover between them, and how many EXAMPLES ran under
  # them — the two numbers the ⭐ section of the class comment exists to keep apart. Both over every
  # cluster found rather than over the ones that fit on the page, because on a truncated repository
  # those are different populations and a caption is about the finding rather than about the page.
  def clustered_identity_count = window(:member_count)
  def clustered_example_count = window(:example_count)

  # How many of those examples reported a timing. The denominator of `#coverage_label`, and the
  # figure that decides whether the ranking above is a ranking or a list in an arbitrary order.
  def clustered_timed_count = window(:timed_count)

  # How many identities this repository holds at all, and how they split across the two sources.
  # Not a figure the ranking needs — they are the figures that decide whether an EMPTY ranking means
  # anything, and the ones that say WHICH population was searched. A repository that is 4,000
  # name-derived identities and 12 intent-derived ones has two findings of very different
  # confidence, and one merged coverage fraction would hide that.
  def identity_count = @population[:identity_count]
  def intent_identity_count = @population[:intent_count]
  def name_identity_count = @population[:name_count]

  # How many per-example rows this repository recorded at all, and how many of them reached no
  # identity. See `SpecObservation.identity_presence_in`: the second is this grain's "rows with no
  # resolvable text" — a spec with neither intent nor name, or one whose embedding failed — and it
  # is excluded from the clustering structurally, so it has to be counted separately or not at all.
  def recorded_count = @presence[:recorded_count]
  def unresolved_count = @presence[:unresolved_count]

  # How many identities came back holding a full `k` of qualifying neighbours, and so may have had
  # further edges cut by the cap. Stated rather than dropped, for the reason `NEIGHBOURS` gives: a
  # component assembled from truncated edges can be smaller than the group it stands for, and a
  # panel that cannot say so is reporting a cap as a finding.
  def saturated_identity_count = @all_clusters.sum(&:saturated_member_count)

  # What a cosine here measures. A method rather than a comment because the caveat travels with the
  # object to wherever the count is rendered — SPGD-115's surfaces consume this, and the constant is
  # what stops the number arriving there without it.
  def similarity_basis = SIMILARITY_BASIS

  # The floor a pair had to clear to be in any of these clusters, so a surface can state the
  # threshold it is showing rather than leaving a reader to assume one.
  def similarity_floor = SIMILARITY

  # This repository recorded per-example rows AT ALL — the question that decides whether the surface
  # has anything to say, and the one an empty `clusters` cannot answer. The `recorded?` /
  # `clusterable?` / `any?` split is `UnstableTests`' three-way split at this grain: "nothing was
  # ingested", "nothing was embedded" and "nothing reads alike" are three different facts and a
  # panel says them differently.
  def recorded? = recorded_count.positive?

  # At least one identity exists, so the search had something to search. False for a repository
  # whose ingests all predate identity resolution, or whose every example failed to embed — and an
  # empty ranking over that is "nobody told us what these tests are", never "every test here is
  # unique".
  def clusterable? = identity_count.positive?

  # Anything clustered at all. The honest zero, and reachable only behind `clusterable?`.
  def any? = clusters.any?

  # There are clusters this repository holds that the list does not show — the state a caption has
  # to SAY rather than leave a reader to infer from a list whose length happens to equal a limit
  # they cannot see.
  def truncated? = cluster_count > clusters.size

  # Examples were excluded for having reached no identity. Asked so a caption can omit the clause
  # entirely on the ordinary repository: "0 examples could not be identified" is a sentence about
  # arithmetic rather than about this suite.
  def excluded_unresolved_rows? = unresolved_count.positive?

  # At least one identity's neighbour list hit the cap, so at least one of these clusters may be a
  # fragment of a larger one.
  def saturated? = saturated_identity_count.positive?

  # At least one cluster has a total to rank. False for a repository whose clustered examples were
  # all untimed — there is a list of repetitions but no ranking, and a column of "not reported"
  # under a heading promising "costliest first" would be a ranking of nothing.
  def any_timed? = clusters.any?(&:timed?)

  # Every example under every cluster reported a timing — over the whole clustered population and
  # not over the listed head, so a truncated repository cannot read as complete on the strength of
  # the ten clusters that fit.
  def complete? = any? && clustered_timed_count == clustered_example_count

  # What the summed wall clock on this panel was measured over, always as a fraction and never as a
  # bare count — the denominator is the point.
  def coverage_label = "#{clustered_timed_count} of #{clustered_example_count}"

  # How much of the repository's embedded population these clusters account for. The answer to "and
  # the other 3,900 tests?", which a bare cluster count invites and cannot answer.
  def identity_coverage_label = "#{clustered_identity_count} of #{identity_count}"

  # One group of tests that read alike, and what the examples under them cost between them.
  #
  # `member_count` and `example_count` are different numbers ON PURPOSE — see the ⭐ section of the
  # class comment. A cluster of two identities can cover eight examples, and reporting either figure
  # as though it were the other is the specific mistake this whole object is shaped to avoid.
  Cluster = Struct.new(:signal_source, :members, :example_count, :total_seconds, :timed_count,
                       :strongest_similarity, :weakest_similarity, :saturated_member_count,
                       keyword_init: true) do
    # How many distinct TEXTS this cluster holds. Never the number of tests it stands for: exact
    # duplicates were collapsed onto one row by the unique key before this object saw them.
    def member_count = members.size

    # This cluster has a measured total. False when every example under it went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    # The text came from declared `@intent` triples / from example descriptions. Whole-cluster
    # questions rather than per-member ones, because the search was partitioned by source — a
    # cluster is one source or it is not a cluster.
    def from_intent? = signal_source == "intent"
    def from_name? = signal_source == "name"

    # At least one member is an identity nothing has resolved to in any ingested run, so the member
    # list holds a row that contributes nothing to what this cluster costs.
    #
    # Asked of the MEMBERS, one at a time, and never of the cluster's arithmetic. `example_count <
    # member_count` is a tempting one-liner and it is wrong in this object's headline scenario: the
    # count is a SUM, so a single member carrying a 3-example table-driven loop pays for two members
    # nothing resolved to and the predicate reports that nobody is missing. That implication only
    # ever ran one way — few examples implies an unobserved member, but a member nothing resolved to
    # implies nothing about the sum — and this method is asked in the other direction. A disclosure
    # that declines to disclose is the exact failure this class exists to prevent, so it does not
    # get to be reproduced inside it.
    def unobserved_members? = members.any? { |member| !member.observed? }

    # At least one member's neighbour list hit `NEIGHBOURS`, so this component may be part of a
    # larger group whose remaining edges were cut by the cap.
    def saturated? = saturated_member_count.positive?

    # The total, rendered through the one seam every duration in this application is spelled by, so
    # a cluster nobody timed says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the cluster the total covers. Always the fraction, over EXAMPLES rather than over
    # members: "6 of 8" is a claim about what ran, and members are texts.
    def coverage_label = "#{timed_count} of #{example_count}"

    # The tightest and loosest edge inside this cluster, both rounded to the two places a surface
    # can honestly render — the provider's own error against a collision-free space is ~0.02 (see
    # `SIMILARITY`), so a third decimal would be printing noise.
    #
    # Both, rather than one average, and the gap between them is the point. The clusters are
    # connected components, so membership is transitive while similarity is not: A near B and B near
    # C puts A and C in one cluster at whatever they actually score. A cluster whose weakest edge
    # sits at the threshold is a chain and reads differently from one whose weakest edge is 0.97,
    # and nothing but these two numbers tells them apart.
    def similarity_range = [ strongest_similarity.round(2), weakest_similarity.round(2) ]

    # The spec files these tests live in, deduplicated and sorted so two clusters spanning the same
    # files read the same way.
    def files_seen = members.map(&:file_path).uniq.sort

    # Ties in the ranking are broken on this rather than on an id, so the order is a property of
    # what the repository contains rather than of what order it was ingested in.
    def sort_key = members.map(&:text).min.to_s
  end

  # One identity inside a cluster: the text, where it was last seen, and what the examples that
  # resolved to it cost.
  Member = Struct.new(:id, :text, :signal_source, :file_path, :line_number, :example_count,
                      :total_seconds, :timed_count, keyword_init: true) do
    def timed? = !total_seconds.nil?

    # No example in any ingested run resolved to this text. Not an error — an identity outlives the
    # runs that observed it, so a deleted test keeps its row — but it contributes nothing to what
    # this cluster costs, and a member list that did not say so would look like a member that ran.
    def observed? = example_count.positive?

    def duration_label = SpecObservation.humanized_duration(total_seconds)
    def coverage_label = "#{timed_count} of #{example_count}"
    def location = "#{file_path}:#{line_number}"
  end

  # Turns the edge list the database returns into connected components.
  #
  # == Why the grouping is here and not in SQL
  #
  # Connected components over an edge set is a transitive closure, and Postgres spells that as a
  # recursive CTE that re-walks the edges once per level — over a set the pair read has already
  # bounded to `identities × k`, and which is in practice a few hundred rows because it holds only
  # pairs that cleared the threshold. Union-find is one pass over that array. The database does the
  # part only it can do (an approximate nearest-neighbour descent per row, off the HNSW index); this
  # does the part that is cheaper in memory than in a round trip.
  #
  # == Single linkage, stated rather than discovered
  #
  # Two tests are in one cluster if a CHAIN of near-duplicate pairs connects them, not because they
  # are near-duplicates of each other. That is what makes a twelve-member family recoverable from
  # ten-neighbour edges, and it is also what lets a cluster stretch: `Cluster#similarity_range`
  # exists so the stretch is visible on the row rather than implied by its size.
  class Assembly
    def initialize(edges, neighbours:)
      @edges = edges
      @neighbours = neighbours
    end

    def clusters
      members_by_id = {}
      pairs = []
      neighbour_counts = Hash.new(0)
      similarity_by_id = Hash.new { |hash, key| hash[key] = [] }

      @edges.each do |id, text, source, path, line, examples, total, timed, neighbour_id, similarity|
        # Every row for one seed repeats that seed's weight columns, so the first row wins and the
        # rest are the same values arriving again.
        members_by_id[id] ||= Member.new(
          id: id, text: text, signal_source: source, file_path: path, line_number: line,
          example_count: examples.to_i, total_seconds: total, timed_count: timed.to_i
        )
        neighbour_counts[id] += 1
        similarity_by_id[id] << similarity.to_f
        pairs << [ id, neighbour_id ]
      end

      components(members_by_id.keys, pairs).map do |ids|
        build(ids.map { |id| members_by_id[id] }, neighbour_counts, similarity_by_id)
      end
    end

    private

    # Union-find with path compression, iterative rather than recursive: a chain of near-duplicates
    # is exactly the input that would otherwise blow the stack, and it is also the input this object
    # is FOR.
    def components(ids, pairs)
      parent = ids.to_h { |id| [ id, id ] }

      pairs.each do |left, right|
        # A neighbour that is not itself a seed cannot happen — cosine is symmetric, so anything
        # close enough to be someone's neighbour has a qualifying neighbour of its own and appears
        # in this result. Guarded anyway, because the alternative to a guard here is a nil key
        # silently forming a cluster of one.
        next unless parent.key?(right)

        root_left = root(parent, left)
        root_right = root(parent, right)
        parent[root_right] = root_left unless root_left == root_right
      end

      ids.group_by { |id| root(parent, id) }.values
    end

    def root(parent, id)
      seen = []
      while parent[id] != id
        seen << id
        id = parent[id]
      end
      seen.each { |node| parent[node] = id }
      id
    end

    def build(members, neighbour_counts, similarity_by_id)
      totals = members.filter_map(&:total_seconds)
      similarities = members.flat_map { |member| similarity_by_id[member.id] }

      Cluster.new(
        signal_source: members.first.signal_source,
        # Costliest member first, by the rule the clusters themselves are ranked by.
        members: members.sort_by { |m| [ m.total_seconds.nil? ? 1 : 0, -(m.total_seconds || 0.0), m.text.to_s ] },
        example_count: members.sum(&:example_count),
        # nil rather than 0.0 when nobody timed anything, which is what `SUM` returns one grain down
        # and what `#timed?` and the `NULLS LAST` ranking both read.
        total_seconds: totals.empty? ? nil : totals.sum,
        timed_count: members.sum(&:timed_count),
        strongest_similarity: similarities.max,
        weakest_similarity: similarities.min,
        saturated_member_count: members.count { |m| neighbour_counts[m.id] >= @neighbours }
      )
    end
  end

  private

  def window(field) = @all_clusters.sum { |cluster| cluster.public_send(field) }
end
