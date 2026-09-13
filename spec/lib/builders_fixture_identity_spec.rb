# frozen_string_literal: true

require "rails_helper"
require "open3"

# The fixture identity seam this suite's concurrency safety rests on: the factory's default
# `github_uid` and the OmniAuth mock's default uid are ONE value per suite process, read from the
# same constant (`Builders::DEFAULT_GITHUB_UID`). These examples pin the properties, because the
# property that matters is NOT "a default exists" but "the default is process-local" — a
# collision-class fix whose discriminating evidence is DISTINCTNESS across processes, not
# greenness within one.
#
# Here rather than in spec/support on purpose: rails_helper blanket-requires every file under
# spec/support at boot, so a *_spec.rb there would be pre-loaded before RSpec collects files and
# could run twice.
RSpec.describe "the per-process fixture GitHub identity" do
  # A fresh Ruby process that loads the two support files the way a second suite boot would, and
  # reports the identity it derives. Kept a process of its own deliberately: the property under
  # test is what a NEW process sees, and there is no way to see that from inside this one. The
  # factories file is required before omniauth's, mirroring rails_helper's sorted glob — the
  # pairing depends on that order.
  def fresh_process_identity
    script = <<~RUBY
      require "bundler/setup"
      require "rspec/core"
      require "./spec/support/factories"
      require "./spec/support/omniauth"
      print [Builders::DEFAULT_GITHUB_UID, OmniAuthHelpers::DEFAULT_AUTH["uid"]].join(" ")
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: Rails.root.to_s)
    raise "fresh process failed: #{status.exitstatus}\n#{stderr}" unless status.success?

    uids = stdout.split
    raise "fresh process reported #{stdout.inspect}" unless uids.size == 2

    { builders: uids.first, omniauth: uids.last }
  end

  # @intent: { entity: "Builders::DEFAULT_GITHUB_UID", action: "read twice in one process", behavior: "the default fixture uid is one stable string value for the whole process", layer: "unit" }
  it "is one stable identity for the whole process" do
    first_read = Builders::DEFAULT_GITHUB_UID
    second_read = Builders::DEFAULT_GITHUB_UID

    expect(first_read).to eq(second_read)
    expect(first_read).to be_a(String)
    expect(first_read).not_to be_empty
  end

  # @intent: { entity: "OmniAuthHelpers::DEFAULT_AUTH", action: "pair with the builders default", behavior: "the mock's default uid reads the same per-process constant the factory default does", layer: "unit" }
  it "pairs the OmniAuth mock's default uid with the factory's default" do
    expect(OmniAuthHelpers::DEFAULT_AUTH["uid"]).to eq(Builders::DEFAULT_GITHUB_UID)
  end

  # @intent: { entity: "Builders::DEFAULT_GITHUB_UID", action: "compare across processes", behavior: "a fresh suite process derives a different fixture identity than this one, so two concurrently running suites cannot collide on the users unique index", layer: "unit" }
  it "gives a fresh suite process a different identity than this one" do
    fresh = fresh_process_identity

    expect(fresh[:builders]).not_to eq(Builders::DEFAULT_GITHUB_UID)
    expect(fresh[:omniauth]).not_to eq(OmniAuthHelpers::DEFAULT_AUTH["uid"])
  end

  # @intent: { entity: "OmniAuthHelpers::DEFAULT_AUTH", action: "pair within a fresh process", behavior: "the uid pairing holds in a brand-new boot too, so the factories-before-omniauth require order the pairing rests on is asserted rather than incidental", layer: "unit" }
  it "keeps the pairing inside a fresh process as well" do
    fresh = fresh_process_identity

    expect(fresh[:omniauth]).to eq(fresh[:builders])
  end
end
