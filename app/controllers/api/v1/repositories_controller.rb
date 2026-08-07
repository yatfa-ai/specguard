# frozen_string_literal: true

# The agent-readable half of the repository page: which repository a key resolves to, and what the
# suite looked like the last time CI reported. Without the `latest_run` block below an agent can
# learn the suite's size only by running the suite and POSTing it — it cannot ask.
#
# Every figure is read off the same row `repositories#show` renders from
# (`Repository#latest_test_run`, tie-break included), so the API and the dashboard cannot name
# different commits for the same repository.
class Api::V1::RepositoriesController < Api::BaseController
  def show
    render json: {
      repository: {
        id: current_repository.id,
        full_name: current_repository.github_full_name,
        name: current_repository.name,
        registered_at: current_repository.created_at.iso8601
      },
      api_key: {
        name: current_api_key.name,
        last_used_at: current_api_key.last_used_at&.iso8601
      },
      latest_run: serialized_latest_run
    }
  end

  private

  # `nil` — not a zeroed block — when CI has never reported. A repository whose CI has never run
  # must not serialize byte-identically to one that ran and genuinely found an empty suite; that is
  # the conflation the Overview panel refuses too (see RepositoriesController#show).
  # `Repository#annotated_ratio` cannot express the difference, which is why this reads the run.
  def serialized_latest_run
    test_run = current_repository.latest_test_run

    return nil if test_run.nil?

    {
      commit_sha: test_run.commit_sha,
      # Nullable, and Ingest::Payload accepts a body without it. `null` here means "the client did
      # not say", which is a different fact from any branch name we could substitute for it.
      branch: test_run.branch,
      total_specs: test_run.total_specs_count,
      annotated_specs: test_run.annotated_specs_count,
      annotated_ratio: annotated_ratio_for(test_run),
      # Nullable by schema. Serializing `0.0` for an unreported duration would assert the run took
      # no time — the same "not reported" vs `0.0s` distinction the Recent runs table draws.
      duration_seconds: test_run.duration_seconds,
      ingested_at: test_run.created_at.iso8601
    }
  end

  # The 0–1 FRACTION, matching what `/ingest` answered for this same run — never the 0–100
  # percentage `TestRun#annotated_ratio` renders for the dashboard. The 100× gap between the two is
  # invisible in a JSON body, so two endpoints disagreeing about it would be a silent
  # two-orders-of-magnitude error for any client that read both.
  #
  # `null` when the run reported no tests at all: `annotated_fraction` floors at `0.0` by
  # zero-denominator guard, and a `0.0` sitting beside real fractions reads as a *measured* zero
  # share rather than "there was nothing to take a share of". The counts stay present either way,
  # so a client that wants to compute its own ratio still can.
  def annotated_ratio_for(test_run)
    return nil if test_run.total_specs_count.to_i.zero?

    test_run.annotated_fraction
  end
end
