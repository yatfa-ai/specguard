# frozen_string_literal: true

require "rails_helper"

# `?limit=` on `GET /api/v1/repository` — the widening ask the two run-grain duration rollups
# honour, read through the same shared `RequestedLimitParam` concern `repositories#show` reads
# (pinned in spec/requests/repository_limit_param_spec.rb). The API publishes the APPLIED limit in
# each block's `limit` field, which is what makes the clamp observable here and nowhere else: the
# response says what it did rather than silently serving fewer rows than the client counted on.
#
# The auth contract lives in `repositories_spec.rb` and is deliberately left untouched, on the
# standing rule of this endpoint's per-block files.
RSpec.describe "GET /api/v1/repository — limit parameter", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def spec_files = get_repository.dig("latest_run", "spec_files")
  def spec_directories = get_repository.dig("latest_run", "spec_directories")

  # One observation row, spelled the way the sibling files in this directory spell it: direct
  # `create!` on the run, `line_number` keeping `example_id` unique, `duration` required so no
  # example is written without meaning to time it.
  def observe(run, path:, duration:, line_number:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line_number}]",
      file_path: path, spec_file_path: path, line_number: line_number,
      status: "unannotated", duration_seconds: duration
    )
  end

  # Fifteen files, each the sole file of its own directory, each distinct in cost. Fifteen is one
  # past both shipped caps, so both blocks truncate by default, and is under `MAX_LIMIT`, so the
  # clamp never silently interferes with a mid-range ask.
  let!(:test_run) do
    run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: "main",
                          total_specs_count: 15, annotated_specs_count: 0, duration_seconds: 60.0)
    (1..15).each do |i|
      observe(run, path: "spec/d#{format('%02d', i)}/a#{format('%02d', i)}_spec.rb",
              duration: i.to_f, line_number: i)
    end
    run
  end

  it "serves both rollups at their shipped defaults without the ask" do
    body = get_repository

    expect(body.dig("latest_run", "spec_files", "rows").size)
      .to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
    expect(body.dig("latest_run", "spec_files", "limit")).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
    expect(body.dig("latest_run", "spec_directories", "rows").size)
      .to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    expect(body.dig("latest_run", "spec_directories", "limit"))
      .to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
  end

  it "widens both rollups and reports the ask as the applied limit" do
    body = get_repository(query: { limit: "3" })

    files = body.dig("latest_run", "spec_files")
    directories = body.dig("latest_run", "spec_directories")

    # Three rows each, and — the disclosure that keeps `limit`/`file_count` agreeing — the
    # population figures are still counted before the LIMIT and stay exact at the widened size.
    expect(files["rows"].size).to eq(3)
    expect(files["limit"]).to eq(3)
    expect(files["file_count"]).to eq(15)
    expect(directories["rows"].size).to eq(3)
    expect(directories["limit"]).to eq(3)
    expect(directories["directory_count"]).to eq(15)
  end

  # Criterion 3 in the one place it is fully observable: the clamp is PUBLISHED. A client that
  # asked for 99,999 and was served 15 rows can read `limit == 200` and know the figure clamped
  # rather than the population ending — the response says what it did.
  it "clamps an ask past the ceiling and publishes the clamped limit" do
    body = get_repository(query: { limit: "99999" })

    files = body.dig("latest_run", "spec_files")
    directories = body.dig("latest_run", "spec_directories")

    expect(files["limit"]).to eq(RequestedLimitParam::MAX_LIMIT)
    expect(directories["limit"]).to eq(RequestedLimitParam::MAX_LIMIT)
    expect(files["rows"].size).to eq(15)
    expect(files["file_count"]).to eq(15)
  end

  # Spellings `Kernel#Integer` accepts that a reader might assume land in the malformed set: a
  # BASE PREFIX (`"0xc"` parses to 12) and SURROUNDING WHITESPACE (`" 12 "` parses to 12). Both
  # honour the ask and the published `limit` reports the parsed magnitude — pinned here because
  # the guard's rationale comment once claimed `"0x10"` answers nil when it parses to 16, and
  # only examples asserting the real behaviour keep that claim from being re-believed.
  it "honours a base-prefixed spelling as the magnitude it parses to" do
    body = get_repository(query: { limit: "0xc" })

    expect(body.dig("latest_run", "spec_files", "rows").size).to eq(12)
    expect(body.dig("latest_run", "spec_files", "limit")).to eq(12)
    expect(body.dig("latest_run", "spec_directories", "limit")).to eq(12)
  end

  it "honours a whitespace-padded spelling as the magnitude it parses to" do
    body = get_repository(query: { limit: " 12 " })

    expect(body.dig("latest_run", "spec_files", "limit")).to eq(12)
    expect(body.dig("latest_run", "spec_directories", "limit")).to eq(12)
  end

  describe "a limit parameter that is not a widening" do
    # The no-ask answer is the DEFAULT body: both blocks at their shipped constants, the very
    # figures the first example above pins — which is why this asserts against the constants
    # rather than a snapshot, so the guard and the default cannot drift apart.
    def expect_limit_param_treated_as_no_ask(query)
      body = get_repository(query: query)

      expect(response).to have_http_status(:ok)
      expect(body.dig("latest_run", "spec_files", "rows").size)
        .to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
      expect(body.dig("latest_run", "spec_files", "limit")).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
      expect(body.dig("latest_run", "spec_directories", "limit"))
        .to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    end

    it_behaves_like "a surface that treats a non-widening limit parameter as no ask"
  end
end
