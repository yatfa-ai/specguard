# frozen_string_literal: true

# The payloads and snippets the public integration guide publishes.
#
# They live here rather than inline in `app/views/pages/integrate.html.erb` for two reasons, and
# the second is the one that matters.
#
# 1. `UI::CopyableCodeComponent(multiline: true)` renders inside `whitespace-pre`, so a snippet
#    indented to sit tidily in the surrounding ERB would copy to the reader's clipboard with that
#    indentation on every line. Built here, each string starts at column 0 and is pasteable as-is.
#
# 2. **The example payload is a fixture, not prose.** The guide's whole claim is that a payload
#    built strictly from what it publishes is accepted by the server; a claim about the wire
#    format written only as page copy is a claim nothing can check, and this document exists
#    precisely because the contract was previously unreadable and therefore unverifiable.
#    `spec/requests/integration_guide_spec.rb` reads {EXAMPLE_PAYLOAD} straight off the *rendered
#    page* — parsing the JSON out of the HTML by its element id — and POSTs it to
#    `/api/v1/ingest`, so the published document is checked against the endpoint rather than
#    against a copy of itself. Editing the payload below into something the server refuses fails
#    the suite.
#
# What is deliberately NOT here: the field tables. Those are the document's body text, they carry
# a sentence of reasoning per row, and moving them out of the template would leave the guide as a
# page of method calls. Only the copy-pasteable payloads live here.
module IntegrationGuideHelper
  # The element id the worked payload is rendered under, and the handle the verification spec
  # finds it by. Named as a constant so the spec cannot drift from the template by a typo.
  EXAMPLE_PAYLOAD_ELEMENT_ID = "ingest-example-payload"

  # One complete, minimal, *accepted* ingest body.
  #
  # Deliberately a Python suite. Nothing in the ingest path is Ruby- or RSpec-specific —
  # `Ingest::Payload#validate_file_path` requires a non-empty string and nothing more, and the
  # directory rollups are string manipulation on that path — and a worked example whose every path
  # ended in `_spec.rb` would teach the opposite by illustration while the prose said otherwise.
  #
  # It carries one annotated and one unannotated spec on purpose: that pair is what makes
  # `annotated_specs` and `annotated_ratio` in the 202 response mean something, and a suite
  # mid-adoption is the ordinary shape rather than the exception.
  #
  # It also carries all three of the fields `Ingest::Payload` never validates and
  # `Ingest::ObservationRecorder` nonetheless consumes — `id`, `spec_file_path` and `outcome`.
  # A reader who builds from this example gets them by default, which is the point: they are the
  # difference between a per-example row that can be re-delivered, attributed to the file that ran
  # it, and followed across runs, and one that cannot.
  EXAMPLE_PAYLOAD = {
    "commit_sha" => "9f2c1ab4e7d3c05f1b8a6d24e0937c5b1a2f8e6d",
    "branch" => "main",
    "ci_run_id" => "17442",
    "shard_id" => "1",
    "duration_seconds" => 42.5,
    "specs" => [
      {
        "id" => "tests/test_checkout_service.py::test_rejects_expired_card",
        "spec_file_path" => "tests/test_checkout_service.py",
        "file_path" => "tests/test_checkout_service.py",
        "line_number" => 12,
        "name" => "CheckoutService rejects an expired card",
        "duration" => 0.184,
        "outcome" => "passed",
        "status" => "annotated",
        "intent" => {
          "entity" => "CheckoutService",
          "action" => "checkout",
          "behavior" => "rejects the transaction on an expired card and emits a payment_failed event",
          "layer" => "unit",
          "preconditions" => ["card is on file", "card is expired"]
        }
      },
      {
        "id" => "tests/test_checkout_service.py::test_applies_discount_before_tax",
        "spec_file_path" => "tests/test_checkout_service.py",
        "file_path" => "tests/test_checkout_service.py",
        "line_number" => 19,
        "name" => "CheckoutService applies the discount before tax",
        "duration" => 0.031,
        "outcome" => "passed",
        "status" => "unannotated",
        "intent" => nil
      }
    ]
  }.freeze

  # The `SPECGUARD_ENDPOINT` value for THIS installation: scheme and host, no trailing slash.
  #
  # SpecGuard is self-hostable, so this is never a constant — it is whatever host the reader is
  # reading the page on. `root_url` supplies that, and the strip matters: the gem joins
  # `/api/v1/ingest` onto whatever it is given, so a trailing slash would produce a double one.
  #
  # It lives here because four surfaces need the same value — the guide's own env-var table, the
  # agent prompt on the persistent repository page, the prompt on the one-shot reveal, and the
  # prompt on each row of the bulk registration summary — and a regex spelled out four times is four
  # chances to fix three of them. The prompt itself was already centralised for exactly this reason;
  # the endpoint it embeds deserves the same.
  def integration_guide_endpoint = root_url.sub(%r{/+\z}, "")

  def integration_guide_example_payload = JSON.pretty_generate(EXAMPLE_PAYLOAD)

  # The Gemfile entry, verbatim from the client gem's own README so the two cannot disagree.
  # `require: false` because the reporters are loaded by the test frameworks, not by Bundler.
  def integration_guide_gemfile_snippet
    <<~RUBY.strip
      # Gemfile
      group :test do
        gem "specguard-ruby", require: false
      end
    RUBY
  end

  def integration_guide_rspec_config_snippet
    <<~RUBY.strip
      # spec/spec_helper.rb
      require "specguard/rspec/formatter"

      RSpec.configure do |config|
        config.add_formatter(SpecGuard::RSpecFormatter)
      end
    RUBY
  end

  # The Minitest half of the same gem: no registration step at all — Minitest discovers
  # the reporter as a plugin from the load path, so `bundle exec` running the suite is the
  # whole integration. The explicit form is for runners where plugin discovery must not be
  # assumed (or plain ruby without Bundler): attach the plugin after minitest itself, or the
  # require opens a bare `module Minitest` with nothing in it.
  def integration_guide_minitest_snippet
    <<~RUBY.strip
      # The suite runner you already have — the gem's plugin attaches itself:
      bundle exec ruby test/all.rb

      # Or explicitly, where discovery must not be assumed:
      bundle exec ruby -rminitest -rminitest/specguard_plugin \
        -e 'Minitest.extensions << "specguard"; load ARGV[0]' test/all.rb
    RUBY
  end

  # The `.rspec` form of the same registration. The `--require` is not optional: RSpec resolves
  # `--format` against constants that are already loaded and cannot guess the path this one lives
  # at.
  def integration_guide_dot_rspec_snippet
    <<~CONFIG.strip
      # .rspec
      --require specguard/rspec/formatter
      --format SpecGuard::RSpecFormatter
    CONFIG
  end

  # A whole GitHub Actions step, because the two variables have to be set on the process that runs
  # the suite and a fragment leaves the reader to work out where they go.
  def integration_guide_github_actions_snippet(endpoint)
    <<~YAML.strip
      # .github/workflows/ci.yml
      - name: Run the test suite
        run: bundle exec rspec
        env:
          SPECGUARD_ENDPOINT: #{endpoint}
          SPECGUARD_API_KEY: ${{ secrets.SPECGUARD_API_KEY }}
    YAML
  end

  # The matrix case, which is the one that needs saying: GitHub Actions exports no per-leg index,
  # so `SPECGUARD_SHARD_ID` has to be fed from the matrix value itself.
  def integration_guide_sharded_actions_snippet
    <<~YAML.strip
      strategy:
        matrix:
          shard: [1, 2, 3, 4]
      steps:
        - name: Run the test suite
          run: bundle exec rspec
          env:
            SPECGUARD_SHARD_ID: ${{ matrix.shard }}
    YAML
  end

  def integration_guide_curl_snippet(endpoint)
    <<~SHELL.strip
      curl -sS -X POST #{endpoint}/api/v1/ingest \\
        -H "Authorization: Bearer $SPECGUARD_API_KEY" \\
        -H "Content-Type: application/json" \\
        --data @run.json
    SHELL
  end

  # `npm install` is sufficient on its own — `package.json` declares `"prepare": "npm run build"`,
  # which npm runs after install for a local checkout, so `dist/` exists before the reader is told to
  # point an agent at it. Spelling the build out as a second command would suggest it is needed.
  def integration_guide_mcp_install_snippet
    <<~SHELL.strip
      git clone https://github.com/yatfa-ai/specguard-mcp.git
      cd specguard-mcp && npm install
    SHELL
  end

  def integration_guide_mcp_config_snippet(endpoint)
    <<~JSON.strip
      {
        "mcpServers": {
          "specguard": {
            "command": "node",
            "args": ["/path/to/specguard-mcp/dist/bin/specguard-mcp.js"],
            "env": {
              "SPECGUARD_ENDPOINT": "#{endpoint}",
              "SPECGUARD_API_KEY": "sgk_…",
              "SPECGUARD_LINT_COMMAND": "bundle exec specguard-lint"
            }
          }
        }
      }
    JSON
  end

  # The copy-paste prompt that replaced the "Connect this repository" panel.
  #
  # == Why this is one method and not three blocks of template text
  #
  # It renders on three surfaces, split by whether the real token is on screen: the one-shot reveal
  # and each row of the bulk registration summary both inline it, so the prompt works exactly as
  # pasted, while the persistent repository page cannot, because only a digest is stored and a token
  # already shown once is unrecoverable. All three differ in *one paragraph* (`credential_line`).
  # Written three times they would differ in more than that within a release, and the one a reader
  # is likeliest to meet — the persistent one — is the one nobody re-reads.
  #
  # == Why it is short, and deliberately not the documentation
  #
  # It names the repository, states where the credential is, and sends the agent to the guide. It
  # does NOT restate the wire contract, the gem, or the annotation syntax: those live on a page that
  # is verified against the server (`spec/requests/integration_guide_spec.rb`), and a second copy
  # here would be an unverified one that goes stale silently. The guide URL is built from
  # `integration_guide_url`, never hand-written, so the prompt cannot outlive the page it points at.
  #
  # @param repository [Repository] the repository being wired up — named in the prompt because an
  #   agent may be pointed at a checkout it has to identify.
  # @param guide_url [String] absolute URL of the integration guide.
  # @param endpoint [String] this installation's base URL, no trailing slash.
  # @param token [String, nil] the raw credential when it is on screen, nil on every other render.
  def integration_guide_agent_prompt(repository:, guide_url:, endpoint:, token: nil)
    <<~PROMPT.strip
      Wire this project up to report its test runs to SpecGuard.

      Repository:  #{repository.github_full_name}
      Endpoint:    #{endpoint}
      #{credential_line(token)}

      Read #{guide_url} in full and follow it for whatever language and test framework
      this project actually uses. When you are done a CI run should reach
      #{endpoint}/api/v1/ingest and show up on the repository's SpecGuard page.
    PROMPT
  end

  private

  # The one paragraph those three surfaces differ in — and the split is 2-to-1 rather than even: the
  # one-shot reveal and each bulk summary row have the token, the persistent repository page does
  # not.
  #
  # The no-token wording says where the credential *is* rather than what it is, which is the only
  # honest thing the persistent page can say: `ApiKey` keeps a SHA-256 digest, so the server cannot
  # reproduce a token it has already shown. Naming the secret is also the more useful instruction of
  # the two — the agent's job is to get the value into CI, and on the token-bearing surfaces it is
  # already there.
  #
  # Written as heredocs and `chomp`ed rather than as one-line strings with `\n` in them, so the
  # continuation indent that lines the second line up under the first is visible here as the
  # alignment it is on the page.
  def credential_line(token)
    return <<~MISSING.chomp if token.blank?
      API key:     read it from the CI secret named SPECGUARD_API_KEY (SpecGuard stores
                   only a digest and cannot show an existing key again).
    MISSING

    <<~PRESENT.chomp
      API key:     #{token}
                   Store it as a CI secret named SPECGUARD_API_KEY. Do not commit it.
    PRESENT
  end
end
