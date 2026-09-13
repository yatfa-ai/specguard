# frozen_string_literal: true

require "rails_helper"
require "open3"

# The fixture identity seams this suite's concurrency safety rests on: the factory's default
# `github_uid` and the OmniAuth mock's default uid are ONE value per suite process, read from the
# same constant (`Builders::DEFAULT_GITHUB_UID`), and the factory's default `github_full_name` is
# the same kind of value (`Builders::DEFAULT_GITHUB_FULL_NAME`), read by BOTH repository-minting
# seams — the model-level `create_repository` and the HTTP-level `register_repository`. These
# examples pin the properties, because the property that matters is NOT "a default exists" but
# "the default is process-local" — a collision-class fix whose discriminating evidence is
# DISTINCTNESS across processes, not greenness within one.
#
# Here rather than in spec/support on purpose: rails_helper blanket-requires every file under
# spec/support at boot, so a *_spec.rb there would be pre-loaded before RSpec collects files and
# could run twice.
RSpec.describe "the per-process fixture GitHub identity" do
  # A fresh Ruby process that loads the two support files the way a second suite boot would, and
  # reports the identities it derives. Kept a process of its own deliberately: the property under
  # test is what a NEW process sees, and there is no way to see that from inside this one. The
  # factories file is required before omniauth's, mirroring rails_helper's sorted glob — the
  # pairing depends on that order.
  def fresh_process_identity
    script = <<~RUBY
      require "bundler/setup"
      require "rspec/core"
      require "./spec/support/factories"
      require "./spec/support/omniauth"
      print [Builders::DEFAULT_GITHUB_UID, OmniAuthHelpers::DEFAULT_AUTH["uid"],
             Builders::DEFAULT_GITHUB_FULL_NAME].join(" ")
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: Rails.root.to_s)
    raise "fresh process failed: #{status.exitstatus}\n#{stderr}" unless status.success?

    values = stdout.split
    raise "fresh process reported #{stdout.inspect}" unless values.size == 3

    { builders: values[0], omniauth: values[1], full_name: values[2] }
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

  # @intent: { entity: "Builders::DEFAULT_GITHUB_FULL_NAME", action: "read twice in one process", behavior: "the default fixture repository name is one stable org/repo-shaped value for the whole process, so a repeat-or-conflict flow inside one example still meets the same name", layer: "unit" }
  it "is one stable org/repo name for the whole process" do
    first_read = Builders::DEFAULT_GITHUB_FULL_NAME
    second_read = Builders::DEFAULT_GITHUB_FULL_NAME

    expect(first_read).to eq(second_read)
    expect(first_read).to be_a(String)
    expect(first_read).not_to be_empty
    # The org/repo shape is what `normalize_full_name` and `derive_name` assume; a default that
    # lost it would surface as validation failures in every default-minting example, not here.
    expect(first_read).to match(Repository::FULL_NAME_FORMAT)
  end

  # @intent: { entity: "Builders::DEFAULT_GITHUB_FULL_NAME", action: "compare across processes", behavior: "a fresh suite process derives a different default repository name than this one, so two concurrently running suites cannot collide on the repositories unique index", layer: "unit" }
  it "gives a fresh suite process a different repository name than this one" do
    fresh = fresh_process_identity

    expect(fresh[:full_name]).not_to eq(Builders::DEFAULT_GITHUB_FULL_NAME)
  end

  # @intent: { entity: "Builders::DEFAULT_GITHUB_FULL_NAME", action: "read from both minting seams", behavior: "a default mint carries the constant and both seam signatures name it, so the model-level and HTTP-level fixtures share one identity per process", layer: "unit" }
  it "reaches both repository-minting seams from the one constant" do
    # Behavioral half: a default mint carries the constant — which also proves the constant is
    # the evaluated default, not a decorative name. The user minted alongside it pins the uid
    # pairing at the same time.
    repository = create_repository

    expect(repository.github_full_name).to eq(Builders::DEFAULT_GITHUB_FULL_NAME)
    expect(repository.user.github_uid).to eq(Builders::DEFAULT_GITHUB_UID)

    # Wiring half, seam by seam: each signature's default expression names the constant. A bare
    # literal restored into either signature turns this example red — that would be a seam
    # carrying its own fixed value again, the exact pairing-coupling the per-process identity
    # exists to prevent.
    [Builders.instance_method(:create_repository),
     RequestBuilders.instance_method(:register_repository)].each do |seam|
      file, line = seam.source_location
      signature = File.readlines(file)[line - 1]

      expect(signature).to include("DEFAULT_GITHUB_FULL_NAME")
      expect(signature).not_to include(%("acme/billing-service"))
    end

    # The gate's side of the same identity: `register_repository`'s default POST is authorized
    # because the default fake lists the same name, so the fake's default answer must carry it too.
    expect(GithubApiHelpers::DEFAULT_REPOS).to include(Builders::DEFAULT_GITHUB_FULL_NAME)
  end
end
