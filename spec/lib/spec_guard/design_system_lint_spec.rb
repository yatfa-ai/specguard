# frozen_string_literal: true

require "rails_helper"
require "spec_guard/design_system_lint"
require "tmpdir"

RSpec.describe SpecGuard::DesignSystemLint do
  describe "the live application" do
    subject(:lint) { described_class.new(root: Rails.root) }

    # @intent: { entity: "SpecGuard::DesignSystemLint", action: "read baseline", behavior: "the live application baseline hash is zero on all three rules", layer: "unit" }
    it "sits at the frozen 0/0/0 baseline" do
      expect(lint.baseline).to eq("heading_sizes" => 0, "raw_palette_colors" => 0, "raw_btn" => 0)
    end

    # @intent: { entity: "SpecGuard::DesignSystemLint", action: "check drift", behavior: "the live application counts stay at the frozen 0/0/0 baseline so any offender reads as a regression", layer: "unit" }
    it "has no drift — SpecGuard is greenfield, so any offender is a regression" do
      expect(lint.counts).to eq("heading_sizes" => 0, "raw_palette_colors" => 0, "raw_btn" => 0),
                             -> { lint.report }
      expect(lint).to be_clean
    end
  end

  describe "the rules" do
    def counts_for(markup)
      Dir.mktmpdir do |dir|
        views = File.join(dir, "app/views/things")
        FileUtils.mkdir_p(views)
        File.write(File.join(views, "show.html.erb"), markup)

        described_class.new(root: dir).counts
      end
    end

    # @intent: { entity: "DesignSystemLint heading rule", action: "flag ad-hoc size", behavior: "a text-3xl heading increments the heading_sizes count", layer: "unit" }
    it "flags an ad-hoc heading size" do
      expect(counts_for(%(<h1 class="text-3xl font-bold">Hi</h1>))["heading_sizes"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint heading rule", action: "accept ramp", behavior: "a text-app-h1 heading leaves the heading_sizes count at zero", layer: "unit" }
    it "accepts the sanctioned type ramp" do
      expect(counts_for(%(<h1 class="text-app-h1">Hi</h1>))["heading_sizes"]).to eq(0)
    end

    # @intent: { entity: "DesignSystemLint palette rule", action: "flag raw colour", behavior: "raw Tailwind palette classes increment the raw_palette_colors count", layer: "unit" }
    it "flags a raw Tailwind palette colour" do
      expect(counts_for(%(<p class="text-gray-900 bg-red-500">Hi</p>))["raw_palette_colors"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint palette rule", action: "flag bare white", behavior: "a bare bg-white class increments the raw_palette_colors count", layer: "unit" }
    it "flags bare white/black" do
      expect(counts_for(%(<p class="bg-white">Hi</p>))["raw_palette_colors"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint palette rule", action: "accept tokens", behavior: "app-* token classes leave the raw_palette_colors count at zero", layer: "unit" }
    it "accepts app-* tokens" do
      expect(counts_for(%(<p class="text-app-content bg-app-surface">Hi</p>))["raw_palette_colors"]).to eq(0)
    end

    # @intent: { entity: "DesignSystemLint button rule", action: "flag raw btn", behavior: "a raw DaisyUI btn class increments the raw_btn count", layer: "unit" }
    it "flags a raw DaisyUI button" do
      expect(counts_for(%(<button class="btn btn-primary">Save</button>))["raw_btn"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint comment handling", action: "skip single-line comment", behavior: "banned tokens inside a single-line ERB comment are not counted", layer: "unit" }
    it "does not flag prose in a single-line comment" do
      expect(counts_for(%(<%# never use btn or text-3xl here %>))["raw_btn"]).to eq(0)
    end

    # `<%#` is on the opening line only. Every line through the closing `%>` used to read as
    # ordinary markup, so the sole difference between green and red was where the sentence wrapped.
    # All three rules fire independently depending on which token lands on a continuation line.
    context "when the comment wraps across lines" do
      # @intent: { entity: "DesignSystemLint comment handling", action: "skip wrapped comment heading", behavior: "an ad-hoc heading size on a comment continuation line is not counted", layer: "unit" }
      it "does not flag an ad-hoc heading size on a continuation line" do
        markup = <<~ERB
          <%# never use btn or
            text-3xl here %>
        ERB

        expect(counts_for(markup)["heading_sizes"]).to eq(0)
      end

      # @intent: { entity: "DesignSystemLint comment handling", action: "skip wrapped comment colour", behavior: "a raw palette colour on a comment continuation line is not counted", layer: "unit" }
      it "does not flag a raw palette colour on a continuation line" do
        markup = <<~ERB
          <%# never use raw colours like
            bg-white or text-slate-500 %>
        ERB

        expect(counts_for(markup)["raw_palette_colors"]).to eq(0)
      end

      # @intent: { entity: "DesignSystemLint comment handling", action: "skip wrapped comment button", behavior: "a raw btn token on a comment continuation line is not counted", layer: "unit" }
      it "does not flag a raw DaisyUI button on a continuation line" do
        markup = <<~ERB
          <%# Raw DaisyUI
            btn is forbidden — use the button component %>
        ERB

        expect(counts_for(markup)["raw_btn"]).to eq(0)
      end

      # @intent: { entity: "DesignSystemLint comment handling", action: "count after comment", behavior: "a real offender on the line after a comment close still increments the count", layer: "unit" }
      it "still counts a real offender on the line after the closing %>" do
        markup = <<~ERB
          <%# note
            more %>
          <a class="btn">x</a>
        ERB

        expect(counts_for(markup)["raw_btn"]).to eq(1)
      end

      # @intent: { entity: "DesignSystemLint comment handling", action: "count later in file", behavior: "a real offender further down the same file past a comment still increments the count", layer: "unit" }
      it "still counts a real offender inside the same file, further down" do
        markup = <<~ERB
          <%# never use
            btn %>
          <p>fine</p>
          <h1 class="text-3xl">Hi</h1>
        ERB

        expect(counts_for(markup)["heading_sizes"]).to eq(1)
      end

      # The comment in a.html.erb is deliberately clean, so the only way this count can move is
      # the open-comment state surviving into b.html.erb and swallowing a real offender.
      # @intent: { entity: "DesignSystemLint comment handling", action: "isolate comment state per file", behavior: "an unterminated comment in one file does not swallow an offender in the next scanned file", layer: "unit" }
      it "does not let an unterminated comment leak into the next file" do
        Dir.mktmpdir do |dir|
          views = File.join(dir, "app/views/things")
          FileUtils.mkdir_p(views)
          File.write(File.join(views, "a.html.erb"), "<%# unterminated, no closing marker\n  and no banned token\n")
          File.write(File.join(views, "b.html.erb"), %(<a class="btn">x</a>))

          expect(described_class.new(root: dir).counts["raw_btn"]).to eq(1)
        end
      end
    end
  end

  # Every example in "the rules" writes `app/views/things/show.html.erb` — glob #1 of the four in
  # SCAN_GLOBS. The other three mutate freely under that suite, and the live-application example
  # above cannot catch them either: it asserts 0/0/0 on a greenfield app, so "found nothing" and
  # "did not look" are the same reading. These examples pin the remaining three globs with a
  # NON-zero assertion, so deleting any of them from SCAN_GLOBS turns this file red.
  #
  # This is load-bearing beyond this spec: `spec/components/ui/copyable_code_component_spec.rb`
  # declines to assert raw-palette colours on the record, because "SCAN_GLOBS already covers
  # app/components/**/*.rb". That delegation is only sound while glob #3 is pinned here.
  describe "the scan scope" do
    # Deliberately NOT `counts_for` — that helper hard-codes glob #1, which is the whole gap.
    def counts_at(relative_path, source)
      Dir.mktmpdir do |dir|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)

        described_class.new(root: dir).counts
      end
    end

    # @intent: { entity: "DesignSystemLint scan scope", action: "scan component templates", behavior: "an offender inside app/components html.erb templates is counted", layer: "unit" }
    it "scans component templates — app/components/**/*.html.erb" do
      counts = counts_at("app/components/ui/button_preview.html.erb", %(<button class="btn btn-primary">Save</button>))

      expect(counts["raw_btn"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint scan scope", action: "scan component classes", behavior: "an offender inside app/components ruby files is counted", layer: "unit" }
    it "scans component classes — app/components/**/*.rb" do
      counts = counts_at("app/components/ui/copyable_code_component.rb", %(def call = tag.a("x", class: "btn")))

      expect(counts["raw_btn"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint scan scope", action: "scan helpers", behavior: "an offender inside app/helpers ruby files is counted", layer: "unit" }
    it "scans helpers — app/helpers/**/*.rb" do
      counts = counts_at("app/helpers/things_helper.rb", %(def cta = link_to("x", "/", class: "btn")))

      expect(counts["raw_btn"]).to eq(1)
    end

    # @intent: { entity: "DesignSystemLint scan scope", action: "scan views", behavior: "an offender inside app/views html.erb templates is counted", layer: "unit" }
    it "scans view templates — app/views/**/*.html.erb" do
      counts = counts_at("app/views/things/show.html.erb", %(<a class="btn">x</a>))

      expect(counts["raw_btn"]).to eq(1)
    end

    # Negative control: without this, the three assertions above would also pass under a
    # SCAN_GLOBS that swept the entire tree, and they would be pinning "scans everything"
    # rather than "scans these four globs".
    # @intent: { entity: "DesignSystemLint scan scope", action: "exclude undeclared paths", behavior: "a banned token in app/models is not counted anywhere", layer: "unit" }
    it "does not scan outside the declared globs" do
      counts = counts_at("app/models/thing.rb", %(BUTTON = "btn text-3xl bg-white"))

      expect(counts).to eq("heading_sizes" => 0, "raw_palette_colors" => 0, "raw_btn" => 0)
    end
  end

  # No example anywhere drove a `.rb` file before the scan-scope block above, so the `.rb` side of
  # `comment?` was unexercised. The ERB side is covered by "when the comment wraps across lines";
  # `.rb` needs its own pins because `#` — unlike `<%#` — is line-initial on every comment line,
  # which is exactly the assumption the implementation states at design_system_lint.rb:170-171.
  describe "comment handling in .rb files" do
    def rb_counts(source)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/helpers"))
        File.write(File.join(dir, "app/helpers/things_helper.rb"), source)

        described_class.new(root: dir).counts
      end
    end

    # @intent: { entity: "DesignSystemLint rb comments", action: "skip line-initial comment", behavior: "prose in a line-initial ruby comment is not counted on any rule", layer: "unit" }
    it "does not flag prose in a line-initial comment" do
      expect(rb_counts("# never use btn or text-3xl or bg-white here\n")).to(
        eq("heading_sizes" => 0, "raw_palette_colors" => 0, "raw_btn" => 0)
      )
    end

    # @intent: { entity: "DesignSystemLint rb comments", action: "skip indented comment", behavior: "prose in an indented line-initial ruby comment is not counted", layer: "unit" }
    it "does not flag prose in an indented line-initial comment" do
      expect(rb_counts("module Things\n  # never use btn here\nend\n")["raw_btn"]).to eq(0)
    end

    # @intent: { entity: "DesignSystemLint rb comments", action: "flag ruby offender", behavior: "a banned token in ruby code increments the raw_btn count", layer: "unit" }
    it "flags a real offender in a .rb file" do
      expect(rb_counts(%(def cta = tag.a("x", class: "btn")\n))["raw_btn"]).to eq(1)
    end

    # PINNED AS IT SHIPS: a trailing `#` comment IS scanned, so prose after code counts as an
    # offender. `comment?` is anchored (`\A\s*#`), so only a WHOLE-line comment is skipped.
    #
    # Mechanically this is the same line-initial-only rule that
    # `spec/components/caller_class_consumption_spec.rb:165-167` applies to its own sweep, but the
    # two sweeps want opposite things from it: there, keeping a trailing-comment line is what stops
    # real code being skipped; here, it is what makes prose count against a shrink-only 0/0/0 gate.
    # Recorded rather than fixed — changing it is a production decision, not a test one.
    # @intent: { entity: "DesignSystemLint rb comments", action: "count trailing comment", behavior: "a banned token after code on the same line counts as an offender, false positive pinned as shipped", layer: "unit" }
    it "flags a banned token in a trailing comment (false positive, pinned deliberately)" do
      expect(rb_counts("def x = 1 # never use btn here\n")["raw_btn"]).to eq(1)
    end
  end

  describe "the baseline" do
    # @intent: { entity: "DesignSystemLint baseline", action: "rewrite baseline", behavior: "update_baseline writes the current smaller count rather than preserving the stored larger one", layer: "unit" }
    it "is shrink-only by default" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config/lint"))
        File.write(File.join(dir, described_class::BASELINE_PATH), "raw_btn: 5\n")
        FileUtils.mkdir_p(File.join(dir, "app/views/things"))
        File.write(File.join(dir, "app/views/things/show.html.erb"), %(<a class="btn">x</a>))

        written = described_class.new(root: dir).update_baseline!

        expect(written["raw_btn"]).to eq(1)
      end
    end

    # @intent: { entity: "DesignSystemLint baseline", action: "report regression", behavior: "a count above the stored baseline marks the lint dirty and names the rule, count and baseline", layer: "unit" }
    it "reports growth past the baseline as a regression" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/views/things"))
        File.write(File.join(dir, "app/views/things/show.html.erb"), %(<a class="btn">x</a>))

        lint = described_class.new(root: dir)

        expect(lint).not_to be_clean
        expect(lint.regressions.first).to include(rule: "raw_btn", count: 1, baseline: 0)
      end
    end
  end
end
