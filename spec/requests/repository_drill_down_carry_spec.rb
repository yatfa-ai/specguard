# frozen_string_literal: true

require "rails_helper"

# The carry-through rule the drill-down links on repositories#show all obey, pinned ACROSS the
# panels rather than inside any one of them.
#
# Four asks (`?branch=`, `?spec_file=`, `?spec_directory=`, `?repeated_description=`) each anchor a
# panel of their own, and eight links open or close one of them. The rule is that a gesture aimed at
# ONE ask leaves the other three alone: opening a file is not a request to close the area, closing an
# area is not a request to close the file, and so on in every direction. That is thirty-two
# decisions — eight links × four asks — and every one of them used to be re-made by hand at the link
# site, because the READ side of these asks was abstracted into four controller concerns while the
# EMIT side was copied.
#
# It failed the way a hand-maintained matrix fails: ONE cell was wrong. The area-open link was
# written after `?spec_file=` shipped, did not carry it, and was later edited to ADD a different ask
# without anyone noticing the missing one. Every panel's own spec was green, because each of them
# asserts about the panel it owns and the wrong cell was a SIBLING'S ask being dropped by someone
# else's link. A per-panel spec cannot see that; only a spec that walks the whole matrix can.
#
# So this file is deliberately not a section of any panel's spec. It owns the invariant, not the
# panel — the panels' own files keep asserting what their rows say, their captions, their empty
# states and their queries, and this one asserts only which asks survive which gesture. When a NINTH
# link is added it gets a row in `gestures` below and its four cells are checked by construction,
# which is the entire point of `RepositoriesHelper#drill_down_path` existing.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand, for the reason every sibling spec states: a hand-built fixture would assert
# against a shape nothing in production writes.
RSpec.describe "Repository drill-down carry-through", type: :request do
  before { @user = sign_in_via_github }

  # THE ask set: all four open at once. Every panel renders, so all eight links exist on one page
  # and each one can be asked what it did with the three asks it does not own. Anything less and the
  # matrix has holes exactly where the defect lived — a link cannot be caught dropping an ask that
  # was never in the request.
  def branch_ask = "main"

  def file_ask = "spec/models/order_spec.rb"

  def area_ask = "spec/models"

  def description_ask = "settles the balance"

  def other_description = "refuses a negative quantity"

  # Shaped so every panel has rows AND so no link's target is its own subject: the file the
  # by-file panel links to is NOT the open file, the area the by-area panel links to is NOT the open
  # area, the description it links to is NOT the open description. A link that carried an ask by
  # accident — because the value it SETS happens to equal the value it should CARRY — would pass a
  # sloppier fixture and prove nothing.
  #
  # TWO descriptions are carried by two examples each, because the ranking is `HAVING COUNT(*) > 1`:
  # a description recorded once is not in that panel at all, so a second repeated one is what gives
  # the open-description gesture a row to link to that is not the row already open.
  def drill_down_run
    repository = create_repository(user: @user)
    ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 3.5, line_number: 1,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/refund_spec.rb", duration: 2.0, line_number: 2,
                                     name: description_ask),
                        example_spec(file_path: "spec/models/user_spec.rb", duration: 1.0, line_number: 3,
                                     name: other_description),
                        example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 4,
                                     name: other_description)])
    repository
  end

  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  def example_spec(file_path:, duration:, line_number:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration).merge(attrs)
  end

  def page = Capybara.string(response.body)

  def open_all_four
    get repository_path(drill_down_run, branch: branch_ask, spec_file: file_ask,
                        spec_directory: area_ask, repeated_description: description_ask)
  end

  # The eight links, as the page offers them.
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
      sets: { spec_file: "spec/models/refund_spec.rb" } }
  ]

  def href_for(gesture)
    page.find(gesture[:panel]).find("a", text: gesture[:link], match: :prefer_exact)[:href]
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

  describe "the whole matrix, one page with all four drill-downs open" do
    # THE spec the missing cell would have failed. Eight links × four asks, and every cell is
    # decided by the gesture's own definition rather than by a list of expected hrefs maintained
    # beside the one in the view — a matrix pinned by a second hand-written matrix is two places to
    # make the same mistake.
    gestures.each do |gesture|
      it "#{gesture[:name]} keeps every ask it does not own" do
        open_all_four
        href = href_for(gesture)
        asks = { branch: branch_ask, spec_file: file_ask,
                 spec_directory: area_ask, repeated_description: description_ask }

        asks.each do |key, requested|
          if gesture[:clears] == key
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
    # omitted ask means KEEP — which makes the three Close buttons the only things on the page that
    # must pass an explicit `nil`. Compacting the OVERRIDES in `drill_down_path`
    # (`asks.merge(overrides.compact)`) drops that nil before it can override anything, the reader's
    # current ask survives, and all three buttons become no-ops that navigate to the page they are
    # already on — the exact inversion of the defect the abstraction was built to kill.
    #
    # These three are asserted separately from the matrix above rather than trusted to it, because
    # they are the cells whose CORRECT value is an absence, and an absence is what a green suite
    # looks like when the assertion is missing. Both halves are checked deliberately: the matrix
    # examples above catch this mutation too (a cleared ask reappearing), and these catch it from the
    # other side, on the one property each button exists for.
    {
      "Close file" => [:spec_file, "#spec-file-examples"],
      "Close directory" => [:spec_directory, "#spec-directory-files"],
      "Close description" => [:repeated_description, "#repeated-description-examples"]
    }.each do |label, (ask, panel_id)|
      it "#{label} still drops its own ask" do
        open_all_four

        href = page.find(panel_id).find("a", text: label, match: :prefer_exact)[:href]

        expect(mentions?(href, ask)).to be(false)
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
      expect(mentions?(href, :spec_file)).to be(false)
      expect(mentions?(href, :repeated_description)).to be(false)
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
    end
  end
end
