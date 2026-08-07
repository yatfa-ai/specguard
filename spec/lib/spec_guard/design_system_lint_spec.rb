# frozen_string_literal: true

require "rails_helper"
require "spec_guard/design_system_lint"
require "tmpdir"

RSpec.describe SpecGuard::DesignSystemLint do
  describe "the live application" do
    subject(:lint) { described_class.new(root: Rails.root) }

    it "sits at the frozen 0/0/0 baseline" do
      expect(lint.baseline).to eq("heading_sizes" => 0, "raw_palette_colors" => 0, "raw_btn" => 0)
    end

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

    it "flags an ad-hoc heading size" do
      expect(counts_for(%(<h1 class="text-3xl font-bold">Hi</h1>))["heading_sizes"]).to eq(1)
    end

    it "accepts the sanctioned type ramp" do
      expect(counts_for(%(<h1 class="text-app-h1">Hi</h1>))["heading_sizes"]).to eq(0)
    end

    it "flags a raw Tailwind palette colour" do
      expect(counts_for(%(<p class="text-gray-900 bg-red-500">Hi</p>))["raw_palette_colors"]).to eq(1)
    end

    it "flags bare white/black" do
      expect(counts_for(%(<p class="bg-white">Hi</p>))["raw_palette_colors"]).to eq(1)
    end

    it "accepts app-* tokens" do
      expect(counts_for(%(<p class="text-app-content bg-app-surface">Hi</p>))["raw_palette_colors"]).to eq(0)
    end

    it "flags a raw DaisyUI button" do
      expect(counts_for(%(<button class="btn btn-primary">Save</button>))["raw_btn"]).to eq(1)
    end

    it "does not flag prose in a single-line comment" do
      expect(counts_for(%(<%# never use btn or text-3xl here %>))["raw_btn"]).to eq(0)
    end

    # `<%#` is on the opening line only. Every line through the closing `%>` used to read as
    # ordinary markup, so the sole difference between green and red was where the sentence wrapped.
    # All three rules fire independently depending on which token lands on a continuation line.
    context "when the comment wraps across lines" do
      it "does not flag an ad-hoc heading size on a continuation line" do
        markup = <<~ERB
          <%# never use btn or
            text-3xl here %>
        ERB

        expect(counts_for(markup)["heading_sizes"]).to eq(0)
      end

      it "does not flag a raw palette colour on a continuation line" do
        markup = <<~ERB
          <%# never use raw colours like
            bg-white or text-slate-500 %>
        ERB

        expect(counts_for(markup)["raw_palette_colors"]).to eq(0)
      end

      it "does not flag a raw DaisyUI button on a continuation line" do
        markup = <<~ERB
          <%# Raw DaisyUI
            btn is forbidden — use the button component %>
        ERB

        expect(counts_for(markup)["raw_btn"]).to eq(0)
      end

      it "still counts a real offender on the line after the closing %>" do
        markup = <<~ERB
          <%# note
            more %>
          <a class="btn">x</a>
        ERB

        expect(counts_for(markup)["raw_btn"]).to eq(1)
      end

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

  describe "the baseline" do
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
