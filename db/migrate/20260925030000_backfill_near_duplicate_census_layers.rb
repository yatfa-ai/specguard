# frozen_string_literal: true
# THE ONE-TIME RE-TAKE: every repository with a stored census gets it recomputed, so the served
# artifact carries the declared-layer cut (SPGD-1475) from the deploy instant rather than from each
# repository's next ingest.
#
# ## Why this migration exists
#
# The layer cut lives INSIDE the stored census payload — that placement is `NearDuplicateCensus`'s
# own argument (one artifact, one stamp, no serve-time join to disagree with the clusters it
# annotates). A census computed before this deploy carries clusters but no `layer_source`, no
# per-cluster `layer_redundancy` and no `layer_groups`, and it serves verbatim until something
# moves its inputs. Without this migration, every repository that does not happen to ingest after
# the deploy would go on serving the layer-free census INDEFINITELY — the feature present in the
# code and absent from the data, with nothing on the wire to say why. SPGD-1474's backfill closed
# the identical window for the stored-census move itself; this is the same gesture for the same
# reason.
#
# ## Why the machinery is the marker, unchanged
#
# The migration does not compute anything. It goes through `NearDuplicateCensus.request_refresh!` —
# the same raise-the-marker-and-enqueue seam the ingest path uses — so each repository's census is
# recomputed by {Ingest::NearDuplicateCensusJob} under the concurrency limit the job already
# carries, over the data as it stands when the job runs. A repository whose census row does not
# exist yet (never ingested, no runs) gets one the same way, and the job stores its honest
# zero-population artifact — which is also why the request goes through `request_refresh!` rather
# than a bare `perform_later`: the job honours a MARKER, and a bare enqueue would schedule work
# that honours nothing.
#
# ## Why a migration and not a rake task
#
# `BackfillNearDuplicateCensuses` states this in full: a committed one-off rake task is exactly the
# shape that gets discovered and re-run later, re-enqueuing the fleet's work for nothing; a
# migration runs once per database by construction. The jobs are idempotent and safe to re-run —
# the marker is an upsert onto the unique `(repository_id)` index and the job recomputes whatever
# is wanted when it runs.
class BackfillNearDuplicateCensusLayers < ActiveRecord::Migration[8.1]
  def up
    # Every repository with at least one run — the population that can hold clusters, and the
    # population SPGD-1474's own backfill addressed. A repository with no runs has nothing for the
    # cut to annotate, and its census (when one is eventually taken) is computed fresh with the
    # cut in it by the normal ingest path.
    Repository.joins(:test_runs).distinct.find_each do |repository|
      NearDuplicateCensus.request_refresh!(repository.id)
    end
  end

  def down
    # The enqueued recomputes are the migration's only effect, and they rebuild a derived artifact
    # that includes MORE disclosure than the artifact they replace. There is nothing to unwind:
    # stripping the layer keys back off stored payloads would serve less honesty for data that
    # exists, which is the one direction this migration refuses to go.
  end
end
