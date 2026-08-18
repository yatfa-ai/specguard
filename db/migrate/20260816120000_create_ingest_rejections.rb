# frozen_string_literal: true

# One row per authenticated request whose payload `POST /api/v1/ingest` refused — the first thing
# SpecGuard stores about a delivery it did **not** accept.
#
# Before this table a 400 left zero platform-side record. The refusal happens at
# `Api::V1::IngestsController#create`, and `Api::BaseController#render_bad_request` renders JSON
# and returns; nothing was written. Meanwhile `authenticate_api_key!` is a `before_action` and
# stamps `api_keys.last_used_at` on the way IN — so the one column the dashboard reads to answer
# "is this repository connected?" was already stamped by the very request being thrown away. A
# repository whose every run is refused rendered `Connected`, in success tone, with a hint saying
# the last request was two minutes ago.
#
# == Why the recordable family is the AUTHENTICATED one, and only that
#
# There is deliberately **no column for a failed authentication**, and no row is ever written for a
# 401. `ApiKey.authenticate` returns `nil` for a wrong or revoked token, so no repository is
# resolved — `render_unauthorized` returns three lines before the stamp. There is nothing to hang
# the row on and nothing honest to attribute it to; a `repository_id` on a 401 row could only be
# guessed. So the population this table holds is precisely the **authenticated-but-refused** one,
# and the surface that lists it must not imply it can see failed authentications.
#
# That asymmetry is not a gap to be closed later by making `repository_id` nullable. A nullable
# repository would turn a per-repository panel into a global error log with rows no repository owns.
#
# == What a row does NOT do
#
# It does not make the run recoverable. The payload was refused and is not stored — this table
# holds the FACT of the refusal and the reason given, so the owner learns it happened and why. It
# is not a retry queue and nothing re-delivers from it.
#
# `details` is `Ingest::Payload`'s own error array, stored in the endpoint's own words as jsonb.
# Nothing platform-side re-words it into a verdict, on the standing rule the endpoint already
# applies to `outcome`: the client is told exactly what the client was told. It is BOUNDED but never
# paraphrased — see the column comment below and `IngestRejection::RETAINED_REASONS_PER_ROW` for why
# a row has a size ceiling and how the row states what the ceiling cost it.
#
# `user_agent` is the request header, and it is here for one concrete reason rather than for
# completeness. `specguard-rspec` sends `specguard-rspec/<version>` (`Transport::USER_AGENT`), and
# the failure mode this table was built for is a VERSION FLOOR — a gem sending
# `Content-Encoding: gzip` against an installation deployed before `GzipRequestBody` 400s every run
# over 256 KiB, which is every large suite. Without the version on the row, "every delivery is
# refused" and "every delivery from the old gem is refused" are the same picture.
#
# == No `timestamps`, on purpose
#
# The row is written once, on a request that is being refused, and is never updated — so
# `updated_at` is a column that could not differ from `created_at`, and `created_at` would be a
# second name for `occurred_at`. One time column, named for the fact it records rather than for the
# INSERT that recorded it.
class CreateIngestRejections < ActiveRecord::Migration[8.1]
  def change
    create_table :ingest_rejections do |t|
      # `index: false` because the composite below already leads with `repository_id` and therefore
      # serves every lookup a standalone index on it would — including the foreign key's own
      # cascade check. `t.references` would otherwise add a second index over a strict prefix of
      # the first: more to write on every refusal, and nothing that can be asked of it that the
      # composite cannot answer.
      t.references :repository, null: false, foreign_key: true, index: false
      # When the endpoint refused the delivery. Not null: a rejection with no time is a row that
      # can neither be listed in order nor aged out by the retention rule.
      t.datetime :occurred_at, null: false
      # `Ingest::Payload#errors` — an array of strings, each stored in the endpoint's own words.
      # jsonb rather than a text column holding a joined string, because the client is handed a
      # LIST (`render_bad_request` sends `details:` as an array) and the panel re-renders that list
      # one reason per line. Joining on the way in and splitting on the way out would invent a
      # delimiter that any error message is free to contain.
      #
      # ⚠️ **Bounded on the way in, and the bound is load-bearing rather than tidiness.**
      # `Ingest::Payload` emits one error PER INVALID SPEC (up to five), each embedding the
      # client's own `file_path`, and nothing caps that array — it was only ever handed to a
      # response and thrown away. Persisting it changes the arithmetic: the design point of this
      # table is a pipeline refusing EVERY run, and an envelope or intent-schema skew refuses every
      # spec in the suite, so the row a 20,000-example suite writes is the ordinary case here and
      # not the exotic one. Unbounded, that is a multi-megabyte row, fifty of them per repository,
      # every element of every one rendered as an `<li>` on a dashboard panel that loads on every
      # page view. `Ingest::RejectionRecorder` therefore applies both halves of
      # `IngestRejection`'s per-row bound before this column is written, which is what makes the
      # row's size a stated ceiling rather than a function of what the client sent.
      t.jsonb :details, null: false, default: []
      # How many reasons the endpoint actually produced, before the per-row bound above dropped any
      # — so a truncated row can say what it is missing instead of silently looking complete.
      #
      # This is the number `Ingest::Payload#errors.size` returned and the number the CLIENT was
      # handed in its 400, which is the point: the reader can tell "one spec is malformed" from
      # "every spec in the suite is", and those two need entirely different fixes. Without it, the
      # panel could show its capped list and no reader could distinguish a suite with twenty
      # problems from one with twenty thousand.
      #
      # `null: false, default: 0` — every row this table has comes from the recorder, which always
      # writes the real count; the default exists so the column can be read without a nil guard.
      t.integer :total_reasons_count, null: false, default: 0
      # Nullable by construction: a `User-Agent` is a header a client may simply not send, and a
      # request without one is still a refusal worth recording. The panel says "not reported"
      # rather than pretending to a version it was never told.
      t.string :user_agent

      # No `t.timestamps` — see the class comment.
    end

    # The one read this table has, and the one the retention rule needs: this repository's
    # rejections, newest first. `id` is in the index as the tiebreaker so the ordering is total —
    # a burst of refusals from a sharded run lands several rows in the same instant, and a bare
    # `occurred_at DESC` would order those arbitrarily, which for the retention boundary means
    # deleting one of them or not depending on the plan. The same `(created_at, id)` total ordering
    # `Ingest::ObservationPruner` uses, for exactly the same reason.
    add_index :ingest_rejections, %i[repository_id occurred_at id],
              order: { occurred_at: :desc, id: :desc },
              name: "index_ingest_rejections_on_repository_and_recency"
  end
end
