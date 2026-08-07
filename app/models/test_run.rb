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
  has_many :test_run_shards, dependent: :destroy

  validates :commit_sha, presence: true

  def annotated_ratio
    return 0.0 if total_specs_count.to_i.zero?

    (annotated_specs_count.to_f / total_specs_count * 100).round(1)
  end

  # The same share as a 0–1 fraction, which is the unit the `/ingest` API reports
  # (see the SpecGuard API Reference). `annotated_ratio` above is the percentage the dashboard renders.
  # Two names rather than one number and a convention: the 100× gap between them is invisible in
  # a JSON body, and a client that guesses wrong is wrong by two orders of magnitude.
  def annotated_fraction
    return 0.0 if total_specs_count.to_i.zero?

    (annotated_specs_count.to_f / total_specs_count).round(3)
  end

  # Whether the client reported a wall clock at all. `duration_seconds` is nullable by design and
  # `Ingest::Payload#validate_duration_seconds` accepts nil explicitly, so "no timing was sent" is
  # a real state — and a distinct one from a run that genuinely measured 0.0 seconds. Deliberately
  # `nil?` rather than `present?`: `0.0.present?` is true, but reading the predicate as "is there a
  # number here" and answering it with a blank check is how a measured zero starts rendering as an
  # omission.
  def duration_reported? = !duration_seconds.nil?

  # The run's wall clock, formatted once for every surface that shows it. Both readers of this
  # column — the Overview panel's header figure and the Recent-runs table cell — go through here,
  # so the same float cannot render two ways on one page.
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
  # each and would pay ten. The caller there holds a single grouped `COUNT(*)` keyed by
  # `test_run_id` (`RepositoriesController#preload_shard_counts`, indexed by
  # `index_test_run_shards_on_test_run_id`) and primes each row from it.
  #
  # Deliberately narrow: it primes the COUNT alone and never the whole `shard_totals` tuple,
  # because a grouped count is the only aggregate a list view can cheaply take. `timed_shard_count`
  # and `machine_seconds` keep reading their own row of facts, so nothing can end up answering a
  # *timing* question out of a number that measured no timing. Priming the tuple with two nils
  # would do exactly that, and it would do it silently.
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
  def timed_shard_count = shard_totals[1]

  # How many reported nothing — the size of the hole in the SUM below, and the number any surface
  # apologising for a partial machine time has to name.
  def untimed_shard_count = shard_count - timed_shard_count

  # SUM over the shards' durations, or nil when not one of them reported a timing. SQL's SUM skips
  # nulls and returns NULL over an empty set, which is the distinction wanted here: nil means "no
  # shard reported", never "the shards added up to nothing".
  def machine_seconds = shard_totals[2]

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

  # Whether the wall clock can honestly be decomposed at all.
  #
  # Two conditions, and the second is the load-bearing one. The floor below divides the SUM by the
  # shard *count*, so a silent shard puts a numerator over the wrong denominator twice over: the
  # floor comes out too low (its own work is missing from the SUM) and the excess therefore comes
  # out too high, in the direction that manufactures a finding. `some_shard_untimed?` is the
  # existing predicate for exactly that question — note its documented caveat, that it is
  # vacuously false on a run with no shards, which is safe here only because `multi_shard?` is
  # asked first and asked in the same expression.
  def wall_clock_decomposable? = multi_shard? && !some_shard_untimed?

  # Every shard's `[shard_id, duration_seconds]`, slowest first.
  #
  # ONE query for all of them regardless of how many there are — a 40-shard matrix costs the same
  # as a 4-shard one. It is a second read against `test_run_shards` beside the memoized
  # `shard_totals` aggregate, which is deliberate: `shard_totals` is a `pick` of three scalars and
  # feeds `GET /api/v1/repository`, so widening it to carry rows would change what its callers
  # load for a figure only the dashboard renders. Constant, not minimal, is the property that
  # matters.
  #
  # Ordered by duration rather than by `shard_id` or by insertion, because the point of rendering
  # the list at all is to make the *shape* visible: slowest-first puts the shard just named at the
  # head and walks down to the fastest, so the spread reads off in one pass. Ordering by name
  # would sort `"10"` before `"2"` (the column is a string, and it is a string because a client
  # may name its slices anything), and ordering by insertion would sort by whichever shard
  # happened to POST first, which is not a fact about the suite. `id` breaks ties so the order is
  # total and stable.
  def shard_durations
    @shard_durations ||= test_run_shards.order(duration_seconds: :desc, id: :asc)
                                        .pluck(:shard_id, :duration_seconds)
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

  # The slowest shard's name — the row the run's `duration_seconds` MAX came from.
  def slowest_shard_label = shard_label(shard_durations.first&.first)

  # The shortest wall clock any arrangement of these shards could have produced: the machine time
  # spread perfectly evenly across them.
  #
  # A **lower bound and never a target**. Tests are not arbitrarily divisible — a single example
  # longer than this floor makes it unreachable on its own — so nothing here claims such a split
  # exists, only that none can go under it. Every surface rendering this has to word it that way.
  def balanced_wall_clock_seconds = machine_seconds / shard_count

  # How much longer the run waited than that floor: the part of the wait attributable to how the
  # suite was divided rather than to the suite itself.
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
  def wall_clock_excess_material?
    wall_clock_excess_seconds >= NEGLIGIBLE_EXCESS_SECONDS &&
      wall_clock_excess_percent >= NEGLIGIBLE_EXCESS_PERCENT
  end

  # The floor and the excess, formatted by the same formatter the wall clock and the machine time
  # already use. Four numbers in one unit within a few lines of each other: a second formatter
  # would eventually print them two ways and destroy the comparison they exist to enable.
  def balanced_wall_clock_label = humanized_seconds(balanced_wall_clock_seconds)
  def wall_clock_excess_label = humanized_seconds(wall_clock_excess_seconds)

  # Every shard as `[name, formatted duration]`, slowest first — the distribution itself, so the
  # shape is visible rather than summarised into a single ratio. Formatted here rather than in the
  # view for the reason directly above: `humanized_seconds` is private, and it stays private.
  def shard_duration_labels
    shard_durations.map { |shard_id, seconds| [shard_label(shard_id), humanized_seconds(seconds)] }
  end

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

  private

  # One aggregate read, on `index_test_run_shards_on_test_run_id`, answering all three questions at
  # once — the Overview asks every one of them about the same already-loaded run, and three separate
  # scalar queries would be three round trips for one row of facts.
  #
  # `COUNT(duration_seconds)` counts non-nulls, which is what separates "four shards, one silent"
  # from "four shards" without a second pass over the rows. Memoized per instance: this is a
  # read-only display path, and `reload` on a run whose shards changed under it is not something
  # any caller does.
  def shard_totals
    @shard_totals ||= test_run_shards.pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(duration_seconds)"),
      Arel.sql("SUM(duration_seconds)")
    )
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
  def humanized_seconds(value)
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
end
