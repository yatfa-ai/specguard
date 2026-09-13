# frozen_string_literal: true

# The GitHub blob URL the drill-down panels link to, for one (sha, path, line) coordinate.
#
# HERE RATHER THAN IN THE FILE THAT FIRST NEEDED IT, for the reason `SerializedStrings` states:
# RSpec scopes a `def` to its own example group, so a sibling's helper is invisible and the only
# way to reuse it is to copy it. Four request specs — the four `repository_*_examples` drill-down
# panels — need the same URL, and four copies are four templates free to drift:
#
#   spec/requests/repository_repeated_description_examples_spec.rb
#   spec/requests/repository_spec_file_examples_spec.rb
#   spec/requests/repository_slowest_examples_spec.rb
#   spec/requests/repository_unannotated_examples_spec.rb
#
# AND THE DRIFT IS MEASURED, NOT HYPOTHETICAL: SPGD-1084's merged commit `15267d2` (PR #326) had
# to edit this exact line in ALL FOUR files in one commit, because the fixture-identity flip
# (the shared `"acme/billing-service"` literal → `Builders::DEFAULT_GITHUB_FULL_NAME`, itself
# run-randomized per spec/support/factories.rb) could not be applied without a four-file lockstep
# edit. One template, four hand-synced copies — that commit is the staying-in-step, demonstrated.
#
# The full name is read from `Builders::DEFAULT_GITHUB_FULL_NAME` exactly as every copy did, and
# stays guarded by `spec/lib/builders_fixture_identity_spec.rb`.
module GithubUrlHelpers
  def blob(sha, path, line) = "https://github.com/#{Builders::DEFAULT_GITHUB_FULL_NAME}/blob/#{sha}/#{path}#L#{line}"
end

RSpec.configure do |config|
  config.include GithubUrlHelpers
end
