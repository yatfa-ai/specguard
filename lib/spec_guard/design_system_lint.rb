# frozen_string_literal: true

require "yaml"

module SpecGuard
  # Design-system drift lint — ported from `Yatfa::DesignSystemLint`; the behaviour is identical,
  # only the namespace changed.
  #
  # It is a deliberately pragmatic grep over the signed-in view templates and the component
  # library, with a **shrink-only** baseline: CI fails the moment a live offender count grows past
  # the frozen number, and `rake lint:design_system:update_baseline` will only ever write a
  # smaller number back (pass FORCE=1 to accept growth — a visible baseline diff a reviewer has
  # to sign off on).
  #
  # SpecGuard is greenfield, so the baseline starts at 0/0/0. There is no legacy to grandfather:
  # any offender is a regression that fails CI from day one.
  class DesignSystemLint
    BASELINE_PATH = "config/lint/design_system_drift_baseline.yml"

    SCAN_GLOBS = [
      "app/views/**/*.html.erb",
      "app/components/**/*.html.erb",
      "app/components/**/*.rb",
      "app/helpers/**/*.rb"
    ].freeze

    PALETTE_FAMILIES = %w[
      slate gray zinc neutral stone red orange amber yellow lime green emerald teal cyan sky
      blue indigo violet purple fuchsia pink rose
    ].freeze

    COLOR_PREFIXES = %w[bg text border ring divide outline fill stroke from via to shadow decoration accent caret].freeze

    RULES = {
      # Ad-hoc heading sizes instead of the sanctioned 4-step ramp.
      "heading_sizes" => {
        pattern: /(?<![-\w])text-(?:xl|2xl|3xl|4xl|5xl|6xl)(?![-\w])/,
        fix: "use text-app-h1..h4 / UI::HeadingComponent / UI::PageHeaderComponent"
      },
      # Raw Tailwind palette colours instead of the app-* token system.
      "raw_palette_colors" => {
        pattern: Regexp.union(
          /(?<![-\w])(?:#{COLOR_PREFIXES.join("|")})-(?:#{PALETTE_FAMILIES.join("|")})-\d{2,3}(?![-\w])/,
          /(?<![-\w])(?:bg|text|border|ring|divide|fill|stroke)-(?:white|black)(?![-\w])/
        ),
        fix: "use the app-* token system (text-app-content, bg-app-surface, text-app-error, …)"
      },
      # Raw DaisyUI buttons instead of the component.
      "raw_btn" => {
        pattern: /(?<![-\w])btn(?:-[a-z]+)*(?![-\w])/,
        fix: "use UI::ButtonComponent (or UI::ButtonComponent.classes for button_to)"
      }
    }.freeze

    Offense = Struct.new(:rule, :path, :line_number, :snippet, keyword_init: true) do
      def to_s = "#{path}:#{line_number}  #{snippet.strip}"
    end

    def initialize(root: Dir.pwd)
      @root = Pathname.new(root)
    end

    attr_reader :root

    # => { "heading_sizes" => [Offense, …], … } — every rule key is always present.
    def offenses
      @offenses ||= begin
        found = RULES.keys.to_h { |rule| [rule, []] }

        scanned_files.each do |path|
          relative = path.relative_path_from(root).to_s

          path.readlines.each_with_index do |line, index|
            next if comment?(line)

            RULES.each do |rule, config|
              next unless line.match?(config[:pattern])

              found[rule] << Offense.new(rule: rule, path: relative, line_number: index + 1, snippet: line)
            end
          end
        end

        found
      end
    end

    def counts
      offenses.transform_values(&:size)
    end

    def baseline
      @baseline ||= begin
        file = root.join(BASELINE_PATH)
        loaded = file.exist? ? (YAML.safe_load_file(file) || {}) : {}
        RULES.keys.to_h { |rule| [rule, (loaded[rule] || 0).to_i] }
      end
    end

    # Rules whose live count has grown past the frozen baseline.
    def regressions
      counts.filter_map do |rule, count|
        next if count <= baseline.fetch(rule, 0)

        { rule: rule, count: count, baseline: baseline.fetch(rule, 0), fix: RULES.dig(rule, :fix) }
      end
    end

    def clean?
      regressions.empty?
    end

    # Writes `counts` back to the baseline file. Shrink-only unless `force:` is set — a growing
    # baseline must be a deliberate, reviewable diff.
    def update_baseline!(force: false)
      next_baseline = counts.to_h do |rule, count|
        frozen = baseline.fetch(rule, 0)
        [rule, force ? count : [count, frozen].min]
      end

      file = root.join(BASELINE_PATH)
      file.dirname.mkpath
      file.write(<<~YAML)
        # Design-system drift baseline — SHRINK-ONLY.
        #
        # Each number is the maximum tolerated count of live offenders for that rule. CI fails
        # when a live count grows past it. Regenerate with:
        #
        #   bin/rails lint:design_system:update_baseline
        #
        # which only ever writes a SMALLER number. FORCE=1 accepts growth, and the resulting
        # diff is something a reviewer has to sign off on.
        #
        # SpecGuard is greenfield: the baseline is 0/0/0 and should stay there.
        #{next_baseline.to_yaml.sub(/\A---\n/, "").chomp}
      YAML

      next_baseline
    end

    def report
      lines = ["Design-system drift lint"]

      counts.each do |rule, count|
        frozen = baseline.fetch(rule, 0)
        status = count > frozen ? "REGRESSION" : (count < frozen ? "improved" : "ok")
        lines << format("  %-20s %3d (baseline %d) %s", rule, count, frozen, status)
      end

      regressions.each do |regression|
        lines << ""
        lines << "#{regression[:rule]}: #{regression[:count]} offender(s), baseline #{regression[:baseline]}"
        lines << "  fix: #{regression[:fix]}"
        offenses[regression[:rule]].each { |offense| lines << "  #{offense}" }
      end

      lines.join("\n")
    end

    private

    # Prose about the rules is not a violation of them — a comment explaining why raw `btn` is
    # banned must not itself count as raw `btn`.
    COMMENT_LINE = %r{\A\s*(?:#|<%#|/\*|\*)}

    def comment?(line)
      line.match?(COMMENT_LINE)
    end

    def scanned_files
      SCAN_GLOBS.flat_map { |glob| Pathname.glob(root.join(glob)) }.uniq.sort
    end
  end
end
