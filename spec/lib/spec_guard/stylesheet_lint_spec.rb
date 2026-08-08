# frozen_string_literal: true

require "rails_helper"
require "spec_guard/stylesheet_lint"
require "tmpdir"

# A stand-in for npm + the Tailwind CLI: it writes whatever the "sources" would have produced to
# the path it is handed, and records that path. The path is the whole point — a builder that
# ignored it and wrote to the committed file is exactly the regression being guarded.
module StylesheetLintSpecSupport
  class RecordingBuilder
    attr_reader :outputs

    def initialize(produces:, available: true)
      @produces = produces
      @available = available
      @outputs = []
    end

    def available? = @available

    def build(output_path)
      @outputs << output_path
      File.write(output_path, @produces)
    end
  end
end

RSpec.describe SpecGuard::StylesheetLint do
  def fake_builder(produces:, available: true)
    StylesheetLintSpecSupport::RecordingBuilder.new(produces: produces, available: available)
  end

  def with_committed(css)
    Dir.mktmpdir do |root|
      path = File.join(root, described_class::BUILT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, css) unless css.nil?

      yield root, path
    end
  end

  it "is driven through the same interface the real Tailwind builder implements" do
    real = described_class::TailwindBuilder.new
    fake = fake_builder(produces: "")

    expect(real).to respond_to(:available?)
    expect(real.method(:build).arity).to eq(fake.method(:build).arity)
  end

  describe "the verdict" do
    it "is current when the sources produce exactly the committed stylesheet" do
      with_committed(".font-medium{font-weight:500}") do |root|
        result = described_class.new(root: root, builder: fake_builder(produces: ".font-medium{font-weight:500}")).call

        expect(result).to be_current
        expect(result).not_to be_failed
      end
    end

    it "is stale when the sources produce a rule the committed stylesheet is missing" do
      with_committed(".gap-x-1\\.5{column-gap:6px}") do |root|
        produced = ".gap-x-1\\.5{column-gap:6px}.font-medium{font-weight:500}"
        result = described_class.new(root: root, builder: fake_builder(produces: produced)).call

        expect(result).to be_stale
        expect(result).to be_failed
      end
    end

    it "is stale on a byte difference the minified one-line diff stat would flatten" do
      with_committed("a{color:red}") do |root|
        result = described_class.new(root: root, builder: fake_builder(produces: "a{color:blue}")).call

        expect(result).to be_stale
      end
    end

    it "is stale when the committed stylesheet is missing entirely" do
      with_committed(nil) do |root|
        result = described_class.new(root: root, builder: fake_builder(produces: "a{color:red}")).call

        expect(result).to be_stale
      end
    end

    it "is skipped — not failed — when npm cannot resolve DaisyUI here" do
      with_committed("stale and wrong, but unjudgeable without a toolchain") do |root|
        builder = fake_builder(produces: "something else entirely", available: false)
        result = described_class.new(root: root, builder: builder).call

        expect(result).to be_skipped
        expect(result).not_to be_failed
        expect(builder.outputs).to be_empty
      end
    end
  end

  # The reason this class exists. The previous gate shelled out to `tailwindcss:build`, whose output
  # path is hard-coded to the committed file, so every run — pass or fail — left an unstaged
  # modification for the next ticket to trip over.
  describe "the working tree" do
    it "leaves the committed stylesheet untouched when it is current" do
      with_committed("a{color:red}") do |root, path|
        described_class.new(root: root, builder: fake_builder(produces: "a{color:red}")).call

        expect(File.read(path)).to eq("a{color:red}")
      end
    end

    it "leaves the committed stylesheet untouched when it is stale" do
      with_committed("a{color:red}") do |root, path|
        described_class.new(root: root, builder: fake_builder(produces: "a{color:blue}")).call

        expect(File.read(path)).to eq("a{color:red}")
      end
    end

    it "builds to a temp path outside the project, never to the committed file" do
      with_committed("a{color:red}") do |root, path|
        builder = fake_builder(produces: "a{color:blue}")
        described_class.new(root: root, builder: builder).call

        expect(builder.outputs.size).to eq(1)
        expect(builder.outputs.first).not_to eq(path)
        expect(builder.outputs.first).not_to start_with(root)
      end
    end

    it "cleans up the temp build so repeated runs do not accumulate stylesheets" do
      with_committed("a{color:red}") do |root|
        builder = fake_builder(produces: "a{color:red}")
        described_class.new(root: root, builder: builder).call

        expect(File).not_to exist(builder.outputs.first)
      end
    end

    it "is idempotent — a second run sees the same verdict and the same file" do
      with_committed("a{color:red}") do |root, path|
        lint = described_class.new(root: root, builder: fake_builder(produces: "a{color:red}"))

        expect(lint.call).to be_current
        expect(lint.call).to be_current
        expect(File.read(path)).to eq("a{color:red}")
      end
    end
  end

  describe "the abort message" do
    it "names the file, the fix, and warns off the misleading diff stat" do
      with_committed("a{color:red}") do |root|
        message = described_class.new(root: root, builder: fake_builder(produces: "a{color:blue}")).call.message

        expect(message).to include(described_class::BUILT_PATH)
        expect(message).to include("npm install && bin/rails tailwindcss:build")
        expect(message).to include("grep -c -F")
      end
    end
  end

  # The live artifact. `bin/rails lint:stylesheet` is the authoritative check (it actually runs
  # Tailwind), but it needs npm and several seconds; these assert the part of its verdict that the
  # suite can afford — that utilities live markup depends on are present in what ships.
  describe "the committed stylesheet" do
    subject(:css) { Rails.root.join(described_class::BUILT_PATH).read }

    it "exists, so a Node-free clone can boot" do
      expect(Rails.root.join(described_class::BUILT_PATH)).to exist
    end

    {
      "font-medium" => ".font-medium{",
      "gap-x-1.5" => ".gap-x-1\\.5{"
    }.each do |utility, rule|
      it "ships a rule for `#{utility}`, which app/views/repositories/show.html.erb applies" do
        markup = Rails.root.join("app/views/repositories/show.html.erb").read

        expect(markup).to match(/class="[^"]*(?<![-\w])#{Regexp.escape(utility)}(?![-\w])/),
                          "precondition: no live markup uses #{utility} any more — retire this example"
        expect(css).to include(rule)
      end
    end
  end
end
