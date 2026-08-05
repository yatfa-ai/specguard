# frozen_string_literal: true

namespace :lint do
  desc "Fail if the committed app/assets/builds/tailwind.css is stale (needs npm for DaisyUI)"
  task :stylesheet do
    built = "app/assets/builds/tailwind.css"

    unless system("npm --version > /dev/null 2>&1")
      puts "Stylesheet check skipped: npm is unavailable, so DaisyUI cannot be resolved here."
      next
    end

    abort "npm install failed" unless system("npm install --silent")
    abort "tailwindcss:build failed" unless system("bin/rails tailwindcss:build")

    if system("git diff --quiet -- #{built}")
      puts "Stylesheet is current."
    else
      abort <<~MESSAGE

        #{built} is stale — the sources produce a different stylesheet than the committed one.
        Run `npm install && bin/rails tailwindcss:build` and commit the result.
      MESSAGE
    end
  end
end
