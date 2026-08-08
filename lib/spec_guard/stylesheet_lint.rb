# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"

module SpecGuard
  # Guards the committed `app/assets/builds/tailwind.css`.
  #
  # That file is a build artifact that is nevertheless committed (see the README) so a
  # Node-free clone can boot — Propshaft raises on a missing stylesheet. The cost of committing a
  # build artifact is that it can drift from its sources, shipping markup whose utilities were
  # never compiled. This lint is what makes the drift loud.
  #
  # **The build must not touch the committed file.** An earlier version of this check ran
  # `bin/rails tailwindcss:build` (which hard-codes its output to `app/assets/builds/tailwind.css`)
  # and then diffed the working tree. That made the lint *mutate the thing it lints*: every run
  # left an unstaged modification behind, which then rode into unrelated commits and collided with
  # `git stash pop`. So the fresh stylesheet is built to a temp path and compared byte-for-byte
  # against the committed one, and the committed one is only ever read.
  #
  # The comparison is byte-for-byte on purpose. The built CSS is minified onto a single line, so
  # `git diff --stat` reports "1 insertion, 1 deletion" no matter how many rules changed — there is
  # no cheap partial comparison to be had, and a line-oriented one would be actively misleading.
  class StylesheetLint
    BUILT_PATH = "app/assets/builds/tailwind.css"

    # Raised when the toolchain itself fails (npm install, or the Tailwind CLI). Distinct from a
    # stale stylesheet: one is a broken environment, the other is the regression we are hunting.
    class BuildError < StandardError; end

    Result = Struct.new(:status, :message, keyword_init: true) do
      def skipped? = status == :skipped
      def current? = status == :current
      def stale? = status == :stale

      # Only a genuine drift fails the gate; a toolchain that cannot resolve DaisyUI is a
      # no-opinion, not a pass-with-doubt.
      def failed? = stale?
    end

    # `builder` is any object answering `available?` and `build(output_path)`. Injecting it keeps
    # the comparison — the part that regressed — testable without npm or a Tailwind binary.
    def initialize(root: Dir.pwd, builder: TailwindBuilder.new)
      @root = Pathname.new(root)
      @builder = builder
    end

    attr_reader :root

    def built_path = root.join(BUILT_PATH)

    def call
      unless @builder.available?
        return Result.new(
          status: :skipped,
          message: "Stylesheet check skipped: npm is unavailable, so DaisyUI cannot be resolved here."
        )
      end

      Dir.mktmpdir("specguard-stylesheet-lint") do |dir|
        candidate = File.join(dir, "tailwind.css")
        @builder.build(candidate)

        if current?(candidate)
          Result.new(status: :current, message: "Stylesheet is current.")
        else
          Result.new(status: :stale, message: stale_message)
        end
      end
    end

    private

    def current?(candidate)
      built_path.exist? && FileUtils.identical?(built_path.to_s, candidate)
    end

    def stale_message
      <<~MESSAGE

        #{BUILT_PATH} is stale — the sources produce a different stylesheet than the committed one.
        Run `npm install && bin/rails tailwindcss:build` and commit the result.

        The built CSS is minified onto one line, so the diff stat will say "1 insertion, 1 deletion"
        however many rules moved. Check individual rules with `grep -c -F '.some-utility{'` instead.
      MESSAGE
    end

    # The real toolchain: npm for DaisyUI, then the Tailwind CLI the `tailwindcss:build` task would
    # have used — same input, same flags, same binary — with only the output redirected.
    class TailwindBuilder
      def available?
        system("npm --version > /dev/null 2>&1")
      end

      def build(output_path)
        raise BuildError, "npm install failed" unless system("npm install --silent")

        # Engine entry points are an input to the compile, and `tailwindcss:build` regenerates them
        # first. Skipping that would compare against something the real build never produces.
        Rake::Task["tailwindcss:engines"].invoke

        command = compile_command(output_path)
        env = Tailwindcss::Commands.command_env(verbose: false)

        raise BuildError, "tailwindcss build failed" unless system(env, *command)
      end

      private

      # Borrow the gem's own command so the flags (`--minify`, `--postcss`, the input path) stay in
      # lockstep with `tailwindcss:build`, then point `-o` somewhere harmless. Anything else risks a
      # gate that fails on a flag difference rather than on real drift.
      def compile_command(output_path)
        command = Tailwindcss::Commands.compile_command
        output_flag = command.index("-o")

        raise BuildError, "tailwindcss compile command has no -o flag: #{command.inspect}" if output_flag.nil?

        command.dup.tap { |c| c[output_flag + 1] = output_path }
      end
    end
  end
end
