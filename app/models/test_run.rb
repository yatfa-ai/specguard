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
  def shard_count = shard_totals[0]

  # Whether there is a composition to disambiguate at all. One shard's MAX *is* its SUM, and zero
  # shards have neither, so both render exactly as they always have — no second figure, no wording
  # change, on the whole existing corpus.
  def sharded? = shard_count > 1

  # How many of those shards reported a duration. `test_run_shards.duration_seconds` is nullable
  # and `Ingest::Payload` accepts nil explicitly, so a shard with no timing is an ordinary state
  # rather than a fault — and the gap between this and `shard_count` is exactly how much of the
  # machine time is missing.
  def timed_shard_count = shard_totals[1]

  # SUM over the shards' durations, or nil when not one of them reported a timing. SQL's SUM skips
  # nulls and returns NULL over an empty set, which is the distinction wanted here: nil means "no
  # shard reported", never "the shards added up to nothing".
  def machine_seconds = shard_totals[2]

  # Deliberately `nil?` and not `present?`, for the same reason `duration_reported?` is: a suite
  # whose shards genuinely measured 0.0 has a measurement, and a blank check would render it as an
  # omission.
  def machine_seconds_reported? = !machine_seconds.nil?

  # Some shard reported no timing, so the SUM is over fewer rows than the run has. The figure is
  # then a floor rather than a total and must not be printed as one — this panel's established
  # refusal is to say what it does not know rather than round it away.
  def machine_seconds_partial? = timed_shard_count < shard_count

  # The machine time, worded to its own coverage. Three states, because there are three: nothing
  # reported, a partial sum, a complete one. Only the last is a total, and only it says so.
  def machine_seconds_label
    return "not reported" unless machine_seconds_reported?

    label = humanized_seconds(machine_seconds)
    machine_seconds_partial? ? "at least #{label}" : label
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
