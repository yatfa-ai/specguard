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

    it "does not flag prose in a comment" do
      expect(counts_for(%(<%# never use btn or text-3xl here %>))["raw_btn"]).to eq(0)
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
