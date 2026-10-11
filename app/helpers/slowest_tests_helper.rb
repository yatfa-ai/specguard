# frozen_string_literal: true

# The sentences of the "Slowest tests across the window" panel on repositories#show. Lifted out of
# RepositoriesHelper, which had grown past what one file can be read as; the methods are
# unchanged. `window_branch_clause` stays in RepositoriesHelper (shared with other panels) and is
# reached here by implicit receiver, since every helper is mixed into the one view class.
module SlowestTestsHelper
  # == The "Slowest tests across the window" panel's sentences
  #
  # The repository-grain sibling of the per-run "Slowest tests" panel's caption, and it has one
  # sentence that panel structurally cannot write: a matching rule. One run's ranking matches
  # nothing, so it has nothing to disclose about how two rows became one test; this one groups on
  # `spec_identity_id` and every row here may be a history assembled across a move and a reword.

  # What the list IS, over what window, ordered on what — before anything else, because a ranked
  # list whose ordering is unstated is read as "the worst of everything" and this one is neither.
  #
  # The ORDERING is named rather than assumed. Every other duration panel on this page ranks one
  # run, where "slowest" has exactly one meaning; here there are two, the window total and the
  # single worst run, both are rendered side by side in the table below, and only one of them
  # decided the order. A reader scanning the "Slowest single run" column down a list ordered on the
  # other one needs to have been told.
  #
  # And the superlative is WITHDRAWN in the one state where it is false. Under the cap this list is
  # not the window's most expensive tests — it is the anchor run's slowest, re-totalled over the
  # window — so a lead reading "The 10 tests that cost this suite the most" would be a claim the
  # truncation clause then takes back two sentences later. A partitive ("10 of the tests that…")
  # says the same thing about the same rows without ever asserting the closure the cap denies.
  def slowest_tests_window_sentence(slowest)
    tests = "#{number_with_delimiter(slowest.rows.size)} #{"test".pluralize(slowest.rows.size)}"
    runs = "#{number_with_delimiter(slowest.run_count)} #{"run".pluralize(slowest.run_count)}"
    opening = if slowest.truncated?
                "#{number_with_delimiter(slowest.rows.size)} of the tests"
              else
                "The #{tests}"
              end

    "#{opening} that cost this suite the most wall clock across the last " \
      "#{runs}#{window_branch_clause(slowest)}, ordered on that window TOTAL — not on any single " \
      "run of it.#{slowest_tests_layer_clause(slowest)}"
  end

  # With `?layer=` asked (SPGD-1726) the ranking is narrowed at its CANDIDATE step: the tests listed
  # are those with at least one example in the newest run that declared the layer. Each row's totals
  # are still the whole test's across the window, which is why a row's declared layers can list more
  # than the one asked for. Empty string unasked, so the unasked sentence is unchanged.
  def slowest_tests_layer_clause(slowest)
    return "" unless slowest.layer?

    " Narrowed to the #{slowest.layer} layer: only tests with at least one #{slowest.layer}-layer " \
      "example in that newest run are candidates, and each row still totals the whole test across " \
      "the window."
  end

  # The layer-narrowed ranking's empty state: the newest run holds resolved tests, none of which has
  # an example declaring this layer. A fact about what was declared, NOT "nothing here is slow".
  def slowest_tests_empty_layer_description(slowest)
    "#{slowest.anchor_run.commit_sha.first(7)}, the newest run in this window, has no example that " \
      "declares the #{slowest.layer} layer, so there is no #{slowest.layer}-layer test to rank across " \
      "the window. That says nothing about whether this suite is slow: tests are narrowed by the " \
      "layer their own @intent declared, never inferred from the spec path."
  end

  # The matching rule, on the panel rather than in the code, for the reason the sibling panel above
  # states its own: it is the one thing here that is a DECISION rather than a measurement, and its
  # consequences are ones a reader can only check against their own repository if they are told it.
  #
  # And the rule here is the OPPOSITE of its neighbour's. `UnstableTestsHelper#unstable_tests_matching_sentence` — the
  # "Tests whose outcome changed" panel further up the page — matches on the description alone and
  # says so: a moved test keeps its history there and a renamed one starts a new one. This panel
  # matches on the durable identity, so BOTH survive, and a reader carrying the other panel's rule
  # down the page would misread every row that discloses a move or a reword below. Two panels on
  # one page with two different matching rules is exactly the drift a shared sentence would hide,
  # so each states its own.
  def slowest_tests_matching_sentence
    "Tests are matched across those runs by the durable identity SpecGuard resolved for them — " \
      "not by file, not by line and not by description, since all three move under a test that " \
      "did not change. So a test that MOVED keeps its history here, and so does one that was " \
      "reworded; where either happened, the row below says so."
  end

  # ⭐ The partition, named. WHICH tests are on this list was decided by one run — the newest in the
  # window — and the window then supplied their history, so a test deleted halfway through is
  # absent however slow it was while it lived.
  #
  # It cannot be recovered from the rows: nothing in a list of ten tests tells a reader which
  # eleventh is missing, and "the slowest tests in this repository" is precisely the reading this
  # sentence exists to narrow. The run is NAMED rather than described, so a reader who thinks a
  # test should be here can go and look at the run that decided it was not.
  def slowest_tests_anchor_sentence(slowest)
    "Which tests are ranked was decided by #{slowest.anchor_run.commit_sha.first(7)}, the newest " \
      "run in this window: a test that run did not report is not in the suite being asked about " \
      "and is not here, however long it took while it existed."
  end

  # How much of the ranked population carried a timing — the same three-state sentence the per-run
  # panel writes one grain down, over this panel's own denominator.
  #
  # The denominator is the anchor's RESOLVED rows and never its recorded ones, because the rows it
  # could not identify are a separate exclusion with a separate sentence (`#slowest_tests_
  # exclusion_sentence`), and folding the two together would report a timing gap for rows that were
  # dropped before timing was ever asked about. `SlowestTests#coverage_label` holds that pairing so
  # this sentence cannot state a fraction whose halves came from two different populations.
  def slowest_tests_coverage_sentence(slowest)
    # Under `?layer=` every figure is the LAYER's (numerator and denominator both), so the
    # population is named as such rather than as the whole run's.
    scope = slowest.layer? ? "#{slowest.layer}-layer " : ""

    if slowest.complete?
      return "Every one of the #{number_with_delimiter(slowest.resolved_count)} " \
             "#{scope}#{"row".pluralize(slowest.resolved_count)} that run resolved to a durable test " \
             "reported a duration, so the ranking covers the whole of what it identified."
    end

    "Ranked over the #{slowest.coverage_label} #{scope}rows that run resolved to a durable test that " \
      "reported a duration; #{number_with_delimiter(slowest.untimed_count)} reported none. A test " \
      "that never ran has no duration to report, so a missing timing is a faithful record rather " \
      "than a gap — and it is why a row here can read \"not reported\" instead of 0.00s."
  end

  # The two silences: rows the anchor wrote that could not be identified, and candidates the cap
  # never examined. Both are facts about the population the ranking was drawn from rather than notes
  # about it, and both are rendered only where they are TRUE of this window — a clause reading "0
  # rows carried no durable identity" is a sentence about arithmetic.
  def slowest_tests_exclusion_sentence(slowest)
    [slowest_tests_unresolved_clause(slowest), slowest_tests_truncation_clause(slowest)]
      .compact.join(" ").presence
  end

  # ⭐ Why an empty ranking is not "nothing in this suite is slow" — the panel's *Vacuous Green*
  # refusal, and the state a reader meets for the seconds after every single ingest.
  #
  # `Ingest::IdentityResolutionJob` runs out of band, so the newest run's rows land identified by
  # nothing at all and are matched to durable tests a moment later. Rendered as an empty list that
  # is "nobody has told us yet" wearing the spelling of "everything is fast", and the two are
  # indistinguishable in every other way — which is the whole reason `SlowestTests` separates
  # `#recorded?` from `#resolved?` rather than serving one `#any?`.
  #
  # The row count is stated because it is what makes the sentence checkable: a reader told that
  # 4,900 rows are waiting can see that their run arrived and that only the matching is outstanding.
  def slowest_tests_unresolved_description(slowest)
    rows = "#{number_with_delimiter(slowest.recorded_count)} " \
           "#{"row".pluralize(slowest.recorded_count)}"

    "#{slowest.anchor_run.commit_sha.first(7)}, the newest run in this window, recorded #{rows} " \
      "and not one of them has been matched to a durable test yet. That matching runs just after a " \
      "run lands rather than during it, so this is the ordinary state for the moments after an " \
      "ingest and it clears on its own. It is reported as what it is: no ranking has been made " \
      "here, which is a different fact from a suite in which nothing is slow."
  end

  private

  # Rows the anchor run wrote that the ranking could not attribute to any test, counted and stated.
  # A row with no durable identity is precisely a row this panel cannot say WHICH test it belongs
  # to, so it cannot be summed into one and cannot be listed as one — and excluding it silently
  # would make the list a claim about the run made from part of it, with nothing saying which part.
  #
  # Counted in ROWS, deliberately, and worded that way, for `UnstableTestsHelper#unstable_tests_unnamed_clause`'s
  # reason at its own grain: reporting a number of "tests" for rows whose test is unknown would be
  # the identity claim the exclusion exists to decline.
  #
  # This clause and the `:unresolved` state above are the same fact at two sizes — some of the
  # anchor's rows unmatched, or all of them — which is why the wording of both names the matching
  # rather than the row.
  def slowest_tests_unresolved_clause(slowest)
    return nil unless slowest.excluded_unresolved_rows?

    count = slowest.unresolved_count
    "#{number_with_delimiter(count)} #{"row".pluralize(count)} that run recorded " \
      "#{count == 1 ? "has" : "have"} not been matched to a durable test yet and " \
      "#{count == 1 ? "is" : "are"} not in this ranking; that matching runs just after a run " \
      "lands rather than during it."
  end

  # ⭐ The cap, disclosed only where it bit — and disclosed as TWO facts rather than one, because
  # this panel narrows on one ordering and then ranks on another.
  #
  # The sibling clause one panel up (`UnstableTestsHelper#unstable_tests_truncation_clause`) has only the first half to
  # state: which end of the candidate list survived. Here the cap is applied on each test's duration
  # in the ANCHOR RUN and the surviving list is then ordered on its WINDOW TOTAL, so the two
  # orderings are different and a test can be excluded by one while it would have led the other — a
  # test that is cheap today and has a long expensive history is exactly that shape. That is
  # inherent to narrowing before aggregating, which is what makes the whole read affordable
  # (`SlowestTests` carries the arithmetic), and it is a fact about the list a reader cannot recover
  # from any row of it.
  #
  # ⚠️ It counts DURABLE TESTS THE ANCHOR RESOLVED, and says so, rather than reaching for "tests
  # that ran". `#candidate_count` comes off `.slowest_identity_candidates_in`, which is
  # `where.not(spec_identity_id: nil).group(:spec_identity_id)` — it cannot see the unresolved rows
  # AT ALL, and those are exactly what `#slowest_tests_unresolved_clause` declines to call tests one
  # clause earlier in the same paragraph. Where an anchor is both truncated and partly unresolved
  # the two clauses render side by side, so a figure that quietly folded the unmatched rows back in
  # would contradict its own neighbour by the width of them. `SlowestTests#recorded_count` draws
  # that line in as many words, and `UnstableTestsHelper#unstable_tests_truncation_clause` keeps it the same way by
  # naming its grouping key and its predicate instead of the word "tests".
  def slowest_tests_truncation_clause(slowest)
    return nil unless slowest.truncated?

    unexamined = slowest.unexamined_count

    scope = slowest.layer? ? "#{slowest.layer}-layer " : ""
    "#{number_with_delimiter(slowest.candidate_count)} #{scope}durable tests that run resolved — more " \
      "than this panel ranks at once — so the #{number_with_delimiter(slowest.rows.size)} " \
      "slowest OF THOSE were the ones whose window history was summed, and the other " \
      "#{number_with_delimiter(unexamined)} #{unexamined == 1 ? "is" : "are"} not represented " \
      "above. The cap is applied on that run's durations and the list is then ordered on the " \
      "window total, so a test that is cheap today and was expensive across the window falls " \
      "through it."
  end
end
