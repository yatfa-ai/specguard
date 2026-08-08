# frozen_string_literal: true

require_relative "../../lib/spec_guard/stylesheet_lint"

namespace :lint do
  desc "Fail if the committed app/assets/builds/tailwind.css is stale (needs npm for DaisyUI)"
  task stylesheet: :environment do
    result = SpecGuard::StylesheetLint.new(root: Rails.root).call

    if result.failed?
      abort result.message
    else
      puts result.message
    end
  end
end
