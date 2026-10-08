# frozen_string_literal: true

# `?near_duplicate_cluster=<rank>` read as the RAW ASK for one cluster of the stored census —
# `nil` when there is no ask. The guard reads the SHAPE only; whether the string is a usable rank
# is {NearDuplicateCensusView#cluster}'s to answer, because an unusable rank (zero, negative,
# non-numeric, out of range) is an ask with a null answer and the ask echoed, never a 404 and
# never a nearest guess. So `?near_duplicate_cluster=abc` is an ask and comes back as
# `cluster: null, requested: "abc"`.
#
# The same discipline as {RequestedSpecFileParam}: a non-String (`?x[]=1`, `?x[a]=b`,
# `?x[][a]=b`) is no ask — the answer an absent parameter gets — and `.presence` makes an empty
# value no ask. A NUL-carrying string is no ask too: it cannot be a rank, but unlike a rank-shaped
# typo it is not an ask a client could have meant, and it is never echoed into a response.
# Pinned in `spec/support/shared_examples/malformed_near_duplicate_cluster_param.rb`.
module RequestedNearDuplicateClusterParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` — `nil` (no ask) is the common answer and `||=` would re-read.
  def requested_near_duplicate_cluster
    return @requested_near_duplicate_cluster if defined?(@requested_near_duplicate_cluster)

    raw = params[:near_duplicate_cluster]
    @requested_near_duplicate_cluster = raw.is_a?(String) && !raw.include?("\u0000") ? raw.presence : nil
  end
end
