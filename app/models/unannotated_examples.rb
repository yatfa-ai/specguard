# frozen_string_literal: true

# ONE run's UNANNOTATED examples — the rows behind the only headline figure on this product that had
# no rung under it, and the drill-in the dashboard's own sentence asks for and cannot answer.
#
# `app/views/repositories/show.html.erb` prints *"SpecGuard cannot see the other N tests"* under a
# stat labelled "Not visible to SpecGuard", and computes N as `total_specs - annotated_specs`. A
# subtraction is the whole answer a reader gets: told to raise annotation coverage — the product's
# stated primary adoption metric — neither a human nor an agent could name ONE of the tests it is
# counting. This object names them.
#
# == The fifth drill-in, and the first that opens a POPULATION rather than a pick
#
# `SpecFileExamples` opens one file, `RepeatedDescriptionExamples` one description, `UnstableTestRuns`
# one test — each the rows behind a LINE of a ranking the reader had already scanned and chosen from.
# There is no ranking here and nothing to pick: the ask is whole-run, and what it opens is a slice of
# the run defined by a column rather than the contents of a row somebody clicked. That is why it holds
# no `path` and no `name` echoed back — there is no ask to restate, which every sibling has and this
# one structurally cannot.
#
# == Why the list and its count are one object
#
# `SlowestExamples` states the rule and the three drill-ins above repeat it: a caption is a claim ABOUT
# the list. "100 of the 1,240 examples this run recorded without an annotation" is only true if both
# figures were counted off the same run's same rows the list was taken from. Fetched separately they
# are figures that agree today with no structural reason to keep agreeing.
#
# It derives no figure of its own, and like `SpecFileExamples` it does not even take a second query for
# the one it carries: the population count rides back on the listed rows as a window count — see
# `SpecObservation::UNANNOTATED_POPULATION_COUNTS`, including for why there is ONE window here where
# every sibling carries two.
#
# == The count this object serves is the SAME NUMBER the dashboard subtracts, by construction
#
# `Ingest::Payload#annotated_specs` rejects `status == "unannotated"` and `Ingest::ObservationRecorder`
# writes that same status verbatim per row, so `recorded_count` and `total_specs - annotated_specs` are
# one predicate evaluated twice rather than two numbers that happen to agree. `SpecObservation.unannotated_in`
# holds that argument in full, and the reconciliation is pinned in
# `spec/requests/api/v1/repository_unannotated_examples_spec.rb` rather than asserted here.
#
# ⚠️ THE RECONCILIATION IS FOR AN UNSHARDED RUN. On a sharded one the run's counters are re-derived by
# SUM over `test_run_shards` while these rows are the observations actually written, and
# `Ingest::ObservationRecorder#record` returns a row count *"not always `specs.size`"* — the same
# separation `SpecFileExamples` states for its own denominator. The two are still ONE predicate; they
# are not always one population, and a client comparing them across a sharded run is comparing what was
# reported against what was stored.
#
# == A fully-annotated run is not an error and not an absence
#
# The whole point of the metric is that it can reach zero, and the run that reaches it is the one the
# adopting repository is working towards. `.for` returns an object with no rows, `recorded_count` is an
# honest `0`, and the surface says "nothing left" rather than 404ing on a success — the same shape
# every sibling drill-in answers an empty ask with, arrived at from the opposite direction.
class UnannotatedExamples
  def self.for(test_run, limit: SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
    new(rows: SpecObservation.unannotated_in(test_run, limit: limit).to_a)
  end

  def initialize(rows:)
    @rows = rows
  end

  # This run's unannotated examples, in the order somebody would open the files in — by
  # `spec_file_path`, then `line_number`, then `id`. Never longer than the limit it was built with, and
  # stable across two identical asks, which the cap makes load-bearing: see
  # `SpecObservation.unannotated_in`, where the ordering is argued.
  attr_reader :rows

  # How many examples this run recorded WITHOUT an annotation in total — counted before the cap, so it
  # describes the population the list was cut from rather than the rows that fit on the page.
  #
  # Read off any row, because the window carries the same figure on all of them; `to_i` over the nil of
  # an empty read, where zero is the honest count — and here the empty read is the SUCCESS case rather
  # than the exotic one, since a fully-annotated run is what the metric exists to reach.
  def recorded_count = rows.first&.[]("unannotated_recorded_count").to_i

  # == No `recorded?` and no `truncated?`, on the API-only sibling's precedent
  #
  # `SpecFileExamples` and `RepeatedDescriptionExamples` define those two because a PANEL calls them —
  # `_examples_under_this_description.html.erb` and `RepositoriesHelper` gate and caption on them. This
  # object has no panel: the dashboard drill-in is out of scope, `?unannotated_examples=` is read by the
  # JSON endpoint alone, and the one serializer that builds this ships `rows` and `recorded_count` and
  # nothing derived from them. `UnstableTestRuns` is API-only for the same reason and defines neither,
  # which is the precedent this follows.
  #
  # Both would be one line and both would be plausible, which is exactly the argument against shipping
  # them: a predicate no surface calls is a claim this object makes that nothing has ever checked —
  # `UNANNOTATED_POPULATION_COUNTS` carries one window rather than two on that same reasoning. The
  # dashboard panel is a known follow-up; whoever builds it should add what it calls, with the spec that
  # runs it, rather than inherit a comparison that has never been executed against an empty or a capped
  # read. Until then `recorded_count > rows.size` is a client's sentence to write, which is what
  # `serialized_unannotated_examples` says when it ships the two numbers instead of the comparison.
end
