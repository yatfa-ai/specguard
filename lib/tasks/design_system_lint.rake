# frozen_string_literal: true

require_relative "../../lib/spec_guard/design_system_lint"

namespace :lint do
  desc "Check signed-in views/components for design-system drift (shrink-only baseline)"
  task design_system: :environment do
    lint = SpecGuard::DesignSystemLint.new(root: Rails.root)
    puts lint.report

    unless lint.clean?
      abort "\nDesign-system drift regression — fix the offenders above, or justify a baseline change."
    end
  end

  namespace :design_system do
    desc "Rewrite the drift baseline from the live counts (shrink-only; FORCE=1 to accept growth)"
    task update_baseline: :environment do
      lint = SpecGuard::DesignSystemLint.new(root: Rails.root)
      force = ENV["FORCE"] == "1"
      written = lint.update_baseline!(force: force)

      puts "Wrote #{SpecGuard::DesignSystemLint::BASELINE_PATH}: #{written.inspect}#{force ? " (FORCE)" : ""}"
    end
  end
end
