module ApplicationHelper
  # The one rendering of a run's wall clock. `TestRun#duration_label` settles the wording; this
  # settles the treatment that goes with it, so the Overview panel's header figure and the
  # Recent-runs table cell cannot drift into two different renderings of the same column.
  #
  # The muted tone is what keeps "the client sent no timing" from reading as a measurement: it is
  # the same treatment the nil `branch` cell already uses one column over, applied on the same
  # rule — an absent fact is styled as absent, never printed as a number.
  def test_run_duration(test_run)
    tag.span(test_run.duration_label,
             class: ("text-app-muted" unless test_run.duration_reported?))
  end

  # The machine-time figure that sits beside the wall clock on a sharded run, on the same rule: an
  # absent fact is styled as absent. Its own helper rather than a flag on the one above, because
  # the two read different columns — one the run's MAX, one the SUM over its shards — and a run
  # can have reported either without the other.
  #
  # Note what is NOT muted: a *partial* sum. "at least 3m 15s" is a measurement, just an incomplete
  # one, and the incompleteness is carried by the wording rather than by desaturating a real
  # number into looking like an omission.
  def test_run_machine_time(test_run)
    tag.span(test_run.machine_seconds_label,
             class: ("text-app-muted" unless test_run.machine_seconds_reported?))
  end
end
