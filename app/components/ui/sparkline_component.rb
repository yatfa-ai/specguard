# frozen_string_literal: true

# A server-rendered inline-SVG trajectory: one line through a short series of figures, with the
# same figures available as text.
#
# == Why inline SVG and no JavaScript
#
# `package.json` devDependencies is `daisyui` alone and `config/importmap.rb` pins only
# stimulus/turbo, so a charting library is out of bounds — and it would be the wrong answer anyway.
# The whole series is already loaded server-side by the time the page renders, so there is nothing
# for a client library to fetch and nothing to hydrate; drawing the path in ERB keeps the chart
# inside the design-system gate (`SpecGuard::DesignSystemLint` scans `app/components/**`, which a
# canvas painted by a bundled library would sit outside of) and keeps it visible with scripting off.
#
# == The chart is data, so the figures are text too
#
# A line is a picture of numbers and cannot be read by anything that does not see. Every point is
# therefore also a row of a real table — disclosed, not visually hidden, because a keyboard user
# who wants the numbers and a screen-reader user who needs them want exactly the same thing. The
# `<svg>` itself is `role="img"`, named from the visible label and described by the visible
# summary, rather than announcing its own path data.
#
# == The vertical axis does not start at zero, and says so
#
# A suite of 20,000 that grew by 47 is a flat line on a zero-based axis — the change this exists to
# show, rendered as no change. So the axis spans the series' own minimum to its own maximum, and
# both bounds are printed beside the plot. The slope is then a picture of the change and NOT of its
# share of the suite, which is a different claim; the caller's caption is where that gets said in
# words.
class UI::SparklineComponent < ApplicationComponent
  # A point of the series. `label` identifies it (a short SHA), `value` is the figure plotted, and
  # `detail` is what else the text alternative and the hover title say about it (an age).
  Point = Struct.new(:label, :value, :detail, keyword_init: true)

  # Chart-space units, not pixels. The `<svg>` is rendered `w-full h-auto` with the default
  # `preserveAspectRatio`, so this fixes the aspect ratio and the browser does the scaling — no
  # distortion of the stroke, and no dependence on knowing the container's width server-side.
  VIEWBOX_WIDTH = 600
  VIEWBOX_HEIGHT = 140
  # Enough room that a marker sitting on the series' own minimum or maximum is not clipped in half
  # by the viewBox edge.
  PADDING_X = 8
  PADDING_Y = 10
  MARKER_RADIUS = 3

  # `id` is required rather than generated. The `<svg>` has to reference its label and summary by
  # id for `aria-labelledby`/`aria-describedby`, and a generated one would make the markup
  # non-deterministic — which is exactly the thing a request spec has to be able to name.
  #
  # `columns` are the three headings of the text alternative, in the caller's own vocabulary: this
  # component knows it is drawing "points", and the page knows they are runs.
  #
  # == Why the unit is a caller's argument and not a default
  #
  # This class documents itself as unit-agnostic above and then used to name the unit in three
  # places — an integer coercion, `number_with_delimiter`, and a hard-coded `"test".pluralize`. Each
  # is a claim about what is being plotted, and every one of them is false of a series of seconds: a
  # cohort moving 74.25s → 74.80s coerces to a flat line, which is the single shape that asserts a
  # quantity did not move.
  #
  # So `formatter` is REQUIRED rather than defaulted to the suite-size wording. A default is the
  # opinion kept, moved one line down: the next caller plotting something else inherits "tests"
  # silently and only finds out by reading the rendered page. Required, the component holds no unit
  # at all — the same way `columns:` already refuses to know that its points are runs.
  #
  # `formatter` is the figure ALONE, because the two places it is used both sit under a heading that
  # names the unit: the axis bounds beside `label`, and the table cells under `columns`. A marker's
  # `<title>` floats free of both, so it gets `point_formatter` and names its own unit. That defaults
  # to `formatter` — not to a unit word — because a figure that already carries its unit (`1m 14s`)
  # needs no second spelling, and a caller whose figure does not (`20,013`) says so once.
  def initialize(id:, points:, label:, coverage:, summary:, columns:, formatter:,
                 point_formatter: nil, **options)
    @id = id
    @points = Array(points)
    @label = label
    @coverage = coverage
    @summary = summary
    @columns = columns
    @formatter = formatter
    @point_formatter = point_formatter || formatter
    @options = options
    super
  end

  attr_reader :id, :points, :label, :coverage, :summary, :columns, :formatter, :point_formatter

  # Two points or nothing. One point drawn as a line is a FLAT line, which is a picture of a suite
  # that was measured twice and did not move — a claim a single measurement cannot support.
  #
  # A backstop and not the message: rendering nothing is honest but says nothing, so a caller owes
  # its reader an explicit "not enough comparable runs yet" of its own rather than relying on this
  # to fall silent. See `repositories/show`.
  def render? = points.size >= 2

  def label_id = "#{id}-label"

  def summary_id = "#{id}-summary"

  # The plotted figures as they were handed over — no coercion. `to_i` here was the unit opinion in
  # its most damaging form: it is invisible on a series of test counts, which are already integers,
  # and on a series of seconds it silently discards the whole range a runtime chart exists to show.
  # 74.25 → 74.80 is a slope; 74 → 74 is a flat line, and `flat?` copy would then assert the
  # quantity "has not moved" over a real regression.
  def values = points.map(&:value)

  def minimum = values.min

  def maximum = values.max

  # `M x,y L x,y …` through every point.
  def line_path
    coordinates.map.with_index { |(x, y), index| "#{index.zero? ? "M" : "L"}#{x},#{y}" }.join(" ")
  end

  # The same line closed down to the floor of the plot, so the area beneath it can be tinted. The
  # tint is decoration — it carries no second figure — which is why it is drawn from the same
  # coordinates rather than from a second pass over the data.
  def area_path
    floor = VIEWBOX_HEIGHT - PADDING_Y
    "#{line_path} L#{coordinates.last.first},#{floor} L#{coordinates.first.first},#{floor} Z"
  end

  def coordinates
    @coordinates ||= points.each_with_index.map { |point, index| [x_for(index), y_for(point.value)] }
  end

  # The figure as the axis bounds and the table cells state it — both under a heading that names
  # the unit, so this is the number and nothing else. The table cells reach it through `#tabulated`
  # rather than directly, which adds to this and never rewords it.
  def formatted(value) = formatter.call(value)

  # The figure as the TEXT ALTERNATIVE states it: the wording, plus the plotted value itself on the
  # rows whose wording cannot tell them apart from another point on the same line.
  #
  # == The equivalence this exists to keep
  #
  # The table is not a caption for the chart, it is the chart — the half a reader who cannot see the
  # line has to work from, which is the whole argument two sections up. That equivalence holds only
  # while `formatter` maps distinct plotted values to distinct strings, and one caller's does not:
  # `TestRun#duration_label` keeps the tenth below a minute and drops it at a minute and above, so a
  # cohort moving 74.25s → 74.30s is two `cy` values and a visible slope on the line, and `1m 14s`
  # printed twice underneath it. The picture says the wait moved and the text says it did not, and
  # only the reader who can see the picture is told the truth. `#values` refuses to coerce for
  # exactly this movement; losing it one row further down is the same defect wearing the other half.
  #
  # == Why the disclosure lands here and not in the wording
  #
  # Because the wording is single-sourced on purpose. That lambda reaches the page four times — the
  # axis bounds, the caller's summary sentence, this cell, and the marker `<title>` — so widening it
  # re-prints three figures at a precision nothing else on the page uses in order to separate a pair
  # of rows. This changes exactly one of the four.
  #
  # NOT because the other three keep the figure — they do not. Rendered against the 74.25s/74.30s
  # pair, the axis bounds read `1m 14s` twice, both markers' `<title>`s read `1m 14s`, and the
  # caller's sentence reads "between 1m 14s and 1m 14s". All four collapse the pair; do not read
  # this comment as saying the other three were checked and found lossless.
  #
  # The table is the one that MAY NOT collapse it. The other three annotate a plot the reader is
  # looking at, and a bound or a hover title a tenth coarser than the line beneath it is a rounded
  # caption on a picture that still carries the movement. The table has no picture behind it — for
  # the reader who cannot see the line it IS the chart, which is the equivalence stated in the
  # section above — so the same rounding there is not a coarse caption but the finding deleted.
  # Same loss, different contract; the contract is what decides the site.
  #
  # Disclosed as VISIBLE text, not as `title`/`data`/`aria`. Each of those reaches a hovering mouse,
  # or a screen reader, or a parser — none reaches all three, and a keyboard reader none of them.
  # An accessibility gap is not closed by moving it to a different reader.
  #
  # And the plotted value verbatim rather than formatted again: a format is an opinion about the
  # unit, this component holds none by construction, and a second wording of the same float is the
  # drift a single formatting seam exists to prevent. This is the number the chart was handed,
  # printed as it was handed over — decimals and all. `74.30` reaches Ruby as the Float `74.3` and
  # discloses as `74.3`, so a column of these sits ragged under `tabular-nums`. That is not a bug to
  # pad out: a fixed number of decimal places is a claim about the precision of the measurement,
  # which is exactly the unit opinion this component holds none of.
  def tabulated(value)
    wording = formatted(value)
    return wording unless ambiguous_wordings.include?(wording)

    "#{wording} (#{value})"
  end

  # What one marker announces on hover. The text alternative below carries the same three facts as
  # a row, so this is a convenience and never the only place a figure appears.
  #
  # `point_formatter` and not `formatted`: a `<title>` is read on its own, with neither the label
  # above the plot nor the column heading below it in reach, so the figure here has to name its own
  # unit. Which unit that is, is the caller's to say.
  def point_title(point)
    [point.label, point_formatter.call(point.value), point.detail].compact_blank.join(" — ")
  end

  def wrapper_class = @wrapper_class ||= merge_classes("space-y-2", @options.delete(:class))

  private

  # The wordings that more than one DISTINCT plotted value collapses onto. Memoised because the
  # text alternative asks once per row and the answer is a property of the series, not of the row.
  #
  # Distinct, and that is the load-bearing word. Two runs that measured the SAME figure are not an
  # ambiguity to resolve: the line draws them at one height deliberately, so one wording repeated is
  # the truth about them, and a float disclosed beside it would be noise printed to separate two
  # things that are not different. Hence `.uniq` — the grouping is over the values the series holds,
  # not over its points.
  def ambiguous_wordings
    @ambiguous_wordings ||= values.uniq
                                  .group_by { |value| formatted(value) }
                                  .filter_map { |wording, sharing| wording if sharing.size > 1 }
  end

  def x_for(index)
    span = VIEWBOX_WIDTH - (2 * PADDING_X)
    (PADDING_X + (index.to_f / (points.size - 1) * span)).round(2)
  end

  # A series whose runs all measured the same suite has no range to scale against, and dividing by
  # that range would be dividing by zero. It draws down the middle instead — a true flat line, which
  # is what a suite that did not move looks like. Distinct from the one-point case `render?`
  # refuses: this one was measured across comparable runs.
  def y_for(value)
    plot_height = VIEWBOX_HEIGHT - (2 * PADDING_Y)
    range = maximum - minimum
    return (VIEWBOX_HEIGHT / 2.0).round(2) if range.zero?

    (VIEWBOX_HEIGHT - PADDING_Y - ((value - minimum).to_f / range * plot_height)).round(2)
  end
end
