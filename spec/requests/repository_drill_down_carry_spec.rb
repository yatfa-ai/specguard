# frozen_string_literal: true

require "rails_helper"

# The carry-through rule the drill-down links on repositories#show all obey, pinned ACROSS the
# panels rather than inside any one of them.
#
# Each ask (`?branch=`, `?commit_sha=`, `?spec_file=`, `?spec_directory=`,
# `?repeated_description=`, `?unstable_test=`) anchors a panel of its own, and every drill-down link
# opens or closes one of them. The rule is that a gesture aimed at ONE ask leaves the others alone: opening a file
# is not a request to close the area, closing an area is not a request to close the file, anchoring
# a run is not a request to close either, and so on in every direction. That is one decision per ask
# at every link, and every one of them used to be re-made by hand at the link site, because the READ
# side of these asks was abstracted into a controller concern each while the EMIT side was copied.
#
# The number of asks is deliberately not stated as a figure anywhere here, and neither is the number
# of links: both are counts sizing a table, the link count went stale twice before anyone noticed,
# and `asks` and `gestures` below are the only places that know them.
#
# It failed the way a hand-maintained matrix fails: ONE cell was wrong. The area-open link was
# written after `?spec_file=` shipped, did not carry it, and was later edited to ADD a different ask
# without anyone noticing the missing one. Every panel's own spec was green, because each of them
# asserts about the panel it owns and the wrong cell was a SIBLING'S ask being dropped by someone
# else's link. A per-panel spec cannot see that; only a spec that walks the whole matrix can.
#
# So this file is deliberately not a section of any panel's spec. It owns the invariant, not the
# panel — the panels' own files keep asserting what their rows say, their captions, their empty
# states and their queries, and this one asserts only which asks survive which gesture. When a link
# is ADDED it gets a row in `gestures` below and its cells are checked by construction, which is
# the entire point of `RepositoriesHelper#drill_down_path` existing.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand, for the reason every sibling spec states: a hand-built fixture would assert
# against a shape nothing in production writes.
#
# TWO runs rather than one, since the two growth panels compare the latest run against the previous
# run ON THE SAME BRANCH and render nothing without it. The single-run panels read the latest run
# and are untouched by the earlier one — their gestures below are the same gestures they were. The
# two runs are also what makes the cross-run ranking comparable at all, which is what gives the
# `?unstable_test=` gestures a row to open.
RSpec.describe "Repository drill-down carry-through", type: :request do
  before { @user = sign_in_via_github }

  # THE ask set: every one of them open at once. Every panel renders, so every link exists on one
  # page and each one can be asked what it did with the asks it does not own. Anything less and the
  # matrix has holes exactly where the defect lived — a link cannot be caught dropping an ask that
  # was never in the request.
  def branch_ask = "main"

  # The LATEST run's sha, deliberately, so anchoring on it changes nothing any other gesture can
  # see: every panel describes the same run it describes on a default page, and the matrix below
  # goes on asserting about the rows it always asserted about. What is added is the ask itself,
  # riding through every link — which is the only thing this file is for. An anchor on the EARLIER
  # run is a different question (does the page follow it), and it is pinned where it belongs, in
  # spec/requests/repository_run_anchor_spec.rb.
  def run_ask = "feedfacecafe0001"

  # The earlier run's sha, and its SEVEN-CHARACTER PREFIX has to differ from the latest one's. The
  # "Recent runs" cells are labelled with `commit_sha.first(7)`, so two shas agreeing over their
  # first seven characters — which `feedfacecafe0000` and `feedfacecafe0001` did — make the
  # anchor gesture's link ambiguous, and `href_for` would silently assert about whichever row
  # Capybara reached first.
  def earlier_run_ask = "0ldde11vercafe00"

  def file_ask = "spec/models/order_spec.rb"

  def area_ask = "spec/models"

  def description_ask = "settles the balance"

  def other_description = "refuses a negative quantity"

  # The cross-run ranking's ask, and a second unstable test to be wrong about. Both are carried by
  # exactly ONE example per run — a description carried by two examples in one run is classified as a
  # shared description and listed BELOW that panel's table as plain text, where it has no link at all.
  def unstable_ask = "reconciles the ledger"

  def other_unstable = "expires the session"

  # The ask above's QUALIFIER, and the only entry in this matrix that is not an ask: it opens no
  # panel and narrows no population, it names WHICH ranking the reader opened the test from so the
  # "Close test" control can return them there. It is in the matrix for the reason the six asks are
  # — a qualifier that stopped following its principal would be silently right until the reader
  # touched any other link, and then point that control at a panel they never opened.
  #
  # Its value here is the OTHER entry point from the one the new gesture below sets, on this file's
  # standing rule that no link's target may be its own subject: a gesture that SET what was already
  # open would pass whether it set the value or merely carried it.
  def unstable_origin_ask = "unstable-tests"

  # Shaped so every panel has rows AND so no link's target is its own subject: the file the
  # by-file panel links to is NOT the open file, the area the by-area panels link to is NOT the open
  # area, the description it links to is NOT the open description. A link that carried an ask by
  # accident — because the value it SETS happens to equal the value it should CARRY — would pass a
  # sloppier fixture and prove nothing.
  #
  # TWO descriptions are carried by two examples each, because the ranking is `HAVING COUNT(*) > 1`:
  # a description recorded once is not in that panel at all, so a second repeated one is what gives
  # the open-description gesture a row to link to that is not the row already open.
  #
  # The EARLIER run exists for the two growth panels, which compare the latest run against the
  # previous run on the same branch and render nothing without one. It is shaped so both of them
  # have a row to link FROM and neither links to its own subject:
  #
  #   - `spec/requests` moved (2 → 1), so "Areas that grew or shrank" has a row for an area that is
  #     not the open one — `spec/models` moved too, and its being present is what makes the other
  #     row's link a real choice rather than the only one. Stated without a figure: the open area's
  #     size is whatever the rows above add up to, and the cross-run tests were added to it after
  #     this sentence was written, which is exactly how a figure here goes stale unnoticed.
  #   - inside the open area, `refund_spec.rb` moved (2 → 1) while `order_spec.rb` — the OPEN file —
  #     did not, so the per-file drill-in has a row to link to that is neither the open file nor a
  #     file the latest run lacks. A file the latest run does not have is deliberately not linked at
  #     all, so a fixture whose only moved file was a deleted one would leave that gesture with no
  #     link to find.
  #
  # TWO tests change their outcome across the two runs, each carried by exactly one example per run,
  # in a file of their own. One example per run is what keeps them in the cross-run RANKING rather
  # than in the shared-description list beneath it, where a description carried twice in one run goes
  # and where there is no link at all. They sit in a file that is the same size in both runs, so the
  # per-file growth panel's row is still `refund_spec.rb` and no gesture above moved.
  #
  # Both runs are ingested in one piece and both report tests, so the panels' comparability gate
  # passes; the earlier run is backdated so `previous_test_run_on_branch` finds it.
  def drill_down_run
    repository = create_repository(user: @user)
    ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 3.5, line_number: 1,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/refund_spec.rb", duration: 2.0, line_number: 2,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/refund_spec.rb", duration: 2.0, line_number: 3,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/user_spec.rb", duration: 1.0, line_number: 4,
                                     name: other_description),
                        example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 5,
                                     name: other_description),
                        example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 6,
                                     name: other_description),
                        example_spec(file_path: "spec/models/ledger_spec.rb", duration: 0.5, line_number: 7,
                                     name: unstable_ask, outcome: "failed"),
                        example_spec(file_path: "spec/models/ledger_spec.rb", duration: 0.5, line_number: 8,
                                     name: other_unstable, outcome: "failed")],
           commit_sha: earlier_run_ask)
    repository.test_runs.last.update!(created_at: 2.hours.ago)
    ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 3.5, line_number: 11,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/refund_spec.rb", duration: 2.0, line_number: 12,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/user_spec.rb", duration: 1.0, line_number: 13,
                                     name: other_description),
                        example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 14,
                                     name: other_description),
                        example_spec(file_path: "spec/models/ledger_spec.rb", duration: 0.5, line_number: 15,
                                     name: unstable_ask, outcome: "passed"),
                        example_spec(file_path: "spec/models/ledger_spec.rb", duration: 0.5, line_number: 16,
                                     name: other_unstable, outcome: "passed")])
    repository
  end

  # Through the resolver as well as the producer, which is the two halves the ingest endpoint runs
  # as a `202` and a job behind it. The window ranking is keyed on `spec_identity_id`, so a fixture
  # that stopped at the producer leaves "Slowest tests across the window" in its `:unresolved` state
  # — a panel with no rows and therefore no link, which is the one condition under which this
  # matrix's newest gesture would silently have nothing to assert about. Every other panel here
  # reads columns the recorder writes directly and is unmoved by this.
  def ingest(repository, specs, commit_sha: run_ask, **attrs)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
    Ingest::IdentityResolver.resolve(run)
    run
  end

  def example_spec(file_path:, duration:, line_number:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration).merge(attrs)
  end

  def page = Capybara.string(response.body)

  def open_every_ask
    get repository_path(drill_down_run, branch: branch_ask, commit_sha: run_ask, spec_file: file_ask,
                        spec_directory: area_ask, repeated_description: description_ask,
                        unstable_test: unstable_ask, unstable_test_from: unstable_origin_ask)
  end

  # The links, as the page offers them.
  #
  # `find` is scoped to the panel that OWNS each gesture, never to the page: three of these panels
  # carry a link with the same text as a link in another panel (a file path appears in three of
  # them), and a page-scoped lookup would silently assert about whichever one Capybara reached
  # first — the failure mode where a link is "verified" by testing a different link.
  #
  # `sets` is what the gesture WRITES (so the expected value is the target, not the reader's current
  # ask). `clears` is the one ask it removes. Everything unnamed must be carried, and that is the
  # assertion — stated once here rather than once per link.
  #
  # A LOCAL and deliberately not a constant, for the reason
  # spec/requests/repository_spec_directory_durations_spec.rb spells out about its fixture names: a
  # constant assigned inside an `RSpec.describe` block is not scoped to the example group, because
  # blocks open no constant scope — it lands on `Object`, where a second file assigning the same
  # name would not merely warn but decide the value BOTH files read at run time. This list is needed
  # at definition time to generate the examples, which a method cannot do, so it is a local: block
  # scope, no global surface.
  gestures = [
    { name: "open a file from Heaviest spec files",
      panel: "#spec-file-durations", link: "spec/requests/checkout_spec.rb",
      sets: { spec_file: "spec/requests/checkout_spec.rb" } },
    { name: "Close file",
      panel: "#spec-file-examples", link: "Close file",
      clears: :spec_file },
    { name: "open an area from Heaviest spec directories",
      panel: "#spec-directory-durations", link: "spec/requests",
      sets: { spec_directory: "spec/requests" } },
    { name: "Close directory",
      panel: "#spec-directory-files", link: "Close directory",
      clears: :spec_directory },
    { name: "open a file from Spec files in this directory",
      panel: "#spec-directory-files", link: "spec/models/refund_spec.rb",
      sets: { spec_file: "spec/models/refund_spec.rb" } },
    { name: "open a description from Descriptions this run recorded more than once",
      panel: "#repeated-descriptions", link: "refuses a negative quantity",
      sets: { repeated_description: "refuses a negative quantity" } },
    { name: "Close description",
      panel: "#repeated-description-examples", link: "Close description",
      clears: :repeated_description },
    { name: "open a file from Examples under this description",
      panel: "#repeated-description-examples", link: "spec/models/refund_spec.rb",
      sets: { spec_file: "spec/models/refund_spec.rb" } },
    { name: "open an area from Areas that grew or shrank",
      panel: "#spec-directory-growth", link: "spec/requests",
      sets: { spec_directory: "spec/requests" } },
    { name: "open an area from How SpecGuard reads this suite, by area",
      panel: "#unannotated-directories", link: "spec/requests",
      sets: { spec_directory: "spec/requests" } },
    { name: "open a file from Files that grew or shrank in this directory",
      panel: "#spec-directory-file-growth", link: "spec/models/refund_spec.rb",
      sets: { spec_file: "spec/models/refund_spec.rb" } },
    { name: "open a file from Slowest tests",
      panel: "#slowest-examples", link: "spec/requests/checkout_spec.rb",
      sets: { spec_file: "spec/requests/checkout_spec.rb" } },
    # The WINDOW panel's file link, which is a different gesture from the row above it even though
    # both open a file: that one is one run's ranking and this one is the window's, they are keyed
    # on different things, and this panel's row can name SEVERAL files. `refund_spec.rb` is the
    # exact text of exactly one anchor on this panel and is not the open file, so the cell it proves
    # is a real choice rather than a link that happened to carry an ask it also sets.
    { name: "open a file from Slowest tests across the window",
      panel: "#slowest-tests-window", link: "spec/models/refund_spec.rb",
      sets: { spec_file: "spec/models/refund_spec.rb" } },
    # Each of the two entry points STAMPS its own panel id as the test's origin, so the "Close test"
    # control can return the reader to the ranking they actually picked the test from rather than to
    # a hardcoded one. Only two values are legal, so one of these two rows necessarily sets the value
    # already open: this one. Its `unstable_test_from` cell therefore cannot tell setting from
    # carrying — the row BELOW is the discriminating one, and it is the reason the open value is the
    # other panel.
    { name: "open a test from Tests whose outcome changed",
      panel: "#unstable-tests", link: "expires the session",
      sets: { unstable_test: "expires the session", unstable_test_from: "unstable-tests" } },
    # THE SECOND ENTRY POINT, and the gesture this matrix gained with it. It opens a test from the
    # wall-clock ranking, where the ordinary row is a test the flakiness ranking does not list at
    # all — so it stamps a DIFFERENT origin, and that difference is what the cell proves.
    #
    # Its link is found by the test's exact text on the "Slowest tests" panel. The fixture's
    # unstable tests are the only rows there carrying a name link, and `reconciles the ledger` is
    # the OPEN test, so this row deliberately opens the other one: a gesture whose target was its
    # own subject would pass while setting nothing.
    { name: "open a test from Slowest tests",
      panel: "#slowest-examples", link: "expires the session",
      sets: { unstable_test: "expires the session", unstable_test_from: "slowest-examples" } },
    # Clears the origin ALONGSIDE the test, which is why `clears` is a list here and a lone symbol
    # everywhere else. The origin qualifies the test: a close that dropped the subject and kept the
    # pointer to where it was opened from would carry that pointer through every later link, aimed
    # at a panel with nothing open in it.
    { name: "Close test",
      panel: "#unstable-test-runs", link: "Close test",
      clears: [:unstable_test, :unstable_test_from] },
    # The one gesture here that RE-ANCHORS rather than narrows: it names which run every panel
    # describes, where the others pick a series or open a panel of the run already chosen. It is in
    # this matrix for exactly the reason the others are — jumping to a run is not a request to close
    # an open area — and it is the gesture with the most to lose from a hand-written href, since a
    # run anchor that dropped the open drill-downs would land the reader back at the top of a page
    # they had already navigated three rungs into.
    { name: "anchor a run from Recent runs",
      panel: "#recent-runs", link: "0ldde11",
      sets: { commit_sha: "0ldde11vercafe00" } },
    # The way back OUT of the ask the row above enters, and it is here for the same reason its
    # counterpart is: un-anchoring is not a request to close an open area, file or description, nor
    # to drop `?branch=`. It renders on this fixture because `run_ask` is deliberately the LATEST
    # run's sha, so the ask resolves, `@run_anchor_run` is present and the gesture is on the page
    # every other row is asserted against.
    { name: "Show the newest run",
      panel: "#overview", link: "Show the newest run",
      clears: :commit_sha }
  ]

  # The gesture's own link, by EXACT text rather than `match: :prefer_exact`. That strategy resolves
  # an ambiguous LOCATOR; it does not rank a `text:` FILTER, which matches on substring — so on a
  # panel whose rows carry both a spec-file drill-in and the definition-site link beside it,
  # "spec/requests/checkout_spec.rb" matches the coordinate "spec/requests/checkout_spec.rb:14" just
  # as well, and the matrix silently read whichever anchor came first. Two gestures here
  # ("open a file from Slowest tests", "open a file from Examples under this description") sit on
  # such panels; a substring filter reads the wrong anchor on both, and only one of the two FAILS
  # when it does — the other's two hrefs carry the same asks, so it passes while asserting about a
  # link it was not aiming at. That is the failure this file cannot afford, because a matrix that
  # cannot say WHICH anchor it read proves nothing about the link it names.
  #
  # What makes the exact match unique is a schema fact: `line_number` is NOT NULL, so the coordinate
  # always carries a `:line` that the path it is built from does not. Every gesture in the table
  # above has its link text as the EXACT text of its anchor — measured, one exact match each, on the
  # page `open_every_ask` builds.
  #
  # So there is no substring fallback, deliberately. A gesture whose text stops identifying its
  # anchor is the one condition a matrix that identifies gestures BY TEXT must not survive quietly:
  # `find` raises `Ambiguous` if a second exact match ever appears and `ElementNotFound` if the text
  # drifts, where falling through to first-substring-match would route straight back into the bug
  # above.
  def href_for(gesture)
    page.find(gesture[:panel]).find("a", exact_text: gesture[:link])[:href]
  end

  # A query value as it appears in a URL, so an assertion cannot pass on a substring of a longer
  # value: `spec_file=spec/models/order_spec.rb` is a prefix of nothing, but `spec_directory=spec`
  # is a prefix of `spec_directory=spec%2Fmodels`, and a bare `include` would call the second the
  # first. Terminated by `&` or by end-of-string, and the fragment is cut off first because `#`
  # terminates a query too.
  def carries?(href, key, value)
    query = href.split("#").first.to_s.split("?", 2).last.to_s

    query.split("&").include?("#{key}=#{CGI.escape(value.to_s)}")
  end

  def mentions?(href, key)
    query = href.split("#").first.to_s.split("?", 2).last.to_s

    query.split("&").any? { |pair| pair.start_with?("#{key}=") }
  end

  describe "the whole matrix, one page with every ask open" do
    # THE spec the missing cell would have failed. Every link against every ask, and every cell is
    # decided by the gesture's own definition rather than by a list of expected hrefs maintained
    # beside the one in the view — a matrix pinned by a second hand-written matrix is two places to
    # make the same mistake.
    gestures.each do |gesture|
      it "#{gesture[:name]} keeps every ask it does not own" do
        open_every_ask
        href = href_for(gesture)
        asks = { branch: branch_ask, commit_sha: run_ask, spec_file: file_ask,
                 spec_directory: area_ask, repeated_description: description_ask,
                 unstable_test: unstable_ask, unstable_test_from: unstable_origin_ask }
        # `clears` is a symbol at every gesture but one, and a LIST at "Close test": the test's
        # origin qualifies the test, so that gesture removes two keys in one act. Wrapped rather
        # than written as a list everywhere, so the fourteen single-key rows stay readable.
        cleared = Array(gesture[:clears])

        asks.each do |key, requested|
          if cleared.include?(key)
            expect(mentions?(href, key)).to be(false),
                                            "expected #{gesture[:name]} to CLEAR #{key}, got #{href}"
          elsif gesture[:sets]&.key?(key)
            expect(carries?(href, key, gesture[:sets][key])).to be(true),
                                                                "expected #{gesture[:name]} to SET " \
                                                                "#{key}=#{gesture[:sets][key]}, got #{href}"
          else
            expect(carries?(href, key, requested)).to be(true),
                                                      "expected #{gesture[:name]} to CARRY " \
                                                      "#{key}=#{requested}, got #{href}"
          end
        end
      end
    end

    # The guard on the trap that a "tidier" helper walks straight into. Carry is the default, so an
    # omitted ask means KEEP — which makes the CLEARING gestures the only things on the page that
    # must pass an explicit `nil`. Compacting the OVERRIDES in `drill_down_path`
    # (`asks.merge(overrides.compact)`) drops that nil before it can override anything, the reader's
    # current ask survives, and every one of them becomes a no-op that navigates to the page it is
    # already on — the exact inversion of the defect the abstraction was built to kill.
    #
    # How many there are is deliberately not stated, for the reason the header gives about the other
    # two counts on this page: the set keeps growing — "Show the newest run" gave the run anchor its
    # way back, and every drill-in added since has brought its own way out — and a sentence that had
    # said "the three Close buttons" would have been left describing the page as it used to be. The
    # table below is the only place that knows the size.
    #
    # They are asserted separately from the matrix above rather than trusted to it, because they are
    # the cells whose CORRECT value is an absence, and an absence is what a green suite looks like
    # when the assertion is missing. Both halves are checked deliberately: the matrix examples above
    # catch this mutation too (a cleared ask reappearing), and these catch it from the other side, on
    # the one property each gesture exists for.
    {
      "Close file" => [:spec_file, "#spec-file-examples"],
      "Close directory" => [:spec_directory, "#spec-directory-files"],
      "Close description" => [:repeated_description, "#repeated-description-examples"],
      "Close test" => [[:unstable_test, :unstable_test_from], "#unstable-test-runs"],
      "Show the newest run" => [:commit_sha, "#overview"]
    }.each do |label, (ask, panel_id)|
      it "#{label} still drops its own ask" do
        open_every_ask

        href = page.find(panel_id).find("a", text: label, match: :prefer_exact)[:href]

        Array(ask).each { |key| expect(mentions?(href, key)).to be(false) }
      end
    end
  end

  describe "an ask nobody made" do
    # `nil` is omitted from the query string, so a page nobody asked a drill-down of links exactly
    # as it did before any of this existed. The helper defaults every ask to its request ivar, so a
    # bug that turned "no ask" into `key=` — an EMPTY ask, which the param concerns read as no ask
    # but which changes every href on the page — would show up here and nowhere else.
    it "writes no parameter for an ask that was not made" do
      get repository_path(drill_down_run)

      href = page.find("#spec-directory-durations").find("a", text: "spec/models")[:href]

      expect(mentions?(href, :branch)).to be(false)
      expect(mentions?(href, :commit_sha)).to be(false)
      expect(mentions?(href, :spec_file)).to be(false)
      expect(mentions?(href, :repeated_description)).to be(false)
      expect(mentions?(href, :unstable_test)).to be(false)
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
    end
  end
end
