# frozen_string_literal: true

# The sentences of the "Areas that got slower or faster over the window" panel on repositories#show —
# the AREA TIME comparison across the branch window's two ends ({SpecDirectoryWindowRuntimeGrowth}).
#
# A module of its own rather than more methods in `RepositoriesHelper`, which is being moved out of
# by a parallel change. The baseline / span / no-baseline sentences are NOT re-spelled here:
# {AreasOverWindowHelper} words them for any presenter with the walk's accessors, and this panel's
# object has the same ones, so the two window panels cannot describe one baseline differently.
module AreasRuntimeOverWindowHelper
  # The "How to read this" paragraph: how many areas are listed, what they are ranked by, what the
  # absences mean, and what the figure does NOT claim. Returned as one string so the template and
  # any other surface say it one way.
  def spec_directory_window_runtime_growth_basis(growth)
    sentences = [spec_directory_window_runtime_growth_scope_sentence(growth),
                 spec_directory_window_growth_baseline_sentence(growth),
                 spec_directory_window_growth_span_sentence(growth),
                 "This window's two ends are compared (not a trend), so what an area did between them " \
                 "is not shown: an area that got slower and then faster again reads here as an area " \
                 "that did not move."]
    sentences << "Where the movement runs out before the list does, areas whose time did not move " \
                 "are listed too, as ±0." if growth.any_unmoved?
    sentences << "Areas one of the two ends reported no timing for are listed last, as \"Not timed\" — " \
                 "nothing about them got faster." if growth.any_timing_gap?
    sentences << "Each area is the immediate parent directory of the files that ran its examples, so " \
                 "the areas sit side by side rather than inside one another."
    sentences << "A test that was MOVED is the same test, and this panel cannot see the difference: a " \
                 "renamed or relocated directory appears here as one area gaining time and another " \
                 "losing the same amount, with nothing having got slower and nothing faster — and " \
                 "across a window this long, that rename may be one nobody remembers."
    sentences << spec_directory_window_runtime_growth_denominator_sentence(growth)
    sentences.join(" ")
  end

  # "The 10 areas whose time moved most, of the 63 either end recorded — largest movement first, in
  # both directions." Counted off the rows the table lists.
  def spec_directory_window_runtime_growth_scope_sentence(growth)
    if growth.truncated?
      "The #{number_with_delimiter(growth.rows.size)} #{"area".pluralize(growth.rows.size)} whose time " \
        "moved most across this window, of the #{number_with_delimiter(growth.directory_count)} either " \
        "end recorded — largest movement first, in both directions."
    else
      "All #{number_with_delimiter(growth.directory_count)} #{"area".pluralize(growth.directory_count)} " \
        "either end of this window recorded — largest movement first, in both directions."
    end
  end

  # What every figure was summed over, and what it is not.
  def spec_directory_window_runtime_growth_denominator_sentence(growth)
    "Summed off the #{number_with_delimiter(growth.baseline_timed_count)} of " \
      "#{number_with_delimiter(growth.baseline_recorded_count)} and " \
      "#{number_with_delimiter(growth.anchor_timed_count)} of " \
      "#{number_with_delimiter(growth.anchor_recorded_count)} #{growth.layer? ? "#{growth.layer}-layer " : ""}" \
      "example rows the two ends recorded here that reported a timing — never the run wall clock on " \
      "the Summary at the top of this page, which is a maximum over the run's shards."
  end

  # The comparable-but-nothing-moved empty state.
  def spec_directory_window_runtime_growth_unmoved_description(growth)
    "Every area the two ends of this window timed took the same time at both, so no area of the " \
      "suite got slower or faster across it. #{spec_directory_window_runtime_growth_denominator_sentence(growth)} " \
      "#{spec_directory_window_growth_baseline_sentence(growth)} " \
      "#{spec_directory_window_growth_span_sentence(growth)} Only those two ends were compared, so " \
      "an area that got slower and faster again in between is counted here as one that did not move."
  end

  # The layer-empty-at-both-ends empty state.
  def spec_directory_window_runtime_growth_layer_empty_description(growth)
    "Neither the run at the far end of this window nor the newest run has an example that declared " \
      "#{growth.layer} as its layer, so there is no #{growth.layer}-layer time to compare area by " \
      "area. Both ends recorded per-example detail; the layer is simply absent from both. " \
      "#{spec_directory_window_growth_baseline_sentence(growth)} " \
      "#{spec_directory_window_growth_span_sentence(growth)}"
  end

  # The description for each refusal state the panel can be in. The two walk states that name no
  # baseline are worded by {AreasOverWindowHelper}; the rest are about the two ends' per-example rows.
  # Returns [title, description].
  def spec_directory_window_runtime_growth_refusal(growth)
    layer = growth.layer? ? "#{growth.layer}-layer " : ""
    baseline = growth.baseline_run&.commit_sha&.first(7)

    case growth.state
    when :anchor_unmeasured
      ["No comparison to draw",
       "This run reported no tests, so there is no suite to time area by area against anything " \
       "earlier on this branch. A run that reported zero tests has a count but not a measurement."]
    when :no_earlier_run
      ["No window to compare across yet",
       "This branch has one run in the window so far, and a comparison needs two ends. This panel " \
       "fills in as soon as there is an earlier run to measure against."]
    when :no_measured_baseline, :no_comparable_composition
      ["No comparison to draw", spec_directory_window_growth_no_baseline_description(growth)]
    when :baseline_unrecorded
      ["No comparison to draw",
       "The run this comparison landed on (#{baseline}, #{growth.runs_back} back in this window) " \
       "recorded no per-example detail, so it has no areas to time against — every area of the " \
       "newest run would read as time newly appearing. A run ingested before that detail was " \
       "stored, or sent by a client that reports only totals, has a suite size and none of these rows."]
    when :anchor_unrecorded
      ["No comparison to draw",
       "This run recorded no per-example detail, so it has no areas to time — every area of the " \
       "run at the far end of this window would read as time disappearing. A client that reports " \
       "only totals sends a suite size and none of these rows."]
    when :baseline_untimed
      ["No comparison to draw",
       "The run at the far end of this window (#{baseline}, #{growth.runs_back} back) reported no " \
       "timings — it recorded #{number_with_delimiter(growth.baseline_recorded_count)} #{layer}examples " \
       "and a duration for none of them — so there is nothing to measure the newest run's areas " \
       "against. Every area would otherwise read as time newly appearing."]
    when :anchor_untimed
      ["No comparison to draw",
       "This run reported no timings — it recorded #{number_with_delimiter(growth.anchor_recorded_count)} " \
       "#{layer}examples and a duration for none of them — so its areas cannot be timed. Every area " \
       "of the run at the far end of this window would otherwise read as time disappearing, which " \
       "is a reporting gap and not a speedup."]
    when :neither_timed
      ["No comparison to draw",
       "Neither this run nor #{baseline}, the run at the far end of this window, reported a duration " \
       "for any #{layer}example, so there is no time to compare area by area. Both recorded their " \
       "examples; neither client sent timings with them."]
    else
      ["No comparison to draw",
       "Neither this run nor #{baseline}, the run at the far end of this window, recorded " \
       "per-example detail, so there are no areas to time. Suite growth over the window as a whole " \
       "is on the chart above, which reads the run totals rather than these rows."]
    end
  end

  # == The "Files that got slower or faster across the window" drill-in's sentences
  #
  # The file rung below the panel above ({SpecDirectoryWindowFileRuntimeGrowth}); same baseline and
  # span sentences, so the two panels cannot describe one window differently.

  # The "How to read this" paragraph of the file drill-in.
  def spec_directory_window_file_runtime_growth_basis(growth)
    sentences = [spec_directory_window_file_runtime_growth_scope_sentence(growth),
                 spec_directory_window_growth_baseline_sentence(growth),
                 spec_directory_window_growth_span_sentence(growth),
                 "Only the two ends are compared, so what a file did between them is not shown: a file " \
                 "that got slower and then faster again reads here as a file that did not move."]
    sentences << "Where the movement runs out before the list does, files whose time did not move are " \
                 "listed too, as ±0." if growth.any_unmoved?
    sentences << "Files one of the two ends ran but reported no timing for are listed last, as " \
                 "\"Not timed\" — nothing about them got faster." if growth.any_timing_gap?
    sentences << "A file listed as new beside one listed as removed is what a RENAMED or relocated file " \
                 "looks like from here — and so is a real addition beside a real deletion. This panel " \
                 "sums each end's rows and pairs no example with any other example, so it cannot tell " \
                 "the two apart and does not try; both files are named so a reader can."
    sentences << "This area is the immediate parent of the files listed, so a nested area such as a " \
                 "subdirectory of it is its own area rather than part of this list."
    sentences << spec_directory_window_file_runtime_growth_denominator_sentence(growth)
    sentences.join(" ")
  end

  # "The 10 spec files whose time moved most across this window, of the 41 either end recorded in
  # this area — largest movement first, in both directions." Counted off the rows the table lists.
  def spec_directory_window_file_runtime_growth_scope_sentence(growth)
    if growth.truncated?
      "#{growth.path} — the #{number_with_delimiter(growth.rows.size)} spec " \
        "#{"file".pluralize(growth.rows.size)} whose time moved most across this window, of the " \
        "#{number_with_delimiter(growth.file_count)} either end recorded in this area — largest " \
        "movement first, in both directions."
    else
      "#{growth.path} — all #{number_with_delimiter(growth.file_count)} spec " \
        "#{"file".pluralize(growth.file_count)} either end of this window recorded in this area — " \
        "largest movement first, in both directions."
    end
  end

  # What every figure was summed over, and what it is not. This area's own rows, not the suite's.
  def spec_directory_window_file_runtime_growth_denominator_sentence(growth)
    "Summed off the #{number_with_delimiter(growth.baseline_timed_count)} of " \
      "#{number_with_delimiter(growth.baseline_recorded_count)} and " \
      "#{number_with_delimiter(growth.anchor_timed_count)} of " \
      "#{number_with_delimiter(growth.anchor_recorded_count)} #{growth.layer? ? "#{growth.layer}-layer " : ""}" \
      "example rows the two ends recorded in this area that reported a timing — this area's own rows, " \
      "never the run wall clock on the Summary at the top of this page, which is a maximum over the " \
      "run's shards."
  end

  # The comparable-but-nothing-moved empty state.
  def spec_directory_window_file_runtime_growth_unmoved_description(growth)
    "Every one of the #{number_with_delimiter(growth.file_count)} " \
      "#{"spec file".pluralize(growth.file_count)} the two ends of this window timed in " \
      "#{growth.path} took the same time at both. " \
      "#{spec_directory_window_file_runtime_growth_denominator_sentence(growth)} " \
      "#{spec_directory_window_growth_baseline_sentence(growth)} Only those two ends were compared, " \
      "so a file that got slower and faster again in between is counted here as one that did not move."
  end
end
