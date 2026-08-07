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

  # A change in a count, rendered as a change rather than as a magnitude. The sign carries the
  # whole meaning: a suite that gained 47 tests and one that lost 47 are opposite facts, and a bare
  # `47` sitting beside a suite size is neither — it reads as a second, smaller count of something.
  #
  # A true minus (U+2212), not a hyphen-minus. This renders inside a `tabular-nums` figure directly
  # under and over other numbers, and a hyphen is drawn narrower and lower than the `+` it has to
  # align with, which is exactly the character difference the typographic minus exists to fix.
  #
  # `±0` for no change, not `+0`. "The suite did not move between these two runs" is a real answer
  # and `+0` claims a direction it does not have. It is still rendered rather than suppressed —
  # a run that changed nothing is precisely the case a reader wants confirmed, and dropping the
  # figure there would be indistinguishable from having no comparison to make at all.
  def signed_count(delta)
    return "±0" if delta.zero?

    "#{delta.negative? ? "−" : "+"}#{number_with_delimiter(delta.abs)}"
  end
end
