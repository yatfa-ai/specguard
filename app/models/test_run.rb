# frozen_string_literal: true

# One CI run's metadata. Append-only history: the aggregate counts live here, while the current
# state of each test location lives in SpecIntent.
#
# One row is one *run*, which is not the same as one POST: a sharded suite delivers itself over N
# requests and `Ingest::RunRecorder` folds every one of them onto the row named by `ci_run_id`.
# For those rows the counters here are **derived** — the SUM of `test_run_shards`, with
# `duration_seconds` the MAX, recomputed on every ingest — which is what makes a redelivered shard
# replace its own slice rather than add to it. `ci_run_id` is nil for every run no CI provider
# named; those rows have no shards, are written once, and are left exactly as they always were.
class TestRun < ApplicationRecord
  belongs_to :repository
  has_many :spec_intents, dependent: :nullify
  # Declared BEFORE `test_run_shards` on purpose. Observations reference the shard that delivered
  # them, so they have to go first — and `delete_all` rather than `destroy_all` because a run is
  # 20,000 of these and there is no callback on them worth 20,000 round trips.
  has_many :spec_observations, dependent: :delete_all
  # The tests this run was the last to observe. Nullified rather than destroyed, and the FK says so
  # too (`on_delete: :nullify`): a {SpecIdentity} is durable and outlives every run, including the
  # one that happened to see it most recently. Declared so a `destroy` on this row does not have to
  # rely on the FK alone — the association is what keeps an in-memory object consistent with it.
  has_many :spec_identities, foreign_key: :last_seen_test_run_id, dependent: :nullify,
                             inverse_of: :last_seen_test_run
  has_many :test_run_shards, dependent: :destroy

  validates :commit_sha, presence: true

  # HOW THIS RUN READS — `IntentReadings` over its per-example rows: how many carry an author's
  # `@intent`, how many SpecGuard read from the test's own description, and how many it could not
  # read at all.
  #
  # **Deliberately beside {#annotated_ratio} and never a replacement for it.** That method answers
  # "how much of this suite has a human-written intent" off the run's own counters, and it answers it
  # today exactly as it did before SPGD-711 — a requirement of that ticket rather than an accident.
  # This answers a different question the dashboard used to conflate with it: how much of the suite
  # SpecGuard can say anything about. On a suite that has never been annotated the first is 0% and
  # the second is most of it, and printing the first while claiming the second is what this pair
  # exists to stop.
  #
  # The two also count DIFFERENT POPULATIONS, and `IntentReadings` states why: the counters are
  # re-derived by SUM over `test_run_shards` from what each shard REPORTED, these are the rows
  # actually STORED. `IntentReadings#recorded` is the denominator that belongs to these three.
  #
  # Memoized, because the Overview panel, the API's `latest_run` block and the areas panel all ask on
  # one page load and the answer is one aggregate over one run.
  def intent_readings = @intent_readings ||= SpecObservation.reading_counts_in(self)

  # Share of this run's suite that carries an @intent annotation — the headline dashboard metric.
  #
  # Read off this run's own counters, not from `spec_intents`, and a row count could not stand in
  # for it — today or after an intent write path exists, for two different reasons.
  #
  # Today nothing writes `spec_intents` outside the test suite. `Ingest::RunRecorder` — the only
  # write path the ingest endpoint reaches — writes `test_runs` and `test_run_shards` and nothing
  # per spec (pinned by spec/requests/api/v1/ingest_spec.rb). Counting rows would report every
  # repository as 0% annotated however many runs its CI has pushed.
  #
  # Counting rows would not become right once that path is built either: `spec_intents.entity`,
  # `.action`, `.behavior` and `.layer` are all NOT NULL, so an unannotated spec — which by
  # definition has none of them — is not a row that can exist. The figure would flip from a
  # structural 0% to a structural 100% without passing through the truth on the way.
  #
  # The run's own counters are the honest denominator because `Ingest::Payload#test_run_attributes`
  # derives them from every spec in the payload, annotated or not.
  def annotated_ratio
    return 0.0 if total_specs_count.to_i.zero?

    (annotated_specs_count.to_f / total_specs_count * 100).round(1)
  end

  # The same share as a 0–1 fraction, which is the unit the `/ingest` API reports
  # (see the SpecGuard API Reference). `annotated_ratio` above is the percentage the dashboard renders.
  # Two names rather than one number and a convention: the 100× gap between them is invisible in
  # a JSON body, and a client that guesses wrong is wrong by two orders of magnitude.
  #
  # `nil` when the run reported no tests at all, rather than `annotated_ratio`'s `0.0` floor: a
  # `0.0` sitting beside real fractions reads as a *measured* zero share rather than "there was
  # nothing to take a share of". The counts stay present either way, so a client that wants to
  # compute its own ratio still can. This is a property of the measurement, not of one endpoint —
  # it lives here so every serializer of this field answers the same way. The guard is on the
  # DENOMINATOR, never on the numerator or the result: `0` of `5` is a genuinely measured zero
  # share and must keep returning `0.0`.
  #
  # `annotated_ratio` above deliberately keeps its `0.0` floor — it feeds a rendered meter, not a
  # JSON contract, and the view draws the "no tests" distinction itself.
  def annotated_fraction
    return nil if total_specs_count.to_i.zero?

    (annotated_specs_count.to_f / total_specs_count).round(3)
  end

  # Whether the client reported a wall clock at all. `duration_seconds` is nullable by design and
  # `Ingest::Payload#validate_duration_seconds` accepts nil explicitly, so "no timing was sent" is
  # a real state — and a distinct one from a run that genuinely measured 0.0 seconds. Deliberately
  # `nil?` rather than `present?`: `0.0.present?` is true, but reading the predicate as "is there a
  # number here" and answering it with a blank check is how a measured zero starts rendering as an
  # omission.
  def duration_reported? = !duration_seconds.nil?

  # The run's wall clock, formatted once for every surface that shows it. Every surface that words
  # this column goes through this method — that is the rule the next reader has to satisfy, and it
  # is stated as a rule rather than as a list of today's callers for the reason given on
  # `#shard_durations` below. So the same float cannot render two ways on one page, nor the same run
  # two ways across pages. A caller holding bare floats rather than rows satisfies it the awkward
  # way round and still satisfies it: `RepositoriesHelper#trajectory_runtime_formatter` wraps the
  # value in an unsaved `TestRun` rather than reaching for the private formatter.
  #
  # The trajectory runtime line is the reader that pays for the rounding. `humanized_seconds` drops
  # the tenth at a minute and above, so a line plotting 74.25s and 74.30s draws a slope whose text
  # alternative words both points `1m 14s`. That is resolved where the information is lost —
  # `UI::SparklineComponent` discloses the plotted float on the rows this wording cannot separate —
  # and deliberately NOT by widening the wording here. Widening here widens every surface that words
  # this column, on more than one page, plus the trajectory's axis bounds and summary sentence, and
  # `#wall_clock_excess_material?` below thresholds on precisely the precision this method renders
  # at.
  def duration_label
    return "not reported" unless duration_reported?

    humanized_seconds(duration_seconds)
  end

  # == The other half of what a sharded run cost
  #
  # `duration_seconds` is the MAX over the shards and that is correct: shards run concurrently, so
  # the slowest one is the run's wall clock. It is not, however, what the suite *cost*. Four shards
  # of 61.0s, 58.5s, 74.25s and 60.0s are a 74.25s wait and 253.75s of machine time — a 3.4× gap on
  # the canonical 20,000-example fixture, widening with every shard added. A surface that prints
  # only the MAX and calls it a total is understating the one cost figure it shows.
  #
  # So the wall clock keeps its meaning and this is added beside it, derived the same way the run's
  # counts are: read off the shard rows, never stored. See `Ingest::RunRecorder#recompute_totals`
  # for why derived-not-accumulated is what makes a redelivered shard replace its own slice.

  # How many shard rows this run was assembled from. Zero for every run that named no `ci_run_id`
  # — a laptop `bundle exec rspec` — which is the entire unsharded corpus.
  #
  # A count of *recorded shards*, not of distinct CI jobs, and the difference is not pedantic: the
  # unique index on `(test_run_id, shard_id)` is partial (`WHERE shard_id IS NOT NULL`), so a client
  # that shards without exposing an index the gem recognises gets one row per delivery rather than
  # one row per slice. Any surface rendering this number has to word it as what it is.
  def shard_count = @shard_count ||= shard_totals[0]

  # Hand this run a shard count that a caller has already counted, so `shard_count` — and the
  # `multi_shard?` / `delivery_description` that route through it — answer without a query.
  #
  # The seam exists because `shard_totals` is one `pick` per instance. That is exactly right for
  # the Overview panel, which asks one already-loaded run three questions and pays one round trip
  # for all of them, and exactly wrong for the Recent-runs table, which asks ten runs one question
  # each and would pay ten. The callers there — the panel, and the `history` block on
  # `GET /api/v1/repository`, which asks the same question of the same rows — hold a single grouped
  # `COUNT(*)` keyed by `test_run_id` (`ShardCountPreloading#preload_shard_counts`, indexed by
  # `index_test_run_shards_on_test_run_id`) and prime each row from it.
  #
  # Deliberately narrow: it primes ONE COUNT and never the whole `shard_totals` tuple, so nothing
  # can end up answering a question out of a number that did not measure it. Priming the tuple with
  # nils would do exactly that, and it would do it silently. The shards' `MAX(updated_at)` therefore
  # keeps reading its own row of facts; the timed count and the machine time each have their own
  # narrow seam beside this one (`#preload_timed_shard_count`, `#preload_machine_seconds`) rather
  # than riding along here, because they are separately-derived numbers and a caller must not be
  # able to prime one from the other.
  #
  # A named method rather than `attr_writer :shard_count`: a writer named for a non-column would be
  # reachable through `TestRun.new(shard_count: 4)`, which looks like it persists something and
  # does not.
  #
  # `.to_i` because a grouped count has no entry at all for a run with no shard rows — the entire
  # unsharded corpus — and `nil` there would send `shard_count` back to querying for a number the
  # caller already knows is zero.
  def preload_shard_count(count)
    @shard_count = count.to_i
    self
  end

  # Whether there is a composition to disambiguate at all. One shard's MAX *is* its SUM, and zero
  # shards have neither, so both render exactly as they always have — no second figure, no wording
  # change, on the whole existing corpus.
  #
  # Named for the count and not for the provenance: a one-shard run *is* sharded in the sense of
  # having come from a sharded client, and a predicate called `sharded?` that answers false for it
  # would be read as "did this run come from CI at all" and be wrong on every single-shard run.
  # This asks the narrower question the panel actually has — is there more than one part to
  # explain — so its name says that and nothing wider.
  def multi_shard? = shard_count > 1

  # How many of those shards reported a duration. `test_run_shards.duration_seconds` is nullable
  # and `Ingest::Payload` accepts nil explicitly, so a shard with no timing is an ordinary state
  # rather than a fault — and the gap between this and `shard_count` is exactly how much of the
  # machine time is missing.
  #
  # Memoized in its own ivar, on the same shape `shard_count` has, so it can be primed across a
  # window of rows without a `pick` each. `||=` is safe over a count: a really-counted `0` is
  # truthy in Ruby, so a run whose shards all went silent memoizes the zero rather than re-asking.
  def timed_shard_count = @timed_shard_count ||= shard_totals[1]

  # Hand this run a timed shard count a caller has already counted, so `timed_shard_count` — and
  # the `some_shard_untimed?` / `untimed_shard_count` / coverage labels that route through it —
  # answer without a query. The seam beside `preload_shard_count`, and it exists for the same
  # reason: one `pick` per instance is right for a single run and wrong for a window of them.
  #
  # The caller is `ShardCountPreloading`, which takes `COUNT(duration_seconds)` as a second column
  # of the ONE grouped aggregate it already runs. `GET /api/v1/repository` needs it because each
  # `history` row serves a `duration_seconds` whose denominator is this number and not
  # `shard_count`.
  #
  # SEPARATE FROM `preload_shard_count` rather than one call taking both, so a caller cannot prime
  # a timing number out of a count that measured no timing — the failure `#preload_shard_count`'s
  # comment refuses. `.to_i` for the same reason it does: a run with no shard rows is absent from
  # the grouped result entirely, and its really-counted answer here is `0`, never nil.
  def preload_timed_shard_count(count)
    @timed_shard_count = count.to_i
    self
  end

  # How many reported nothing — the size of the hole in the SUM below, and the number any surface
  # apologising for a partial machine time has to name.
  def untimed_shard_count = shard_count - timed_shard_count

  # SUM over the shards' durations, or nil when not one of them reported a timing. SQL's SUM skips
  # nulls and returns NULL over an empty set, which is the distinction wanted here: nil means "no
  # shard reported", never "the shards added up to nothing".
  #
  # Memoized on PRESENCE OF ASSIGNMENT rather than on truthiness, which is the one thing that
  # separates this from the two counts above. `||=` is safe over a count because the only falsey
  # answer a count has is a nil that never occurs; here BOTH of the answers `||=` would re-ask on
  # are real and distinct. `nil` is "no shard reported" and `0.0` is "the shards were measured and
  # they cost nothing" — `0.0` is truthy so `||=` would in fact hold it, but it would re-query the
  # nil on every call, and a primed nil is exactly what the seam below exists to make stick.
  # `defined?` holds both, which is what lets a caller prime "not reported" without a query.
  def machine_seconds
    return @machine_seconds if defined?(@machine_seconds)

    @machine_seconds = shard_totals[2]
  end

  # Hand this run a machine time a caller has already summed, so `machine_seconds` — and the
  # `machine_seconds_reported?` / `machine_seconds_label` / `machine_seconds_coverage` that route
  # through it — answer without a query. The seam beside the two above, and it exists for the same
  # reason: one `pick` per instance is right for a single already-loaded run and wrong for a window
  # of them. The caller that needed it is the repositories grid, which states what each of N suites
  # cost and would otherwise pay one SELECT per card for this SUM alone.
  #
  # SEPARATE from the two count seams rather than one call taking all three, on
  # `#preload_timed_shard_count`'s rule: a caller must not be able to prime a timing figure out of a
  # number that measured no timing.
  #
  # NO `.to_i`, which is the other thing that sets this apart from its siblings. Their `.to_i` turns
  # "absent from the grouped result" into the really-counted `0` it means; here that absence means
  # NO SHARD REPORTED, and a `0` would render as a measurement of zero seconds —
  # `#machine_seconds_reported?` below is deliberately a `nil?` check and not a `present?` one for
  # exactly that reason. The value is assigned through unchanged: nil stays nil, `0.0` stays `0.0`.
  def preload_machine_seconds(sum)
    @machine_seconds = sum
    self
  end

  # Deliberately `nil?` and not `present?`, for the same reason `duration_reported?` is: a suite
  # whose shards genuinely measured 0.0 has a measurement, and a blank check would render it as an
  # omission.
  def machine_seconds_reported? = !machine_seconds.nil?

  # Some shard reported no timing, so BOTH derived cost figures are computed over fewer rows than
  # the run has: the SUM is a floor rather than a total, and the MAX is a maximum over a subset.
  # One predicate and not two, because it is one fact about the shard rows — and the two labels
  # that read it were only ever asking the same question in different words.
  #
  # Vacuously false on a run with no shards (`0 < 0`), which is correct but load-bearing rather
  # than incidental: it is safe only because every caller sits behind `multi_shard?`, and a future
  # caller that does not would read "nothing is missing" off a run that reported nothing at all.
  def some_shard_untimed? = timed_shard_count < shard_count

  # The machine time, worded to its own coverage. Three states, because there are three: nothing
  # reported, a partial sum, a complete one. Only the last is a total, and only it says so.
  def machine_seconds_label
    return "not reported" unless machine_seconds_reported?

    label = humanized_seconds(machine_seconds)
    some_shard_untimed? ? "at least #{label}" : label
  end

  # The figure's own denominator, carried by the label that names it rather than left to a caveat
  # further down the page. A label is the most prominent claim a number wears, so "all 4 added up"
  # over a SUM of three is the same overclaim as "Total runtime" over a MAX — this defect one
  # level down, and stating the partial count in the caption below does not undo it. The complete
  # case is the only one allowed to say "all".
  def machine_seconds_coverage
    return "all #{shard_count} added up" unless some_shard_untimed?

    "#{timed_shard_count} of #{shard_count} added up"
  end

  # The wall clock's denominator, on the same rule and for the same reason one row up.
  # `duration_seconds` is the MAX over the shards that *reported*, so on a run with a silent shard
  # it is a maximum over a subset — and the silent one may well have been the slowest, since a
  # cancelled or timed-out job usually is. "slowest of 4 shards" over a MAX of three claims a
  # coverage the figure does not have, which is this ticket's own defect one row up from where it
  # was found. The complete case is the only one entitled to the run's full shard count.
  #
  # No inflected noun rides on the count in the partial branch. `pluralize` inflects a noun and
  # nothing around it, and the words *around* the count are exactly where this panel's wording has
  # broken before, so that branch names the number and drops the noun rather than betting on a
  # determiner reading correctly at every count.
  def wall_clock_coverage
    return "slowest of #{shard_count} shards" unless some_shard_untimed?
    return "0 of #{shard_count} reported" if timed_shard_count.zero?

    "slowest of the #{timed_shard_count} that reported"
  end

  # == Decomposing the wall clock across the shards that produced it
  #
  # The pair above tells a reader that the wall clock is the slowest single shard. It does not say
  # *which* shard, *how far ahead of the others* it was, or *how much of the wait came from uneven
  # splitting rather than from the suite* — so two runs that are opposite operational facts print
  # byte-identically. Four shards at 63.4s each and three at ~60s beside a runaway at 74.25s are
  # both `253.75s` of machine time; only the second has anything to fix, and only the second is
  # what the canonical fixture actually contains.
  #
  # None of this is a new measurement. The run's MAX *is* the slowest shard's `duration_seconds`
  # (`Ingest::RunRecorder#recompute_totals`), so naming it is identifying the row the headline
  # number already came from. Everything else here is arithmetic over rows that are already
  # stored and already indexed.
  #
  # **This is about shards and never about tests.** Which *tests* are slow is not derivable from
  # anything here — no per-test duration exists in the schema — and every string this feeds must
  # be worded so a reader cannot mistake one for the other.

  # Below either of these, the excess is stated but not presented as a finding.
  #
  # Two floors rather than one, because "immaterial" has two independent causes and a single
  # threshold would miss whichever it was not written for. Under a second, the gap is smaller than
  # the scheduling jitter between two CI runners starting the same suite — it is not a property of
  # the split at all. Under a few percent, it is inside the run-to-run variance of the same suite
  # on the same shards, so re-dividing them could not reliably recover it. A run has to clear BOTH
  # to have a gap worth acting on.
  NEGLIGIBLE_EXCESS_SECONDS = 1.0
  NEGLIGIBLE_EXCESS_PERCENT = 5.0

  # How long this run's shard reports must have been quiet before their composition is read as
  # final. See `#shard_delivery_settled?` for what it is standing in for and why a clock is the
  # only observable that can stand in for it at all.
  #
  # Generous on purpose, because the two ways of being wrong are not symmetric. Too short and the
  # decomposition is published over a half-delivered run — the exact fabrication the gate exists to
  # prevent. Too long and a settled run's decomposition appears a few minutes after the run does,
  # which costs a reader nothing they can act on: a suite's split is not a thing anybody fixes in
  # the first quarter of an hour. Shards run concurrently, so a run's parts normally land within
  # the spread of their own durations — minutes, not hours — and this leaves room for a retried
  # shard on top of that.
  #
  # **Does a longer window widen the straggler hole documented on `#shard_delivery_settled?`?** It
  # does not; it narrows it, monotonically, and the direction is worth writing down because it is
  # easy to assume the opposite and the assumption would argue for shortening this.
  #
  # Let the fast shards fall quiet at `q` and the straggler arrive at `q + T`, for a window `W`.
  # The run settles at `q + W`, so it can be decomposed WITHOUT the straggler only while
  # `q + W < q + T` — that is, only when `T > W`. The wrong figure is then on screen for exactly
  # `T - W`, because the straggler's own write bumps `MAX(updated_at)` and un-settles the run,
  # which re-settles `W` later with every row in. Both the condition (`T > W`) and the exposure
  # (`T - W`) shrink as `W` grows. A shorter window would publish sooner over runs that had more
  # still coming, which is the same failure from the other end.
  #
  # So the two concerns do NOT pull in opposite directions: both the in-flight window and the
  # straggler favour a longer `W`, and the only thing traded away is latency — the paragraph above.
  # What a longer `W` cannot touch is the abandoned-mid-delivery row, which is quiet forever and so
  # sits outside this arithmetic entirely; that residual is a property of the proxy, not of its
  # length, and no value here reaches it.
  SHARD_DELIVERY_SETTLING_PERIOD = 15.minutes

  # When the most recent shard report arrived. `Ingest::RunRecorder#upsert_shard` writes a shard
  # row on every delivery — inserting it, or updating the named slice in place — so this is the
  # moment the last POST touched this run's parts. `nil` for a run that has no shards at all.
  def last_shard_arrived_at = shard_totals[3]

  # Whether this run's shards have stopped arriving, as nearly as anything here can know it.
  #
  # **A run cannot be asked whether it is complete.** `Ingest::Payload` accepts a shard *index* and
  # never a total — `#assembled_like?` below says so at length — so nothing in the schema or the
  # protocol distinguishes "four shards, all in" from "four of eight, still going". The only
  # observable that separates them is that a run still being delivered is a run something wrote to
  # recently, so that is what this asks, and it asks it in those words rather than pretending to
  # ask about completeness.
  #
  # It is a proxy and it is stated as one. What it catches and what it does not:
  #
  # - **Catches the in-flight window**, which is the ordinary state of every sharded run for the
  #   minutes its build takes. `Repository#latest_test_run` picks a run up the instant its first
  #   shard lands (`created_at` is stamped by that POST), so the Overview renders half-delivered
  #   runs routinely rather than exceptionally.
  # - **Does not catch a run that was abandoned mid-delivery** — a job cancelled after two of four
  #   shards, which `#assembled_like?` records leaves a half-sized row in the history forever. That
  #   row goes quiet and is then indistinguishable, in every column and at every later moment, from
  #   a genuine two-shard run that a reader is entitled to see decomposed. No gate can separate
  #   them, so this one does not claim to; a gate that withheld from both would withhold from every
  #   small honest matrix in order to catch a cancelled job it cannot name.
  #
  # **That residual is asymmetric, and only one half of it is benign.** It is written out in both
  # directions because it is the artifact a later reader will trust when deciding how much to
  # believe this figure, and the benign half on its own reads as a licence the whole does not give.
  #
  # - **A missing shard cannot manufacture an imbalance the whole run did not have.** If every
  #   shard is within a narrow spread then so is any subset of them. So a *positive* verdict —
  #   this split cost you time — survives a partial set even where its magnitude does not; that
  #   direction fails in size and not in kind.
  # - **A missing shard can conceal one, and the shard it conceals is preferentially the slowest.**
  #   Imbalanced-whole does NOT imply imbalanced-subset, and it fails exactly when the absent row
  #   is the runaway — which is the row likeliest to be absent at any given moment, because it is
  #   the one still running. The correlation is adverse rather than neutral. Drop the 74.25s shard
  #   from the canonical `[61.0, 58.5, 74.25, 60.0]` run and the remaining three read as a 1.2s /
  #   1.9% spread: immaterial, and `#wall_clock_excess_material?` cannot catch it, because over
  #   those three rows the excess genuinely IS immaterial. A 14.6% finding becomes no finding.
  #
  # So **a negative verdict from this panel is weaker than a positive one**, and the two branches
  # in `repositories/show` are worded to that asymmetry rather than to a symmetry they do not have:
  # the imbalanced branch needs no hedge because it can only understate, and the balanced branch
  # states what the recorded shards show and declines the operational claim about the run, the way
  # `#machine_seconds_label` words itself to its own coverage. Without that, the page moves from
  # withholding a finding to affirmatively denying one — the worse of the two failures, and the
  # only one that puts a false sentence in front of a reader.
  #
  # Three routes reach a concealed runaway past the quiet period: a straggler slower than the
  # window, a CI-retried shard landing after it, and the abandoned run above — which is the
  # straggler case made permanent, and is why accepting that residual is not as small a decision as
  # its own bullet makes it sound. The first two self-heal (the straggler's write bumps the
  # timestamp, un-settling the run until it re-settles with every row in); the third never does.
  #
  # Deliberately not a comparison against the previous run's shard count, the way `#assembled_like?`
  # decides its own question. That test is answerable there because a suite-size delta already has
  # two runs in hand; here it would make a first run on a branch, and every legitimate change of
  # matrix width, silently undecomposable — a permanent cost paid to catch a transient state a
  # clock catches directly.
  def shard_delivery_settled?
    last_shard_arrived_at.present? && last_shard_arrived_at <= SHARD_DELIVERY_SETTLING_PERIOD.ago
  end

  # Whether the wall clock can honestly be decomposed at all.
  #
  # Three conditions, and the last two are each guarding the same hazard from a different side: the
  # floor divides the machine time by the shard *count*, so any shard whose work is absent from the
  # numerator while its slot is present in the denominator — or whose slot is absent from both —
  # moves the floor and the excess together, in the direction that manufactures a finding.
  #
  # - `multi_shard?` — there is a composition to explain. Also what makes the next condition safe:
  #   `some_shard_untimed?` is vacuously false on a run with no shards, as its own comment records.
  # - `!some_shard_untimed?` — every shard that is HERE reported a timing. A recorded row carrying
  #   a NULL duration is missing from the SUM but counted in the denominator, which drags the floor
  #   down and pushes the excess up by exactly the same amount.
  # - `shard_delivery_settled?` — every shard that is COMING has arrived, as nearly as a clock can
  #   know it. This is the other half, and it is a different question rather than a stricter form
  #   of the same one: the predicate above reads the rows that exist, and cannot see a row that
  #   does not. On a half-delivered run every shard present has a timing, so it waves the run
  #   straight through while both the SUM and the count are still climbing — a partial numerator
  #   over a partial denominator, published with no more hedging than a settled run gets.
  #
  # The comment on `#shard_delivery_settled?` says which incompleteness that third condition
  # catches and which it cannot, and it does not catch all of them. It is written that way rather
  # than named for a completeness it cannot establish.
  def wall_clock_decomposable?
    multi_shard? && !some_shard_untimed? && shard_delivery_settled?
  end

  # A run whose shards are all timed and still arriving: the decomposition is not withheld because
  # anything is wrong, only because it is too early to take. The panel says so in those words
  # rather than rendering nothing, which is the difference between "we are waiting" and "there is
  # nothing to say" — and a reader who can see two figures and no third fact is owed which one it
  # is. The untimed case has a sentence of its own already and is not routed here; the two are
  # mutually exclusive by construction.
  def wall_clock_decomposition_pending?
    multi_shard? && !some_shard_untimed? && !shard_delivery_settled?
  end

  # Every shard's `[shard_id, duration_seconds, total_specs_count]`, slowest first.
  #
  # ONE query for all of them regardless of how many there are — a 40-shard matrix costs the same
  # as a 4-shard one. It is a second read against `test_run_shards` beside the memoized
  # `shard_totals` aggregate, which is deliberate: `shard_totals` is a `pick` of three scalars and
  # feeds `GET /api/v1/repository`, so widening it to carry rows would change what its callers
  # load for a figure only the dashboard renders. Constant, not minimal, is the property that
  # matters.
  #
  # `total_specs_count` rides along rather than taking a read of its own, and the position it rides
  # in is load-bearing in exactly the way `MAX(updated_at)` is on `#shard_totals`: it is APPENDED,
  # so index 0 stays `shard_id` and index 1 stays `duration_seconds`, and `#longest_shard_label`'s
  # `shard_durations.first&.first` keeps naming a shard rather than a count. A wider `pluck` over
  # the same index is the same round trip.
  #
  # It is the denominator of every duration beside it, and without it the distribution below cannot
  # separate the two things a slow shard can be: a shard holding more tests than its siblings — the
  # split is wrong — from a shard holding the same number of individually dearer ones, where the
  # split is fine and the tests are where the cost is. Both print byte-identically on durations
  # alone. `Ingest::RunRecorder#upsert_shard` has written this column on every sharded POST since
  # sharding shipped; nothing read it.
  #
  # Ordered by duration rather than by `shard_id` or by insertion, because the point of rendering
  # the list at all is to make the *shape* visible: slowest-first puts the shard just named at the
  # head and walks down to the fastest, so the spread reads off in one pass. Ordering by name
  # would sort `"10"` before `"2"` (the column is a string, and it is a string because a client
  # may name its slices anything), and ordering by insertion would sort by whichever shard
  # happened to POST first, which is not a fact about the suite. `id` breaks ties so the order is
  # total and stable.
  #
  # **Safe only behind `#wall_clock_decomposable?`, and that is load-bearing rather than
  # incidental** — the same kind of fact `#some_shard_untimed?` records about its own vacuous
  # false. `duration_seconds: :desc` is **NULLS FIRST** in Postgres, so on a run carrying a silent
  # shard the head of this list is the shard that reported *nothing*, and `#longest_shard_label`
  # below would name it as the longest while `#shard_distribution_labels` printed it at the top of
  # the distribution. Unreachable today because the gate's `!some_shard_untimed?` condition is
  # exactly the statement that no such row exists — but this method and EVERY public reader derived
  # from it below re-check nothing, so a future caller that skipped the gate would be handed an
  # untimed row wearing the word "longest". Call any of them from anywhere else and either keep the
  # gate or order `NULLS LAST` first.
  #
  # That enumeration is stated as a rule and not as a count on purpose. It read "all three of these
  # readers" until this slice, which was true when it was written and false the moment
  # `#shard_spec_counts` and `#shard_seconds_per_spec` were added below — the one paragraph that
  # bounds the ungated exposure understating it by two, in the commit that widened it. A rule the
  # next reader has to satisfy cannot rot the way a tally does.
  def shard_durations
    @shard_durations ||= test_run_shards.order(duration_seconds: :desc, id: :asc)
                                        .pluck(:shard_id, :duration_seconds, :total_specs_count)
  end

  # The same three columns in DELIVERY order, for a machine-readable consumer.
  #
  # A separate read rather than a reuse of `#shard_durations`, because the ORDER is the whole
  # difference between them and the order is what decides where each is safe. `#shard_durations`
  # RANKS by duration, which is NULLS FIRST in Postgres, so it is safe only behind
  # `#wall_clock_decomposable?` — whose `!some_shard_untimed?` condition is precisely the statement
  # that no untimed row exists to surface at the head. `GET /api/v1/repository`'s `shards` block
  # gates on `#multi_shard?` alone, which establishes nothing of the kind, and widening the tuple
  # is not a licence to call a ranked list from an unranked gate.
  #
  # So this ranks nothing: `id: :asc` is the order the shards were recorded in, a fact about the
  # deliveries rather than a claim about the suite, and a client that wants them slowest-first
  # sorts them itself over a `duration_seconds` it can see is null. One query, constant in the
  # number of shards, on `index_test_run_shards_on_test_run_id`.
  def shard_reports
    @shard_reports ||= test_run_shards.order(id: :asc)
                                      .pluck(:shard_id, :duration_seconds, :total_specs_count)
  end

  # What to call one shard in a sentence.
  #
  # `shard_id` is nullable and a nil one is not an oversight — `Ingest::RunRecorder#upsert_shard`
  # says outright that a client which shards without exposing an index the gem recognises sends
  # nothing to tell its slices apart, so each POST becomes its own row. Numbering those rows by
  # their position in this list would hand a reader a name the client never sent, and a stable-
  # looking one: "shard 2 is your slow shard" is unactionable advice when nothing in CI is called
  # shard 2, and it would point at a different slice on the next run.
  #
  # One label and not two — the same string names a shard in the prose and in the list below it,
  # so the sentence and the row a reader checks it against cannot drift apart.
  def shard_label(shard_id) = shard_id.present? ? "shard #{shard_id}" : "an unnamed shard"

  # The name of the shard the run's `duration_seconds` MAX came from.
  #
  # Named for the measurement and not for the verdict. Being the longest is a fact about the row;
  # being *the slowest* is a claim about the run, and the panel deliberately declines to make it
  # when four shards are tied to the tenth. A method called `slowest_shard_label` feeding a
  # sentence that refuses the word "slowest" is a name working against its own caller — the same
  # discipline `#wall_clock_coverage` applies one section up, where the label is allowed to say
  # "slowest of 4 shards" only in the branch where the MAX covers all four.
  #
  # Reads the head of `#shard_durations`, so it inherits that method's NULLS-FIRST dependency on
  # the gate verbatim: off-gate, on a run with a silent shard, this names the shard that reported
  # nothing.
  def longest_shard_label = shard_label(shard_durations.first&.first)

  # The shortest wall clock any arrangement of these shards could have produced: the machine time
  # spread perfectly evenly across them.
  #
  # A **lower bound and never a target**. Tests are not arbitrarily divisible — a single example
  # longer than this floor makes it unreachable on its own — so nothing here claims such a split
  # exists, only that none can go under it. Every surface rendering this has to word it that way.
  def balanced_wall_clock_seconds = machine_seconds / shard_count

  # How much longer the run waited than that floor: the part of the wait attributable to how the
  # suite was divided rather than to the suite itself.
  #
  # Unguarded on `duration_seconds` where `#duration_label` guards the same column with
  # `#duration_reported?`, and the reason is written here because it is the one link in the chain
  # that is not visible from this file. `Ingest::RunRecorder#recompute_totals` re-derives the
  # parent's `duration_seconds` as the MAX over its shard rows after every ingest, and a MAX over
  # rows that all reported a timing cannot be NULL — which is exactly what the gate's
  # `!some_shard_untimed?` condition establishes. So the invariant holds through the recorder and
  # nowhere else: call this outside `#wall_clock_decomposable?` and it raises on a nil.
  def wall_clock_excess_seconds = duration_seconds - balanced_wall_clock_seconds

  # The same as a share of the wait.
  #
  # Guarded on a positive denominator, not on a blank one: a run whose shards all genuinely
  # measured `0.0` is a real state with a real (zero) excess, and `0.0 / 0.0` is `NaN` — which
  # formats as `NaN%` and compares false against every threshold, so it would slip past the
  # materiality test below and render as a finding.
  def wall_clock_excess_percent
    return 0.0 unless duration_seconds.to_f.positive?

    (wall_clock_excess_seconds / duration_seconds * 100).round(1)
  end

  # Whether that excess is worth reading as a finding rather than as noise.
  #
  # This decides the WORDING and never whether the number is shown. An evenly split run has a
  # measured excess of `0.0s` and says so; what it does not do is dress that up as time something
  # could have recovered. Same rule the machine time follows one section up — an incomplete fact
  # carries its incompleteness in the words, and an unremarkable one carries that.
  #
  # Both operands are compared at the precision they are RENDERED at, which is why the seconds are
  # rounded here even though nothing stores them rounded. The percent has always been thresholded
  # on the value the reader sees (`#wall_clock_excess_percent` rounds), and the seconds reach the
  # page through `humanized_seconds`, which rounds to the same tenth. Judging one operand rounded
  # and the other raw opens a seam either side of the boundary where two runs print the identical
  # figure and receive opposite verdicts — `[17.0, 18.96]` and `[17.0, 19.04]` both read `1.0s`
  # over the floor — which is this ticket's own defect one level down. The boundary belongs where
  # a reader can see it.
  def wall_clock_excess_material?
    wall_clock_excess_seconds.round(1) >= NEGLIGIBLE_EXCESS_SECONDS &&
      wall_clock_excess_percent >= NEGLIGIBLE_EXCESS_PERCENT
  end

  # The floor and the excess, formatted by the same formatter the wall clock and the machine time
  # already use. Four numbers in one unit within a few lines of each other: a second formatter
  # would eventually print them two ways and destroy the comparison they exist to enable.
  #
  # A known and accepted consequence: at a minute and above `humanized_seconds` drops the tenth, so
  # the three figures do not reconcile by subtraction on screen. The canonical run prints a `1m 14s`
  # wait and a `1m 3s` floor, and a reader taking the difference gets `11s` where the excess reads
  # `10.8s`. The alternative is a second formatter for the excess alone — which would print the
  # wait and the floor at one precision and the gap between them at another, in a paragraph whose
  # entire purpose is to relate the three. A rounding seam is the smaller cost, and it is only ever
  # a tenth wide.
  def balanced_wall_clock_label = humanized_seconds(balanced_wall_clock_seconds)
  def wall_clock_excess_label = humanized_seconds(wall_clock_excess_seconds)

  # Every shard as `[name, formatted duration, size, per-test cost]`, slowest first — the
  # distribution itself, so the shape is visible rather than summarised into a single ratio.
  # Formatted here rather than in the view for the reason directly above: `humanized_seconds` is
  # private, and it stays private.
  #
  # Named for the distribution rather than for the durations it used to be, because it is no longer
  # a list of durations: the size and the cost per test are the two figures that say whether a long
  # shard is long because it holds more work or because its work is dearer, and a method still
  # called `shard_duration_labels` would be a name arguing against its own contents.
  #
  # The fourth element is `nil` — never a formatted zero — for a shard with no denominator, and the
  # third states that absence in words. See `#shard_size_label`.
  #
  # Zipped against `#shard_seconds_per_spec` rather than re-derived per row, so *which shards have
  # a cost per test* is decided in exactly one place. An earlier draft called a private
  # `#shard_seconds_per_spec_label` that repeated the `seconds.nil? || !spec_count.to_i.positive?`
  # test, which put the same load-bearing predicate behind two surfaces — this list and the spread
  # comparison — free to drift apart into a row showing a rate for a shard the spread excluded,
  # with each half independently green. The alignment `#shard_seconds_per_spec` promises (nils kept
  # in place, not compacted) is what makes the zip safe, and this is the caller it was promised to.
  def shard_distribution_labels
    shard_durations.zip(shard_seconds_per_spec).map do |(shard_id, seconds, spec_count), rate|
      [shard_label(shard_id), humanized_seconds(seconds), shard_size_label(spec_count),
       rate && humanized_seconds_per_spec(rate)]
    end
  end

  # == Which of the two things a slow shard is
  #
  # The section above measures the spread of the shards' WALL CLOCKS and says how much of the wait
  # it cost. It cannot say what caused it, and the two causes take opposite actions:
  #
  # - the slow shard holds more tests than its siblings — the work is fine, the *split* is wrong,
  #   and evening the counts out across the same shards is what moves the number;
  # - the slow shard holds the same number of individually dearer tests — the counts are already
  #   even, so a partitioner splitting by COUNT has nothing left to even out and reproduces the gap
  #   however often it re-runs. A duration-weighted split, or cheaper tests in that partition, is
  #   what moves it.
  #
  # Note what is NOT different between the two, because an earlier draft of these strings got it
  # wrong and shipped operational advice this model's own arithmetic falsifies: machine time is
  # invariant under re-partitioning and the balanced floor is `machine / shard_count`
  # (`#balanced_wall_clock_seconds`), so a duration-weighted split reaches the floor in BOTH cases
  # and `#wall_clock_excess_seconds` is recoverable in BOTH. What the count spread decides is which
  # partitioner can get there — never whether re-dividing helps at all. Any string built from these
  # names a partitioner; none of them may tell a reader the excess is unrecoverable.
  #
  # `duration = count × cost-per-test`, so the two are separately computable from the tuple
  # `#shard_durations` now carries, and the panel is entitled to name whichever of them the numbers
  # support — including neither, when a material duration spread is the product of two immaterial
  # ones. Same discipline `#wall_clock_coverage` and `#longest_shard_label` apply: the branch that
  # cannot carry a word does not say it.
  #
  # **A shard is not a code area.** RSpec/Knapsack partitions are arbitrary with respect to
  # directory structure, so "which partition of this run is expensive per test" is the question
  # answered here. "Which DIRECTORY is expensive" is a different question with a different answer,
  # and it is answered elsewhere — `SpecObservation.directory_durations_in` rolls the same run's
  # per-example rows up by code area. The two are not substitutes and cannot be read off each
  # other: an area's cost is spread across every shard that happened to draw its files. Every
  # string built from these has to be worded so a reader cannot mistake one for the other.

  # Below this, a spread is not a finding. Same reasoning as `NEGLIGIBLE_EXCESS_PERCENT` and
  # deliberately a separate constant rather than a reuse of it: that one thresholds the excess over
  # the balanced floor, this one thresholds the dispersion of a set of per-shard values, and two
  # different quantities sharing one constant is how a later change to either silently moves the
  # other. Both happen to sit at 5% today, which is not a reason to fuse them.
  NEGLIGIBLE_SPREAD_PERCENT = 5.0

  # Each shard's test count, in `#shard_durations` order. `.to_i` because the column is
  # `null: false, default: 0` — a shard that loaded no specs is a real row carrying a real zero.
  def shard_spec_counts = shard_durations.map { |_shard_id, _seconds, spec_count| spec_count.to_i }

  # Each shard's seconds per test, in the same order, with `nil` for any shard that has no
  # denominator to divide by (or no numerator to divide). Aligned with `#shard_durations` rather
  # than compacted, so a caller cannot line a rate up against the wrong shard.
  #
  # **Two different absences arrive here as the same `nil`, and they are not the same fact.** A
  # shard with `total_specs_count = 0` reported a wall clock over no tests — an ordinary row, since
  # the column is `null: false, default: 0`, and the one `#unsized_shard_count` counts. A shard
  # with a null `duration_seconds` reported no wall clock at all, which is the coverage gap
  # `#some_shard_untimed?` / `#untimed_shard_count` already word for the whole panel. Collapsing
  # them here is correct for THIS list — neither shard has a cost per test, and this list is of
  # costs per test — but it means `nil` here answers "is there a rate?" and never "why not". A
  # caller that wants to SAY why must ask one of those two named predicates; it cannot recover the
  # reason from this array.
  def shard_seconds_per_spec
    @shard_seconds_per_spec ||= shard_durations.map do |_shard_id, seconds, spec_count|
      next nil if seconds.nil? || !spec_count.to_i.positive?

      seconds / spec_count
    end
  end

  # How many shards reported no tests at all. Not an error state: `total_specs_count` defaults to
  # `0` and a client can deliver a slice that loaded nothing.
  def unsized_shard_count = shard_spec_counts.count(&:zero?)

  # Whether every shard has a per-test cost. False makes the cost comparison below unavailable
  # rather than approximate — the line `#suite_size_measured?` draws for the run-level column, one
  # level down: a shard with a duration and no denominator has a wall clock and no cost per test,
  # and dividing by its zero, or quietly taking the spread over the rest and calling it the run's,
  # are both figures this panel cannot stand behind.
  #
  # **Named for the conjunction it is, not for either half.** It is false in two distinct states —
  # a shard that reported no TESTS and a shard that reported no TIMING — because
  # `#shard_seconds_per_spec` needs both and its comment writes out why the two nils differ. An
  # earlier draft of this called itself `every_shard_sized?`, which named only the first half while
  # answering both, and the sentence built on it then reported `#unsized_shard_count` — a count of
  # the first half alone — as the evidence for a branch the second half could also have entered.
  # Anything that wants to SAY which absence it hit branches on `#unsized_shard_count` or on
  # `#untimed_shard_count`, the two predicates that each name one of them; this one is for deciding
  # whether a cost figure exists at all.
  #
  # Vacuously TRUE on a run with no shards (`[].none?`), which is safe only because every caller
  # sits behind `#wall_clock_decomposable?` — the same load-bearing vacuity `#some_shard_untimed?`
  # records about its own vacuous false, and it fails the same way: a future ungated caller would
  # read "every shard has a cost" off a run that has no shards. That same gate is also what makes
  # the untimed half of this predicate unreachable from the panel today: `!some_shard_untimed?` is
  # exactly the statement that no null-duration row is present.
  def every_shard_costed? = shard_seconds_per_spec.none?(&:nil?)

  # How far apart the shards' test counts are, as a percentage of their mean. `nil` when there is
  # no mean to divide by — every shard reported zero — which is a real state and not a spread of 0.
  def spec_count_spread_percent = relative_spread_percent(shard_spec_counts)

  # The same dispersion over the per-test costs, and `nil` unless every shard has one. A spread
  # taken over the sized shards alone would be a fact about a subset wearing a sentence about the
  # run.
  def seconds_per_spec_spread_percent
    return nil unless every_shard_costed?

    relative_spread_percent(shard_seconds_per_spec)
  end

  # Whether each spread is worth reading as a cause rather than as noise. Both decide WORDING and
  # never whether a number is shown — the rule `#wall_clock_excess_material?` states. A `nil`
  # spread is not material: an uncomputable figure is not a finding.
  def spec_count_spread_material?
    spec_count_spread_percent.present? && spec_count_spread_percent >= NEGLIGIBLE_SPREAD_PERCENT
  end

  def seconds_per_spec_spread_material?
    seconds_per_spec_spread_percent.present? &&
      seconds_per_spec_spread_percent >= NEGLIGIBLE_SPREAD_PERCENT
  end

  # The two spreads as strings, rounded where they are compared and formatted where they are read —
  # `#relative_spread_percent` rounds to the tenth and the thresholds above are applied to that
  # rounded value, so the boundary a reader can see is the boundary the branch was chosen on. This
  # is `#wall_clock_excess_material?`'s rule about judging an operand at the precision it renders.
  def spec_count_spread_label = "#{spec_count_spread_percent}%"
  def seconds_per_spec_spread_label = "#{seconds_per_spec_spread_percent}%"

  # The cheapest and dearest per-test costs on record, for a sentence that wants the two ends of
  # the spread rather than the spread itself. `nil` unless every shard has a cost, on
  # `#every_shard_costed?`'s rule.
  def cheapest_seconds_per_spec_label = extreme_seconds_per_spec_label(:min)
  def dearest_seconds_per_spec_label = extreme_seconds_per_spec_label(:max)

  # == Whether this run's suite size may be differenced against another run's
  #
  # `total_specs_count` is not a suite size. On a run with shards it is the SUM over the shards
  # **recorded so far** — `Ingest::RunRecorder#recompute_totals` re-derives it after every ingest —
  # so it climbs from one slice to the whole suite across the minutes a sharded CI job takes. And
  # `Repository#latest_test_run` picks that row up the instant the first shard lands, because
  # `created_at` is stamped by the first POST. A four-shard 20,000-example suite therefore reads as
  # ~5,000 for most of its own build.
  #
  # A *level* survives that: "5,010 tests, measured on <sha>" is a true statement about what was
  # reported. A *difference* does not. Subtracting yesterday's complete 20,000 from today's
  # in-flight 5,010 prints −14,990 — a suite-size change no commit made, wearing a named SHA and an
  # age that make it read as a checked fact. That is not an exotic state; it is the ordinary window
  # every sharded run passes through, and it has a permanent form too: a job cancelled after two of
  # four shards leaves a half-sized row in the history forever.
  #
  # So the two predicates below are the same question asked of each side of the subtraction — *is
  # this a measurement of the whole suite?* — and the panel withholds the figure rather than
  # printing a change across two rows of unequal coverage.

  # Whether this run measured a suite at all. A run that reported zero tests has a count but not a
  # measurement, and the panel already says so in those words a paragraph below the figure. A
  # difference taken against it describes the report, not the suite.
  #
  # `.to_i` because the column is nullable (default `0`, no `null: false`): a NULL is "nothing was
  # reported", which is the answer this predicate already gives for a reported zero.
  def suite_size_measured? = total_specs_count.to_i.positive?

  # Whether `other` was put together from the same number of parts as this run, so a difference
  # between their counts is a change in the *suite* rather than a change in *how much of it has
  # been reported*.
  #
  # Shard count is a proxy and not a proof, deliberately. Nothing in the payload says "shard 1 of
  # 4" — `Ingest::Payload` accepts a shard *index* and never a total — so no run can be asked
  # whether it is complete, and a check that pretended otherwise would be inventing a fact. What
  # two runs can be asked is whether they were assembled the same way, and unequal counts is
  # exactly the observable shape of all three ways this goes wrong: the in-flight window, the
  # cancelled job, and a laptop run sitting beside a sharded CI one.
  #
  # It answers true across the entire unsharded corpus (`0 == 0`), which is every run that named no
  # `ci_run_id`. Those rows are written once and never re-derived, so they were always comparable
  # and nothing about them changes.
  def assembled_like?(other) = shard_count == other.shard_count

  # How this run arrived, as a phrase a sentence can name it by when two runs disagree.
  #
  # Zero shards is not "0 reports". It is a run that arrived whole in a single POST — the unsharded
  # corpus — and wording it as a count of parts would read as a delivery that lost all of them.
  def delivery_description
    return "reported in one piece" if shard_count.zero?

    "assembled from #{shard_count} shard #{"report".pluralize(shard_count)}"
  end

  # Seconds below a minute keep their tenth, which is the precision the Recent-runs cell already
  # rendered this column at. At a minute and above the tenth stops carrying anything a reader
  # wants and `372.4s` stops being legible as "six minutes", so it becomes h/m/s parts instead.
  #
  # Only the *minutes* part survives a zero, and only when hours precede it, which keeps
  # `1h 0m 12s` from collapsing into a misleading `1h 12s`. A trailing zero is dropped instead —
  # `1h 0m`, not `1h 0m 0s` — because a last part has no following part to be misread as.
  #
  # The rounding happens BEFORE the sub-minute test, not after it. Rounding after would let
  # `59.96` choose the seconds branch and then print as `60.0s`: a string this format can
  # otherwise never produce, in exactly the raw-seconds shape the h/m/s branch exists to retire,
  # at exactly the value where it decided raw seconds stop being legible.
  #
  # Shared by the wall clock and the machine time on purpose. They are the same quantity in the
  # same unit sitting one row apart in the same list, and two formatters would eventually print
  # them two ways — which is precisely the comparison the pair exists to let a reader make.
  #
  # ON THE CLASS rather than private on the instance, because a *third* reader arrived that holds
  # no run: `ApplicationHelper#runtime_change` renders the signed difference between two runs'
  # wall clocks, and a difference belongs to neither row. The alternative was a helper-side
  # re-implementation of the branching above, which is the one outcome the "two formatters" note
  # exists to prevent — the delta and the level sitting in the same cell are exactly the two
  # figures that must not print seconds two ways. It takes a magnitude and knows nothing of sign:
  # the caller special-cases zero and renders the sign, so nothing here has to grow a branch for
  # a negative it would format as a bare `-` hyphen anyway.
  def self.humanized_seconds(value)
    seconds = value.to_f.round(1)
    return "#{seconds}s" if seconds < 60

    hours, remainder = seconds.round.divmod(3600)
    minutes, whole_seconds = remainder.divmod(60)

    parts = []
    parts << "#{hours}h" if hours.positive?
    parts << "#{minutes}m" if minutes.positive? || hours.positive?
    parts << "#{whole_seconds}s" if whole_seconds.positive?
    parts.join(" ")
  end

  # "Is this difference one the formatter above can print?" — the zero test, asked at the precision
  # the figure is RENDERED at rather than the precision the column stores it at, and living here
  # because that precision is `humanized_seconds`' own and belongs beside it.
  #
  # `duration_seconds` is a float of arbitrary precision; the formatter rounds to a tenth. So a
  # 0.03s difference is real in the column and invisible in the string, and a caller that asked
  # `delta.zero?` of the raw float sent it down the *changed* branch to render `+0.0s` — a second
  # spelling of "it did not move" in a panel that reserves exactly one (`±0`), beside an
  # `aria-label` reading "0.0s slower", which contradicts itself in four words.
  #
  # A predicate rather than each caller rounding for itself: `ApplicationHelper` asks this three
  # times (the figure and the two readings), and three spellings of one precision is how they
  # would eventually disagree about whether the same delta moved.
  def self.seconds_unchanged?(value) = value.to_f.round(1).zero?

  private

  # How far apart a set of per-shard values is, as a percentage of their own mean.
  #
  # `(max - min) / mean` and not `max / min`: a ratio against the smallest is undefined the moment
  # one shard reports zero — the ordinary state this section has to survive — and it explodes
  # rather than degrading as the smallest approaches it. Dividing by the mean keeps the figure
  # finite over any set with a positive mean, and reads as "how wide, relative to typical", which
  # is the sentence the panel wants.
  #
  # `nil`, never `0.0`, when there is no mean to divide by. A set that is entirely zeroes has no
  # dispersion *to measure*, and reporting that as a measured 0% would let "the shards are evenly
  # sized" be said about shards that reported nothing at all.
  #
  # Rounded to the tenth because that is the precision this figure is RENDERED at, and the
  # materiality thresholds are applied to the value this returns — so two runs printing the same
  # percentage cannot receive opposite verdicts. `#wall_clock_excess_material?` writes out why.
  def relative_spread_percent(values)
    return nil if values.empty?

    mean = values.sum.to_f / values.length
    return nil unless mean.positive?

    ((values.max - values.min) / mean * 100).round(1)
  end

  # One shard's size, or the stated absence for a shard that loaded none.
  #
  # `total_specs_count` is `null: false, default: 0`, so "no tests" is a real row and not a missing
  # one — and it is the row with a wall clock and no denominator. It renders as words rather than
  # as `0 tests` beside a `0.0ms/test`, because a computed zero there would read as "these tests
  # are free" about a shard that ran no tests at all.
  def shard_size_label(spec_count)
    count = spec_count.to_i
    return "no tests reported" unless count.positive?

    "#{ActiveSupport::NumberHelper.number_to_delimited(count)} #{"test".pluralize(count)}"
  end

  # A per-test cost, in the unit that keeps it legible.
  #
  # NOT `humanized_seconds`, which is right for the three run-level figures that sit within a few
  # lines of each other and wrong here: this quantity is three to five orders of magnitude smaller,
  # and `74.25 / 5000` through that formatter prints `0.0s` — a computed zero, in the panel whose
  # rule is that a figure it cannot stand behind is withheld with its reason rather than rounded
  # away. A different unit is not a second formatter for the same quantity; it is the first
  # formatter for a different one, and it says its unit on every value so the two cannot be
  # confused for each other on the same line.
  #
  # Three branches because there are three magnitudes a real suite produces: a slow integration
  # suite at seconds per example, an ordinary unit suite at milliseconds, and a suite so fast the
  # tenth of a millisecond stops resolving it. The last states a bound rather than rounding to
  # `0.0ms/test`, on the same rule as `#shard_size_label`.
  def humanized_seconds_per_spec(value)
    return "#{value.round(1)}s/test" if value >= 1.0

    millis = value * 1000
    return "#{millis.round(1)}ms/test" if millis.round(1).positive?

    "under 0.1ms/test"
  end

  # The cheapest or dearest per-test cost, formatted. `nil` unless every shard has one, so a
  # sentence naming the two ends of the spread cannot quote an end of a subset.
  def extreme_seconds_per_spec_label(bound)
    return nil unless every_shard_costed?

    humanized_seconds_per_spec(shard_seconds_per_spec.public_send(bound))
  end

  # One aggregate read, on `index_test_run_shards_on_test_run_id`, answering all four questions at
  # once — the Overview asks every one of them about the same already-loaded run, and four separate
  # scalar queries would be four round trips for one row of facts.
  #
  # `COUNT(duration_seconds)` counts non-nulls, which is what separates "four shards, one silent"
  # from "four shards" without a second pass over the rows. Memoized per instance: this is a
  # read-only display path, and `reload` on a run whose shards changed under it is not something
  # any caller does.
  #
  # `MAX(updated_at)` rides along rather than taking a read of its own, and the position it rides
  # in is load-bearing: it is APPENDED, so `shard_count`, `timed_shard_count` and `machine_seconds`
  # keep reading indices 0-2 and every caller of theirs — including `GET /api/v1/repository`, whose
  # body is pinned byte-for-byte by `spec/requests/api/v1/repository_latest_run_spec.rb` — answers
  # exactly what it answered before. A wider aggregate over the same index is the same round trip.
  def shard_totals
    @shard_totals ||= test_run_shards.pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(duration_seconds)"),
      Arel.sql("SUM(duration_seconds)"),
      Arel.sql("MAX(updated_at)")
    )
  end

  # The instance-side spelling of the formatter above, so `duration_label` and
  # `machine_seconds_label` read as they always did. Private because a run's own two labels are the
  # only instance-side callers there have ever been, and the third reader — the signed change on
  # the Overview panel — holds a difference rather than a run and reaches the class method directly.
  def humanized_seconds(value) = self.class.humanized_seconds(value)
end
