# frozen_string_literal: true

# The sentences of the two unstable-test panels on repositories#show — the "Tests whose outcome
# changed" panel and the opened unstable test's run-by-run drill-down. Lifted out of
# RepositoriesHelper, which had grown past what one file can be read as; the methods are
# unchanged. `window_branch_clause` stays in RepositoriesHelper (shared with other panels) and is
# reached here by implicit receiver, since every helper is mixed into the one view class.
module UnstableTestsHelper
  # == The "Tests whose outcome changed" panel's sentences

  # What window every figure on the panel was drawn from — how many runs, on which branch, and how
  # many of them said anything at all about how their examples ended.
  #
  # The third figure is the one that cannot be left out. `outcome` is nullable, so a run of nils is
  # an ordinary state, and a window's LENGTH says nothing about how much of it reported. "Across
  # the last 30 runs on main" over a window where three of them reported outcomes is a claim about
  # thirty runs made from three, and every count under it inherits the overstatement.
  #
  # Reported in RUNS throughout, never in rows: the comparison this panel makes is between runs, so
  # its denominator has to be one a reader can put the row counts beside.
  def unstable_tests_window_sentence(unstable)
    runs = "#{number_with_delimiter(unstable.run_count)} #{"run".pluralize(unstable.run_count)}"
    reported =
      if unstable.runs_reporting_outcomes == unstable.run_count
        "every one of which reported an outcome for at least one example"
      else
        "#{number_with_delimiter(unstable.runs_reporting_outcomes)} of which reported an outcome " \
          "for any example"
      end

    "Across the last #{runs}#{window_branch_clause(unstable)}, #{reported}." \
      "#{unstable_tests_silent_runs_clause(unstable)}"
  end

  # The matching rule, said on the panel rather than left in the code — because it is a rule a
  # reader has to know to read the list at all, and because it is the one thing here that is a
  # DECISION rather than a measurement. A test that moved keeps its history; a renamed one starts a
  # new history and its old one stops at the rename. Both are consequences a reader can only check
  # against their own repository if they are told the rule.
  def unstable_tests_matching_sentence
    "Tests are matched across those runs by their durable identity, not by file and not by line, " \
      "since both move under a test that did not change. So a test that moved keeps its history " \
      "here, and a test whose wording changed while its annotation held keeps its history too — " \
      "an unannotated test is identified by its description, so a reworded unannotated test " \
      "starts a new one."
  end

  # Where the panel stops looking, stated as a boundary rather than implied by an absence.
  #
  # The search begins at the runs' failures, which is what makes it affordable at the design point
  # (see `SpecObservation.unstable_identity_candidates_in`). The cost of that narrowing is real and specific:
  # a test that alternated `pending` and `passed` and never failed varied its outcome and is not
  # reported. A reader who is not told that reads this list as "every test whose outcome varied".
  def unstable_tests_boundary_sentence
    "The search starts from what failed, so a test that alternated between other outcomes — " \
      "pending in one run, passed in the next — without ever failing is outcome variance this " \
      "panel does not report."
  end

  # What the window held that the matching could not use, and what the narrowing did not reach.
  # All are silences, and a silence a reader cannot see is the one thing a panel counted off a
  # partial population must not leave them to discover.
  def unstable_tests_exclusion_sentence(unstable)
    [unstable_tests_unnamed_clause(unstable), unstable_tests_unresolved_clause(unstable),
     unstable_tests_truncation_clause(unstable)].compact.join(" ").presence
  end

  # Why there is no list and no zero: fewer than two runs of the window reported an outcome, so
  # there is no comparison to make and nothing this panel could print that would not be a figure
  # about silence.
  #
  # This is the panel's *Vacuous Green* refusal, and the description says which of the two states a
  # reader is looking at, because they are indistinguishable in every other way. A window whose
  # runs all passed and a window whose client sends no outcomes both produce an empty list; only
  # this sentence separates "we compared and found nothing" from "there was nothing to compare".
  #
  # The gate is `runs_reporting_outcomes >= 2`, so it is false in TWO states, and they have
  # different causes and different remedies. Silence is one of them; the other is a window that
  # reported perfectly well and holds exactly one run to have reported it. Both the leading clause
  # AND the explanation behind it are therefore per-state: "said nothing" is a claim about THIS
  # window, and asserting it over a window that did say something is the mirror of the Vacuous
  # Green hazard this method exists to refuse — a report read as silence, sending a reader to check
  # their formatter config when what they need is a second run. The two branches are worded so that
  # each names the thing its own reader has to change.
  def unstable_tests_incomparable_description(unstable)
    reported, cause =
      if unstable.runs_reporting_outcomes.zero?
        ["not one of them said how any example ended",
         "What CI reports here is optional and nothing validates it, so a window that said " \
           "nothing and a window with nothing wrong in it produce the same empty list. This one " \
           "said nothing, and no count is printed over it."]
      else
        ["one of them said how an example ended",
         "That report is real — it is simply the only one here, and an outcome needs an earlier " \
           "outcome to have changed from. A second run that reports is what this window is short " \
           "of, and no count is printed over it."]
      end

    "Comparing outcomes takes at least two runs that reported them — one run's outcome cannot have " \
      "changed from anything. Of the #{number_with_delimiter(unstable.run_count)} " \
      "#{"run".pluralize(unstable.run_count)}#{window_branch_clause(unstable)}, " \
      "#{reported}. #{cause}"
  end

  # The honest zero — reachable only behind `#comparable?`, and worded against the runs it was
  # actually drawn from rather than against the length of the window.
  #
  # Three different zeroes, said differently, because they are three different facts about a
  # repository: nothing failed at all, things failed but always failed, and something DID vary but
  # under a description this panel cannot attribute to one example. Collapsing the first two would
  # tell a reader with a permanently red test that their suite is stable. Collapsing the third
  # would be worse than imprecise — "not one of them reported any other outcome" is FALSE over a
  # window whose shared-description group reported two, and it would sit directly above the section
  # saying so.
  #
  # Every one of them is also worded against the descriptions it was drawn from, and not only
  # against the runs. A zero is a UNIVERSAL — "no description varied", "not one of them reported
  # any other outcome" — and when the candidate cap bit, the population it quantifies over is the
  # part of the window this panel examined rather than the window. Left unqualified it asserts a
  # property of descriptions that were never read, inches under the clause disclosing that they
  # were not read (`#unstable_tests_truncation_clause`). That is the same defect the shared-
  # description branch exists to refuse, one silence over: a caption is a claim about the list it
  # was counted off, so when the list is part of the candidates the caption says which part.
  def unstable_tests_none_description(unstable)
    reporting = "#{number_with_delimiter(unstable.runs_reporting_outcomes)} " \
                "#{"run".pluralize(unstable.runs_reporting_outcomes)}" \
                "#{window_branch_clause(unstable)} that reported outcomes"

    if unstable.shared_description_rows.any?
      "No description belonging to a single example changed its outcome " \
        "#{unstable_tests_examined_scope(unstable, reporting)}. What did vary, varied under a " \
        "description more than one example answers to, which is reported below rather than " \
        "counted here.#{unstable_tests_unexamined_caveat(unstable)}"
    elsif unstable.candidate_count.zero?
      # Unreachable under truncation by construction: the cap can only have bitten a window in
      # which something failed, so there is no unexamined population to qualify this one against.
      "No example failed in any of the #{reporting}, so there is nothing here whose outcome could " \
        "have changed. That is a comparison this window supported and it came back empty."
    elsif unstable.truncated?
      "#{number_with_delimiter(unstable.examined_count)} of the " \
        "#{number_with_delimiter(unstable.candidate_count)} descriptions that failed somewhere in " \
        "the #{reporting} were the ones compared across runs, and not one of those reported any " \
        "other outcome anywhere in them. Tests that fail consistently are not what this panel is " \
        "looking for.#{unstable_tests_unexamined_caveat(unstable)}"
    else
      "#{number_with_delimiter(unstable.candidate_count)} " \
        "#{"description".pluralize(unstable.candidate_count)} failed somewhere in the " \
        "#{reporting}, and not one of them reported any other outcome anywhere in them. Tests that " \
        "fail consistently are not what this panel is looking for."
    end
  end

  # The population a zero on this panel quantifies over. "Across the window" is only true when
  # every description that failed in it was compared; when the cap bit it is true of the examined
  # part alone, and the phrase says which part rather than letting the reader supply the wrong one.
  def unstable_tests_examined_scope(unstable, reporting)
    return "across the #{reporting}" unless unstable.truncated?

    "among the #{number_with_delimiter(unstable.examined_count)} of " \
      "#{number_with_delimiter(unstable.candidate_count)} failing descriptions this panel compared " \
      "across the #{reporting}"
  end

  # What a zero above a capped candidate list does NOT establish, said in the same breath as the
  # zero. `#unstable_tests_truncation_clause` discloses the cap against the LIST — "not represented
  # above" — which is a statement about rows that were printed; this one is about a claim, and the
  # claim is the thing a reader would otherwise carry away as clean.
  def unstable_tests_unexamined_caveat(unstable)
    return "" unless unstable.truncated?

    # `unexamined_count == 1` is one description past the cap, not a contrived state — the count is
    # the pre-LIMIT total, so a window with `UNSTABLE_CANDIDATE_LIMIT + 1` failing descriptions
    # lands here. Verb and pronoun agree with the noun, as at `#unstable_tests_shared_description_
    # sentence` and the trajectory captions above.
    one = unstable.unexamined_count == 1

    " The other #{number_with_delimiter(unstable.unexamined_count)} " \
      "#{"description".pluralize(unstable.unexamined_count)} that failed in this window " \
      "#{one ? "was" : "were"} never compared across runs, so nothing here is a finding about " \
      "#{one ? "it" : "them"}."
  end

  # The groups the matching rule could not rule on, said as what they are. Not flakiness and not
  # dropped: a description carried by two examples in one run holds that run's `failed` and its
  # `passed` at the same time, and either reading — listing it above, or omitting it — asserts
  # something nothing here established.
  def unstable_tests_shared_description_sentence(unstable)
    count = unstable.shared_description_rows.size

    "#{number_with_delimiter(count)} #{"description".pluralize(count)} varied in outcome across " \
      "this window AND #{count == 1 ? "was" : "were"} carried by more than one example in at least " \
      "one run of it. A description is not a key within a single run — a table-driven loop, or two " \
      "examples simply given the same words, put several under one — so what varied may be which " \
      "of those examples was which rather than a test that changed. Listed here rather than " \
      "counted above, because calling them flaky would be a false positive manufactured by the " \
      "matching rule."
  end

  # == The opened unstable test's sentences

  # DID THE CAP BITE — asked once here and never recomputed, because three sentences on this panel
  # branch on it and the failure mode of the panel is those sentences DISAGREEING inside one
  # paragraph. The scope sentence says "the 200 oldest of the 250 rows", the alert above the table
  # says the newest rows are missing, and the reading rule says which readings survive that; two of
  # those spelling the comparison out by hand is two places for one of them to keep the old
  # unconditional wording after the other is fixed. That is not hypothetical — it is exactly how
  # this panel shipped the first time, with a scope sentence that disclosed the truncation and a
  # reading rule two clauses later that contradicted it.
  #
  # `recorded_count` is counted over the WINDOW and before the cap, and `rows` is what survived it,
  # so their difference is the number of rows the cap dropped and nothing else. Neither is a count
  # of runs, and this predicate deliberately says nothing about runs: whether whole RUNS fell off
  # depends on how many rows each run carries, and the surface's claims are worded so they do not
  # need to know.
  def unstable_test_runs_capped?(sequence) = sequence.recorded_count > sequence.rows.size

  # What the sequence IS — how much of this description's history the window holds, and how much of
  # THAT is on the page.
  #
  # Its own method rather than a widening of `#spec_file_examples_scope_sentence` or
  # `#repeated_description_examples_scope_sentence`, for the reason the second of those states about
  # the first: those two count a RUN's examples and this counts a WINDOW's rows, so parameterising a
  # noun would make one sentence stand for claims about two populations that are free to diverge.
  #
  # Counted in ROWS and never in runs, and that is the sentence's one hard rule. One row per run is
  # what the data usually is rather than a promise this list makes, and it comes apart in BOTH
  # directions: a run that recorded nothing under this description contributes no row — a test added
  # halfway through a window of thirty has fifteen — and a description carried by more than one
  # example in a run contributes one row per example. So `rows.length` is neither the window's length
  # nor bounded below by it, and a sentence saying "12 of the last 30 runs" off this list would be
  # reporting a coverage nobody counted. The window's own length is stated beside the count as what
  # it is: the span these rows were drawn from, not their denominator.
  #
  # The cap is disclosed only when it BIT, and whether it bit is asked of
  # `#unstable_test_runs_capped?` rather than recomputed here — see that predicate for why the
  # comparison is written down once. The object is not asked: `UnstableTestRuns` serves
  # `recorded_count` as an operand — counted before the cap — and no `truncated?` predicate, on the
  # standing rule that this ladder serves operands and the surface states the reading.
  #
  # WHICH END the cap keeps is a property of the WINDOW and not of the read, and this sentence is
  # the only place that difference is visible. `SpecObservation.outcome_sequence_in` orders by
  # `array_position` over the run ids it was handed, so the rows come back in the order of the
  # window itself — and this page's window (`Repository#suite_size_trajectory`) is OLDEST FIRST,
  # because it is the window the "Suite growth" chart above is plotted along. So the cap keeps the
  # OLDEST rows here, where the same method under `GET /api/v1/repository` keeps the newest ones off
  # a newest-first window. Reading the direction off the object would be reading it off a promise
  # nothing makes; it is stated here, for this window, in this caller's words.
  def unstable_test_runs_scope_sentence(sequence)
    recorded = number_with_delimiter(sequence.recorded_count)
    shown = number_with_delimiter(sequence.rows.size)
    plural = "row".pluralize(sequence.recorded_count)
    runs = "#{number_with_delimiter(sequence.run_count)} #{"run".pluralize(sequence.run_count)}"

    if unstable_test_runs_capped?(sequence)
      "The #{shown} oldest of the #{recorded} #{plural} the last #{runs} of this window recorded " \
        "under it, in the window's own order — oldest run first, the direction the “Suite growth” " \
        "chart above is plotted in."
    else
      "All #{recorded} #{plural} the last #{runs} of this window recorded under it, in the " \
        "window's own order — oldest run first, the direction the “Suite growth” chart above is " \
        "plotted in."
    end
  end

  # HOW TO READ THE COLUMN, said on the panel because it is the entire reason the panel exists.
  #
  # The ranking above cannot make this distinction and is right not to try: its row says `30 runs,
  # 4 failed, [failed, passed]`, and those three figures are IDENTICAL for two windows that call for
  # opposite work. Four failures at the newest four runs is a regression with a commit to find; four
  # failures scattered through thirty is flakiness with none. A reader who has the sequence but not
  # the rule reads a shape and guesses, and the guess that costs most is hunting nondeterminism in a
  # test that fails deterministically on code that changed.
  #
  # Worded by POSITION IN THIS LIST rather than by "recent" or "latest", because the two are not the
  # same word here: this window runs oldest first, so the newest run is the LAST row and a sentence
  # about "the failures at the top" would point a reader at the opposite end of the evidence from
  # the one it means. The scope sentence beside it states the direction; this one names the end.
  #
  # == Why this is CONDITIONED on the cap and not static
  #
  # It was static once, on the argument that it is "a rule for reading the list rather than a claim
  # about this one, so it has nothing to drift from". That argument was wrong on its own premise.
  # "Failures bunched at the END of this list — ITS NEWEST RUNS" is a claim about this list: it
  # asserts that the end of the rendered rows is the newest end of the window. On a newest-first
  # window that would hold whatever the cap did, but this window is OLDEST FIRST, so the `LIMIT`
  # sheds the NEWEST rows — and the moment it bites, the sentence is false in the one direction the
  # panel cannot survive being false in.
  #
  # The geometry is ordinary rather than exotic. Truncation needs more than 200 rows over at most 30
  # runs, i.e. more than ~6.7 rows per run — one description carried by ten examples in a run is a
  # table-driven loop. At 25 runs × 10 rows the newest FIVE RUNS are not on the page at all, so a
  # test that started failing at run 21 renders as 200 consecutive passes under a rule instructing
  # the reader that failures at the end mean regression and no failures scattered means no
  # flakiness. Neither branch applies, nothing on the page says the answer is missing rather than
  # negative, and the available conclusions are "this test is fine" or "this panel is broken". Both
  # are the wrong-culprit-commit failure `UnstableTestRuns`' "window is HANDED IN" section calls the
  # one error this drill-in cannot survive, reached from the other side.
  #
  # So the regression branch is WITHHELD when the cap bit, rather than reworded. The flakiness
  # branch survives untouched and is stated: scattered failures among the rows that ARE here are
  # still scattered failures. What cannot be done is read a regression off an end that is not the
  # end — and, just as importantly, read the ABSENCE of failures there as health, which is the
  # reading a reader falls into by default and the one that lets a live regression off the page.
  #
  # Both branches are counted off `#unstable_test_runs_capped?`, the same predicate the scope
  # sentence and the alert use, so the three cannot disagree about whether the cap bit.
  def unstable_test_runs_reading_sentence(sequence)
    return unstable_test_runs_capped_reading_sentence if unstable_test_runs_capped?(sequence)

    "Read down the sequence rather than across the counts. Failures bunched at the END of this " \
      "list — its newest runs — are a regression, and the commit to look at is the one on the " \
      "first failing row after the last row that passed; failures scattered through the list are " \
      "flakiness, where there is no culprit commit to find and the work is quarantine or shared " \
      "state."
  end

  # The reading rule with the regression branch withheld, for a list the cap stopped short of the
  # window's newest rows. Its own method rather than a second string inside the branch above, so the
  # two readings are side by side in the file where a later edit to one is read against the other.
  #
  # It states what is NOT available before what is, which is the opposite of the usual ordering and
  # deliberate: the failure mode here is a reader applying the regression rule to a truncated end,
  # so the withdrawal has to arrive before the rule that survives it. And it names the absence of
  # failures explicitly, because "no failures at the end" is not a neutral observation on a list
  # whose end was cut off — it is the reading that turns a missing answer into a clean bill of
  # health.
  def unstable_test_runs_capped_reading_sentence
    "Read down the sequence rather than across the counts — but not off the end of it here. The " \
      "regression reading is taken off the window's newest runs, and the newest rows are the ones " \
      "the cap dropped, so the end of this list is not the end of this window's evidence: " \
      "failures sitting there need not be where the trouble started, and no failures sitting " \
      "there is not evidence that the test is passing now. Failures scattered through the rows " \
      "that ARE here are still flakiness, where there is no culprit commit to find and the work " \
      "is quarantine or shared state."
  end

  # THE CAP, SAID LOUDLY — the heading of the alert that sits above the table when the list stopped
  # short of the window's newest rows.
  #
  # A clause in the basis paragraph is not enough here, and that is a judgement about this panel
  # rather than a general preference for alerts. On its siblings a truncated list is a footnote: the
  # by-file and by-description drill-ins are read for WHAT IS IN THEM, and a reader who sees the top
  # 200 of 250 rows has the answer they came for. This panel is read for WHERE IN THE SEQUENCE the
  # failures sit, and the cap removes the end the reading is taken from — so truncation does not
  # shorten the answer here, it removes it, and does so while leaving a full-looking table of 200
  # rows on the page. A missing answer that looks exactly like a negative one is the thing a reader
  # cannot detect for themselves, which is the standing test for whether a disclosure belongs in the
  # prose or in front of it.
  def unstable_test_runs_cap_alert_title = "This list stops short of the window's newest rows"

  # WHAT the cap took and WHERE the list therefore ends, with the way to see the missing end.
  #
  # Three facts, and each one is checkable against something else on this page rather than taken on
  # trust: how many rows are missing (against the scope sentence's two figures), which commit the
  # list ends at (against the "Recent runs" panel below, where the window's actual newest commit is
  # printed — that comparison is the whole point of naming the sha, and on a window whose newest
  # runs fell off entirely the two shas differ, visibly), and how long ago that was (because "the
  # list ends four commits back" is a different size of gap on a busy branch than on a quiet one).
  #
  # It claims the rows are the newest and NOT that whole runs are missing, which is the precise
  # thing that is true in both truncation geometries. The read is ordered by window position and
  # capped, so what it sheds is always a suffix in window order — the newest rows recorded under
  # this description, full stop. Whether that suffix is two rows off the newest run or five entire
  # runs depends on how many examples carry the description per run, and a sentence asserting either
  # shape would be false in the other one. "The end of this list is not the end of this window's
  # evidence" is true whenever the cap bit and is the claim the reading rule needs; nothing here
  # says more than that.
  #
  # The escape hatch is real and is the same sequence over the OTHER window: `GET
  # /api/v1/repository`'s `unstable_test` block reads `recent_test_runs`, which is ordered
  # newest-first, so its cap sheds the OLDEST rows and keeps exactly the end this page drops. That
  # is a property of the two windows rather than of the read — `SpecObservation.outcome_sequence_in`
  # orders by `array_position` over the run ids it is handed and imposes no direction of its own —
  # which is why the pointer can be given as a fact rather than as a hope.
  def unstable_test_runs_cap_alert_body(sequence)
    dropped = sequence.recorded_count - sequence.rows.size
    last = sequence.rows.last

    # The gate above is STRICT, so this alert first renders at one dropped row — the singular is
    # the state that OPENS it, not a tail case — and the verb and noun phrase branch with the noun
    # the way `unstable_tests_unnamed_clause`'s do. Per-site here rather than a shared agreement
    # helper, and the plural wording below is byte-identical to what always rendered before.
    one = dropped == 1
    dropped_clause = if one
                       "it dropped is the newest one recorded under this description"
                     else
                       "it dropped are the newest ones recorded under this description"
                     end

    "The cap keeps this window's OLDEST rows, so the #{number_with_delimiter(dropped)} " \
      "#{"row".pluralize(dropped)} #{dropped_clause}. " \
      "The list ends at #{last.commit_sha.first(7)}, ingested #{time_ago_in_words(last.ingested_at)} " \
      "ago — compare that against the newest commit in “Recent runs” below to see how far short of " \
      "the window it stops. For the other end of the same sequence, read `unstable_test` over " \
      "`GET /api/v1/repository`: its window runs newest first, so its cap sheds the oldest rows and " \
      "keeps the ones missing here."
  end

  # Rows this window recorded under the description that said NOTHING about how it ended, counted
  # and stated — the silence the sequence would otherwise read as a gap in the story.
  #
  # `outcome` is nullable and nothing platform-side validates it, so a client that stopped sending
  # outcomes writes rows that are present and silent. Those are not passes and are counted as one
  # nowhere: `UnstableTests::Row#changed?` compares against `reported_outcome_count` rather than
  # `recorded_count` one rung up precisely so such a client cannot manufacture a flip, and a sequence
  # that let them read as passes would manufacture the same flip HERE — where it would look like a
  # date, which is the one wrong answer this panel is read to produce.
  #
  # Counted over the WINDOW rather than over the listed rows, so a truncated list's silence is still
  # countable, and rendered only when there is any: a clause reading "0 of them said nothing" is a
  # sentence about arithmetic rather than about this test.
  #
  # The NOUN is carried on the denominator — "1 of the 3 rows" and not "1 of the 3". This clause
  # renders after the reading rule, which is several sentences of its own, so the "3 rows" it is
  # counting against is no longer in the reader's ear by the time the bare number arrives; and the
  # paragraph it sits in is one that also counts RUNS, which is the other noun a reader would supply
  # for it. One word removes the choice.
  def unstable_test_runs_silence_clause(sequence)
    silent = sequence.unreported_outcome_count
    return "" unless silent.positive?

    recorded = sequence.recorded_count

    " #{number_with_delimiter(silent)} of the #{number_with_delimiter(recorded)} " \
      "#{"row".pluralize(recorded)} said nothing about how it ended. Silence is not a pass and is " \
      "not counted as one here, so a gap in the column is a run that recorded the test and " \
      "reported no outcome for it."
  end

  # The window recorded nothing under the description that was asked for. An ordinary answer and not
  # an error, on the spelling `RepeatedDescriptionExamples`' empty state fixed one ladder over:
  # `?unstable_test=` is a URL a reader types, edits and bookmarks, so a typo, a reworded description
  # and a stale bookmark all arrive here.
  #
  # It NAMES THE DESCRIPTION BACK, because an empty state without a subject is a sentence about
  # nothing — and here the subject is a sentence somebody wrote, which is the one thing a reader can
  # check against their own suite.
  #
  # And it names the RULE that makes the commonest cause of this state ordinary rather than broken:
  # the project matches tests by description alone, so a renamed test STARTS A NEW HISTORY and its
  # old one stops at the rename. A reader who does not know that reads an empty panel as a lost
  # history rather than as two.
  def unstable_test_runs_none_description(sequence)
    runs = "#{number_with_delimiter(sequence.run_count)} #{"run".pluralize(sequence.run_count)}"

    "None of the last #{runs} of this window recorded an example described " \
      "“#{sequence.name}”. Tests are matched here by their description alone, so a test renamed or " \
      "reworded since starts a new history under its new description and this one stops at the " \
      "rename — a bookmark to the old wording goes stale by design. The “Tests whose outcome " \
      "changed” panel above lists the descriptions this window did record."
  end

  private

  # Runs of the window that wrote no per-example rows at all — a different absence from "reported
  # no outcome", and one the sentence above would otherwise fold into it. A run ingested before
  # these rows existed, or one whose client sends no per-example detail, is a run of the window
  # with nothing at this grain rather than a run that was quiet about outcomes.
  def unstable_tests_silent_runs_clause(unstable)
    silent = unstable.run_count - unstable.runs_with_rows
    return "" unless silent.positive?

    " #{number_with_delimiter(silent)} of them recorded no per-example rows at all."
  end

  # Rows the matching had to leave out, counted and stated. A null description cannot be matched to
  # itself across runs — two nulls are not known to be one example — so pooling them under one
  # group would invent a test with a history. Excluding them silently is the other failure: the
  # panel would be a claim about the window made from part of it, with nothing saying which part.
  #
  # Counted in ROWS, deliberately, and worded that way. An unnamed row is precisely a row this
  # panel cannot say is a test, so reporting a number of "tests" here would be the same identity
  # claim the exclusion exists to decline.
  #
  # The second clause states the rule about the rows this window actually holds, so it counts with
  # the first. At one row there is no pair to be unequal and nothing to pool it with, so the reason
  # is the one that still holds of a single null: it cannot be matched to ITSELF across runs.
  def unstable_tests_unnamed_clause(unstable)
    return nil unless unstable.unnamed_count.positive?

    one = unstable.unnamed_count == 1
    reason = if one
               "a null description is not known to be one test with itself across runs, so it is"
             else
               "two of those are not known to be one test, so they are"
             end

    "#{number_with_delimiter(unstable.unnamed_count)} " \
      "#{"row".pluralize(unstable.unnamed_count)} in this window carried no description; " \
      "#{reason} excluded from the matching rather than pooled into #{one ? "a test" : "one"}."
  end

  # The sibling exclusion, for the rows that carried a description but reached no durable identity
  # — the column the identity-grained matching (SPGD-758) is denied by instead. Same grain as the
  # clause above, same refusal: a row the resolver never matched to a test cannot be followed
  # across runs, and dropping it silently would be a claim about a population the panel did not
  # read. Counted in ROWS for the same reason the unnamed count is.
  #
  # Rendered under the same conditions and behind the same `comparable?` guard as the clause above:
  # the count is `nil`, never `0`, on an incomparable window, and this clause is reached only
  # through `#unstable_tests_exclusion_sentence` inside the panel's compared branch.
  def unstable_tests_unresolved_clause(unstable)
    return nil unless unstable.unresolved_count.positive?

    one = unstable.unresolved_count == 1

    "#{number_with_delimiter(unstable.unresolved_count)} " \
      "#{"row".pluralize(unstable.unresolved_count)} in this window reached no durable identity " \
      "(it was never matched to a test), and #{one ? "was" : "were"} excluded from the matching " \
      "rather than pooled."
  end

  # The cap, disclosed only when it bit — and stated as what was KEPT rather than as a bare number
  # cut, because which end of the candidate list survived is the part that decides what this panel
  # could still see. Fewest failures first: a description that failed in every run of the window is
  # one whose outcome did not change, so the cap sheds that end first.
  def unstable_tests_truncation_clause(unstable)
    return nil unless unstable.truncated?

    "#{number_with_delimiter(unstable.candidate_count)} descriptions failed somewhere in this " \
      "window — more than this panel examines at once — so the " \
      "#{number_with_delimiter(unstable.examined_count)} that failed fewest times were the ones " \
      "compared across runs, and the other #{number_with_delimiter(unstable.unexamined_count)} " \
      "#{unstable.unexamined_count == 1 ? "is" : "are"} not represented above."
  end
end
