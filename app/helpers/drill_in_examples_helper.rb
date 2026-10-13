# frozen_string_literal: true

# The sentences of the three per-example drill-in panels' "How to read this" notes on
# repositories#show (the "Slowest tests" outcome sentence and the spec-file / repeated-description
# example scope sentences). Lifted out of RepositoriesHelper, which had grown past what one file
# can be read as; the methods are unchanged. Reached by implicit receiver, since every helper is
# mixed into the one view class.
module DrillInExamplesHelper
  # == The "Slowest tests" panel's outcome sentence

  # What this run's rows said HAPPENED to the examples they recorded — counted off those rows and
  # never off the Overview's suite size, which is re-derived by SUM over shard reports and can
  # legitimately disagree with them.
  #
  # ONE method for BOTH branches of the panel, which is a deliberate decision and not an accident
  # of extraction. The `else` branch — rows exist, not one of them timed — renders an empty state
  # instead of a ranking, and it would have been easy to let this sentence fall through with the
  # table. It must not: "nothing was timed" is a fact about DURATIONS and says nothing whatever
  # about outcomes, and a run that reported no timings and four failures is exactly the run whose
  # reader most needs the second half. Sharing the method also means the caption and the empty
  # state cannot end up quoting different failure counts for the same rows — the contradiction
  # `remove_confirmation`/`remove_notice` live together to avoid.
  #
  # `failed` and `pending` are counted BY NAME and the remainder is worded as "something other
  # than either", never as "passed". Nothing platform-side validates that string (see
  # `SpecObservation::COVERAGE_COUNTS`), so calling the remainder a pass would be asserting a value
  # nobody checked.
  #
  # The no-outcomes case is worded as an ABSENCE and gets no zero. `outcome` is nullable, so a run
  # whose client sends none stores a nil on every row and `failed_count` is legitimately 0 — and
  # "0 failed" printed over that run is "nothing to check" wearing the spelling of "everything
  # passed". It is the same separation `SlowestExamples#recorded?` draws between "no rows" and "no
  # timings", made on the outcome axis by `#outcomes_reported?`.
  def slowest_examples_outcome_sentence(slowest_examples)
    recorded = slowest_examples.recorded_count
    # With `?layer=` asked every count is the LAYER's, so the population is named as such rather than
    # as "this run's" — "the 40 request-layer examples", not a claim the run recorded only 40.
    examples = if slowest_examples.layer?
                 "#{number_with_delimiter(recorded)} #{slowest_examples.layer}-layer " \
                   "#{"example".pluralize(recorded)} this run recorded"
               else
                 "#{number_with_delimiter(recorded)} #{"example".pluralize(recorded)} this run recorded"
               end

    unless slowest_examples.outcomes_reported?
      return "Not one of the #{examples} reported an outcome, so nothing here says whether any of " \
             "them passed. That is a run which did not say, rather than a run with nothing wrong " \
             "in it."
    end

    "#{slowest_examples_outcome_scope(slowest_examples, examples)}: " \
      "#{slowest_examples_outcome_breakdown(slowest_examples)}." \
      "#{slowest_examples_unreported_clause(slowest_examples)}"
  end

  # == The opened spec file's basis sentence

  # What the drill-down list under a single spec file IS — how much of the file it shows, and
  # whether it is ordered by anything.
  #
  # Two axes, and the four sentences they make are written out rather than assembled from clauses,
  # because three of the four are wrong in a way only the fourth's wording hides.
  #
  # TRUNCATION is the axis every capped list on this page discloses: the cap is
  # `SpecObservation::FILE_EXAMPLES_LIMIT` and a reader cannot see it, so a list whose length
  # happens to equal it reads as the whole file. It is stated whether or not anything was cut, for
  # the reason `SpecFileDurations#truncated?` gives one grain up — "all 12 examples" and "the 50
  # heaviest of 340" are the two facts, and a bare list is neither.
  #
  # ORDER is the axis that is new here. Every sibling list on this page EXCLUDES untimed rows, so
  # "slowest first" is unconditionally true of them; this one lists them, because a file's untimed
  # examples are part of that file's population and hiding them would leave the list disagreeing
  # with the `recorded_count` printed beside it. On a file that reported no timing at all there is
  # therefore a list and no ranking — every row ties — and "slowest first" over it would be
  # promising an order nothing measured. It says "in the order this run recorded them" instead,
  # which is what `id` ascending actually gives.
  #
  # The truncated-and-unranked sentence is the one this exists for: "the 50 slowest of 340" is
  # false on a file nothing timed, and it is the sentence a reader is most likely to act on.
  #
  # The two axes are not independent where they MEET, which is why there are five sentences and not
  # four. A truncated file that timed SOME of its examples runs the timed rows out before the cap
  # does, and the page then ends in untimed rows: on 340 examples of which 40 are timed, the list
  # is 40 ranked rows followed by 10 of 300 that nothing ranked. "The 50 slowest" is false of that
  # page twice over — those last ten are not the slowest of anything, and the 290 untimed rows it
  # does not mention are not on the page at all. `#lists_untimed?` is that meeting, and it gets its
  # own sentence naming both populations and what was cut from each.
  def spec_file_examples_scope_sentence(examples)
    recorded = number_with_delimiter(examples.recorded_count)
    shown = number_with_delimiter(examples.rows.size)
    # With `?layer=` asked every figure is that declared layer's, so the noun says so: "request-layer
    # examples". Unasked it is the plain "example" and the sentences are byte-identical to before.
    noun = spec_file_examples_noun(examples)
    plural = noun.pluralize(examples.recorded_count)

    if examples.any_timed?
      return "All #{recorded} #{plural} this run recorded in it, slowest first." unless examples.truncated?
      return spec_file_examples_mixed_tail_sentence(examples) if examples.lists_untimed?

      "The #{shown} slowest of the #{recorded} #{noun.pluralize(2)} this run recorded in it, slowest first."
    elsif examples.truncated?
      "The first #{shown} of the #{recorded} #{noun.pluralize(2)} this run recorded in it, in the order this " \
        "run recorded them — nothing here was timed, so there is no order to rank them in."
    else
      "All #{recorded} #{plural} this run recorded in it, in the order this run recorded them — " \
        "nothing here was timed, so there is no order to rank them in."
    end
  end

  # "example", or "request-layer example" when the opened file was narrowed to a declared layer.
  def spec_file_examples_noun(examples)
    examples.layer? ? "#{examples.layer}-layer example" : "example"
  end

  # == The opened repeated description's basis sentence

  # What the drill-down list under a single repeated description IS — how much of the group it
  # shows, and whether it is ordered by anything.
  #
  # The same two axes, in the same five sentences, as `#spec_file_examples_scope_sentence` above,
  # and deliberately its own method rather than a widening of that one with a noun argument.
  #
  # The two are not the same claim wearing different words. That one says "in it", where "it" is a
  # FILE and the phrase "this run recorded in it" is what makes the denominator a file's population;
  # this says "under this description", where the population is the rows of one run that share a
  # sentence and may sit in any number of files. Parameterising the noun would make one sentence
  # stand for two claims about two different populations, which is the thing every `_LIMIT` constant
  # in `SpecObservation` is kept separate to prevent — and it would put the wording of both panels
  # behind a single edit nobody meant to make at either.
  #
  # The ORDER axis is louder here than one rung over, and it is why the unranked sentences are worth
  # writing out. A file that timed nothing is an unusual file; a repeated description that timed
  # nothing is an ORDINARY group — the ranking above sorts exactly such groups to the end of itself
  # and says so — so the reader who opened one is meeting the unranked list as a normal state rather
  # than an edge of one. "Slowest first" over it would promise an order nothing measured.
  #
  # Nothing here uses the word "duplicate", by the rule the panel this drills out of states: a shared
  # description is equally a table-driven loop, a shared example group, or the same test written
  # twice, and a sentence describing the list must not decide which.
  def repeated_description_examples_scope_sentence(examples)
    recorded = number_with_delimiter(examples.recorded_count)
    shown = number_with_delimiter(examples.rows.size)
    plural = "example".pluralize(examples.recorded_count)

    if examples.any_timed?
      return "All #{recorded} #{plural} this run recorded under it, slowest first." unless examples.truncated?
      return repeated_description_examples_mixed_tail_sentence(examples) if examples.lists_untimed?

      "The #{shown} slowest of the #{recorded} examples this run recorded under it, slowest first."
    elsif examples.truncated?
      "The first #{shown} of the #{recorded} examples this run recorded under it, in the order this " \
        "run recorded them — nothing here was timed, so there is no order to rank them in."
    else
      "All #{recorded} #{plural} this run recorded under it, in the order this run recorded them — " \
        "nothing here was timed, so there is no order to rank them in."
    end
  end
  private

  # The truncated file whose timed rows ran out before the cap did — a ranked head and an unranked
  # tail on one page, and the only shape here where the list shows part of BOTH populations.
  #
  # It counts each population separately because one figure cannot describe both: the timed rows
  # are ranked and complete (a listed untimed row means the cap never reached the timed ones), the
  # untimed rows are a sample of a population nothing ordered, and the remainder is the part of the
  # file this page does not have. Said as one number — "the 50 slowest" — every one of those three
  # facts is lost and the first is stated backwards.
  def spec_file_examples_mixed_tail_sentence(examples)
    "The #{number_with_delimiter(examples.shown_timed_count)} timed #{spec_file_examples_noun(examples).pluralize(2)} of the " \
      "#{number_with_delimiter(examples.recorded_count)} this run recorded in it, slowest first, " \
      "then #{number_with_delimiter(examples.shown_untimed_count)} of the " \
      "#{number_with_delimiter(examples.untimed_count)} that reported no duration and nothing " \
      "ranked — the remaining #{number_with_delimiter(examples.untimed_omitted_count)} are not " \
      "shown."
  end

  # The same meeting of the two axes for the repeated-description drill-down, and its own sentence
  # for the reason its caller is its own method: "in it" names a file's population and "under it"
  # names a description's, and one string standing for both would make that a single edit nobody
  # meant to make at either panel.
  def repeated_description_examples_mixed_tail_sentence(examples)
    "The #{number_with_delimiter(examples.shown_timed_count)} timed examples of the " \
      "#{number_with_delimiter(examples.recorded_count)} this run recorded under it, slowest " \
      "first, then #{number_with_delimiter(examples.shown_untimed_count)} of the " \
      "#{number_with_delimiter(examples.untimed_count)} that reported no duration and nothing " \
      "ranked — the remaining #{number_with_delimiter(examples.untimed_omitted_count)} are not " \
      "shown."
  end

  # How much of the run the breakdown after it covers. Worded "Every one of the …" when it covers
  # all of them, matching the timing sentence directly above it on the page rather than inventing a
  # second way to say the same shape of thing.
  def slowest_examples_outcome_scope(slowest_examples, examples)
    reported = slowest_examples.reported_outcome_count
    return "Every one of the #{examples} reported an outcome" if reported == slowest_examples.recorded_count

    "#{number_with_delimiter(reported)} of the #{examples} reported an outcome"
  end

  # The two counted names, plus the remainder when there is one.
  #
  # The zeroes here are honest zeroes and are printed: they sit behind `#outcomes_reported?`, so
  # "0 failed" is only ever reached on a run that DID report outcomes and reported no failures
  # among them. The remainder clause is omitted entirely when it is zero, because "0 reported
  # something other than either" is a sentence about arithmetic rather than about this run.
  def slowest_examples_outcome_breakdown(slowest_examples)
    counted = ["#{number_with_delimiter(slowest_examples.failed_count)} failed",
               "#{number_with_delimiter(slowest_examples.pending_count)} pending"]

    other = slowest_examples.other_outcome_count
    return counted.to_sentence unless other.positive?

    counted << "#{number_with_delimiter(other)} reported something other than either — not read " \
               "as a pass, since nothing validates what CI sends here"
    counted.to_sentence
  end

  # The rows that said nothing, on a run where some rows did. Silence inside a population that
  # reported is not covered by the counts before it, and leaving it to be reached by subtraction is
  # how a reader concludes a failure count was taken over more rows than it was.
  def slowest_examples_unreported_clause(slowest_examples)
    unreported = slowest_examples.unreported_outcome_count
    return "" unless unreported.positive?

    " The other #{number_with_delimiter(unreported)} reported none."
  end
end
