# frozen_string_literal: true

require "rails_helper"

# The integration guide documents the CLIENT GEM but lives in the PLATFORM'S repository — two
# codebases, one page. That gap is how it drifted before: the page shipped a yanked gem name in
# its install snippet and described a Ruby validator arm the gem had deleted, for a full day
# before anyone noticed. This spec is the seal: it renders the page and holds it against the
# bundled gem itself, so the gem changing (a variable added or renamed, a default moved, a
# concept removed) reddens THIS suite until the page catches up. The gem is the source of truth
# because it is the code the reader will actually install.
# `require: false` in the Gemfile — the gem is loaded by the reporters at test time, so a
# spec reading its constants says so itself.
require "specguard/rspec/configuration"
require "specguard/rspec/annotation_lookup"

RSpec.describe "docs/integrate drift against the client gem", type: :request do
  # The truth, read from the gem this application bundles — not a list copied into this file,
  # which would be a second document that drifts the same way the page does.
  def gem_environment_variables
    configuration = SpecGuard::RSpec::Configuration
    [
      configuration::ENDPOINT_KEYS, configuration::API_KEY_KEYS, configuration::TIMEOUT_KEYS,
      configuration::OUTPUT_PATH_KEYS, configuration::LOCAL_OUTPUT_PATH_KEYS,
      configuration::COMMIT_SHA_KEYS, configuration::BRANCH_KEYS,
      configuration::RUN_ID_KEYS, configuration::SHARD_ID_KEYS,
      [SpecGuard::RSpec::ValidatorBackend::ENV_VAR,
       SpecGuard::RSpec::ValidatorBackend::Installer::CACHE_DIR_VAR]
    ].flatten.grep(/\ASPECGUARD_/).uniq
  end

  # Every string here names something the gem once had and no longer does. The page mentioning
  # one is not a style problem: each of these misled a reader in the wild — the yanked gem name
  # broke a copy-paste install, the Ruby-validator wording described a code path that no longer
  # exists, and the flag it references was deleted with that path.
  BANNED_STRINGS = {
    "specguard-rspec" => "the client gem is specguard-ruby since the rename; the old name is " \
                         "yanked from rubygems, so the snippet fails to install",
    "validated in Ruby" => "annotations are validated by the validate-intent Go binary; there " \
                           "is no Ruby arm and no such output line",
    "vendored Ruby" => "the vendored Ruby schema copy no longer validates anything",
    "require-validator" => "the flag was deleted together with the Ruby validation arm"
  }.freeze

  # @intent: {"entity": "GET /docs/integrate", "action": "document gem env vars", "behavior": "the page returns ok and mentions every SPECGUARD_ environment variable the bundled gem's configuration constants read, with none missing", "layer": "request"}
  it "documents every SPECGUARD_ variable the bundled gem reads" do
    get integration_guide_path
    expect(response).to have_http_status(:ok)

    missing = gem_environment_variables.reject { |name| response.body.include?(name) }
    expect(missing).to be_empty,
          "the bundled gem reads #{missing.join(', ')}, which /docs/integrate does not mention — " \
          "the page has drifted behind the client"
  end

  # @intent: {"entity": "GET /docs/integrate", "action": "name default sink files", "behavior": "the page names the replay queue and the no-key development record by the gem's own DEFAULT_OUTPUT_PATH and DEFAULT_LOCAL_OUTPUT_PATH defaults", "layer": "request"}
  it "names the sink files by the gem's own defaults" do
    configuration = SpecGuard::RSpec::Configuration
    get integration_guide_path

    expect(response.body).to include(configuration::DEFAULT_OUTPUT_PATH),
          "the replay queue is #{configuration::DEFAULT_OUTPUT_PATH} in the gem"
    expect(response.body).to include(configuration::DEFAULT_LOCAL_OUTPUT_PATH),
          "the no-key development record is #{configuration::DEFAULT_LOCAL_OUTPUT_PATH} in the gem"
  end

  # @intent: {"entity": "GET /docs/integrate", "action": "omit removed gem strings", "behavior": "none of the banned strings the gem has removed \u2014 specguard-rspec, validated in Ruby, vendored Ruby, require-validator \u2014 appear anywhere on the page", "layer": "request"}
  it "carries nothing the gem has removed" do
    get integration_guide_path

    present = BANNED_STRINGS.keys.select { |stale| response.body.include?(stale) }
    expect(present).to be_empty,
          "stale on the page: #{present.map { |s| "#{s} (#{BANNED_STRINGS[s]})" }.join('; ')}"
  end

  # @intent: {"entity": "GET /docs/integrate", "action": "name current client", "behavior": "the page includes the strings specguard-ruby and Minitest, documenting the renamed client for both Ruby frameworks", "layer": "request"}
  it "documents the client under its current name, for both Ruby frameworks" do
    get integration_guide_path

    expect(response.body).to include("specguard-ruby")
    expect(response.body).to include("Minitest")
  end

  # @intent: {"entity": "GET /docs/integrate", "action": "state the loss arm, not an unconditional promise", "behavior": "the page neither promises replay-queue recovery unconditionally (the old 'so a run survives a network blip' sentence) nor omits the double-failure arm: when the replay queue cannot be written either, the page states that the run's telemetry was lost", "layer": "request"}
  it "does not promise queue recovery unconditionally, and states the double-failure loss arm" do
    get integration_guide_path

    # Negative-first, because every positive clause on this page ("specguard-ingest",
    # "log/test_results.jsonl", "replay queue") is already true on a page that collapsed both
    # delivery arms into one promise — which is exactly how the four name-checking examples
    # above missed that drift. The clients split the arms (specguard-rspec formatter.rb
    # sink_clause; specguard-ts transport.ts outcome "lost"): the queue line written means the
    # run can be re-delivered; the queue not written either means the telemetry is gone.
    expect(response.body).not_to include("so a run survives a network blip"),
          "/docs/integrate promises queue recovery unconditionally again — false whenever the " \
          "replay queue itself cannot be written"

    expect(response.body).to include("telemetry was lost"),
          "/docs/integrate states only the recoverable arm — it never says what happens when " \
          "the replay queue cannot be written either"
  end

  # @intent: {"entity": "GET /docs/integrate", "action": "state the keyless local sink's write-failure arm, not an unconditional promise", "behavior": "the page neither describes the keyless local write as unconditional (the old 'the run is written to a file' framing) nor omits the arm: when the local file cannot be written, the page states that the client prints one line naming the configured path (the clients' own warning wording) and that the test run is unaffected, while a successful write stays silent", "layer": "request"}
  it "does not promise the keyless local write unconditionally, and states its failure arm" do
    get integration_guide_path

    # Negative-first, because every positive token about this sink ("log/test_results.local.jsonl",
    # SPECGUARD_LOCAL_OUTPUT_PATH, "development record") is already true on a page that presented
    # the local write as something that always succeeds — which is exactly why the name-checking
    # examples above stayed green through that drift. The clients split the arms
    # (specguard-rspec formatter.rb append_local; specguard-ts transport.ts local branch): the
    # write succeeding is silent and ordinary; the write failing prints one line naming the
    # configured path and leaves the test run unaffected.
    expect(response.body).not_to include("the run is written to a file"),
          "/docs/integrate presents the keyless local write as unconditional again — false " \
          "whenever log/test_results.local.jsonl cannot be written"

    expect(response.body).to include("could not write telemetry"),
          "/docs/integrate states only the ordinary keyless arm — it never says what happens " \
          "when the local file cannot be written"

    expect(response.body).to include("nothing is printed"),
          "/docs/integrate no longer describes the successful keyless write as silent and " \
          "ordinary — the failure arm must not read as the usual case"
  end
end
