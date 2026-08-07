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
end
