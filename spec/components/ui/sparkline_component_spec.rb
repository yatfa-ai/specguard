# frozen_string_literal: true

require "rails_helper"

RSpec.describe UI::SparklineComponent, type: :component do
  def build_point(label, value, detail = "1 day ago")
    described_class::Point.new(label: label, value: value, detail: detail)
  end

  def three_points
    [build_point("aaaaaaa", 1_000, "3 days ago"),
     build_point("bbbbbbb", 1_020, "2 days ago"),
     build_point("ccccccc", 1_047, "1 day ago")]
  end

  # The suite-size wording the component used to hard-code, now supplied by its caller. Kept here
  # verbatim so every assertion below is still a statement about the same rendered chart.
  def size_formatter = ->(value) { ActiveSupport::NumberHelper.number_to_delimited(value.to_i) }

  def size_point_formatter
    ->(value) { "#{size_formatter.call(value)} #{"test".pluralize(value.to_i)}" }
  end

  def render_series(points: three_points, **overrides)
    render_inline(described_class.new(**{
      id: "trajectory",
      points: points,
      label: "Tests in suite on main",
      coverage: "3 of 4 runs plotted",
      summary: "The suite measured between 1,000 and 1,047 tests.",
      columns: ["Run", "Tests in suite", "Ingested"],
      formatter: size_formatter,
      point_formatter: size_point_formatter
    }.merge(overrides)))
  end

  it "draws one path through every point" do
    render_series

    # Three points, so three commands: the opening move and two lines.
    d = page.find("svg path[stroke-width]")[:d]
    expect(d.scan(/[ML]/).size).to eq(3)
    expect(d).to start_with("M")
  end

  it "puts a marker on every point, each naming its own figure" do
    render_series

    expect(page).to have_css("svg circle", count: 3)
    expect(page.all("svg circle title").map(&:text))
      .to eq(["aaaaaaa — 1,000 tests — 3 days ago",
              "bbbbbbb — 1,020 tests — 2 days ago",
              "ccccccc — 1,047 tests — 1 day ago"])
  end

  # The lowest value sits at the floor of the plot and the highest at its ceiling — which is the
  # whole point of not starting at zero, and the reason the bounds have to be printed.
  it "scales the plot to the series' own range" do
    render_series

    ys = page.all("svg circle").map { |circle| circle[:cy].to_f }
    expect(ys.first).to eq((described_class::VIEWBOX_HEIGHT - described_class::PADDING_Y).to_f)
    expect(ys.last).to eq(described_class::PADDING_Y.to_f)
    expect(ys.first).to be > ys[1]
    expect(ys[1]).to be > ys.last
  end

  it "prints both axis bounds beside the plot, so a slope can be read" do
    render_series

    # A line climbing corner to corner is +47 tests on a suite of 1,000 or a suite that doubled;
    # nothing in the picture distinguishes them, so the numbers are on the page.
    expect(page).to have_text("1,047")
    expect(page).to have_text("1,000")
  end

  # A suite that was measured repeatedly and did not move IS a flat line. Dividing by its
  # zero-width range is the bug; drawing the flat line is the correct answer.
  it "draws a series that never moved down the middle rather than dividing by zero" do
    render_series(points: [build_point("steady1", 1_000), build_point("steady2", 1_000)])

    ys = page.all("svg circle").map { |circle| circle[:cy].to_f }
    expect(ys).to eq([described_class::VIEWBOX_HEIGHT / 2.0, described_class::VIEWBOX_HEIGHT / 2.0])
  end

  # A backstop, not the message. One point drawn as a line is a flat one, which says the suite is
  # stable — a claim one measurement cannot support. The caller still owes its reader an explicit
  # empty state; this only guarantees the component will not invent the claim on its own.
  it "renders nothing at all rather than a flat line through one point" do
    render_series(points: [build_point("onlyone", 1_000)])

    expect(page).to have_no_css("svg", visible: :all)
    expect(page).to have_no_css("#trajectory", visible: :all)
  end

  it "renders nothing on an empty series" do
    render_series(points: [])

    expect(page).to have_no_css("svg", visible: :all)
    expect(page).to have_no_css("#trajectory", visible: :all)
  end

  describe "the text alternative" do
    # The series is data, not decoration: a line is a picture of numbers and cannot be read by
    # anything that does not see.
    it "states every plotted figure as a table row" do
      render_series

      rows = page.all("details table tbody tr", visible: :all)
                 .map { |row| row.all("td", visible: :all).map { |cell| cell.text(:all) } }
      expect(rows).to eq([["aaaaaaa", "1,000", "3 days ago"],
                          ["bbbbbbb", "1,020", "2 days ago"],
                          ["ccccccc", "1,047", "1 day ago"]])
    end

    it "uses the caller's vocabulary for the columns" do
      render_series

      expect(page.all("details table thead th", visible: :all).map { |th| th.text(:all) })
        .to eq(["Run", "Tests in suite", "Ingested"])
    end

    # Not `sr-only`, and not CSS-hidden either. A native `<details>` is a real disclosure widget:
    # keyboard-operable, announced as one, and it needs no JavaScript — the same constraint the
    # chart itself is drawn under. What it must never be is content withheld from sight while
    # exposed to assistive technology, which would put the honest version of this panel behind a
    # screen reader.
    it "is a native disclosure open to everyone, not markup hidden from sight" do
      render_series

      expect(page).to have_css("details > summary", text: "Show the 3 plotted figures")
      expect(page).to have_no_css(".sr-only", visible: :all)
      expect(page).to have_no_css("[hidden]", visible: :all)
      expect(page.native.to_html).not_to include("display: none")
    end

    it "inflects the disclosure at two figures" do
      render_series(points: three_points.first(2))

      expect(page).to have_css("details summary", text: "Show the 2 plotted figures")
    end
  end

  describe "what the plot announces" do
    # The default treatment of an inline <svg> ranges from "graphic" with no name to the raw path
    # data read aloud, so the name is declared rather than left to the browser — and it points at
    # the same text a sighted reader gets, so the two cannot drift.
    #
    # Name and description are separate attributes rather than two ids on `aria-labelledby`. An
    # accessible name is announced in full and uninterrupted, so a ~60-word summary used as the name
    # sits unskippably between the reader and the table of figures below; as a description it is the
    # same sentence, reachable and passable.
    it "names itself from the visible label and describes itself from the visible summary" do
      render_series

      svg = page.find("svg")
      expect(svg[:role]).to eq("img")
      expect(svg["aria-labelledby"]).to eq("trajectory-label")
      expect(svg["aria-describedby"]).to eq("trajectory-summary")
      expect(page.find("#trajectory-label").text).to eq("Tests in suite on main")
      expect(page.find("#trajectory-summary").text)
        .to eq("The suite measured between 1,000 and 1,047 tests.")
    end

    # The id is a caller's argument rather than a generated one: non-deterministic markup is
    # markup no request spec can name.
    it "scopes its element ids to the id it was given" do
      render_series(id: "other-chart")

      expect(page).to have_css("#other-chart-label")
      expect(page).to have_css("#other-chart-summary")
    end

    it "carries the coverage beside the label, not only in the caption" do
      render_series

      expect(page).to have_text("3 of 4 runs plotted")
    end
  end

  it "appends caller classes to the wrapper instead of replacing them" do
    render_series(class: "mt-4")

    expect(page).to have_css("div#trajectory.mt-4.space-y-2")
  end

  # == The component holds no unit
  #
  # It used to name one in three places — an integer coercion, `number_with_delimiter`, and a
  # hard-coded `"test".pluralize` — while documenting itself as unit-agnostic. Each is a claim about
  # what is being plotted, and each is false of a series of seconds.
  describe "a series that is not a count of tests" do
    # 74.25 → 74.80 is a real 0.55s regression. Coerced to integers it is 74 → 74: a flat line,
    # which is the single shape that asserts the quantity did NOT move — and `flat?` copy on the
    # page would then say so in words.
    def duration_points
      [build_point("aaaaaaa", 74.25, "3 days ago"),
       build_point("bbbbbbb", 74.50, "2 days ago"),
       build_point("ccccccc", 74.80, "1 day ago")]
    end

    def render_durations(**overrides)
      render_series(points: duration_points,
                    formatter: ->(value) { "#{value.round(1)}s" },
                    point_formatter: nil,
                    columns: ["Run", "Wall clock", "Ingested"],
                    **overrides)
    end

    it "draws a sub-integer range as a slope rather than flattening it to a line" do
      render_durations

      ys = page.all("svg circle").map { |circle| circle[:cy].to_f }
      expect(ys.uniq.size).to eq(3)
      expect(ys.first).to be > ys[1]
      expect(ys[1]).to be > ys.last
    end

    # The same series through the OLD `to_i` coercion is 74, 74, 74 — a zero-width range, drawn
    # down the middle of the plot. Naming that value here is what makes the guard above fail if the
    # coercion ever comes back, rather than merely testing that three floats differ.
    it "does not park a moving series on the flat-line midpoint" do
      render_durations

      midpoint = described_class::VIEWBOX_HEIGHT / 2.0
      expect(page.all("svg circle").map { |circle| circle[:cy].to_f }).not_to include(midpoint)
    end

    it "announces markers in the caller's unit and never as a count of tests" do
      render_durations

      titles = page.all("svg circle title").map(&:text)
      expect(titles).to eq(["aaaaaaa — 74.3s — 3 days ago",
                            "bbbbbbb — 74.5s — 2 days ago",
                            "ccccccc — 74.8s — 1 day ago"])
      expect(titles.join).not_to include("test")
    end

    it "prints the axis bounds and the table cells in the caller's unit" do
      render_durations

      expect(page).to have_text("74.8s")
      expect(page).to have_text("74.3s")
      cells = page.all("details table tbody tr", visible: :all)
                  .map { |row| row.all("td", visible: :all)[1].text(:all) }
      expect(cells).to eq(["74.3s", "74.5s", "74.8s"])
    end

    # A figure that already carries its unit needs no second spelling, so a caller that supplies
    # only `formatter` — which is what the wall-clock series does — gets the same wording in the
    # marker as in the table. A caller whose figure does not carry its unit (`20,013`) passes both,
    # which is the suite-size shape every assertion above this block exercises.
    it "words a marker exactly as the table when the caller supplies no marker wording" do
      render_durations

      marker = page.all("svg circle title").map(&:text).first
      cell = page.all("details table tbody tr", visible: :all).first
                 .all("td", visible: :all)[1].text(:all)
      expect(marker).to include(cell)
      expect(marker).to eq("aaaaaaa — #{cell} — 3 days ago")
    end
  end
end
