# frozen_string_literal: true

# HOW ONE RUN READS — its examples split across the three states of `SpecObservation::READINGS`,
# plus the population they were counted out of.
#
# This is the figure the Overview panel prints where it used to print a subtraction. `total_specs -
# annotated_specs` counts the examples with no AUTHORED intent, and the dashboard rendered it as the
# examples SpecGuard *cannot see* — a sentence that was true only of a suite whose descriptions say
# nothing, and false of the ordinary `Class#method behavior` shape most suites are written in. The
# three states here are what let a surface say which of the two it means.
#
# == It carries its own denominator, and that is the point of the object
#
# `SlowestExamples` states the rule every read object here obeys: a caption is a claim ABOUT the
# rows, and it holds only if both figures came off the same read. The rule bites harder at this grain
# than anywhere else, because the obvious denominator is the WRONG one. `TestRun#total_specs_count`
# is re-derived by SUM over `test_run_shards` from what each shard REPORTED; these four are counted
# over the rows actually STORED, and `UnannotatedExamples` documents in full why a sharded or
# partially-redelivered run legitimately has more of one than the other. So {#recorded} rides back
# with the three states and nothing here is ever divided by the suite size.
#
# == The three do not answer "how much of this suite has a human-written intent"
#
# {#authored} looks like it should and must not be used for it. That question is answered by
# `TestRun#annotated_ratio` off the run's own counters, exactly as it was before SPGD-711 and with
# the same value — which is a requirement, not a coincidence: a reader must be able to ask it and get
# today's answer. {#authored} is the same predicate over a possibly different population, and it is
# here so the three states SUM to {#recorded} rather than so anybody divides by it.
#
# == Why there is no `#fraction` and no `#label`
#
# `SpecDirectoryDurations` states it and `UnannotatedDirectories` repeats it: these objects ship the
# OPERANDS and the reading is the reader's. A run at 900 derived and 40 unreadable is a suite
# SpecGuard largely understands with a specific dark corner, and equally a suite of 940 tests nobody
# has annotated; nothing here decides which. {#unreadable?} is the one predicate, and it exists
# because a SENTENCE branches on it — "SpecGuard cannot read N of them" may not be rendered at N = 0.
IntentReadings = Struct.new(:authored, :derived, :unreadable, :recorded, keyword_init: true) do
  # Whether this run has any per-example rows AT ALL — the question that decides whether this object
  # has anything to say. A run ingested before those rows existed, or one whose client sends only
  # suite totals, answers false, and the surface says "no per-example detail on this run" rather than
  # reporting three honest zeros as though the suite were entirely readable.
  #
  # `UnannotatedDirectories#recorded?` draws the same line for the same reason, one grain down.
  def recorded? = recorded.positive?

  # Whether this run has a population the "SpecGuard cannot see this" sentence may be said about.
  # The ONLY predicate on this object, and it is here because a sentence branches on it — see the
  # class comment for why nothing else is.
  def unreadable? = unreadable.positive?

  # Every example SpecGuard has a reading of, authored or derived — the complement of {#unreadable}
  # within {#recorded}, and the figure behind "SpecGuard reads N of the M tests this run recorded".
  #
  # DERIVED FROM THE THREE rather than counted as a fourth aggregate: a `COUNT(*) FILTER (WHERE
  # reading <> 'unreadable')` would be a second definition of the same set, and the two would agree
  # until somebody added a fourth reading and only one of them noticed.
  def read = authored + derived
end
