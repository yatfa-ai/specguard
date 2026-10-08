# frozen_string_literal: true

# `?near_duplicates_summary=` read as a REQUEST FOR THE RANKING — the predicate answers `false`
# when there is no ask. A presence flag shaped exactly like {RequestedNearDuplicatesParam}, and
# for the same reasons: the value is NOT read (`?near_duplicates_summary=false` opens the block
# like any other non-blank string — a client that does not want it omits the parameter), a
# non-String (`?x[]=1`, `?x[a]=b`, `?x[][a]=b`: all truthy in Ruby) is no ask rather than a 400
# because there is nothing for a client to correct, and an empty value is no ask because an ask
# has to be affirmative rather than merely present in the URL. See that module for the argument
# in full; this one is its own file because each parameter means one thing and one guard answers
# one, and the two blocks they open (the full census, and its short ranking) are free to diverge.
#
# What the flag opens is the stored census WITHOUT its member listings — see
# {NearDuplicateCensusView#summary}. It costs the one stored-row read the full block costs.
# Pinned for every surface in
# `spec/support/shared_examples/malformed_near_duplicates_summary_param.rb`.
module RequestedNearDuplicatesSummaryParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`: the falsy answer — no ask — is the common one, and
  # `||=` would re-read the params on every call whenever the memo is falsy.
  def requested_near_duplicates_summary?
    return @requested_near_duplicates_summary if defined?(@requested_near_duplicates_summary)

    raw = params[:near_duplicates_summary]
    @requested_near_duplicates_summary = raw.is_a?(String) && raw.present?
  end
end
