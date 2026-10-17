# frozen_string_literal: true
# THE ONE-TIME RE-TAKE for `layer_redundancy_leaders` (SPGD-1844): the per-kind leaders cover
# clusters beyond the stored page, so they cannot be derived from a census already on disk, and a
# stored payload without the key means "this census predates the leaders", never "no leaders".
# Same gesture and same reasoning as BackfillNearDuplicateCensusLayerRedundancyCounts (SPGD-1822):
# nothing is computed here — each census is re-taken through `NearDuplicateCensus.request_refresh!`,
# the raise-the-marker-and-enqueue seam the ingest path uses, under the job's concurrency limit.
class BackfillNearDuplicateCensusLayerRedundancyLeaders < ActiveRecord::Migration[8.1]
  def up
    Repository.joins(:test_runs).distinct.find_each do |repository|
      NearDuplicateCensus.request_refresh!(repository.id)
    end
  end

  def down
    # Nothing to unwind: the enqueued recomputes rebuild a derived artifact with MORE disclosure.
  end
end
