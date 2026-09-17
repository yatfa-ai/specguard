# frozen_string_literal: true

# Adds `server_version` to `ingest_rejections`: WHICH BUILD answered the refused delivery.
#
# An `IngestRejection` row already names the client that was refused (`user_agent`) and the
# sentences the endpoint produced (`details`) — but never the server that refused it. The table's
# founding scenario (`CreateIngestRejections`) is a VERSION FLOOR: a gem sending
# `Content-Encoding: gzip` against an installation deployed before `GzipRequestBody` 400s every
# run over 256 KiB. The question that scenario asks is WHICH SIDE is outdated — the old gem, or
# the installation — and the panel's "Reported by" column serves only the client half. "Refused
# by the build before the deploy" and "refused by the build after it" are the same picture one
# column over, and this is the third leg: the one place client identity, server sentences and
# server identity meet on a row.
#
# == Why capture-at-write, not a live ask
#
# SPGD-1197 landed unauthenticated `GET /version` and SPGD-1200 put it behind the bridge — but
# both answer NOW. A rejection row is a HISTORICAL record and
# `IngestRejection::REPOSITORY_RETENTION_ROWS` keeps fifty per repository: a window spans deploys,
# so by the time an owner reads a refusal dated days ago, the build that produced it may be gone.
# The row carries `occurred_at` rather than a lookup for the same reason. `server_version` is
# stamped by `Ingest::RejectionRecorder#write` at the moment of refusal, read from the same
# memoized per-process answer `VersionsController.server_version` serves — the process answering
# the HTTP request is the process writing the row, and a deploy is a process restart, which is
# exactly when the answer changes.
#
# == Nullable by construction, and NO backfill
#
# The column answers "which build answered", and a row predating the stamp genuinely does not
# know — the model's own stated rule for an absent `User-Agent`: the surface says so ("Not
# recorded") rather than substituting a version nobody reported. A backfill would fabricate a
# build for rows written by whatever build happened to run the migration, which is a worse lie
# than an honest absence — the same arithmetic `occurred_at` argues for existing rather than
# leaning on `created_at`.
#
# == No index
#
# The panel reads by the existing `index_ingest_rejections_on_repository_and_recency`; nothing
# looks up by build. An index here would be a second index to maintain on every refusal in the
# exact write path `CreateIngestRejections` argues must stay cheap, serving no read.
class AddServerVersionToIngestRejections < ActiveRecord::Migration[8.1]
  def change
    # Nullable by construction: see the class comment. The recorder bounds it to
    # `IngestRejection::MAX_SERVER_VERSION_LENGTH` so the whole-row size ceiling stays a claim
    # about the WHOLE row — the value is platform-owned (the VERSION file, not client input), so
    # the bound only ever fires on a pathological VERSION file.
    add_column :ingest_rejections, :server_version, :string
  end
end
