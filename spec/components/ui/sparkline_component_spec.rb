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

  def render_series(points: three_points, **overrides)
    render_inline(described_class.new(**{
      id: "trajectory",
      points: points,
      label: "Tests in suite on main",
      coverage: "3 of 4 runs plotted",
      summary: "The suite measured between 1,000 and 1,047 tests.",
      columns: ["Run", "Tests in suite", "Ingested"]
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
end
