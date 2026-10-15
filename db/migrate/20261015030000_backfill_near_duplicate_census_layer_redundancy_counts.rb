# frozen_string_literal: true
# THE ONE-TIME RE-TAKE: every repository with a stored census gets it recomputed, so the served
# artifact carries the census-wide `layer_redundancy_counts` tally (SPGD-1822) from the deploy
# instant rather than from each repository's next ingest.
#
# ## Why this migration exists
#
# The tally counts EVERY cluster the census found, but the stored payload keeps only the top-ranked
# page of them — so it cannot be derived from a census already on disk, and a stored payload
# without the key means "this census predates the tally", never "zero". Without this migration a
# repository that does not happen to ingest after the deploy would go on serving the tally-free
# census indefinitely. SPGD-1475's layer backfill closed the identical window for the layer cut
# itself; this is the same gesture for the same reason.
#
# ## Why the machinery is the marker, unchanged
#
# The migration computes nothing. It goes through `NearDuplicateCensus.request_refresh!` — the
# raise-the-marker-and-enqueue seam the ingest path uses — so each census is recomputed by
# {Ingest::NearDuplicateCensusJob} under the concurrency limit the job carries. A bare
# `perform_later` would schedule work that honours no marker. A migration rather than a rake task
# because a committed one-off task is the shape that gets discovered and re-run later; a migration
# runs once per database by construction, and the jobs are idempotent besides.
class BackfillNearDuplicateCensusLayerRedundancyCounts < ActiveRecord::Migration[8.1]
  def up
    Repository.joins(:test_runs).distinct.find_each do |repository|
      NearDuplicateCensus.request_refresh!(repository.id)
    end
  end

  def down
    # The enqueued recomputes are the migration's only effect, and they rebuild a derived artifact
    # that carries MORE disclosure than the one they replace. There is nothing to unwind: stripping
    # the tally back off stored payloads would serve less honesty for data that exists.
  end
end
