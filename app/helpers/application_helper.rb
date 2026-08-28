module ApplicationHelper
  # Filename for the reveal-once token download. Named after the key, so somebody who mints two of
  # them in a sitting can tell the files apart; `parameterize` is also what stops a user-controlled
  # key name from reaching the browser's `download` attribute as a path.
  #
  # Here rather than in `RepositoriesHelper`, where it started, because there are now THREE reveal
  # panels rendering it — a repository's `sgk_` key on repositories#show, a person's `sgu_` key on
  # accounts#show, and each newly registered repository's first key on the bulk registration summary
  # — and no one surface owns the rule. Nothing about it was ever repository-shaped.
  #
  # The batch summary is also the one caller that does not hand this a bare key name: it renders N
  # panels in one response, where every key carries the same `ApiKey::DEFAULT_NAME`, so it composes
  # the repository's full name in as well and gets a distinct filename per row. That is a caller's
  # decision rather than this method's — what is owned here is the shape and the `parameterize`.
  def revealed_token_filename(name)
    ["specguard", name.to_s.parameterize.presence, "api-key"].compact.join("-") + ".txt"
  end

  # What a repository whose deliveries are being REFUSED is called, in the one place both surfaces
  # that say it read from.
  #
  # Two surfaces state this now: the connection indicator on repositories#show, and the card on the
  # repositories grid. They put it in different containers — a header row and a card badge row — so
  # what is shared is the WORDING and not the markup, which is exactly the split
  # `test_run_delivery_note` below already makes for its own two callers and the reason it returns a
  # plain String rather than a `tag`.
  #
  # A seam and not the same literal typed twice, for the reason `test_run_cost_rows` states in full:
  # two copies are agreement that merely HOLDS TODAY. Rename this on the indicator, update the
  # indicator's own specs, and the grid keeps rendering the old word against green literals of its
  # own — one repository's refusal worded two ways on the page and the page it links to, with
  # nothing in the suite able to see it. The `:error` tone is deliberately NOT here: it is markup,
  # each caller picks its own badge, and both pick error for the reason the indicator gives — work
  # is being destroyed, not merely absent.
  def refused_deliveries_label = "Deliveries refused"

  # The sentence under that label: WHEN the last refusal landed, and the one thing a reader who has
  # just seen a green "Connected" needs told — that the credential is fine and the payload was not.
  #
  # Shared for the same reason the label above is, and split from it because the two callers place
  # them differently: the indicator renders both, and the grid's card renders them in two separate
  # containers. `show` appends its own "See Rejected deliveries" link after this, which is markup
  # pointing at a panel that exists on that page only — the grid links to the page, not to an anchor
  # inside it, so the pointer stays at the caller rather than becoming a fact this seam asserts
  # about every surface.
  #
  # Takes the timestamp rather than a `RejectedIngests`, so the caller with no rows loaded — the
  # grid, which reads one grouped `MAX(occurred_at)` for the whole page — can render it without
  # constructing an object it has no other use for.
  def refused_deliveries_note(last_rejection_at)
    "Last refused #{time_ago_in_words(last_rejection_at)} ago — " \
      "the key works, the payload did not."
  end

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

  # What a run COST, as the rows of a definition list — the labels, the pairing with their
  # denominators, and the choice between one row and two. Every surface that states a run's cost
  # renders these: the single-repository Overview panel and the repositories grid's card.
  #
  # A helper and not two copies of the same six lines of ERB, for the reason `test_run_delivery_note`
  # above is one: the card must not be able to word a figure differently from the page it links to.
  # The two helpers above already made that true of the FIGURES; this makes it true of the labels,
  # the denominators and the branch as well. Sharing it by hand — the same literals typed on both
  # surfaces — is agreement that merely *holds today*, and nothing in the suite can see the next
  # rename move one surface and not the other, because each side asserts its own literal.
  #
  # Which row shape is a question about the RUN, so it is asked here rather than by each caller:
  # `multi_shard?`, never `shard_count.positive?`. A run of exactly one shard has a `machine_seconds`
  # — the SUM over its one row — but for it the MAX and the SUM are the same number, and a second row
  # would print one figure twice under two labels. One shard or none keeps the single "Total runtime"
  # row, which is every unsharded run there has ever been.
  #
  # `wall_clock:` and `machine_time:` are how the Overview panel keeps its delta decoration: it
  # renders the same two seams with a signed change riding in the same cell, and passes the decorated
  # figure in rather than forking the labels to get it. Omitted — the card's case — each falls back to
  # the bare seam. So the two surfaces can differ in what they DECORATE while being unable to differ
  # in what they SAY.
  #
  # Free of queries on either caller. `duration_label` reads a column on the run; `multi_shard?`,
  # `machine_seconds_label` and both coverage phrases read shard facts that the grid primes for the
  # whole page through one grouped aggregate (`ShardCountPreloading`) and `show` primes for its one
  # run — so routing the card through here does not move the grid's shard-query budget off 1.
  def test_run_cost_rows(test_run, wall_clock: nil, machine_time: nil)
    wall_clock ||= test_run_duration(test_run)
    return [["Total runtime", wall_clock]] unless test_run.multi_shard?

    machine_time ||= test_run_machine_time(test_run)
    [["Wall clock (#{test_run.wall_clock_coverage})", wall_clock],
     ["Machine time (#{test_run.machine_seconds_coverage})", machine_time]]
  end

  # The suite-size change on the Overview panel, rendered as a change rather than as a magnitude.
  # The sign carries the whole meaning: a suite that gained 47 tests and one that lost 47 are
  # opposite facts, and a bare `47` sitting beside a suite size is neither — it reads as a second,
  # smaller count of something.
  #
  # Named for the one figure it renders, like `test_run_duration` and `test_run_machine_time`
  # above, and NOT as a general `signed_count`. The `±0` decision below is specific to "compared,
  # and it did not move" on this panel; a wider name would invite the next signed figure to inherit
  # it somewhere that reading is wrong.
  #
  # A true minus (U+2212), not a hyphen-minus. This renders inside a `tabular-nums` figure directly
  # under and over other numbers, and a hyphen is drawn narrower and lower than the `+` it has to
  # align with, which is exactly the character difference the typographic minus exists to fix.
  #
  # `±0` for no change, not `+0`. "The suite did not move between these two runs" is a real answer
  # and `+0` claims a direction it does not have. It is still rendered rather than suppressed —
  # a run that changed nothing is precisely the case a reader wants confirmed, and dropping the
  # figure there would be indistinguishable from having no comparison to make at all.
  def suite_size_change(delta)
    return "±0" if delta.zero?

    "#{delta.negative? ? "−" : "+"}#{number_with_delimiter(delta.abs)}"
  end

  # The same fact in words, for the `aria-label` on that figure.
  #
  # The visible rendering is three characters of typography doing a sentence's work, and neither
  # half survives being read aloud: the `dd` announces as "1,047 +47" with nothing tying the second
  # number to the first, and U+2212 — chosen above precisely because it is not a hyphen — is
  # announced inconsistently across screen readers, from "minus" to nothing at all. So the sign and
  # the basis are both spelled out here rather than left to the glyph.
  def suite_size_change_reading(delta)
    return "unchanged since the previous run on this branch" if delta.zero?

    direction = delta.negative? ? "fewer" : "more"
    "#{number_with_delimiter(delta.abs)} #{"test".pluralize(delta.abs)} #{direction} " \
      "than the previous run on this branch"
  end

  # The cost change on the Overview panel, on exactly the rule `suite_size_change` above sets for
  # the size: a change rendered as a change, sign carrying the meaning, `±0` a real answer.
  #
  # ONE helper for both cost rows, where `test_run_duration` and `test_run_machine_time` are two.
  # Those are two because they read different columns and a run can have reported either without
  # the other — a difference in the *data*. This is a difference between two seconds figures, and
  # the wall clock's and the machine time's are the same quantity in the same unit sitting one row
  # apart: the argument `TestRun.humanized_seconds` makes for being one formatter is the same
  # argument for one signed rendering over it. What is NOT shared is the wording — a wall clock
  # that grew is *slower*, machine time that grew is *more*, and those are the two readings below.
  #
  # Named for the pair of rows it renders and not as a general `signed_seconds`, for the reason
  # `suite_size_change` gives: the `±0` reading is specific to "compared, and it did not move" on
  # this panel, and a wider name would invite the next signed figure to inherit it somewhere that
  # reading is wrong.
  #
  # A true minus (U+2212), the same character and for the same typographic reason as the size
  # delta one method up — this sits in the same `tabular-nums` list, in a cell directly below it.
  #
  # The magnitude goes through `TestRun.humanized_seconds`, which is the single formatter the level
  # in the very same cell is printed by. A second formatter here would let `1m 14s` and `74.3s`
  # appear side by side in one `dd`.
  #
  # And the zero test goes through `TestRun.seconds_unchanged?`, which is that same formatter's own
  # precision asked as a question. `delta.zero?` would be the raw float's answer, not the printed
  # figure's: a 0.03s difference is real in the column and invisible at a tenth, so it fell out of
  # the unchanged branch and rendered `+0.0s` — the panel's second spelling of the one thing `±0`
  # is reserved to say.
  def runtime_change(delta)
    return "±0" if TestRun.seconds_unchanged?(delta)

    "#{delta.negative? ? "−" : "+"}#{TestRun.humanized_seconds(delta.abs)}"
  end

  # The wall-clock change in words, for the `aria-label` on that figure — same job as
  # `suite_size_change_reading`, and needed for the same two reasons: the `dd` announces as
  # "1m 14s +3.2s" with nothing tying the second figure to the first, and U+2212 is announced
  # inconsistently across screen readers, from "minus" to nothing at all.
  #
  # *Slower* and *faster*, not "more"/"less": the wall clock is the time a reader waited through,
  # and a signed number read aloud beside it should say what it meant for them.
  #
  # Unchanged on the same predicate the visible figure uses, so the two cannot answer the question
  # differently — a cell reading `+0.0s` announced as "0.0s slower" is a sentence that contradicts
  # itself, and a cell reading `±0` announced as "0.0s slower" is worse.
  def wall_clock_change_reading(delta)
    return "wall clock unchanged since the previous run on this branch" if TestRun.seconds_unchanged?(delta)

    direction = delta.negative? ? "faster" : "slower"
    "#{TestRun.humanized_seconds(delta.abs)} #{direction} than the previous run on this branch"
  end

  # The machine-time change in words. Its own reading rather than a flag on the one above, because
  # the two are not the same claim: machine time is what the suite *cost*, not how long anyone
  # waited, and calling a bigger bill "slower" would describe a four-shard split that got wider —
  # more machine time, less wall clock — with the wrong word in both halves.
  def machine_time_change_reading(delta)
    return "machine time unchanged since the previous run on this branch" if TestRun.seconds_unchanged?(delta)

    direction = delta.negative? ? "less" : "more"
    "#{TestRun.humanized_seconds(delta.abs)} #{direction} machine time than the previous run on this branch"
  end

  # The one rendering of how a run was assembled, and of what that means for the count sitting
  # above it. Two surfaces state this now — the Recent-runs table on `show` and the repositories
  # index card — and they must not state it in two sets of words: the fact is that
  # `total_specs_count` on a sharded run is the SUM over the shards recorded SO FAR
  # (`Ingest::RunRecorder#recompute_totals` re-derives it after every POST), which is a single fact
  # about the data and not a per-page nuance to be re-explained.
  #
  # The composition itself comes from `TestRun#delivery_description` and is never re-derived here —
  # a hand-rolled count of parts would print "0 shards" for the unsharded corpus, which is every run
  # that named no `ci_run_id`.
  #
  # The qualifier is `shard_count.positive?` and not `multi_shard?`. The clause is not about
  # arithmetic WITHIN what arrived — one shard's SUM is indeed its own whole report — it is about
  # the gap between the shards RECORDED and the shards the suite HAS. A four-way split whose first
  # POST has landed sits at `shard_count == 1` and a quarter of its suite: three parts missing,
  # strictly more than the two-shard case this already warns about. `SuiteTrajectory#withheld_part_way`
  # answers the identical question with `positive?` and withholds that very row from the growth
  # line for sitting at a fraction of its own suite — on the same page load this cell renders it.
  #
  # Zero is the exclusion, not one: an unsharded run arrived whole in a single POST
  # (`TestRun#delivery_description`) and has no missing part to name.
  #
  # What is retired here is the imported RATIONALE, not the predicate. `multi_shard?`'s own doc
  # argues from MAX-is-SUM, which is an argument about DURATION (wall clock vs machine time): it
  # settles the Overview's cost rows and settles nothing about whether a count discloses its
  # coverage, so it is the wrong reason to GATE this clause. That is the whole of the dispute.
  # It says nothing against the predicate itself, which is `shard_count > 1` and is named, by that
  # same doc, for the count and not the provenance — "is there more than one part to explain".
  #
  # Which is exactly the question three lines below, so it is what inflects the wording there. The
  # clause inflects for the same reason `delivery_description` does: "covers those" over a single
  # report promises more parts than the phrase before it just named.
  #
  # A plain String, not a `tag`, because the two callers put it in different containers — a table
  # cell and a card paragraph — and only the wording is shared. Neither predicate queries: every
  # run reaching here was primed with its shard count by
  # `RepositoriesController#preload_shard_counts`.
  def test_run_delivery_note(test_run)
    return test_run.delivery_description unless test_run.shard_count.positive?

    covered = test_run.multi_shard? ? "those" : "that report"
    "#{test_run.delivery_description} — the count above covers #{covered}, " \
      "not necessarily the whole suite"
  end
end
