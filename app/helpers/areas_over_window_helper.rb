# frozen_string_literal: true

# The sentences of the "Areas that grew or shrank over the window" panel on repositories#show. Lifted
# out of RepositoriesHelper, which had grown past what one file can be read as (the lift itself
# moved no behavior; SPGD-1865 later gave the baseline sentence its link and a SafeBuffer return).
# `window_branch_clause` stays in RepositoriesHelper (shared with other panels) and is reached here
# by implicit receiver, since every helper is mixed into the one view class.
module AreasOverWindowHelper
  # == The "Areas that grew or shrank over the window" panel's sentences

  # WHICH run this comparison was actually taken against, and how far back it sits.
  #
  # The panel's single most important sentence, and the one that has no counterpart on the last-push
  # panel beside it. There, "the previous run on this branch" names the comparand exactly: there is
  # only one candidate and it is either usable or the panel says why not. Here the baseline is WALKED
  # — the oldest run of the window that can be compared against this one — so the comparand is a
  # choice the reader did not make and cannot see, and a figure headed "across the window" that was
  # in fact taken across four runs is a wrong measurement rather than a vague one.
  #
  # Three facts, because three different readers need different ones: the commit, so it can be looked
  # up; how far back, so the figure can be sized against the window; and how long ago, because "26
  # runs back" is a week on one branch and a quarter on another.
  #
  # Since SPGD-1865 the sha names itself the family's read gesture: a link into that run's own page,
  # anchored at the Summary — the same pattern _comparison_basis, _areas_grew_or_shrank,
  # _recent_runs and _unstable_test_runs already use. The href carries the FULL sha on purpose
  # (`latest_test_run_for_commit` matches exactly, so a seven-character ask would resolve nil,
  # silently fall back to the newest run and only the run-anchor notice would say so);
  # `drill_down_path` carries the page's open asks (branch, window, layer, limit, drill-ins) and the
  # explicit commit_sha beats any carried run anchor, so the reader keeps every ask they opened and
  # lands on this baseline run rather than the page they were on. +0 queries: `baseline_run` is the
  # walk's own loaded row (`SpecDirectoryWindowContext`), and the link is built from it in memory.
  #
  # Returns a SafeBuffer, not a String. Every composer that embeds this sentence MUST join it with
  # `safe_join` or a block slot — interpolating it into a plain String strips html_safe at every
  # nesting level and the anchor renders as escaped text with no error, and a text assertion cannot
  # tell the difference. The five composers in `AreasRuntimeOverWindowHelper` and the two
  # EmptyState-interpolating partials are the consumers to keep honest.
  def spec_directory_window_growth_baseline_sentence(growth)
    position =
      if growth.runs_back == 1
        "the run immediately before it"
      else
        "#{number_with_delimiter(growth.runs_back)} runs back"
      end

    safe_join(["Measured against ",
               spec_directory_window_baseline_run_link(growth),
               " — #{position} in this window, " \
               "#{time_ago_in_words(growth.baseline_run.created_at)} ago — and this run."])
  end

  # The window family's one spelling of the baseline naming: seven characters as the link text,
  # the FULL sha in the href, the Summary as the anchor. Defined once here so the runtime helper,
  # the refusal arms and the partials that compose their own sentences around a bare sha cannot
  # drift into four spellings of one gesture. +0 queries by construction: `growth.baseline_run` is
  # the walk's own row and nothing here re-reads it.
  def spec_directory_window_baseline_run_link(growth)
    link_to(growth.baseline_run.commit_sha.first(7),
            drill_down_path(@repository, commit_sha: growth.baseline_run.commit_sha, anchor: "summary"),
            class: "rc-link")
  end

  # How much of the window the comparison actually spans, and what the walk stepped over to reach
  # its baseline.
  #
  # A window is a promise about depth, so a comparison that spans less of it than the heading says
  # has to say by how much and why. Both reasons are named separately rather than totalled: a run
  # that reported no tests is a client or a job that failed to report, and a run assembled from a
  # different number of parts is a sharding change — two different things to go and fix, and a bare
  # "3 runs were skipped" is neither.
  def spec_directory_window_growth_span_sentence(growth)
    branch = window_branch_clause(growth)
    unless growth.shortened?
      return "It spans all #{number_with_delimiter(growth.window_run_count)} " \
             "#{"run".pluralize(growth.window_run_count)} of this window#{branch}."
    end

    "It spans #{number_with_delimiter(growth.covered_run_count)} of the last " \
      "#{number_with_delimiter(growth.window_run_count)} " \
      "#{"run".pluralize(growth.window_run_count)}#{branch}: the " \
      "#{number_with_delimiter(growth.skipped_count)} older " \
      "#{"run".pluralize(growth.skipped_count)} could not be compared against this one — " \
      "#{spec_directory_window_growth_skipped_reasons(growth)}."
  end

  # Why the walk reached the far end of the window without finding a baseline — the two states
  # decidable from the runs alone, said apart because they are two different repairs.
  #
  # The composition branch names this run's own delivery, through the same `TestRun#delivery_description`
  # seam the Overview delta and the last-push panel word this with, so a reader is told what the
  # earlier runs would have had to match rather than only that they did not.
  # Each branch counts the runs ITS OWN condition rejected, off the split counters, rather than
  # every earlier run in the window. The walk rejects on two conditions and `next`s past the
  # unmeasured ones before composition is ever asked of them, so a composition sentence sized to
  # the whole window makes two wrong claims at once: it blames sharding for runs whose sharding was
  # never looked at (and is often fine — an unmeasured run reports zero shards, which is assembled
  # exactly like an unsharded anchor), and it then counts those same runs a second time in the
  # clause below. Both are the rule the `#..._skipped_reasons` comment sets: a reason given for
  # runs it did not apply to is a wrong explanation, not a vague one.
  #
  # `:no_measured_baseline` was previously right only by accident — it is unreachable while any run
  # mismatched, so "every earlier run" happened to equal the unmeasured count. Deriving it makes
  # the accident a guarantee.
  def spec_directory_window_growth_no_baseline_description(growth)
    if growth.state == :no_measured_baseline
      unmeasured = growth.skipped_unmeasured_count
      return "#{unmeasured == 1 ? "The" : "Every one of the"} " \
             "#{spec_directory_window_growth_earlier_runs(growth, unmeasured)} reported no tests, " \
             "so there is no measured end to compare this run against. A run that reported zero " \
             "tests has a count but not a measurement, and differencing against it would charge " \
             "this branch for a gap in the reporting."
    end

    # Qualified as the runs that got PAST the measured check, but only where some run did not —
    # where none was rejected earlier the qualifier would distinguish nothing.
    mismatched = growth.skipped_assembled_differently_count
    runs = spec_directory_window_growth_earlier_runs(growth, mismatched)
    runs += " that reported tests" if growth.skipped_unmeasured_count.positive?

    "#{mismatched == 1 ? "The" : "Not one of the"} #{runs} " \
      "#{mismatched == 1 ? "was not" : "was"} assembled the way this run was — this run was " \
      "#{growth.anchor_run.delivery_description}. A run's examples arrive shard by shard, so a " \
      "difference taken across two compositions would report areas growing and shrinking that no " \
      "commit touched.#{spec_directory_window_growth_unmeasured_clause(growth)}"
  end

  private

  # "2 earlier runs in this window on main" — the noun phrase both no-baseline branches count with,
  # written once so the two of them cannot drift into describing the same window differently. The
  # COUNT is the caller's, because the two branches are about different subsets of the window.
  def spec_directory_window_growth_earlier_runs(growth, count)
    "#{number_with_delimiter(count)} earlier #{"run".pluralize(count)} in this window" \
      "#{window_branch_clause(growth)}"
  end

  # The walk's two rejections, in the words of what each one is. Joined rather than templated
  # per-state so a window that hit both says both, and neither clause is printed where its count is
  # zero — a reason given for runs it did not apply to is a wrong explanation, not a vague one.
  #
  # A single stepped-over run says "it", because the sentence has already counted it: "the 1 older
  # run could not be compared — 1 reported no tests" counts one run twice in eleven words, and a
  # reader re-reads it looking for the second one.
  def spec_directory_window_growth_skipped_reasons(growth)
    unmeasured = growth.skipped_unmeasured_count
    mismatched = growth.skipped_assembled_differently_count

    if growth.skipped_count == 1
      return unmeasured.positive? ? "it reported no tests" : "it was assembled from a different " \
                                                             "number of parts"
    end

    reasons = []
    reasons << "#{number_with_delimiter(unmeasured)} reported no tests" if unmeasured.positive?
    if mismatched.positive?
      reasons << "#{number_with_delimiter(mismatched)} #{mismatched == 1 ? "was" : "were"} " \
                 "assembled from a different number of parts"
    end

    reasons.join(" and ")
  end

  # Runs the walk rejected before it ever reached the composition question. Only where there were
  # any: the composition sentence is true of the runs it describes, and appending "a further 0" to
  # it would be a clause about nothing.
  def spec_directory_window_growth_unmeasured_clause(growth)
    count = growth.skipped_unmeasured_count
    return "" unless count.positive?

    " A further #{number_with_delimiter(count)} #{"run".pluralize(count)} in the window reported " \
      "no tests at all."
  end
end
