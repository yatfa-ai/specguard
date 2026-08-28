# frozen_string_literal: true

module Ingest
  # Maps every example one run ingested onto the durable {SpecIdentity} it belongs to, and is the
  # only thing that writes that table.
  #
  # For each unresolved observation: take the text that represents it ({SpecObservation#signal},
  # which defers to {Ingest::SpecSignal}), embed it, ask this repository's identities for the
  # nearest neighbour within {SpecIdentity::MATCH_DISTANCE}, and either re-sight the row that came
  # back or insert a new one. The observation is then pointed at whichever it was.
  #
  # One case sits between those two outcomes: a test that just gained an `@intent` is represented by
  # its triple where it used to be represented by its name, so nothing matches it and yet it is not
  # new. {#upgrade_from_name} moves the row it already has onto the declaration rather than letting
  # a second one be inserted beside it — the one path in this class that rewrites an identity's text.
  #
  # Ahead of all of that sits one equality: text byte-identical to a row this repository already
  # holds is re-sighted without embedding anything at all ({#identical_text}). It answers the
  # ordinary case — an unchanged suite re-ingested — and it is a shortcut past the above rather than
  # a replacement for it, because a miss there proves nothing. It is asked once per PAGE rather than
  # once per row ({#digest_index}), so the ordinary case is ~40 digest lookups at the design point
  # rather than 20,000, and what it decides is WRITTEN once per page too ({#flush_page}), so that
  # case is ~80 `UPDATE`s rather than 40,000. The decision both of those feed is still made one row
  # at a time.
  #
  # == Why this runs in a job and not in the ingest transaction
  #
  # {Ingest::ObservationRecorder} writes inside the transaction holding the run's `FOR UPDATE` lock,
  # and its class comment explains at length why that lock is taken where it is: a delete-then-upsert
  # keyed on the shard is only atomic against a concurrent delivery if something holds the run still
  # while it happens. N shards therefore serialize there, which is affordable because the whole
  # section is one bulk statement.
  #
  # This is not one statement. At the 20,000-example design point it is 20,000 embeddings and 20,000
  # index lookups, and putting that inside the serialized section would make every other shard of
  # the run wait behind it. That is the reason the ingest endpoint answers `202` before any per-spec
  # work and the reason the `enqueue_embeddings` seam exists at all. So resolution runs afterwards,
  # out of band, against rows that are already committed.
  #
  # == Idempotency, and the two ways it is reached twice
  #
  # Every shard of a run enqueues a job for the *run*, so an N-shard delivery schedules N jobs over
  # the same rows, and a redelivered shard schedules another. Both are ordinary, and neither is
  # special-cased:
  #
  # * The work list is `SpecObservation.unresolved`, so a row already claimed is simply not in it —
  #   once the claim is WRITTEN. That write is per PAGE, not per row ({#link_all}, called from
  #   {#flush_page}), so a row stays visible to a concurrent job for up to {BATCH_SIZE} rows of embed
  #   + lookup + upsert rather than for one row. This bounds how much duplicate work an overlap costs;
  #   it does not affect whether the result is correct, which the next bullet answers. How OFTEN the
  #   overlap happens at all is {Ingest::IdentityResolutionJob}'s concern — it serializes one run's
  #   jobs — but that reduces the frequency and never the need for what follows.
  # * Two jobs that read the list at the same moment and both miss on the same text converge on one
  #   row, because the insert is an upsert onto `(repository_id, text_digest)` — see
  #   {#claim_identity} and the migration's "The conflict key" section.
  #
  # == The work list is TWO lists, and the second is what makes an unresolved row recoverable
  #
  # This run's unresolved observations, and — before them — the rows of the repository's EARLIER runs
  # that nothing else will ever revisit. Until that second list existed there was exactly one
  # `perform_later` in the whole application and its argument was the run just created, so run-1's
  # leftovers were never read again by anything: run-2's job walks run-2's rows. The identity was not
  # lost — run-2 re-creates it from the same text — but run-1's duration and outcome stayed orphaned
  # from that test's history permanently, which is the half of "nothing is permanently lost" that was
  # not true.
  #
  # That second list is itself two, because there are two ways a row is left behind and only one of
  # them leaves evidence (see {#retry_backlog}):
  #
  # * **Something was tried and it failed.** Stamped with `embed_failed_at`, bounded by
  #   {SpecObservation::EMBED_RETRY_WINDOW}, ordered so a large backlog drains fairly. Ordinarily
  #   that is the provider being asked and unable to answer; since {#claim_inherited} it is also a
  #   row of THIS list that failed some other way while the sweep held it. One stamp covers both,
  #   and {#record_resolve_failure} is where that is argued rather than assumed.
  # * **Nothing was ever tried**, because the job that would have tried never got there — an
  #   exception out of `perform`, a dropped connection, a deploy mid-job. There is no stamp, since
  #   {#record_resolve_failure} only runs where the row was actually reached, so this population
  #   was invisible to the first list and to both audit scopes: the ONE unresolved state with no
  #   query that could find it. {SpecObservation::EMBED_ATTEMPT_GRACE} is what makes it sweepable
  #   without racing the job that may still be on its way.
  #
  # The trigger is deliberately the next INGEST rather than a scheduled sweep. `config/recurring.yml`
  # has one production entry and it is Solid Queue housekeeping; adding a cron is a deployment
  # concern and a second thing that can be off. An ingest is the moment the answer can have changed
  # and the moment somebody is waiting for it, and it is already enqueuing this job.
  #
  # == What is deliberately not here
  #
  # Caching the embeddings — the rest of the *Cost* axis, still SPGD-72's. FOUR of that paragraph's
  # items ARE now here. Three of them do not depend on which provider is installed: skipping the
  # re-embed when a run's text is byte-identical to a row this repository already holds
  # ({#identical_text}); batching the lookup that answers it, so asking it costs one lookup per page
  # rather than one per row ({#digest_index}); and batching the two `UPDATE`s the answer then writes,
  # so an unchanged page costs a constant number of statements rather than two per row
  # ({#flush_page}). They shipped in that order because the first removes work rather than
  # reorganising it, and because the key both of the first two need already existed; each of the
  # later ones was worth doing once round trips rather than work were what was left.
  #
  # The fourth is the EMBED, and it is the one that is entirely about which provider is installed:
  # the path a CHANGED suite takes, which no equality can shortcut. {#page_embeddings} asks for a
  # page's worth of vectors in ONE provider request, so a changed 20,000-example suite is ~40 round
  # trips rather than 20,000 — which, on the network provider this application ships, is the
  # difference between a usable deployment and an unusable one, and the reason it went last rather
  # than never. CACHING those vectors was the rest of
  # that axis and it is now here too — {EmbeddingCacheEntry} for the store (SPGD-420) and
  # {#reclaim_expired_cache} for the half that bounds what it costs to keep (SPGD-428), which is
  # what makes it a store-and-invalidate answer rather than only the store. Also the ANN recall
  # measurement {#nearest} hands over by name.
  #
  # **Not** a `retry_on` / `discard_on` policy on {Ingest::IdentityResolutionJob}, and that omission
  # is now a finding rather than a deferral: `retry_on EmbeddingGenerator::Error` cannot fire.
  # {#embed} rescues that class at the single call site and returns nil, so the error never reaches
  # ActiveJob and the job always completes *successfully* having resolved nothing. The rescue is
  # deliberate — one unembeddable example must not abandon the other 19,999 — so the retry has to
  # live in the work list, which is where it now lives.
  #
  # {#claim_inherited} is the same argument applied one level out, and it is why a `retry_on` for
  # the OTHER errors is not the answer either. One inherited row that raises — an ANN lookup on a
  # dropped connection, a dimension-mismatched stored vector — used to abort the whole delivery
  # before this run's own list was reached, on every ingest of that repository forever, because the
  # backlog is walked first and a deterministic failure fails identically every time. A job retry
  # would only multiply that into N identical failed executions. Recovery lives in the work list, so
  # the containment does too: the row takes a stamp, sinks under the fairness ordering, and the
  # delivery goes on.
  class IdentityResolver
    # Rows per database round trip on the work list. A repository-scoped ANN lookup and an upsert
    # per row means a page of genuinely NEW text is round-trip bound whatever this is; what the batch
    # bounds is how many observations are held in memory at once, and 20,000 of them is the design
    # point.
    #
    # It is now also the width of every list this class puts ON THE WIRE rather than merely holds:
    # the digest short-circuit's `IN` list ({#digest_index}), and the two `VALUES` lists
    # {#flush_page} spends a page's decisions through. So on the ordinary case — an unchanged suite
    # re-ingested — the whole page's digest QUESTION is one round trip and the whole page's ANSWER
    # is two more.
    #
    # Stated as the invariant, because that is the part that survives the next slice: an unchanged
    # page costs **one digest lookup and two `UPDATE`s PER PAGE** — the identities' `last_seen`
    # touch and the observations' `spec_identity_id` — **plus a small constant for the work-list
    # reads**. Both `UPDATE`s were per ROW until SPGD-395, and that is why the resolver spec's
    # round-trip group now bounds them by their own predicate: a page cost that is O(1) in the page
    # WIDTH is a claim worth a falsifier, and it was O(N) while this comment's previous revision
    # said so.
    #
    # As an illustration and not as the claim: on this tree a 12-row unchanged page measures 12 round
    # trips — 1 digest lookup, 2 UPDATEs, 4 reads (the repository, {#resolve}'s two backlog lists,
    # and the run's own page), {#report}'s 4 counts, and 1 retention sweep statement
    # ({Ingest::EmbeddingCachePruner}, against an empty cache — see the caveat below) — where it
    # measured 33.
    #
    # A page that is exactly FULL measures **13 and not 12**, at any width, and the extra trip is
    # `find_in_batches`: a batch that comes back exactly `batch_size` wide cannot be known to have
    # exhausted the relation, so one more `SELECT` is issued and returns nothing. Worth the sentence
    # because the full page is the case this constant is ABOUT and the 12-row fixture is under-full —
    # the one width at which the probe cannot appear. Measured on this branch at two widths, 6 and
    # 12, and it is 13 at both; before SPGD-395 the same two measured 22 and 34, i.e. `2N + 10`,
    # which puts a full page of 500 at ~1,010. That flatness in the width — not the size of the drop
    # — is the whole of what that slice bought, and the sweep does not touch it: the sweep is issued
    # per PASS rather than per page, so it moves both of these figures by a constant and neither of
    # them with the width.
    #
    # ⚠️ **That constant is one only when the backlog is empty.** {Ingest::EmbeddingCachePruner}
    # issues AT MOST ONE statement PER BATCH and up to
    # {Ingest::EmbeddingCachePruner::MAX_BATCHES_PER_RESOLVE} of them, breaking early on a short
    # batch — so a pass costs 1 statement with nothing to reclaim and up to 5 with a backlog. The
    # figures above read as exactly one because the specs run against an empty cache table, which
    # makes the first batch short. The invariant that holds at every width is what matters here:
    # the sweep is O(1) in the page width, not that it is exactly one statement.
    # (The `2N + 10` figures were measured before this pass carried a retention sweep, so the
    # like-for-like comparison against them is 12 rather than 13.)
    #
    # Deliberately phrased as the invariant plus an example, because the total is rebase-fragile in a
    # way the invariant is not: it was 28 before SPGD-379 split the backlog into two reads, 29 after,
    # and 33 once SPGD-388 added the completion report — three revisions of one number for changes to
    # methods this constant has nothing to do with.
    #
    # What it does NOT bound is a page of genuinely new text, and the paragraph above says why: the
    # ANN lookup is still one per row, so a first run is round-trip bound whatever this is. The embed
    # no longer is — {#page_embeddings} asks for the page's vectors in one request, and asks for none
    # of the ones this deployment already owns — and neither is the insert, which is one
    # `INSERT … ON CONFLICT` for the page's whole set of new identities
    # ({#insert_pending_identities}) where it was one per miss. Both lower that page's floor without
    # changing its shape, and the ANN lookup is the only per-row round trip this path has left. The
    # number tuned here is what an UNCHANGED page costs, which is the ordinary case; the changed one
    # is SPGD-375's lookup.
    #
    # **It is the one number here whose square something pays, and that is worth knowing before
    # raising it.** Deferring the insert means a page's misses are compared against each other in
    # process ({#nearest_pending}) rather than through the index, which is O(page²) on a page of
    # pure misses. On the provider that ships — `VoyageProvider`, 1024 dimensions, **dense** — that
    # is 124,750 pairs of 1024-element Ruby dot product per full page, and it makes a first ingest
    # ~1.4s per page SLOWER than the per-row path on a local socket, bought back only once a
    # statement's round trip exceeds ~2.9ms. {#nearest_pending} carries the measured ledger and the
    # two cheaper scans that were tried and refused.
    #
    # **What that implies for this number, stated because the ledger above invites the question.**
    # The scan is O(page²) per page and therefore O(N x page) over a suite, while the round trips
    # batching saves are O(N) and almost independent of page width — at any page above ~100, a
    # 20,000-example first ingest saves ~N of them either way. So the two pressures point OPPOSITE
    # WAYS and shrinking this number strictly improves the first ingest: halving it halves total
    # scan time while giving up almost none of the batching's benefit.
    #
    # It stays at 500 regardless, and the reason is that a first ingest is not what this constant is
    # tuned for. Halving it doubles the page count, and with it the 13 statements every page costs
    # on an UNCHANGED re-ingest (pinned at `identity_resolver_spec.rb`'s "what a page of unchanged
    # text costs in round trips") — the ordinary case, paid on every CI run for the life of the
    # repository, against a first ingest paid once. Trading the common case for the rare one is the
    # wrong direction. And this has exactly ONE use site — `find_in_batches(batch_size:)` in
    # {#resolve} — which makes it look more local than it is: it sets the page width, and every
    # per-page cost in this class (the embed request, the digest short-circuit, the three flush
    # statements, this scan) is a function of the page it hands out. Recorded here as a known
    # tension, not resolved unilaterally: if a first ingest's wall clock ever becomes the complaint,
    # this paragraph is where the lever is, and lowering the page is the lever.
    #
    # **What it does not decide is how many identities a suite gets**, and that is a property worth
    # stating because one revision of this slice broke it: a page-pending row is matched at the same
    # `SpecIdentity::MATCH_SIMILARITY` the index applies, so two near-identical new tests land on one
    # identity whether they share a page or straddle the boundary between two. This stays a knob on
    # cost, tunable without changing what a repository ends up holding.
    #
    # That makes this a size worth tuning where it used not to be, but not a different KIND of
    # constant: both readings bound one page, and neither is a bound on how much work a delivery
    # inherits — that is {RETRY_SWEEP_LIMIT}, and it stays separate for the reason stated there.
    BATCH_SIZE = 500

    # **How much of an earlier run's unfinished business ONE JOB is made to pay for.** The cost
    # bound on the cross-run sweep — on BOTH of the lists {#retry_backlog} draws it from, together
    # and not each — and its own constant rather than a reuse of `BATCH_SIZE` by the rule this
    # codebase's `_LIMIT`s obey: that one bounds how many rows are held in MEMORY at once and would
    # be just as correct at 50 or 5,000, this bounds how much EXTRA WORK a delivery inherits from
    # deliveries before it. They move for different reasons and one number standing for both would
    # make that a single edit nobody meant to make.
    #
    # A bound is needed because the failure mode is the design point: a provider outage across a
    # 20,000-example run leaves 20,000 failed rows — and a job that dies mid-resolve leaves up to as
    # many unattempted ones — so an uncapped sweep would make the very next ingest do 40,000
    # embeddings, its own suite plus the whole backlog, on the one path that is already the largest
    # thing this application does. Capped, a job is at worst its own share of the suite plus 500, and
    # a backlog larger than the cap drains across the ingests that follow instead of landing on one
    # of them.
    #
    # **Across both lists and never per list**, which is what {#retry_backlog} is a method for
    # rather than a relation: two lists each capped at this number is a job inheriting `2 × 500`
    # while this comment went on claiming 500.
    #
    # == A JOB and not an INGEST, and the difference is the shard count
    #
    # Stated precisely, because the imprecise version is contradicted by this class's own comment
    # three sections up: *every shard of a run enqueues a job for the run*, so an N-shard delivery
    # runs {#retry_backlog} N times, largely over the same rows, for up to `N × RETRY_SWEEP_LIMIT`
    # backlog embeddings in one ingest. That is the same duplicate-work multiplier
    # {SpecObservation::EMBED_RETRY_WINDOW} names as fatal to an attempt cap, and it does not
    # disappear here just because this is a cost bound rather than a lifetime bound.
    #
    # It remains a bound worth having, and the reason is what it is a function OF. `N × 500` follows
    # the SHARD COUNT, which is a small constant a client picks; an uncapped sweep follows the
    # BACKLOG, which is the suite size. A 20,000-row backlog still cannot land on one delivery. What
    # would be untrue is the sentence "an ingest is at worst its own suite plus 500", so it is not
    # the sentence.
    #
    # It is a cap on ROWS and never a fraction of the run, so a small delivery cannot be made to
    # carry a large one's backlog in proportion to itself. Sized at the same order as one batch: the
    # sweep loads its rows in a single query rather than in batches, so this is also what keeps that
    # load the size of one `BATCH_SIZE` page — the coincidence of value is not a coincidence of
    # meaning, which is precisely why they are two constants.
    RETRY_SWEEP_LIMIT = 500

    # One row of {#digest_index}'s answer: the identity this repository holds under some digest, and
    # **which of {Ingest::SpecSignal}'s sources supplied its text**.
    #
    # The id alone was the whole of what the map needed while the only question asked of it was "is
    # this text already held". The name→intent upgrade ({#upgrade_from_name}) asks a second one — *is
    # the row under this test's NAME a name-derived row* — and the answer decides whether a row is
    # rewritten, so it cannot be inferred from the id. Carried here rather than fetched per candidate
    # because it rides the same `pluck`: one more column on a query the page already issues, against
    # a round trip per upgrade otherwise.
    #
    # Still no record and still no vector, which is {#digest_index}'s standing rule — `signal_source`
    # is a short string, and loading identities to read one of their columns would put the 1024
    # element embeddings that method exists to avoid touching straight into memory.
    HeldIdentity = Struct.new(:id, :source) do
      # Mirrors {SpecIdentity#from_name?} over the plucked value rather than over a record. The two
      # read the same column and must agree; this one exists because there is no record here.
      def from_name? = source == "name"
    end

    # **A stand-in for the id of a row this page has decided to insert but has not inserted yet.**
    # {#claim_identity} buffers its row and hands one of these back; {#insert_pending_identities}
    # issues the page's single `INSERT` and {#substitute_pending} replaces every one of them with the
    # id the database returned, before any statement that could carry it is built.
    #
    # A Struct and deliberately not a negative integer or any other in-band id. A placeholder that
    # survived substitution has to fail LOUDLY: as an object it makes {#link_all}'s bind refuse it,
    # or {#resight_all}'s, at the seam that produced it. As an integer it would be written to
    # `spec_observations.spec_identity_id` — a foreign key to a row that does not exist, or worse a
    # row that does — and the first anyone heard of it would be a repository whose observations point
    # at strangers.
    #
    # Carries the DIGEST rather than an index into the buffer, because the digest is what the
    # returned ids are keyed by ({#insert_pending_identities} maps `RETURNING` by `text_digest`, not
    # by position) and what the buffer itself is keyed by — one name for the row, held by everything
    # that has to agree about which row it is.
    PendingIdentity = Struct.new(:digest)

    # **One pending row's vector, in the form {#nearest_pending} can compare cheaply.** The page's
    # answer to a question {#nearest} can no longer be asked: the rows this page has decided to
    # insert are not in the table yet, so the index cannot see them.
    #
    # Stored as the indices of the non-zero dimensions and their values rather than as the dense
    # 1024-wide array. **Read what that does and does not buy, because it is easy to over-read.**
    #
    # It is a compression that is INERT on everything this application ships. The one provider is
    # `EmbeddingGenerator::VoyageProvider` (`voyageai/voyage-4-lite`, 1024 dimensions — owner
    # decision, 2026-08-17, "one provider, one model, one width"), and its vectors are dense: every
    # dimension non-zero, so `indices` holds all 1024 of them and the scan pays the dense cost. The
    # suite's default stub (`spec/support/embedding_generator.rb`) is dense too — measured, 1024 of
    # 1024 non-zero. The only configuration in which this shape compresses anything is
    # `LexicalEmbeddingProvider`, which is spec-only by its own header ("**Not shipped**") and which
    # feature-hashes a description into a few percent of the 1024 dimensions. How few is a function
    # of description LENGTH rather than a constant, so it is quoted as a range over a named corpus —
    # the descriptions these specs actually use — instead of as a single figure over an unnamed one:
    # 24/1024 (2.3%) for "rejects an expired card", 40/1024 (3.9%) for "Order#checkout rejects an
    # expired card", and 75/1024 (7.3%) for the longer `Invoice#finalize` description in
    # `identity_resolver_spec.rb`'s pluralisation example.
    #
    # Kept anyway, on two grounds and not on a claim about what ships. It is CORRECT under either
    # density — walking the non-zero dimensions is the same dot product, not an approximation of one
    # — and it is what the identity-resolution specs actually run under, so the code exercised by
    # the suite is the code deployed. What it must not be read as is a reason the scan is cheap in
    # production. It is not; {#nearest_pending} carries the measured ledger for the dense case, and
    # the dense case is the shipped one.
    #
    # Carries its own `magnitude` so the comparison is a true COSINE rather than a bare dot product.
    # Every provider in this tree whose output can be inspected normalises explicitly — the suite's
    # stub and `LexicalEmbeddingProvider` both divide by the norm — which is what makes the division
    # LOOK like dead code. Nothing enforces it: `EmbeddingGenerator.validate` checks width and
    # finiteness and does NOT check normalisation, and a vendor's normalisation is a property of the
    # vendor rather than of this interface. A provider returning unrolled vectors would silently turn
    # every similarity here into a number that is not one, against a threshold that assumes it is.
    # One `Math.sqrt` per pending row buys the guarantee that this method and `nearest` are answering
    # the same question.
    PendingVector = Struct.new(:digest, :indices, :values, :magnitude)

    # One identity's pending spelling refresh — see {#note_drift} for what earns a row one and
    # {#refresh_all} for which of a page's candidates is actually written.
    #
    # Carries the observation because the page settles WHICH spelling wins by settling which
    # SIGHTING wins ({#newest_sighting_per_identity}), and that is a question about observations.
    # Carries `from_digest` — the digest the identity was holding when the match was made — because
    # the write is a compare-and-set on it, so a concurrent writer that has already moved the row
    # off that digest refuses this statement instead of racing it.
    Drift = Struct.new(:observation, :text, :digest, :from_digest, :embedding)

    def self.resolve(run) = new(run).resolve

    def initialize(run)
      @run = run
      @repository = run.repository
      # Replaced wholesale by each {#resolve_page}; `{}` here so the three methods that touch it —
      # {#identical_text}, {#upgrade_from_name} and {#claim_identity} — are total rather than
      # conditional on a page being open, and so that a page is a page's worth of entries rather
      # than the suite's.
      @digest_index = {}
      # The page's embeddings, filled by {#page_embeddings} for the same reason and with the same
      # guarantee: {#embedding_for} is total rather than conditional on a page being open, and falls
      # back to a single embed for a text no page fetched — unless `@provider_dark` below has been
      # tripped, in which case that fallback answers nil rather than asking. See {#embedding_for},
      # which explains where the missing key comes from and why the breaker has to be re-read there.
      @embeddings = {}
      # The page's write buffers, emptied and refilled by every {#resolve_page} for the same
      # reason and with the same total-rather-than-conditional guarantee: {#resight}, {#claim} and
      # {#claim_identity} append to them one row at a time, and {#flush_page} spends each on ONE
      # statement. See {#resolve_page} for why the decision stays per row while the write is per page.
      @sightings = []
      @links = []
      # The page's pending identity inserts, `digest => row attributes`. Keyed by digest and never a
      # list, because one `upsert_all` carrying two rows with the same `(repository_id, text_digest)`
      # is refused by Postgres outright ("ON CONFLICT DO UPDATE command cannot affect row a second
      # time") — a page-shaped crash where the per-row path merely conflicted onto itself. The map
      # {#claim_identity} writes is what stops a second byte-identical row reaching it at all; this
      # key is the belt to that brace, and it is the same key the returned ids arrive under.
      @pending_identities = {}
      # The vectors of the rows above, as {PendingVector}s — **what {#nearest} cannot see, answered
      # without asking it.** A page's pending rows are not in the table yet, so the index lookup
      # misses them, and the per-row path this replaced did not: it inserted each row before the
      # next row asked. Scanned by {#nearest_pending}, which is what keeps a page's identity graph
      # the same one the per-row path produced.
      @pending_vectors = []
      # The page's pending spelling refreshes, `identity_id => {Drift}` — one entry per identity by
      # construction, which is {#note_drift}'s first bound against thrash. Same total-rather-than-
      # conditional guarantee as the two buffers above.
      @drifts = {}
      # **The PASS-scoped state, and it is the only state here {#resolve_page} does not empty.**
      # Everything above is a page's worth by design; these are deliberately a whole `#resolve`'s,
      # because the hazard each answers is a page BOUNDARY and a per-page value cannot see across
      # one. See {#refresh_all} for what the two sets refuse and why one page's bound was not enough.
      #
      # `@refreshed` — identities this pass has already written a spelling to. `@spellings_in_use` —
      # identities some observation of this pass matched by exact text ({#identity_for}), so their
      # stored spelling is demonstrably still presented and is not stale.
      @refreshed = Set.new
      @spellings_in_use = Set.new
      # `@provider_dark` — this pass has watched a whole page's batch request AND every one of its
      # per-signal retries fail, which is evidence about the PROVIDER rather than about any of those
      # texts, so it asks the provider nothing more. See {#embed_page} for the trip condition and
      # what a skipped text costs, and {#report} for where a tripped pass says so.
      #
      # **Pass-scoped and deliberately never process-scoped**, which is the difference between this
      # and a circuit breaker. A flag that outlived its `#resolve` would make the NEXT ingest skip a
      # provider that has since recovered — silently, with no ask to discover the recovery with and
      # nothing but a deploy to end the skipping. A per-pass flag is re-earned from scratch by every
      # pass, so the cost of being wrong about an outage is one page of requests and never a
      # deployment that has stopped embedding.
      @provider_dark = false
    end

    # @return [Integer] how many observations now carry an identity that did not before — **across
    #   both lists**, so a rescued row of an earlier run is counted here too. Not `specs.size`, and
    #   deliberately not "observations OF THIS RUN": the number says what this invocation resolved,
    #   which is the only thing it has ever been read as and the only thing the caller could act on.
    #   A run whose own rows all resolved and which rescued four earlier ones returns the four; the
    #   alternative — counting only `@run`'s rows — would report a sweep that did real work as a
    #   no-op. `spec/services/ingest/identity_resolver_spec.rb`'s "running twice over the same run"
    #   example is unaffected either way: a repository with no failed embeds has an empty backlog.
    #
    #   An inherited row {#claim_inherited} contained contributes 0, for the same reason a row that
    #   never had an identity to find does: it does not now carry one. The count says what was
    #   resolved and never what was attempted, so containment cannot inflate it.
    def resolve
      resolved = 0

      # **The backlog first, and the order is deliberately NOT load-bearing.**
      #
      # It was, and that was the defect this rework exists for. A re-sighting moves the identity's
      # "last known path", so whichever observation is resolved LAST used to have the final word on
      # where the test was last seen — and this loop holds observations from several runs at once,
      # so "last" had to mean "newest" for that word to be true. Two axes then wanted one ordering
      # key: chronology wants oldest-first, and {#failed_embed_backlog}'s fairness wants least-tried
      # first, which is INVERSELY correlated with age because an older failed row has been swept by
      # more ingests and carries a higher count. No single key serves both, and the one that was
      # chosen served fairness while a comment here claimed it served chronology.
      #
      # So the ordering stopped being the mechanism. {SpecIdentity::SIGHTING_NOT_OLDER} refuses, in
      # SQL and on both of the two paths that re-sight a row, a sighting from a run older than the
      # one the identity already names. Monotonic by construction: these two lists may be walked in
      # any order at all — including interleaved by two concurrent jobs, which no iteration order
      # could have covered anyway — and the identity still ends on the newest run that saw the test.
      #
      # The backlog stays first because it is the older debt and a rescue is what somebody is
      # waiting for, not because anything depends on it being first.
      #
      # **Both lists are walked a PAGE at a time**, because the digest short-circuit is answered per
      # page and what it decides is written per page — see {#resolve_page}. The backlog is already
      # capped at one page by
      # {RETRY_SWEEP_LIMIT} — across BOTH of the reads {#retry_backlog} draws it from, together and
      # not each — and those reads' `order` and `limit` are load-bearing, so it is handed over as the
      # one page it already is rather than made symmetric with `find_in_batches`, which would ignore
      # both. It arrives as an Array for that budget's arithmetic and is a page all the same.
      #
      # `inherited: true` sends this page's rows through {#claim_inherited} and not {#claim}, and
      # the asymmetry is the point: a row of an earlier run is best-effort by construction, so one
      # of them failing is contained to itself rather than allowed to end the delivery. The
      # run-scoped loop below takes the default and keeps claiming bare — see {#claim_inherited} for
      # why the two halves are treated differently.
      resolved += resolve_page(retry_backlog, inherited: true)

      @run.spec_observations.unresolved.find_in_batches(batch_size: BATCH_SIZE) do |page|
        resolved += resolve_page(page)
      end

      reclaim_expired_cache
      report(resolved)

      resolved
    end

    private

    # Reclaim the disk {EmbeddingCacheEntry::RETENTION_WINDOW} has already stopped serving from —
    # see {Ingest::EmbeddingCachePruner} for the rule, for why the ceiling converges, and for why
    # this seam and not `Ingest::RunRecorder`'s.
    #
    # **Here because this class is the table's only writer**, on the same rule that puts the
    # `spec_observations` pruner at the write path that grows THAT table. It runs after both lists
    # have been walked and before {#report}, so a pass reclaims what it can only once the work
    # somebody is waiting for is done, and so the report stays the last line of the pass.
    #
    # ⚠️ **Contained on exactly the terms {#store_embeddings} is contained, and the sibling
    # pruner's opposite policy must not be read across.** `Ingest::ObservationPruner` lets a prune
    # failure fail the ingest on purpose, because the rows it bounds are the product's data and a
    # rule that has stopped keeping up is the last thing that should fail quietly. This table is a
    # cache and every caller is required to be able to lose it, so the same failure here — an unrun
    # migration, a saturated pool, a statement timeout on a table that got large before this rule
    # arrived — must cost this resolve nothing at all. A prune that could abandon a page of rows
    # mid-pass would have made a losable cache load-bearing for the only path that resolves
    # anything, which is the one thing {EmbeddingCacheEntry} forbids.
    #
    # `warn` and not `error`, and the register is the point rather than a formality: nothing is
    # wrong with this resolve. It is the same line {#cached_embeddings} and {#store_embeddings}
    # emit, saying the same thing — the application is correct and merely holding more disk than
    # its own rule says it should, until the next ingest tries again.
    def reclaim_expired_cache
      Ingest::EmbeddingCachePruner.prune
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not reclaim expired cache entries: " \
        "#{e.message}; the retention window still bounds what is served"
      )
      nil
    end

    # **The one thing this pass says for itself.** Until it existed the whole asynchronous half of
    # ingest had a single voice — the per-row warn in {#embed} — and that voice can only speak about
    # rows the provider refused. So a resolve of 20,000 rows that worked perfectly and a resolve that
    # was never scheduled at all were the same observable event, while a provider outage across the
    # design point emitted 20,000 identical lines and no total. This is the complement: one line, per
    # pass, whatever happened, carrying the number {#resolve} already computes and the population it
    # left behind.
    #
    # `info` rather than `warn`, and unconditional rather than "only when something is wrong". The
    # figure an operator most needs is `resolved=0`, and a report that stays silent when there is
    # nothing to complain about cannot distinguish "nothing to complain about" from "did not run" —
    # which is the defect this method exists for, reintroduced one level up.
    #
    # Emitted from HERE and not from {Ingest::IdentityResolutionJob} because the counts are this
    # class's own vocabulary: which four scopes are the bounded ones, and why a raw `unresolved`
    # count is not among them, is the knowledge {#retry_backlog} and {SpecObservation} hold. The job
    # is thin by its own class comment's rule, and it stays thin. A run that no longer exists never
    # reaches here at all — the job returns before it resolves, and there is nothing to report.
    #
    # A single line and not four, because a log is read by grep and by eye: four lines per job would
    # have to be re-joined by whoever read them, and the joining key would be the run id they all
    # already carry.
    #
    # **A tripped provider breaker is named on that same line**, for the reason the resolved count
    # is here at all. A pass that STOPPED ASKING and a pass that asked and was refused are different
    # events, and the difference is invisible in `embed_failed_retrying`: both populations are
    # stamped identically, on purpose ({#embed_page}). Without the marker an operator would have to
    # infer the trip from an ABSENCE — the per-row warn lines that are no longer there — which is
    # exactly the inference this method exists to stop asking anybody to make.
    def report(resolved)
      fields = ["run=#{@run.id}", "resolved=#{resolved}", "repository=#{@repository.id}"]
      fields.concat(unresolved_bounds.map { |label, relation| "#{label}=#{relation.count}" })
      # The one conditional field here, and the asymmetry with the four counts above is deliberate.
      # Each of those is a FIGURE whose zero is a positive statement an operator needs to read; this
      # is an EVENT, and `provider_breaker=healthy` on every line of every pass forever would be
      # noise standing in for the absence of one. Greppable in the direction that matters:
      # `provider_breaker=tripped` finds every pass that stopped asking, and the passes that did not
      # are already enumerable by the line itself.
      fields << "provider_breaker=tripped" if @provider_dark

      Rails.logger.info("[IdentityResolver] #{fields.join(' ')}")
    end

    # **The repository's remaining unresolved population, as the four figures it is honest to state
    # it in** — and deliberately not as one.
    #
    # Each is `@repository.spec_observations` narrowed by a scope that already exists and had, until
    # this method, no production caller at all. Repository scoping is the caller's on all four
    # ({SpecObservation}'s scopes say so where they are defined), which is why they are narrowed here
    # and exactly as {#failed_embed_backlog} and {#unattempted_embed_backlog} narrow theirs.
    #
    # == Why four figures and never a sum
    #
    # * **"We stopped trying" and "we are still trying" are different facts**, which is the reason
    #   `.embed_abandoned` and `.embed_unattempted_abandoned` were given their own scopes:
    #   *"a bound that cannot be queried is a bound nobody can audit"*. Pooling them back into one
    #   `unresolved=N` here would spend that separation on the way out.
    # * **The two backlogs are different facts**, because the reason nobody attended to them differs
    #   — asked and refused, versus never asked — and that is the whole distinction {#retry_backlog}
    #   is two lists for.
    # * **`never_attempted_gave_up` is NOT a failure count**, and its name says so. That scope's own
    #   comment forbids the other reading outright: the set is *"rows nothing will ever attempt
    #   again"* and NOT *"rows we failed"*, because it pools rows a dead job stranded and outlived
    #   with the frozen signalless tail that is behaving exactly as it should. Labelling it a failure
    #   would ship *"an alarming number that is mostly legacy rows behaving correctly"*.
    #
    # == Why not `.unresolved.count`, which is the figure everyone reaches for first
    #
    # Because it is not bounded away from rows that are merely YOUNG. All four scopes here sit inside
    # `EMBED_RETRY_WINDOW` and outside `EMBED_ATTEMPT_GRACE`; a raw count is neither, and
    # {#unattempted_embed_backlog} states why that matters — the unattempted population *"cannot be
    # empty on a healthy repository — every row is in it between the ingest commit and the job's
    # pass"*. A raw count taken while a concurrent 20,000-row delivery is mid-flight reports that
    # delivery as a problem, on every ingest, forever. The four figures stay at zero through it.
    #
    # == What these numbers are NOT
    #
    # They are a REPOSITORY snapshot read at the end of this pass — not a tally of what this pass
    # did, which is what `resolved` is, and not a partition of anything. Every shard of a run
    # enqueues a job for the run, so an N-shard delivery emits N of these over largely the same rows
    # while other jobs are mutating them; the same distinction {#resolve}'s `@return` draws for the
    # resolved count, kept rather than re-invented.
    #
    # And they do not add up to the run, or to the repository, or to each other's complement. Rows
    # younger than the grace are outside all four, and so is the signalless tail pooled inside the
    # last of them. Four bounded figures that answer four questions is the whole claim; a total would
    # be a new vacuous figure replacing a missing one.
    def unresolved_bounds
      observations = @repository.spec_observations

      { embed_failed_retrying: observations.embed_retryable,
        embed_failed_gave_up: observations.embed_abandoned,
        never_attempted_retrying: observations.embed_unattempted_retryable,
        never_attempted_gave_up: observations.embed_unattempted_abandoned }
    end

    # **The work that is not this run's**, under one budget — the rows of the repository's EARLIER
    # runs that this ingest is entitled to attempt on their behalf. Two populations, and they are
    # two because the reason nobody attended to them is different:
    #
    # * {#failed_embed_backlog} — something was tried and it failed. Stamped with `embed_failed_at`,
    #   ordered by how often it has been tried, bounded by {SpecObservation::EMBED_RETRY_WINDOW}.
    #   Ordinarily that is the provider being asked and unable to answer; since {#claim_inherited} it
    #   is also a row of THIS list that failed some other way while the sweep held it. One stamp
    #   covers both, and {#record_resolve_failure} is where that is argued rather than assumed.
    # * {#unattempted_embed_backlog} — nothing was ever tried, because the job that would have tried
    #   never got there. Unstamped, and therefore invisible to every mechanism the first list is
    #   built on.
    #
    # The failures come first and take their share of the budget first. Not because the order is
    # load-bearing — {#resolve} explains at length why no iteration order is any more — but because
    # a stamped row is a row something has already tried and failed to rescue at least once, which
    # is a stronger claim on a scarce slot than a row nobody has tried at all.
    #
    # == ONE budget, and this is the whole reason the method exists
    #
    # `RETRY_SWEEP_LIMIT` bounds *"how much EXTRA WORK a delivery inherits from deliveries before
    # it"*, and that sentence is about the inheriting, not about any particular list. Two
    # independently `.limit(RETRY_SWEEP_LIMIT)`ed relations would quietly double what a job can
    # inherit — `N × 2 × 500` at the shard multiplicity that constant already accounts for — while
    # every word of its comment went on reading as though it had not changed. So the second list is
    # asked for the REMAINDER, and a full first list means it is not queried at all.
    #
    # An Array rather than a relation, which is what makes that arithmetic possible at all: two
    # relations over disjoint predicates with different ordering keys cannot be capped jointly in
    # one statement without a UNION whose outer ordering key neither list has. {#resolve} hands the
    # result straight to {#resolve_page} as the ONE PAGE it already is — `RETRY_SWEEP_LIMIT` is one
    # `BATCH_SIZE` — so the digest short-circuit is batched over this list exactly as it is over a
    # run's own page, and nothing downstream notices that this is an Array. `find_in_batches` was
    # never available to either half in any case: it ignores exactly the `order` and `limit` these
    # two reads are, which is why the cap is applied here and the page seam reads it rather than
    # re-deriving it.
    def retry_backlog
      failed = failed_embed_backlog.to_a
      remaining = RETRY_SWEEP_LIMIT - failed.size
      return failed if remaining <= 0

      failed + unattempted_embed_backlog(remaining).to_a
    end

    # One page of the work list: ask the database once which of these texts this repository already
    # holds, ask the provider once for the vectors the rest of them need, decide each row against
    # those two answers, and write what the whole page decided in a fixed number of statements rather
    # than in three per row.
    #
    # This is where the page seam has to be. Both of {#resolve}'s lists run through {#claim}, and
    # {#identity_for} sees one observation at a time and cannot know what the other 499 are — so a
    # lookup driven from in there is a lookup per row however cheap the row makes it, and so is a
    # write.
    #
    # **The DECISION stays per row and only the COST is per page**, which is the same division
    # {#digest_index} introduced and is now the shape of both halves. A row the index cannot answer
    # still falls through to embed/{#nearest}/{#claim_identity} unchanged, and {#identical_text} is
    # still the method that answers one row — see it for why that seam is load-bearing rather than
    # stylistic. What changed is that {#resight}, {#claim} and {#claim_identity} now RECORD what they
    # decided instead of writing it, and {#flush_page} spends each buffer on one statement.
    #
    # `inherited:` chooses which of the two claim seams the page's rows take, and it is a parameter
    # rather than a second method because the page itself is identical either way: the same one
    # lookup, the same per-row decision after it, the same writes at the end. {#claim_inherited}
    # for the repository's earlier runs, {#claim} for `@run`'s own, and {#claim_inherited} is where
    # the asymmetry is argued.
    #
    # **{#digest_index} and {#flush_page} are outside that containment, deliberately and for one
    # reason.** Each is one query for the whole page, so a failure in either is not row-shaped: there
    # is no single observation it can be attributed to, stamped and demoted. Rescuing the lookup
    # would leave an empty map that silently re-embeds the entire page while reporting a clean sweep;
    # rescuing the flush would report rows as resolved that carry no identity. Both propagate, which
    # is the same line {#claim_inherited}'s stated non-promise draws.
    #
    # {#page_embeddings} is the third page-shaped statement and it is the one exception, because the
    # failure it can meet is one it CAN attribute: `EmbeddingGenerator::Error` is the provider's, the
    # texts that were in the request are known, and {#embed_page} re-asks them one at a time so each
    # lands back on the row that contributed it. Only that class is rescued there and only around the
    # provider call, so anything else about the page — including a row whose signal cannot be read —
    # propagates exactly as {#digest_index}'s does.
    #
    # == The `ensure` is load-bearing, and it is what keeps a DIED pass behaving as it did
    #
    # A per-row write commits per row, so a pass that raises halfway through a page used to leave
    # the rows it had already claimed holding their identity and the rest untouched and unstamped —
    # the state "a resolve that died before it reached the rest of the run" describes at length and
    # the cross-run sweep exists to rescue. A buffer flushed only on the happy path would quietly
    # widen that: everything the page had decided would be discarded, and rows the resolver had
    # genuinely resolved would go back to looking never-attempted. So the flush runs on the way out
    # whatever the way out is, and the exception propagates after it exactly as before.
    #
    # **And it must not cost the diagnosis it exists to preserve.** A flush that raises while an
    # exception is already propagating would replace it — Ruby discards the in-flight exception for
    # whatever an `ensure` raises — so a page that died on {#nearest} and then met a deadlock in
    # {#flush_page} would report the deadlock and lose the cause. That is not hypothetical now that
    # the flush is where a page's database errors surface ({#write_page}): the page's writes are the
    # only statements left on this path that a concurrent job can collide with. So the flush's own
    # failure is logged and dropped WHEN there is an original to keep, and raised as before when
    # there is not. Dropped and never swallowed silently: the log line names both, because "the page
    # failed twice" is a different event from either one alone.
    def resolve_page(observations, inherited: false)
      @digest_index = digest_index(observations)
      @embeddings = page_embeddings(observations)
      @sightings = []
      @links = []
      @pending_identities = {}
      @pending_vectors = []
      @drifts = {}
      resolved = 0

      begin
        observations.each do |observation|
          inherited ? claim_inherited(observation) : claim(observation)
        end
      ensure
        in_flight = $!

        begin
          resolved = flush_page
        rescue StandardError => e
          raise if in_flight.nil?

          Rails.logger.error(
            "[IdentityResolver] run=#{@run.id} page flush failed with #{e.class}: #{e.message} " \
            "while #{in_flight.class} was already propagating; keeping the original"
          )
        end
      end

      resolved
    end

    # The page's writes, and the whole of what this lineage bought: **O(1) statements per page where
    # there were two `UPDATE`s and an `INSERT` per ROW.**
    #
    # Order matters and it is the order the per-row path had. A re-sighting moves the identity;
    # linking the observation is what makes it resolved. Flushing the sightings first keeps the two
    # in the same relative order they were written in when they were written per row, so a pass that
    # dies between them leaves the same state a pass that died between two rows' UPDATEs did.
    #
    # **{#insert_pending_identities} goes FIRST, and for two reasons that happen to agree.** It is
    # the statement that produces the ids: a page's new identities are held as {PendingIdentity}
    # placeholders while the page is walked, and every buffer below can be carrying one, so the
    # substitution has to happen before anything binds them. And it writes `spec_identities`, so it
    # belongs on the same side of the identities/observations lock order as {#resight_all} and ahead
    # of {#link_all} — see below, and {#write_page} for what that order is for.
    #
    # It is also the seam the placeholders are resolved at, and deliberately the ONLY one. The three
    # methods below read `@sightings`, `@links` and `@spellings_in_use` exactly as they did when
    # every id in them was already real; resolving a placeholder inside each consumer instead would
    # be three implementations of one rule that have to agree, and a fourth the next slice forgets.
    #
    # It is also, now, a lock order. Both `UPDATE`s are multi-row ({#write_page} argues what that
    # changed), and every page of every job issues them in this order — identities, then
    # observations — so two concurrent passes cannot hold one of these tables while waiting for the
    # other. Whatever contention is left is inside a single table, which is what {#write_page}'s
    # sort and its retry are about.
    #
    # **{#refresh_all} goes LAST, after both of them, and that ordering is load-bearing.** It is the
    # only write on this path that is OPTIONAL: the sightings and the links are what the page
    # decided and what {#resolve_page}'s `ensure` exists to get written even when the walk died
    # halfway; the refresh is a convergence write whose entire benefit is that the NEXT ingest is
    # cheaper. Issued first, any error it raised that its own rescue does not name — a deadlock, a
    # lock timeout, a statement timeout on a page carrying many drifts — would propagate out of here
    # before either required statement was issued, and a page that had already met an exception
    # would take the "keep the original" branch and silently discard everything the page resolved.
    # An optional write must not be able to cost the page its required ones, so it is ordered behind
    # them and the count is taken before it. (It has no lock-ordering claim to make by going first:
    # it commits its own transaction per row and holds nothing while the statements above run.)
    #
    # **It IS a per-row write in a burst, and the bound is page-shaped rather than lifetime-shaped.**
    # An ordinary page issues nothing at all, and an identity crosses the drift transition once —
    # but "once" is the bound over an identity's LIFETIME, not over an ingest. A single style change
    # that reformats punctuation across a suite drifts every row on the same ingest, and this then
    # issues one single-row `UPDATE` per drifted identity: up to `BATCH_SIZE` per page, 20,000 across
    # a suite at the design point, on that one ingest. That is the per-row shape this lineage exists
    # to remove, and it is chosen here with the trade named: the batched `VALUES` form is available
    # ({#resight_all}'s statement with the compare-and-set moved into the join), but one identity
    # whose presented spelling is already held by another row raises `RecordNotUnique` and would
    # abort the whole batch with it, losing every other row's convergence to one row's conflict.
    # Per-row keeps that refusal contained to the row it belongs to ({#refresh}), and it is paid on
    # the ingest AFTER a mass edit and never again — the population it walks is the population that
    # has not converged yet, which is empty on every steady-state page.
    #
    # **{#newest_sighting_per_identity} is settled ONCE, here, and handed to both readers.** It was
    # {#resight_all}'s private business while it had one; {#refresh_all} is the second, and the two
    # must agree about which of a page's observations speaks for an identity or the row could take
    # one observation's path and another observation's spelling. Passing the settled list is what
    # makes that agreement structural rather than a property of calling the same method twice.
    #
    # @return [Integer] how many observations this page actually linked — see {#link_all}, which
    #   counts the rows the statement MATCHED rather than the rows it was handed.
    def flush_page
      insert_pending_identities
      sightings = newest_sighting_per_identity

      resight_all(sightings)
      resolved = link_all
      refresh_all(sightings)

      resolved
    end

    # **The page's new identities, in one `INSERT … ON CONFLICT … RETURNING`.** The last of the
    # per-row statements this lineage set out to remove: a repository's FIRST ingest of a
    # 20,000-example suite is 20,000 misses by construction, so this was 20,000 sequential round trips
    # to write what one page had already decided.
    #
    # Nothing about the row changed — see {#claim_identity} for the conflict key, why it is an upsert
    # rather than an insert, and what the conflict branch does. What changed is that the statement is
    # the page's rather than the row's, and the id therefore arrives after the walk instead of during
    # it.
    #
    # **The ids are mapped by `text_digest` and never by position.** `RETURNING` makes no promise
    # that its rows come back in `VALUES` order — a different plan may not scan them in it — so
    # zipping the result against the buffer would look correct in a green test and cross-link rows
    # under a plan nobody asked for. The digest is already the buffer's key and already unique within
    # the page; asking the statement to return it costs one short column.
    #
    # **Sorted by that key** before the statement is built, for the reason {#write_page} argues at
    # length: these rows take locks on `spec_identities` — an upsert that conflicts locks the row it
    # conflicts onto — and two concurrent jobs over overlapping pages should present the rows they
    # share in the same relative order. `repository_id` is constant across a page, so the digest is
    # the whole of the conflict key that varies.
    #
    # Through {#write_page} like the page's other batched statements, and sound to re-issue for the
    # same reason: it is one statement in autocommit with nothing partial to unwind, and a second
    # attempt either inserts what the first would have or conflicts onto the row that arrived
    # meanwhile and re-sights it — guarded, as ever, by {SpecIdentity::SIGHTING_NOT_OLDER}.
    def insert_pending_identities
      return if @pending_identities.empty?

      rows = @pending_identities.keys.sort.map { |digest| @pending_identities.fetch(digest) }

      ids = write_page do
        SpecIdentity.upsert_all(
          rows,
          unique_by: %i[repository_id text_digest],
          on_duplicate: Arel.sql(SpecIdentity::RESIGHT_ON_CONFLICT),
          record_timestamps: false, returning: %w[id text_digest]
        ).rows.to_h { |id, digest| [digest, id] }
      end

      substitute_pending(ids)
    end

    # **Every {PendingIdentity} the page handed out, replaced by the id the insert returned** — in
    # all three of the buffers one can reach, at one seam, before any of them is spent.
    #
    # Three and not one, which is the whole reason this is its own method. `@links` is the obvious
    # one. `@sightings` and `@spellings_in_use` are reached by the *second* byte-identical row of a
    # page: {#claim_identity} puts its row into `@digest_index`, so that row takes {#identical_text}'s
    # hit branch in {#identity_for}, which appends the id to `@spellings_in_use` and re-sights it. A
    # placeholder therefore rides into {#resight_all}, {#link_all} and {#refresh_all} alike, and the
    # only way for those three to need no knowledge of it is for none of them to see one.
    #
    # `fetch` and never `[]`: a placeholder with no returned id is a broken invariant — the statement
    # returns a row per row it was handed, conflict or not — and it must raise here rather than write
    # a `nil` foreign key or silently drop a spelling refusal.
    #
    # `@spellings_in_use` is rebuilt entry by entry rather than mapped because it is a Set and it is
    # PASS-scoped: it holds ids from earlier pages, each already substituted at its own page's flush,
    # and they must be left alone.
    def substitute_pending(ids)
      real = ->(identity) { identity.is_a?(PendingIdentity) ? ids.fetch(identity.digest) : identity }

      @links.each { |link| link[1] = real.call(link[1]) }
      @sightings.each { |sighting| sighting[0] = real.call(sighting[0]) }
      @spellings_in_use.select { |identity| identity.is_a?(PendingIdentity) }.each do |pending|
        @spellings_in_use.delete(pending)
        @spellings_in_use << ids.fetch(pending.digest)
      end
    end

    # **The page's write, issued once and retried at most once if Postgres picks it as the deadlock
    # victim.** Every batched statement below goes through here, and this is the whole of what answers
    # the concurrency question batching them asks.
    #
    # The per-row path could not deadlock, structurally rather than by luck. `update_column`, a one-row
    # `update_all` and a one-row upsert each ran in autocommit: one row lock, taken and released
    # inside one statement. A transaction that never holds a second lock cannot be half of a cycle.
    # {#insert_pending_identities}, {#resight_all} and {#link_all} each take up to `BATCH_SIZE` row
    # locks and hold them all until the statement ends, which is a lock footprint three orders of
    # magnitude wider at the design point.
    #
    # That would be academic if two passes could not overlap, and this class says twice that they do:
    # every shard of a run enqueues a job for the run ({#unresolved_bounds}, {RETRY_SWEEP_LIMIT}),
    # and {#record_resolve_failure} increments atomically precisely because N of them run over the
    # same rows. {#retry_backlog} is repository-scoped rather than run-scoped, so those N jobs read
    # substantially the SAME page.
    #
    # == The sort first, because it removes the systematic disagreement
    #
    # Overlapping row sets are not enough for a deadlock; overlapping sets acquired in DIFFERENT
    # orders are. The reads that build a page do not agree on an order between two jobs and cannot be
    # made to: {#failed_embed_backlog} orders by `embed_failure_count`, which is exactly the column
    # those concurrent jobs are incrementing, so two reads moments apart legitimately return the same
    # rows in different positions. Both `VALUES` lists are therefore sorted by their join key before
    # the statement is built ({#resight_all}, {#link_all}), which makes the statement a function of
    # the SET of rows the page holds and not of the order it read them in. Two jobs over overlapping
    # sets then present the rows they share in the same relative order.
    #
    # **That is a strong tendency and not a guarantee, which is why it is not the whole answer.**
    # Postgres does not promise to lock in `VALUES` order — a sort or hash node in the join can
    # reorder the scan — so the sort makes agreement the overwhelmingly likely case rather than a
    # coincidence, and the retry below is what makes the path CORRECT rather than merely lucky.
    #
    # == Why a retry is sound here, and why exactly one
    #
    # A deadlock aborts the victim's statement entirely. These are single statements in autocommit,
    # so there is no partial application to compensate for and nothing to unwind — the retry is the
    # same statement against a database that never saw the first attempt.
    #
    # All three are safe to re-issue. The insert is an upsert onto `(repository_id, text_digest)`, so a
    # second attempt lands on the row a first attempt inserted — or on a concurrent job's — and
    # re-sights it under the same guard as the rest. The re-sighting is guarded per row against the row's own
    # `last_seen_test_run_id`, so a second attempt either writes exactly what the first would have or
    # is refused by a newer sighting that landed in between — and being refused is the correct
    # outcome, not a lost write. The link sets one column to one value and counts what it MATCHED, so
    # a row a concurrent redelivery deleted meanwhile is not counted on the retry either, which is
    # the contract {#link_all} states.
    #
    # Once, and deliberately not a loop or a job-level `retry_on`. The detector aborts one side of a
    # pair and lets the other finish, so a single retry runs against locks that have just been
    # released — the case a retry can actually fix. A page that deadlocks twice is under contention
    # trying harder cannot resolve, and this class already has a recovery for a pass that dies: the
    # rows stay unresolved and unstamped, and the next ingest's cross-run sweep picks them up
    # ({Ingest::IdentityResolutionJob} states that this, and not a redelivery, is what re-does the
    # work). Spending a delivery in a retry loop would only postpone that while the page goes stale.
    #
    # `warn` and not `info`: a retried page is not an error — nothing was lost — but a deadlock here
    # is the signal that two shards' jobs are colliding, and that is worth being able to grep for.
    def write_page
      retried = false

      begin
        yield
      rescue ActiveRecord::Deadlocked => e
        raise if retried

        retried = true
        Rails.logger.warn(
          "[IdentityResolver] run=#{@run.id} page write chosen as a deadlock victim, " \
          "retrying once: #{e.message}"
        )
        retry
      end
    end

    # `digest => {HeldIdentity}`, for every text on this page that this repository already holds —
    # the text that represents each row, and, for an annotated one, the name it may still be held
    # under ({#lookup_texts}).
    #
    # **One `WHERE text_digest IN (…)` against the unique `(repository_id, text_digest)` index**, in
    # place of the one equality per row this used to be. On run 2 of an unchanged 20,000-example
    # suite — the ordinary case, since every run writes its own observations with a NULL identity and
    # so re-presents the WHOLE suite — that is ~40 digest lookups where it was 20,000. Nothing about
    # the work changed; SPGD-373 already removed the embed from this path. What is left is the
    # lookups, and this is them. The two `UPDATE`s a re-sighting then writes were the other O(N) on
    # this path, and they are now one statement each per page too — {#flush_page}, and see
    # {BATCH_SIZE} for what a page costs once both halves are batched.
    #
    # Digested in Ruby before anything is asked, which costs no queries: {Ingest::SpecSignal} is pure
    # over the already-loaded row, and {SpecIdentity.digest_for} is a SHA-256 of a string.
    #
    # This builds each row's signal a second time — {#identity_for} builds its own — and that is
    # deliberate rather than an oversight. {SpecObservation#signal} does not memoise, so the price
    # is one extra object per row and no extra query. Caching it would mean carrying a
    # per-observation map alongside the digest map for the width of a page, to save an allocation
    # nothing has measured; and {#identity_for} taking a pre-built signal would move the seam that
    # `resolve_as_the_loser`'s stub hangs on. Not worth either.
    #
    # `pluck` and not a relation of records: what a hit is acted on with is an id and a
    # `signal_source`, and {SpecIdentity::RESIGHTABLE} is what a re-sighting moves — `text`,
    # `text_digest`, `signal_source` and `embedding` are all deliberately absent from it, so nothing
    # downstream of a hit ever WRITES them by re-sighting. The second plucked column is one of those
    # four and that is not a contradiction: it is READ here to answer `from_name?`, which is a
    # different thing from a re-sighting moving it. Loading 500 identities to use 500 ids would put
    # the vectors this method exists to avoid touching straight into memory; a short string alongside
    # the id changes nothing about that. {#upgrade_from_name} WRITES the excluded columns, and writes
    # them by id in one `UPDATE` rather than by loading the row first, for the same reason.
    #
    # `uniq` because a page may carry the same text twice — two examples with identical
    # `full_description` is the case `identity_resolver_spec.rb`'s "cannot separate two tests whose
    # descriptions are identical" pins — and an `IN` list is not the place to repeat it. It now also
    # collapses the ordinary overlap {#lookup_texts} creates, where one page carries a test's name
    # both as its own row's text and as an annotated row's former text. Empty page, or a page of
    # nothing but `:none` rows, asks nothing at all rather than issuing `IN ()`.
    # {#lookup_texts} is what keeps that true: a `:none` row has no text, and `digest_for(nil)` is a
    # perfectly good SHA-256 of the empty string — so a nil left in this list becomes a real digest
    # that no row can ever hold, and a real round trip spent asking about it. That is the whole cost
    # this method exists to remove, reintroduced by one method name.
    #
    # No early return for the empty case, deliberately: `where(text_digest: [])` compiles to `1=0`
    # and Rails answers it without a round trip, so a page of nothing but `:none` rows already costs
    # nothing and a guard here would be a branch no test could reach. The property is pinned by the
    # resolver spec's "still costs nothing when a page carries no text to look up at all", which
    # asserts the ABSENCE of the query rather than the presence of the guard — so it stays honest if
    # that optimisation ever goes away.
    def digest_index(observations)
      digests = observations.flat_map { |observation| lookup_texts(observation) }
                            .uniq.map { |text| SpecIdentity.digest_for(text) }

      @repository.spec_identities.where(text_digest: digests)
                 .pluck(:text_digest, :id, :signal_source)
                 .to_h { |digest, id, source| [digest, HeldIdentity.new(id, source)] }
    end

    # @return [Hash{String => Array<Float>, nil}] every vector this page's rows are going to need,
    #   fetched in ONE provider request — nil for a text the provider could not answer about.
    #
    # **The third thing this page asks once instead of per row, and — with the cache below — the
    # last of the three SPGD-72's cost clause names.** {#digest_index} made the identical-text
    # answer one query per page and {#flush_page} made the writes a fixed number of statements per
    # page; what was left was the embed, which the
    # identical-text shortcut removes for an UNCHANGED suite and does nothing for a changed one. Any
    # first run, any rename, any delivery whose text is not byte-identical to a row already held
    # still reached the provider once per example — 20,000 sequential HTTPS round trips on a changed
    # 20,000-example suite, against an endpoint that takes the whole array in one request.
    #
    # There is no provider on which that is free: `EmbeddingGenerator::VoyageProvider` is the only
    # one this application ships, and every `.call` on it is a billed request over the network.
    #
    # == The cost is per page and the DECISION is still per row
    #
    # The same division {#digest_index} and {#flush_page} made. Nothing here decides anything: it
    # collects the texts the per-row path is going to ask for and puts the answers where
    # {#embedding_for} can hand each row its own. {#identity_for} runs exactly as it did — its
    # `:none` return, its {#identical_text} shortcut, its {#nearest} lookup, its upgrade and its
    # insert — and a row whose vector is nil takes the same {#record_resolve_failure} stamp it took
    # when its own embed returned nil.
    #
    # == What is deliberately NOT in the request
    #
    # `identical_text` is asked BEFORE a text joins the list, so a byte-identical re-ingest sends
    # the provider nothing at all — the shortcut's whole point, and it would be undone by a batch
    # that embedded the page indiscriminately. The list is deduped for the same reason
    # {#digest_index}'s is: two examples carrying the same description are one text to embed, and
    # the vector is a pure function of the text.
    #
    # The snapshot is taken before the first row is claimed, so a text that a LATER row of this same
    # page will create an identity for is embedded here and its duplicate is not — {#claim_identity}
    # puts the new row into `@digest_index` and the second occurrence takes the shortcut, exactly as
    # it does today.
    #
    # == The vectors this deployment already owns are not bought again
    #
    # The last of SPGD-72's three cost levers, and the one the other two cannot reach.
    # {#identical_text} answers *"is this text on one of THIS repository's identity rows"* — that
    # is what {#digest_index} is built from — so a page of genuinely new bytes gets no help from it
    # and is billed in full. But "new to this repository" is not "new to this deployment": another
    # repository's suite contains `"validates the email format"` too, and this repository's own
    # renamed test was embedded under its old text last week. {EmbeddingCacheEntry} is keyed
    # `(provider_fingerprint, text_digest)` across every repository, so those are hits, and a page
    # that hits on all of them asks the provider nothing at all.
    #
    # **Read once, embed the remainder, write what was bought.** Three page-shaped statements where
    # there were two, and the division is the one this class has made four times now: the cost is
    # per page and the DECISION is still per row. Nothing here decides anything — a row whose vector
    # came from the cache takes precisely the path a row whose vector came from the provider takes,
    # through {#embedding_for}, {#nearest} and {#claim_identity}, and a text that missed both is a
    # nil exactly as it was.
    #
    # `texts - cached.keys` is the whole of the change to what gets asked. When the provider
    # publishes no fingerprint — which the whole test suite's provider does, and which the shipped
    # `VoyageProvider` does not — `cached` is empty, the
    # subtraction is a no-op, and this method is byte-for-byte the behaviour it had before.
    def page_embeddings(observations)
      texts = unheld_texts(observations)
      fingerprint = cache_fingerprint
      cached = cached_embeddings(fingerprint, texts)
      fresh = embed_page(texts - cached.keys)
      store_embeddings(fingerprint, fresh)

      cached.merge(fresh)
    end

    # @return [String, nil] the current provider's cache key, or nil for "do not cache".
    #
    # Asked once per PAGE rather than once per cache call, so that the read and the write of one
    # page cannot disagree about which provider they are talking about — and per page rather than
    # per process, because `EmbeddingGenerator.fingerprint` is required to be recomputed on every
    # call and memoizing it here would reintroduce exactly the staleness that contract exists to
    # prevent.
    #
    # Rescued because it runs provider code: `VoyageProvider.fingerprint` reads the environment
    # today and a future provider might read a config file or a socket. Whatever it does, a
    # provider that cannot say what it is must cost this ingest nothing more than the caching it
    # declines to authorise. Nil is the same answer as "no fingerprint published", and the caller
    # already treats that as "no caching".
    def cache_fingerprint
      EmbeddingGenerator.fingerprint
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not read the embedding provider fingerprint: " \
        "#{e.message}; embedding this page without the cache"
      )
      nil
    end

    # @return [Hash{String => Array<Float>}] the subset of this page's texts this deployment has
    #   already embedded under `fingerprint` — one query, an `IN` list on the unique key.
    #
    # == The rescue is WIDE in class and NARROW in scope, and both halves are deliberate
    #
    # {#page_embeddings} is the one exception inside {#resolve_page}'s containment, and `:499-505`
    # argues exactly why it is allowed to be: `EmbeddingGenerator::Error` is attributable to known
    # texts that {#embed_page} re-asks one at a time, so each failure lands back on the row that
    # contributed it. **A cache failure is not that**, and this rescue must not be read as widening
    # that licence. It is a different claim on a different statement.
    #
    # *Wide in class* because the failures are not the provider's: an unrun migration is
    # `ActiveRecord::StatementInvalid`, a saturated pool is `ActiveRecord::ConnectionTimeoutError`,
    # a dropped socket is lower still. Rescuing `EmbeddingGenerator::Error` here would catch none of
    # them and a deployment that had not yet run the migration would fail every ingest — the cache
    # would have become load-bearing, which is the one thing a cache must never be. Every one of
    # those has the same correct answer, and it is not an incident: ask the provider, as this class
    # did before the table existed.
    #
    # *Narrow in scope* because it wraps this call and nothing else. The provider request, the
    # per-row decisions, {#nearest}, {#claim_identity} and {#flush_page} are all outside it and
    # every one of them fails exactly as loudly as it did before. What {#page_embeddings} is
    # permitted to swallow is unchanged: this adds a rescue AROUND A NEW STATEMENT, it does not
    # loosen the existing one.
    #
    # Logged at `warn` and not `error`: the ingest is correct and merely more expensive, which is
    # the same register {#embed_page}'s fallback line uses for the same reason.
    def cached_embeddings(fingerprint, texts)
      return {} if fingerprint.blank? || texts.empty?

      EmbeddingCacheEntry.vectors_for(fingerprint, texts)
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not read #{texts.size} cached embeddings: " \
        "#{e.message}; asking the provider for the whole page"
      )
      {}
    end

    # Remember what this page just paid for — one statement, on the way out.
    #
    # Both of {#embed_page}'s paths land here, which is why the write is at this seam and not
    # inside it: the batch path and the one-at-a-time fallback return the same shape, and the
    # fallback's per-text nils are dropped by {EmbeddingCacheEntry.store} rather than remembered as
    # answers. A text the provider refused must be re-asked next time, not permanently cached as a
    # failure.
    #
    # Rescued on the same terms as the read, and with more at stake in getting it right: a write is
    # the half that can meet a unique-key conflict, a read-only replica or a full disk, and none of
    # those is a reason to fail an ingest whose rows are already resolved. The page's vectors are in
    # hand and the resolve continues with them; the only thing lost is that the next page pays again.
    #
    # **It commits on its own, and that is a property worth keeping.** {#resolve_page} holds no
    # transaction — this class runs in a job precisely so that it is out of the ingest's, and
    # {#claim_identity} commits per row — so this `upsert_all` is its own statement and its own
    # transaction. Two consequences, both wanted: a page that dies later at {#nearest} or
    # {#flush_page} still keeps the vectors it paid for, which is exactly the behaviour a cache
    # should have on a failed pass; and the row locks the upsert takes are released at the end of
    # the statement rather than held for the length of a page, so the concurrent shards of a first
    # run — the case where two ingests upsert the SAME digest at the same moment — queue for
    # microseconds instead of for each other's whole page. Wrapping the page in a transaction later
    # would quietly reverse both.
    def store_embeddings(fingerprint, fresh)
      return if fingerprint.blank? || fresh.empty?

      EmbeddingCacheEntry.store(fingerprint, fresh)
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not cache #{fresh.size} fresh embeddings: " \
        "#{e.message}; this page's vectors will be bought again"
      )
      nil
    end

    # The texts this page will have to embed: every row's signal text, minus the rows that have no
    # text at all and minus the ones the page's map already names an identity for, deduped.
    #
    # Reads {#identical_text} rather than re-deriving the digest comparison, so the question asked
    # here is by construction the same question {#identity_for} asks a moment later — a second
    # phrasing of it could drift and would show up as a provider bill rather than as a failure.
    def unheld_texts(observations)
      observations.filter_map do |observation|
        signal = observation.signal
        next unless signal.present?
        next if identical_text(signal)

        signal.text
      end.uniq
    end

    # @return [Hash{String => Array<Float>, nil}] text => vector, empty when there is nothing to
    #   embed — which is the ordinary case, so it costs no call rather than an empty one. Every text
    #   is a KEY of the result whenever there was one to ask about, including on the paths that asked
    #   nothing: see the nil-versus-omitted section below, which is the one thing a caller here can
    #   get wrong.
    #
    # **The fallback is what keeps SPGD-367 true through a batch.** One unembeddable example must
    # not abandon the other 19,999, and a batch fails as a batch: `EmbeddingGenerator.embed_many`
    # raises for the whole page and cannot say which input was refused, because one bad text and a
    # dropped connection arrive identically. Nilling the whole page on that error would stamp 20,000
    # rows for one bad one — the exact regression the per-row rescue in {#embed} exists to prevent —
    # so the page falls back to asking one text at a time, and each text then fails, or does not, on
    # its own. That path is today's path unchanged, warning line and per-row nil included.
    #
    # == What the fallback costs, and the breaker that bounds it
    #
    # One wasted request on a page that fails, plus a request per text behind it — **once per PAGE,
    # and that is the part the previous revision of this comment got wrong.** It said a provider that
    # is simply down "pays it once and then behaves exactly as it does now"; it paid it once per
    # page, every page, and a full page of single-text requests each time. At {BATCH_SIZE} = 500 a
    # first or fully-changed run at the roadmap's 20,000-example design point is 40 pages, so a
    # provider that was simply down cost 40 batch + 20,000 single requests, 20,040 `warn` lines,
    # 20,000 {#record_resolve_failure} `UPDATE`s — and zero identities. Under `VoyageProvider`, where
    # every `.call` is a serial HTTPS round trip, that is hours of a three-thread pool spent inside a
    # job holding a six-hour run-scoped semaphore, with every other shard's job queued behind it.
    # {RETRY_SWEEP_LIMIT} bounds how much failure a delivery INHERITS; nothing bounded how much one
    # pass CREATES.
    #
    # So a page whose batch failed AND whose every per-text retry also failed, over **at least two
    # texts**, trips `@provider_dark` and the rest of the pass asks the provider nothing
    # ({#stop_asking_the_provider}). The trip condition is the fallback's own justification read
    # carefully: *"one bad text and a dropped connection arrive identically"* is true OF ONE TEXT and
    # is not true of a page. Both halves of the rule follow from that and neither is a tuning knob:
    #
    # * **Zero successes**, because one poison text among successes is evidence about that text and
    #   about nothing else — which is what keeps *"contains a failed page to the row that caused
    #   it"* green, and an over-trip there would undo SPGD-367 wholesale rather than bound anything.
    # * **At least two texts**, because a one-text page is precisely the case the two readings cannot
    #   be told apart in. It pays its ask and says nothing about the provider. Two texts each
    #   individually unembeddable is already unlikely and 500 of them is not a thing that happens; a
    #   provider being down is.
    #
    # The bound is **~501 requests where it was 20,040**, and the observable row state is identical:
    # a skipped text is stamped by {#record_resolve_failure} exactly as a refused one is and stays
    # retryable for {SpecObservation::EMBED_RETRY_WINDOW} through the cross-run sweep. Identical
    # rather than merely similar, because abandonment is TIME-based and not attempt-count-based
    # (`SpecObservation.embed_abandoned`) — `embed_failure_count` only orders the sweep's fairness —
    # so a row stamped without a fresh ask has no lifecycle side effect at all. It is also the honest
    # record: the page's batch request did carry that text.
    #
    # == A skipped text is present with a NIL VALUE and is never OMITTED
    #
    # The whole of what the tripped return has to get right, and it is not obvious from here.
    # {#embedding_for} treats the two absences differently: a MISSING KEY means "no page fetched
    # this", while a PRESENT NIL means "asked and refused" and stays a failure. So returning `{}` on
    # the tripped path — or omitting the skipped texts from it — would send every skipped row through
    # that block rather than leaving it holding this page's own answer.
    #
    # **That block is now breakered too, and this rule is still the one that matters.** SPGD-478
    # added the same `@provider_dark` check inside {#embedding_for}, for a missing key this method
    # cannot reach — {#upgrade_from_name}'s mid-page invalidation, which produces a key no page ever
    # asked for — so a tripped `{}` would today be caught one layer down rather than costing 20,000
    # requests. It is a second line and not a replacement: the per-signal FALLBACK below reaches that
    # same block with the breaker NOT tripped (a batch that failed while at least one retry succeeded
    # leaves nil values and no trip), and omitting those texts would re-ask the provider for a text
    # it has just refused, once per row. Nil-valued and never omitted is what keeps both true.
    #
    # `zip` is where the interface's ORDER CONTRACT is consumed: `texts[i]`'s vector is
    # `vectors[i]`, and `embed_many` guarantees both the order and the count (a short array is an
    # `Error` there rather than a nil here, which would attach every later vector to the wrong
    # text). Rescuing `EmbeddingGenerator::Error` and nothing wider, for the reason {#embed} gives:
    # a broader rescue at a page-level call could swallow a failure that is not the provider's.
    def embed_page(texts)
      return {} if texts.empty?
      return texts.to_h { |text| [text, nil] } if @provider_dark

      texts.zip(EmbeddingGenerator.embed_many(texts)).to_h
    rescue EmbeddingGenerator::Error => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not embed a page of #{texts.size} spec signals " \
        "in one request: #{e.message}; falling back to one request per signal"
      )
      embedded = texts.to_h { |text| [text, embed(text)] }
      stop_asking_the_provider(texts.size) if texts.size > 1 && embedded.values.none?
      embedded
    end

    # Trip the pass-scoped breaker: for the remainder of this `#resolve`, {#embed_page} asks the
    # provider nothing and answers every text with the nil a refusal would have produced.
    #
    # Said once and at `warn`, in the register {#embed}'s per-row line uses and for the same reason:
    # nothing here is broken on this side of the wire, and the rows this pass stops asking for are
    # stamped and retryable exactly as refused rows are. This is the line that makes the skipping
    # visible at the moment it starts, where the provider's own message still is; {#report} carries
    # the same fact to the end of the pass, where the totals are. Neither is the other, on the same
    # rule {#embed} states for its log line and its stamp.
    #
    # `asked` is the width of the page that earned the trip rather than a total, because that is the
    # evidence: this many separate per-signal requests were made and this many came back refused.
    def stop_asking_the_provider(asked)
      @provider_dark = true

      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} stopped asking the embedding provider: a page's batch " \
        "request and all #{asked} of its per-signal retries failed, which is evidence about the " \
        "provider and not about those signals; the rest of this pass is stamped without a request " \
        "and stays retryable"
      )
    end

    # Every text this row could already be held under: the one that REPRESENTS it, and — when that
    # is a declared triple — the NAME it was held under before the declaration existed.
    #
    # The second one is what makes {#upgrade_from_name} cost nothing extra. `Ingest::SpecSignal`
    # prefers the intent deliberately (*"preferring the name would make annotating a test change
    # nothing"*), so the run on which a test gains an `@intent` presents text this repository has
    # never seen while the row it already has is held under text nobody will ever present again.
    # Asking for both digests is one wider `IN` list against the same unique key — a longer list, not
    # a second round trip — and it is the only reason the upgrade is affordable at all.
    #
    # Asked only for an intent-derived signal, and never the other way round. A name-derived row has
    # no second text to be held under: `SpecSignal` yields the name only when there is no triple, so
    # there is nothing to ask for. It is also the direction {#upgrade_from_name} refuses — see there
    # for why intent→name must never be inferred — and a lookup nothing may act on is a wider list
    # for nothing.
    #
    # `filter_map` semantics are preserved through `compact` and the `:none` guard: a row with no
    # text contributes NOTHING rather than a digest of the empty string, which is the whole cost
    # {#digest_index}'s own comment is about. `flat_map` because a row now contributes zero, one or
    # two texts.
    def lookup_texts(observation)
      signal = observation.signal
      return [] unless signal.present?
      return [signal.text] unless signal.from_intent?

      [signal.text, name_signal(observation).text].compact
    end

    # @return [Ingest::SpecSignal] what this row's identity WOULD have been built from before it was
    #   annotated — its `full_description` and nothing else. `#present?` is false for a row that has
    #   no name, which is the shape `Ingest::Payload#validate_name` refuses today and which rows
    #   written before it exist in.
    #
    # Built through `SpecSignal` rather than by reading the column, so the stripping and the
    # blank-rejection are the ones every other caller gets. {SpecObservation#signal} cannot answer
    # this — it applies the precedence, which on an annotated row is exactly the answer that hides
    # the name — so this asks the same class the narrower question.
    def name_signal(observation) = Ingest::SpecSignal.for("name" => observation.name)

    # The rows an EARLIER run of this repository was reached on and failed to resolve — the provider
    # unable to answer, or a failure {#claim_inherited} contained — and which this ingest is entitled
    # to re-attempt. Empty on a repository that has never had one, which is the normal case and costs
    # one probe of an index that is empty there — see the migration for why the index is partial.
    #
    # Scoped to the repository because identity is per repository and so is the provider outage that
    # produced these rows; `@repository` is already in hand from {#initialize}. `@run` is EXCLUDED
    # rather than left in: this run's own unresolved rows are {#resolve}'s run-scoped list, and a row
    # that appeared on both would be embedded twice in one pass — once for nothing.
    #
    # Ordered least-tried first, and — since the monotonicity guard {#resolve} describes — ordered
    # for FAIRNESS alone. Nothing about correctness rides on this key any more, which is what frees
    # it to be the one fairness actually wants: a pure `embed_failed_at` ordering re-attempts the
    # same 500 rows on every ingest until the window closes on all 20,000 at once — they failed in
    # the same outage, so they expire together and 19,500 of them never get a single retry. Ordering
    # on `embed_failure_count` makes a retried row sink below the rows that have not been tried yet,
    # so the sweep round-robins the whole backlog instead of a window into it. `embed_failed_at`
    # then `id` break the ties, so the order is total and stable rather than whatever the planner
    # returned first.
    #
    # What that counter counts is attempts BY ANYTHING — the N concurrent jobs an N-shard delivery
    # schedules over these same rows included — and {SpecObservation::EMBED_RETRY_WINDOW} reads it
    # exactly that way when it refuses it as a CAP. The two are not in tension: shard multiplicity
    # is fatal to a cap, because it spends the allowance on the failure rather than on the retrying,
    # and harmless to a ranking, because concurrent sweeps bump roughly the same top-N together and
    # leave the ORDER BETWEEN rows where it was. This wants a key that is monotone in "has been
    # tried", not a key that is calibrated in tries.
    def failed_embed_backlog
      @repository.spec_observations
                 .embed_retryable
                 .where.not(test_run_id: @run.id)
                 .order(:embed_failure_count, :embed_failed_at, :id)
                 .limit(RETRY_SWEEP_LIMIT)
    end

    # The rows of this repository's earlier runs that were never attempted at all — the population
    # `SpecObservation::EMBED_ATTEMPT_GRACE` and the migration beside it exist for, and the one that
    # had no query that could find it.
    #
    # Its whole predicate is an absence, so unlike the failure backlog it cannot be empty on a
    # healthy repository — every row is in it between the ingest commit and the job's pass. What
    # keeps it small is the grace floor, which excludes exactly the rows a live job is plausibly
    # still walking, and the fact that a row leaves by being resolved. The new partial index is what
    # keeps the probe cheap all the same; see the migration for why the failure index cannot serve
    # this predicate, which is its complement.
    #
    # `@run` is excluded for the same reason it is above — its own unresolved rows are {#resolve}'s
    # second list, and a row on both would be embedded twice in one pass. It is not redundant with
    # the grace floor: an ingest whose job is dequeued more than an hour after the commit would
    # otherwise find its own rows here.
    #
    # == Ordered NEWEST first, which is the opposite of the failure backlog and deliberate
    #
    # That list orders by attempts so a retried row sinks and the whole backlog round-robins. This
    # one has no attempt counter to sink by — nothing here has ever been attempted, and the two rows
    # this sweep cannot resolve are precisely the ones that will never acquire one: a row with no
    # intent and no name returns nil from {#identity_for} BEFORE the embed, so it takes no stamp, no
    # count, and no place in any ordering that could demote it.
    #
    # Oldest-first would therefore park that population permanently at the head of the list. A
    # repository carrying `RETRY_SWEEP_LIMIT` signalless rows inside the window would spend its
    # entire sweep budget on them on every ingest, forever, and no genuinely stranded row would ever
    # be reached — starvation by a set that is behaving correctly.
    #
    # Newest-first structurally cannot do that, and the structure is `Ingest::Payload#validate_name`:
    # it rejects "absent name and no intent", so a signalless row is one written before that
    # validator existed and is therefore older than every row written since. Sorting by age
    # descending puts the unresolvable population last by construction rather than by hope. It also
    # happens to be the order a rescue wants — the freshest stranding is the one whose run somebody
    # may still be looking at — but that is a bonus and not the argument.
    #
    # `id` breaks ties, and here the ties are the NORMAL case rather than a corner:
    # `Ingest::ObservationRecorder#record` writes a run's observations in a single bulk `upsert_all`,
    # so a whole run can share one `created_at` to the microsecond. Without the tiebreak the cap
    # would take an arbitrary and differently-chosen slice of that run on every ingest, and rows
    # could be passed over indefinitely while the count of them never moved. Both keys descend
    # together so the read is one backward walk of
    # `index_spec_observations_on_unattempted_embed_backlog`, which carries `id` for exactly this.
    #
    # `limit` is a parameter and not `RETRY_SWEEP_LIMIT`, because this list spends what the failure
    # backlog left — see {#retry_backlog} for why there is one budget and not two.
    def unattempted_embed_backlog(limit)
      @repository.spec_observations
                 .embed_unattempted_retryable
                 .where.not(test_run_id: @run.id)
                 .order(created_at: :desc, id: :desc)
                 .limit(limit)
    end

    # @return [Integer, nil] the identity this observation belongs to, once the row has been ADDED TO
    #   THE PAGE'S LINK BUFFER — nil when it has none to belong to.
    #
    # **The write moved to {#link_all} and the decision did not.** This used to be one
    # `update_column` per observation and therefore one round trip per example, which at the design
    # point is 20,000 of them for a suite that did not change. What it records is the same pair the
    # UPDATE carried, so the statement the page issues writes exactly what these writes wrote.
    #
    # It no longer returns a COUNT, and that is the visible half of the change: a row cannot know
    # whether its UPDATE matched until the statement has run, so the counting moved to {#link_all}
    # with the write. The contract it counts by is unchanged and is stated there — a row deleted by
    # a concurrent shard redelivery is still not counted.
    #
    # No `update!` and no validation either way: there is nothing to validate on a foreign key the
    # database already enforces.
    def claim(observation)
      identity = identity_for(observation)
      return if identity.nil?

      @links << [observation.id, identity]
      identity
    end

    # {#claim}, with the blast radius of ONE inherited row held to that row.
    #
    # == Why the two halves of the work list are not treated the same
    #
    # {#resolve} walks the repository's earlier runs before it walks `@run`'s own observations, and
    # the two lists have different standing. This run's rows are the delivery's own business and the
    # caller is entitled to see them fail: an exception there is a report about the thing that was
    # just asked for. An inherited row is work this delivery volunteered for on an earlier one's
    # behalf — best-effort by construction, under a budget it is only *entitled* to spend — and
    # letting one of them abort the whole pass inverts that entirely.
    #
    # It inverted it badly, which is the defect this method exists for. The backlog is walked FIRST,
    # so a row that raises killed the delivery before `@run`'s own list was reached at all. And a
    # deterministic failure — a stored vector of the wrong dimension, a row whose signal trips a
    # provider bug — fails identically on every attempt, so *every subsequent ingest of that
    # repository* re-read it, re-raised, and left its own observations unresolved and unstamped:
    # exactly the invisible population the never-attempted sweep was built to rescue, defeated by
    # the one row that kills the sweep. One row, one repository, forever.
    #
    # **`StandardError` and not a list**
    #
    # Deliberately broad, because the enumerable failures are already handled elsewhere and what is
    # left is by definition the one nobody enumerated. `EmbeddingGenerator::Error` never arrives
    # here — {#embed} consumes it at the single call site and returns nil, so the stamping path
    # below is reached through {#identity_for} rather than through this rescue, and SPGD-367's
    # behaviour is untouched. Everything else the class comment lists as "what a job-level policy
    # would have to cover" is what this catches, and what is left of that list is {#nearest}'s
    # lookup and {#nearest_pending}'s scan of it in memory — the two questions still asked per row.
    #
    # What it can no longer catch is the row's own two `UPDATE`s — nor, since this slice, its
    # `INSERT` — and that is not a narrowing of the containment so much as a consequence of those
    # writes no longer being the row's: they are the page's now, issued once by {#flush_page}, and a
    # failure in one of them is page-shaped for the same reason {#digest_index}'s is. {#resolve_page}
    # states that line rather than leaving it here. A poison inherited row that used to cost only
    # itself an upsert now costs the page one, which is the same trade this method's neighbours made
    # when their writes moved, and it is bounded the same way: the page's rows stay unresolved and
    # unstamped, and the cross-run sweep re-reads them.
    #
    # **It is not a promise that the delivery survives anything.** {#record_resolve_failure} is
    # itself an UPDATE, so a failure broad enough to take the connection with it raises from inside
    # this rescue and propagates exactly as before. That is the right answer rather than a gap: a
    # database that cannot be written to must not produce a delivery that reports a clean sweep. The
    # case this contains is the row-shaped one, and the row-shaped one is the one that recurs.
    #
    # @return [nil] always on the contained path — the row is not added to the page's link buffer,
    #   so it contributes nothing to {#flush_page}'s count. See {#resolve}'s `@return` for why a
    #   contained row counts as nothing rather than as an attempt.
    def claim_inherited(observation)
      claim(observation)
    rescue StandardError => e
      Rails.logger.error(
        "[IdentityResolver] run=#{@run.id} contained a failure on inherited observation " \
        "#{observation.id}: #{e.class}: #{e.message}"
      )
      record_resolve_failure(observation)
      nil
    end

    # @return [Integer, nil] the id of the identity this observation belongs to, or nil when it has
    #   none to belong to.
    def identity_for(observation)
      signal = observation.signal
      # `:none` — no intent and no name. `Ingest::Payload#validate_name` refuses that shape today,
      # so this is for rows written before it existed. There is no text to embed and therefore no
      # identity to have; the row stays unresolved, which is the honest answer rather than an
      # identity standing for nothing.
      #
      # Returns BEFORE the embed, so it leaves no failure stamp — which is exactly what keeps this
      # population separable from the one below it. A row with nothing to embed is permanently
      # unresolved and must never enter the retry backlog; a row whose attempt failed is temporarily
      # unresolved and must.
      #
      # Before {#identical_text} and {#nearest} too, which is what keeps that true now that
      # {#claim_inherited} can stamp a row for a failure anywhere on this path: there is no database
      # work on the `:none` path for it to catch. The signalless population takes no stamp, no count
      # and no place in any ordering, exactly as {#unattempted_embed_backlog} needs.
      return nil unless signal.present?

      # The cheap answer first, and only when it is certain — see {#identical_text} for why a miss
      # here proves nothing and must fall through to the embed rather than stand in for it.
      identical = identical_text(signal)
      if identical
        # A hit is also the one piece of evidence that an identity's stored spelling is NOT stale:
        # this observation presented it verbatim. {#refresh_all} refuses to move a row that any
        # observation of this pass matched exactly, which is what stops two equivalent spellings of
        # one identity from taking turns rewriting each other. Recorded here rather than inside
        # {#identical_text} so that method stays a pure read of the page's map.
        @spellings_in_use << identical
        return resight(identical, observation)
      end

      embedding = embedding_for(signal.text)
      return record_resolve_failure(observation) if embedding.nil?

      match = nearest(embedding)
      if match
        # Before the re-sighting and not instead of it: a drifted row is re-sighted exactly as it
        # was, and {#note_drift} only records that this identity's SPELLING is worth moving too.
        note_drift(match, signal, embedding, observation)
        return resight(match.id, observation)
      end

      # The same question about the rows THIS PAGE has decided to insert and has not inserted yet,
      # which the lookup above cannot see. Asked here and not earlier because that is exactly where
      # the lookup answered it while the insert was per row — see {#nearest_pending}.
      pending = nearest_pending(embedding)
      return resight(pending, observation) if pending

      # Nothing matched the text that represents this test — and if this test just gained an
      # `@intent`, nothing ever will, because the row it already has is held under a name no run
      # will present again. Last question before inserting, and only for an intent-derived signal.
      #
      # **After {#nearest} and not before it**, which is worth stating because the ordering puts
      # fuzzy evidence about SOME test ahead of exact evidence about THIS one: the upgrade's own
      # question — does this repository hold a row under this example's `full_description`? — could
      # be asked as soon as the embedding is in hand. It is asked here because a match at
      # `SpecIdentity::MATCH_DISTANCE` is the settled answer on this path and the upgrade is the
      # exception to it, not a replacement for it; moving it earlier would let a name-derived row
      # take a test away from the identity similarity says it belongs to, on a run that changed
      # nothing but an annotation. The exposure that ordering accepts is the mirror of it — a triple
      # landing within `MATCH_DISTANCE` of a DIFFERENT identity re-sights that stranger and orphans
      # the row this test owns — and `spec_identity.rb`'s threshold table puts a lexically similar
      # but different test at 0.80 against a 0.95 bar, so it is the rarer of the two.
      upgraded = upgrade_from_name(signal, embedding, observation)
      return upgraded if upgraded

      claim_identity(signal, embedding, observation)
    end

    # @return [PendingIdentity, nil] the row THIS PAGE has already decided to insert whose text this
    #   observation's is a match for at {SpecIdentity::MATCH_SIMILARITY} — nil when the page holds no
    #   such row, which is every page in the steady state.
    #
    # **The half of the page's snapshot {#nearest} cannot cover, and the reason this method exists at
    # all.** {#nearest} asks the HNSW index, and a page's pending rows are not in the table yet. The
    # per-row path never had that gap: it inserted and committed each row before the next row asked,
    # so the second of two near-identical BRAND-NEW tests — "Order#checkout rejects an expired card"
    # and "Order  checkout rejects an expired card!" arriving in one page of a repository's FIRST
    # ingest, neither held, the digests different — found the first at the index and was re-sighted
    # onto it. Deferring the insert takes that answer away, and getting two identities for one test
    # is a permanent split of its history: every later ingest presents both spellings, each hits its
    # own digest, and nothing ever reconciles them.
    #
    # So this scans, and it scans at the SAME threshold {#nearest} uses rather than a cheaper one.
    # That is what makes deferring the insert invisible in the identity graph — the page a repository
    # ends up with is the page the per-row path would have written — and it is what keeps `BATCH_SIZE`
    # a cost knob rather than a decision about how many identities a suite has. An earlier revision
    # of this method keyed a Hash on the vector and closed only the cosine-1.0 band; that left an
    # ordinary pair of descriptions differing by one pluralised word (measured at cosine 0.9925
    # under `LexicalEmbeddingProvider`, the provider these specs run, against a 0.95 bar) splitting
    # into two identities on a first ingest, and splitting or not according to where the page
    # boundary fell. Both are refused here.
    #
    # == What the scan costs, measured on the provider that ships — and it is the dominant term
    #
    # It is O(pending) per miss and therefore O(page²) over a page of pure misses: 124,750 pairs at
    # `BATCH_SIZE` = 500, each pair a 1024-element dot product in Ruby.
    #
    # **Measure it dense, because dense is what ships.** `VoyageProvider` returns 1024 non-zero
    # floats, so {PendingVector} compresses nothing in production and the inner loop runs its full
    # width. The suite's default stub is dense at the same width, which makes it a faithful stand-in
    # for the COST (not the semantics) and means these numbers need no API key. Resolving one page
    # of 500 genuinely new tests end to end, against a local Postgres socket:
    #
    #                                          test (no YJIT)   production (YJIT)
    #   per-row `INSERT`, no scan (main)            5.2s              4.8s
    #   batched `INSERT` + this scan                11.4s             6.2s
    #
    # Read it honestly: **on a local socket this slice is a net slowdown on the page shape it
    # targets** — +6.2s in the suite's interpreter, **+1.4s in production's**, where `config.yjit`
    # is on (`load_defaults 8.1` sets `yjit = !Rails.env.local?`). YJIT is why the production row is
    # the one that matters and the test row overstates the cost by better than 4x.
    #
    # What the batching removes against that is 499 round TRIPS, which cost nothing measurable over
    # a Unix socket and are the whole of the cost over a network. So the break-even is
    # **~2.9ms of round trip** (the unrounded 1.46s / 499), not the sub-millisecond figure an earlier
    # revision of this comment claimed from a sparse provider: below that the slice is a loss, above
    # it a win. Same-host and same-AZ Postgres sit under that bar; a cross-AZ or cross-region managed
    # database sits over it. **This is genuinely marginal on latency, and it is bought for the
    # correctness of the identity graph, which is not marginal at all.**
    #
    # Both rows above produce 500 identities for these 500 deliberately-unlike tests, so the table is
    # a like-for-like cost comparison and nothing else. What it does NOT show is the third variant —
    # batching the insert with this scan REMOVED — which is the fast and wrong one: two near-identical
    # brand-new tests in one page split into rows the per-row path never created, permanently. That
    # variant is not benchmarked here because it is pinned as behaviour instead, by the two examples
    # "gives ONE row to two spellings of one test that are both new and both on this page" and
    # "gives ONE row to two new spellings that MATCH without embedding to the same vector" — delete
    # the scan and those fail, which is the point of them.
    #
    # == Two ways to make it cheaper, both refused, and why
    #
    # A Cauchy-Schwarz early exit over entries sorted by descending magnitude was tried and measured
    # at 0.655s against 0.645s on the sparse provider — no gain, because the bound decays as a
    # square root and never bites early. Dense is no better and the reason is the same, only more so:
    # 1024 dimensions spread the mass flatter still, so the partial-sum bound sits near 1.0 for every
    # pair and rejects nothing. Cauchy-Schwarz cannot separate candidates at a 0.95 bar in this
    # regime; that is a property of the geometry, not of the implementation.
    #
    # Bucketing pending rows by a cheap LEXICAL key and dotting only within a bucket would cut the
    # quadratic honestly — and is refused, because it is unsound against the provider that ships.
    # `voyage-4-lite` is semantic: two brand-new tests can sit above 0.95 while sharing few tokens,
    # and that pair is exactly the one this method exists to catch. A lexical prefilter would let it
    # split, silently and un-testably under a stub whose vectors carry no meaning.
    #
    # No cheap EXACT prefilter is available for dense high-dimensional vectors at a high threshold.
    # The scan is irreducible at this page size; what is tunable is the page. See {BATCH_SIZE}.
    #
    # And it is paid ONLY on that shape. `@pending_vectors` holds the page's misses SO FAR, which is
    # empty on every page of an unchanged suite and stays empty however large the page is: an
    # ordinary re-ingest never reaches this method, because {#identical_text} answered it. The cost
    # is a first ingest and a mass rename, where it buys the identity lineage those two ingests
    # establish for the life of the repository — and a permanent split is not a cost that a later
    # ingest can pay off, which is what makes it worth a second on a page that happens once.
    #
    # The remaining per-row round trip on this page is the ANN lookup, and it is **SPGD-375's**. If
    # the scan above is ever to get cheaper, that is where the pending rows would have to become
    # visible to an index instead of to a Ruby loop; there is no cheaper answer at this layer.
    #
    # == Cosine and not a dot product, and the best match and not the first
    #
    # Divided by both magnitudes so the number compared against `SpecIdentity::MATCH_SIMILARITY` is
    # the same number pgvector's `cosine` operator produces for {#nearest}. See {PendingVector} for
    # why that division is not dead code even though every provider in this tree normalises.
    #
    # The whole buffer is scanned and the BEST match taken, rather than returning the first row over
    # the bar, because that is what `nearest_neighbors(...).first` does and the two must not disagree
    # about which identity a text belongs to depending on which side of the page boundary it fell.
    # A zero-magnitude vector — a description with no alphanumeric content, which
    # `LexicalEmbeddingProvider` honestly reduces to no direction at all — matches nothing here,
    # exactly as it matches nothing at the index, where pgvector answers NaN rather than a confident
    # wrong neighbour. Guarded rather than assumed away: `EmbeddingGenerator.validate` checks width
    # and finiteness, so a zero vector is a valid one as far as the interface is concerned.
    #
    # {#nearest} is still asked FIRST and still wins: a committed row is at least as good an answer
    # as a pending one, and the row that is already in the table is the one a later page would find
    # anyway.
    #
    # That ordering is NOT a reproduction of the per-row path's, and the difference is worth stating
    # where the reader meets it. The per-row path asked ONE question, over a union that already
    # contained this page's earlier rows because each was committed before the next row asked, and
    # it took the global best. This asks two questions in sequence, so **a committed row over the
    # bar wins regardless of margin** — a committed candidate at 0.96 takes an observation that a
    # pending one at 0.99 would have taken before. Reaching that needs a triple where the two
    # candidates score below {SpecIdentity::MATCH_SIMILARITY} against EACH OTHER while both sit above
    # it against the incoming text, which is a narrower shape than the band this method exists to
    # close, and every candidate in it is inside the threshold's own declared ambiguity: the bar says
    # these are the same test, and it does not rank two rows that both clear it. Preferring the
    # committed row is the deliberate call — it is the answer that does not depend on where the page
    # boundary fell, which is the property the rest of this method buys.
    #
    # No {#note_drift} on this path, and that is not an omission. A drift candidate says an EXISTING
    # row's stored spelling is worth moving; this row has no stored spelling yet — it is being
    # written by this same page, from the observation that claimed it — so there is nothing to
    # converge, and a candidate keyed by a placeholder would be a fifth buffer for
    # {#substitute_pending} to keep straight.
    def nearest_pending(embedding)
      return nil if @pending_vectors.empty?

      magnitude = magnitude_of(embedding)
      return nil if magnitude.zero?

      best = nil
      best_similarity = 0.0

      @pending_vectors.each do |pending|
        next if pending.magnitude.zero?

        indices = pending.indices
        values = pending.values
        width = indices.size
        dot = 0.0
        offset = -1
        while (offset += 1) < width
          dot += embedding[indices[offset]] * values[offset]
        end

        similarity = dot / (magnitude * pending.magnitude)
        next unless similarity > best_similarity

        best_similarity = similarity
        best = pending.digest
      end

      PendingIdentity.new(best) if best && best_similarity >= SpecIdentity::MATCH_SIMILARITY
    end

    # This page's record of a row it has decided to insert, in the shape {#nearest_pending} scans —
    # see {PendingVector} for why it is sparse and why it carries its own magnitude.
    #
    # Built once, when the row is claimed, rather than re-derived per comparison: a page of pure
    # misses compares each new vector against every earlier one, so anything done here is done once
    # per row and anything done in the scan's inner loop is done up to 124,750 times.
    def pending_vector(digest, embedding)
      indices = []
      values = []
      total = 0.0
      index = -1

      while (index += 1) < embedding.size
        value = embedding[index]
        next if value.zero?

        indices << index
        values << value
        total += value * value
      end

      PendingVector.new(digest, indices, values, Math.sqrt(total))
    end

    # The Euclidean norm of a raw embedding — the divisor that turns {#nearest_pending}'s dot product
    # into a cosine. Walks the dense array because the vector being scored has not been reduced to a
    # {PendingVector} yet and may never be: it becomes one only if it turns out to be a miss.
    def magnitude_of(embedding)
      total = 0.0
      index = -1

      while (index += 1) < embedding.size
        value = embedding[index]
        total += value * value
      end

      Math.sqrt(total)
    end

    # @return [Integer, PendingIdentity, nil] the identity this repository already holds for text
    #   that is **byte-identical** to this signal's, found without embedding anything and — now —
    #   without asking the database anything either. A {PendingIdentity} when the row is one THIS
    #   PAGE has decided to insert and has not inserted yet ({#claim_identity}), which is the same
    #   answer one statement earlier and is resolved to an id by {#substitute_pending}.
    #
    # **Still the per-row seam, and deliberately so.** What moved is where the answer comes from: the
    # page asked once ({#digest_index}, one `WHERE text_digest IN (…)` against the UNIQUE
    # `(repository_id, text_digest)` key {#claim_identity} already upserts onto), and this reads that
    # answer for one row. Keeping the seam here is what keeps the decision per row while the cost is
    # per page — and it is what `identity_resolver_spec.rb`'s `resolve_as_the_loser` stubs to
    # reproduce a race, which is a second reason not to dissolve it into {#identity_for}.
    #
    # == What it removes
    #
    # Every run writes its own observations with `spec_identity_id` NULL, so {#resolve}'s work list
    # is the WHOLE SUITE on every run rather than the part of it that changed. Run 2 of an unchanged
    # 20,000-example suite was therefore 20,000 embeddings and 20,000 approximate-index lookups to
    # rediscover 20,000 rows that this equality names outright.
    #
    # The embed is a billed HTTPS round trip on the provider this application ships, so an unchanged
    # re-ingest that skipped this equality would pay 20,000 of them to rediscover 20,000 rows it
    # already holds — every ingest, forever. It also narrows {#nearest}'s recall exposure by not
    # reaching the index at all on the identical-text case — which does not settle the measurement
    # that method hands to SPGD-72, only shrinks what rides on it.
    #
    # That removed the WORK. Removing the round trips is {#digest_index}, and it is the same
    # optimisation finished rather than a second one: the equality that answered a row for free still
    # cost a query to ask, so the best case — nothing changed — spent 20,000 sequential lookups to
    # rediscover 20,000 rows the database could name in ~40.
    #
    # == This is a SHORTCUT and never THE lookup
    #
    # **The digest is exact; the embedding is not.** SHA-256 answers "these are the same bytes",
    # and two descriptions differing only by a comma or a doubled space are not the same bytes —
    # while the vectors they embed to sit far above `SpecIdentity::MATCH_SIMILARITY`, because a
    # comma is not what a text is about. A miss here is therefore not evidence that the test is new
    # — it is evidence that the cheap question cannot answer this one — and {#identity_for} falls
    # through to today's path completely unchanged.
    #
    # ⚠️ It was a *stronger* statement under the feature-hashing provider this application shipped
    # until 2026-08-17: that one embedded a downcased, punctuation-stripped form, so those two
    # spellings embedded *identically* rather than merely closely. `VoyageProvider` sends the text
    # as written, so the gap between the digest and the vector is now a matter of degree rather than
    # of kind — which changes nothing here, since this was always a shortcut past the similarity
    # lookup and never a substitute for it.
    #
    # Reading this as the lookup and the embed as an insert-only fallback is the tempting shape and
    # it is wrong: it would start a second history for every test whose description gained a comma,
    # while every existing example about *moved* tests stayed green. The falsifier is the resolver
    # spec's "still matches text that differs only in punctuation and whitespace", which is exactly
    # that pair and which only similarity can resolve. **Batching does not touch that**: a digest
    # absent from the page's map is absent for the same reason it missed the per-row `find_by`, and
    # falls through to the same place.
    #
    # ⚠️ Under a normalising provider that miss was paid ONCE per drift rather than on every ingest:
    # {#note_drift} re-pointed the identity at the spelling actually presented, so the run after the
    # drift asked this equality and got its answer for free. `VoyageProvider` publishes no
    # normalisation, so `EmbeddingGenerator.equivalent?` answers `false` for every pair of different
    # strings and {#note_drift} never fires — the miss is paid on every ingest again, and is settled
    # by {#nearest} rather than by this equality. The fallthrough is unchanged; what changed is how
    # often it is taken.
    def identical_text(signal)
      @digest_index[SpecIdentity.digest_for(signal.text)]&.id
    end

    # Writes the one fact that makes this row's absence of an identity mean something: **it was
    # reached, something was tried, and it did not land.**
    #
    # == What the stamp means, since it now has two writers
    #
    # It meant "the provider was asked and could not answer", which was the only failure that could
    # be recorded when SPGD-367 introduced the column. {#claim_inherited} is the second caller and
    # its failures are not the provider's, so the column is read here as the wider fact — and the
    # widening is stated rather than left for the next reader to infer from a name, because
    # `embed_failed_at` still says the narrower thing and cannot be renamed without a migration that
    # would move two audit scopes and the index under them.
    #
    # The widening is safe because of WHICH distinction the rest of this class actually leans on.
    # {#identity_for}'s `:none` early return is the one that matters, and its claim is *"a row with
    # nothing to embed is permanently unresolved and must never enter the retry backlog; a row whose
    # embed failed is temporarily unresolved and must"* — a split between **permanently** and
    # **temporarily** unresolved, not between the provider and everything else. A contained row is
    # squarely on the temporary side: a dropped connection is exactly the transient thing a bounded
    # retry is for, and a row that is genuinely hopeless leaves by the window rather than by being
    # recognised. That early return also still leaves no stamp of any kind — it returns before
    # {#identical_text}, before {#embed} and before {#nearest}, so there is nothing left on that path
    # for {#claim_inherited} to catch, and the signalless population stays exactly as separable as
    # it was.
    #
    # What it is NOT is a claim that a stamped row failed at the provider. Anything that needs that
    # distinction has the log line {#embed} and {#claim_inherited} each write; the column is the
    # queryable, retryable fact and never the diagnosis.
    #
    # == The mechanics, unchanged since SPGD-367
    #
    # `embed_failed_at` is `COALESCE`d so it holds the FIRST failure and no later one moves it. That
    # is what makes `SpecObservation::EMBED_RETRY_WINDOW` a window that closes rather than one every
    # retry pushes forward — a stamp refreshed on each attempt would keep a hopeless row retryable
    # for exactly as long as anything kept retrying it, which is forever.
    #
    # One UPDATE with the increment computed in SQL rather than read into Ruby and written back,
    # because N shards of a run schedule N jobs over the same rows: two of them reading `0` and both
    # writing `1` would lose an attempt, and the count is what orders the sweep.
    #
    # `updated_at` is deliberately not moved, following {#link_all} — resolution facts are written
    # below Active Record's timestamping precisely so they do not disturb the row's measurement
    # history, and `Ingest::ObservationRecorder::REMEASURABLE` keeps the two halves apart from the
    # other direction.
    #
    # == What bounds a poison row, and what deliberately does not
    #
    # Both columns do a job for {#claim_inherited} and neither is new machinery. The count demotes:
    # {#failed_embed_backlog} orders `(:embed_failure_count, :embed_failed_at, :id)`, so a contained
    # row sinks below every row that has been tried less and the sweep goes on round-robining the
    # rest of the backlog instead of spending itself on the one that cannot be rescued. The
    # timestamp ends it: seven days after its first containment the row leaves `.embed_retryable`
    # for `.embed_abandoned` and stops being swept at all, queryable as a thing that was given up on.
    #
    # **No failure-count exclusion is added**, and that is a decision rather than an omission.
    # `SpecObservation::EMBED_RETRY_WINDOW`'s own comment refuses an attempt CAP for this pipeline
    # and the argument transfers here without modification: `embed_failure_count` counts attempts by
    # ANYTHING, and an N-shard delivery schedules N jobs over these same rows, so a cap is spent by
    # the concurrency rather than by the retrying and the number that would survive it is a client's
    # shard count — which this application never sees. The same inflation is harmless to the
    # ordering, because concurrent sweeps bump roughly the same rows together and leave the order
    # BETWEEN them where it was. So the count ranks and the clock bounds, exactly as before.
    #
    # What that costs, stated: a contained row is re-attempted once per ingest for up to a week, at
    # one lookup and one embedding each — the same price a provider-failed row has always carried,
    # under a budget `RETRY_SWEEP_LIMIT` already caps, and demoted below everything with a better
    # claim on that budget. A row stranded UNSTAMPED and then contained also restarts its clock: its
    # seven days ran from `created_at` and now run from `embed_failed_at`. Bounded either way, and
    # anchoring the window to the first failure is what `embed_failed_at` has always meant.
    #
    # @return [nil] always — the callers are {#identity_for}, which still has no identity, and
    #   {#claim_inherited}, which returns 0 of its own.
    def record_resolve_failure(observation)
      SpecObservation.where(id: observation.id).update_all(
        ["embed_failed_at = COALESCE(embed_failed_at, ?), embed_failure_count = embed_failure_count + 1",
         Time.current]
      )

      nil
    end

    # The nearest existing identity in THIS repository, if one is close enough to be the same test.
    #
    # Repository-scoped because identity is per repository — two codebases sharing a test name share
    # nothing else, and the tenant boundary is not a thing similarity gets to cross. `threshold:` is
    # `neighbor`'s own, a cosine *distance*, so the comparison lands in SQL rather than being
    # re-derived from `neighbor_distance` here; `first` on an ordered relation is `LIMIT 1`.
    #
    # == The scope filter is applied AFTER the index scan, and under-recall here costs an identity
    #
    # An HNSW scan produces `hnsw.ef_search` candidates (default 40) from the whole table and only
    # then applies `repository_id` — for the shapes where the planner chooses that scan. Measured
    # (SPGD-375, `script/ann_recall_audit.rb`, PostgreSQL 17.9 / pgvector 0.8.6, an 80,100-row
    # table of four 20,000-row tenants and one 100-row one, near-band probes at cosine 0.96–0.995
    # of a tenant's own row): the planner does NOT hand every shape to HNSW. For a SMALL tenant it
    # bitmap-scans `index_spec_identities_on_repository_id` and computes distances as a filter —
    # exact, recall 1.000 at every `ef_search`. For a tenant whose own 20,000 rows make the
    # repository filter unselective, it chooses the HNSW index with `repository_id` applied after
    # the scan — the exposure shape — and at stock `ef_search` 40 that query returns the exact
    # truth's row for only **0.91** of near-band probes: one observation in eleven that is inside
    # the match band comes back with nothing, and a test that already had an identity gets a second
    # one. A miss here is not a worse ranking, it is a history split in two.
    #
    # **Mitigated, with the number that chose it.** The query below runs inside its own
    # transaction and issues `SET LOCAL hnsw.iterative_scan = 'relaxed_order'` before it, scoped
    # to this statement and undone at commit — a global `hnsw.*` change would tax every other
    # vector consumer for a fix only this query needs. On the same grid: `iterative_scan =
    # relaxed_order` at stock `ef_search` returns recall **1.000**. Raising `ef_search` to 200
    # also reaches 1.000, and is not preferred because it buys the same recall for the same
    # latency (~148 ms/query against ~7.9 unmitigated) while making EVERY query dearer at the
    # index level; iterative scan pays only when the filtered candidate list is short, which is
    # exactly the under-recall case. What the fix costs on a miss — the axis it was left off for
    # in the first place — is bounded and symmetric on this corpus (~140 ms miss vs ~138 ms hit
    # for a large tenant), and it cannot tax the first-ingest run that made the old paragraph
    # hesitate: a repository's first run inserts into a table its tenant does not yet dominate,
    # the planner answers small-tenant shapes from the `repository_id` index, and the GUC is inert
    # on a non-HNSW plan. Unchanged re-ingests never reach this method at all ({#identical_text}
    # and the digest shortcut return first), so the ~18x per-query cost lands only on the changed
    # and new tests of an already-large repository. Rerun the grid against a bigger corpus — or
    # against real Voyage geometry rather than the synthetic cluster corpus the script documents —
    # before trusting these numbers past 10^5 rows.
    #
    # What it cannot cost is the identical-text case — a moved test, or the same test ingested by
    # two shards. {#identical_text} answers that one before this method is called at all, and
    # `(repository_id, text_digest)` catches it again in {#claim_identity} whatever this returns.
    # The exposure is exactly the near-identical band, the case the spec's "differs only in
    # punctuation and whitespace" example isolates: the bytes differ, so neither equality can see
    # it and only similarity can find the row.
    #
    # == The projection is narrowed, and it is the four columns the callers actually read
    #
    # `neighbor` decides its select list as `select_values.any? ? [] : column_names` — so a scope
    # carrying no `select` gets EVERY column, `embedding` among them, and each hit ships a 1024
    # element pgvector back to materialise 1024 Ruby `Float`s that nothing reads. This is the
    # per-row path: an unchanged re-ingest never reaches it (the digest shortcut returns first), but
    # a first run or a changed suite at the 20,000-example design point pays it 20,000 times, inside
    # a job holding a run-scoped semaphore. It is the same prohibition {#digest_index},
    # {#resight_all} and {#refresh} each state in their own words for their own batch or by-id path,
    # and this was the one place that broke it.
    #
    # The four are what the callers read and no more: `id` for {#resight}, and `text`,
    # `text_digest`, `signal_source` for {#note_drift}'s three guards. {Drift} carries the QUERY
    # embedding it is handed, never `match.embedding` — which is why dropping the column costs
    # nothing here. A fifth reader would raise `ActiveModel::MissingAttributeError` on the row
    # rather than fail quietly, so this list stays honest by being too narrow and not too wide.
    #
    # == `order(:id)`: exact ties, and why the tiebreak stays
    #
    # `neighbor` calls `reorder`, which replaces the order with distance alone, and `first` on an
    # already-ordered relation adds no key of its own. Two identities can hold texts that embed to
    # the same array of floats — byte-identically, not approximately — and this class already
    # asserts such rows can coexist in one repository ({#refresh}'s rescue). Once two do, a third
    # equivalent observation matches BOTH at distance 0 and Postgres is free to emit either first:
    # one test's durations split across two identities, and {#note_drift} converges on a different
    # row each pass. Rails appends to the gem's `reorder`, so this is the second key that ranking
    # never had.
    #
    # ⚠️ This was the NORMAL case under the feature-hashing provider retired on 2026-08-17, which
    # embedded a downcased, punctuation-stripped form and so collapsed whole families of spellings
    # onto one vector. `VoyageProvider` sends the text as written, which makes an exact tie rare
    # rather than routine — and rare is not never, so the tiebreak is not removed. A
    # non-deterministic winner is the kind of bug that reproduces once a quarter.
    # {#failed_embed_backlog} and {#unattempted_embed_backlog} carry an explicit tiebreak for the
    # same REASON — cite them for that and not for the shape, because their cost is nothing like
    # this one's. Inert under a provider that publishes no normalisation, where the two vectors
    # really are different.
    #
    # **What the second key costs, and the condition attached to it.** Those two are ordinary B-tree
    # orderings over `spec_observations` backed by partial indexes, where appending `id` is free.
    # Appending it to an ANN-ORDERED scan is not. Measured here on a 20,000-row single-repository
    # fixture built with the real {EmbeddingGenerator}, with the ANN plan forced (`enable_sort=off`)
    # at `ef_search` 40 and `iterative_scan` off:
    #
    #   without `id`:  Limit -> Index Scan using index_spec_identities_on_embedding  (0.6-1.1 ms)
    #   with `id`:     Limit -> Incremental Sort (Presorted Key: distance)
    #                             -> Index Scan using index_spec_identities_on_embedding
    #
    # Postgres can no longer take the ordering straight off the HNSW scan, so it sorts over the
    # candidates the scan drains rather than stopping at the first row that clears the threshold.
    # The cost is bounded, does not grow with the table, and is far smaller than the 20,000 x 1024
    # `Float` materialisations the narrowing above removes — it is **accepted deliberately**. What
    # it scales with is `ef_search`, which is **SPGD-72's** to set: this key makes that ticket's
    # likeliest move — raising `ef_search` — dearer than it was before, because the incremental sort
    # drains the candidate list on every hit. SPGD-72 is measuring this plan, not the one that was
    # here before.
    #
    # **But that plan was not the one this query got under the old column, and SPGD-375's run
    # closed the question.** On PG 17.10 / pgvector 0.8.0 over the retired 1536-float `vector`,
    # the planner chose `index_spec_identities_on_embedding` for NO shape of this query — TOAST
    # made the "cheap" seq scan win and the index sat at zero scans. On `halfvec(1024)`
    # (PostgreSQL 17.9 / pgvector 0.8.6, `script/ann_recall_audit.rb`'s 80,100-row corpus, stock
    # costs, after ANALYZE) that has changed: for the shape where the repository filter is
    # unselective — a tenant's own 20,000 rows — the planner now CHOOSES `Limit -> Incremental
    # Sort (Presorted Key: distance) -> Index Scan using index_spec_identities_on_embedding`,
    # with `repository_id` and the threshold as filters applied after the scan. The tiebreak's
    # incremental sort is therefore no longer hypothetical: it is on the plan this query actually
    # gets for large tenants, and the under-recall paragraph above was measured on that same
    # plan. For a small tenant the planner bitmap-scans `repository_id` and the HNSW index never
    # runs — the tiebreak is free there and the exposure is absent there, and those are the same
    # statement. Which plan wins remains planner-version- and data-shape-dependent; correctness
    # (the tiebreak, the projection) holds under either, and the recall mitigation below is
    # inert on a non-HNSW plan.
    def nearest(embedding)
      SpecIdentity.transaction do
        # Scoped to THIS query via SET LOCAL inside the surrounding transaction — never a global
        # `hnsw.*` change, which would tax every other vector consumer for a fix only this query
        # needs. Two notes for whoever touches this: (1) SET LOCAL persists until COMMIT, so if a
        # caller already holds a transaction this savepoint joins, the GUC rides to that outer
        # transaction's end — harmless here because `iterative_scan` only alters how an HNSW scan
        # gathers candidates and the resolver's other statements are not vector scans, but it is
        # why this is a transaction of its own whenever nothing outer holds one; (2)
        # `relaxed_order` and not `strict_order`: the `.order(:id)` tiebreak below already forces
        # an Incremental Sort over whatever the scan emits, so paying for strict ordering inside
        # the scan as well buys nothing.
        SpecIdentity.connection.execute("SET LOCAL hnsw.iterative_scan = 'relaxed_order'")
        @repository.spec_identities
                   .select(:id, :text, :text_digest, :signal_source)
                   .nearest_neighbors(:embedding, embedding, distance: "cosine",
                                      threshold: SpecIdentity::MATCH_DISTANCE)
                   .order(:id)
                   .first
      end
    end

    # **The one match that can never learn from itself, marked so it stops recurring.** A test whose
    # description drifts only in punctuation or whitespace embeds to the SAME vector as the row it
    # already has, so {#nearest} finds it at cosine 1.0 and it is re-sighted correctly — and the row
    # keeps the ORIGINAL spelling's `text_digest` forever, because {SpecIdentity::RESIGHTABLE} does
    # not move it. Every later ingest presents the new spelling, {#identical_text} misses again
    # (neither side ever changes), and the row pays a full embed and a per-row ANN round trip again.
    # Permanently, and for a population that only grows: every punctuation edit ever made adds a row
    # that can never take the cheap path again.
    #
    # Re-pointing the identity at the presented spelling converges it — one write, once, and from
    # the next ingest on {#identical_text} answers the row for free like any other. That is the whole
    # of what this records; {#refresh_all} decides which candidate is written and {#refresh} writes
    # it.
    #
    # == Why the band is normalisation-equivalence and NOT {SpecIdentity::MATCH_SIMILARITY}
    #
    # Refreshing on any match at or above 0.95 would move an identity's text on an ordinary edit,
    # which is the opposite of what this class decides everywhere else: *"a renamed unannotated test
    # is a different test"*, and the resolver spec pins that a rename starts a new identity and
    # leaves the old row's text alone. The stuck population is not "everything that matched" — it is
    # exactly the texts the provider cannot tell apart, which is why only they can never self-heal
    # and why only they are touched here.
    #
    # `EmbeddingGenerator.equivalent?` and not a comparison against a cosine of 1.0: the provider
    # knows which of its inputs collapse together, and a float distance is the wrong instrument for
    # an exact question. A provider that publishes no normalisation answers `false` for every pair
    # of different strings, so this whole path is inert under `VoyageProvider` — correctly, because
    # there the two spellings really are two different vectors and the drift really is an edit.
    #
    # == Same source only
    #
    # A cosine-1.0 match ACROSS sources — an intent triple whose words happen to normalise onto the
    # name a row is still held under — is {#upgrade_from_name}'s question and not this one. That
    # transition moves `signal_source` too, deliberately in one direction only; answering it here
    # would let a de-annotation ride in as a spelling refresh and leave a row claiming a source its
    # text no longer matches. Skipped rather than guessed at, and it costs only that today's
    # behaviour continues for a case the upgrade path already owns.
    #
    # == At most one refresh per identity per page — and {#refresh_all} bounds the rest
    #
    # `@drifts` is keyed by identity, so a page carrying several spellings of one test records one
    # candidate and not one per row. WHICH of them survives is not decided here: the last writer into
    # the hash is arbitrary and {#refresh_all} re-settles it against the sighting the page actually
    # chose. That answers a page and only a page — two examples differing only in punctuation can
    # land in different pages and would otherwise rewrite each other's text on every ingest — so the
    # bound against thrash is finished there, by two refusals scoped to the whole `#resolve` rather
    # than to one of its pages.
    def note_drift(match, signal, embedding, observation)
      digest = SpecIdentity.digest_for(signal.text)
      return if digest == match.text_digest
      return unless match.signal_source == signal.source.to_s
      return unless EmbeddingGenerator.equivalent?(match.text, signal.text)

      @drifts[match.id] = Drift.new(observation, signal.text, digest, match.text_digest, embedding)
    end

    # **A test that gained an `@intent` is the test it already was.** Moves the identity it already
    # has onto its declaration — `text`, `text_digest`, `signal_source`, `embedding` — instead of
    # inserting a second row beside it and orphaning the first.
    #
    # @return [Integer, nil] the id of the upgraded identity, or nil when there is nothing to upgrade
    #   and {#identity_for} should insert exactly as it did before.
    #
    # == Why nothing else can reach this case
    #
    # {Ingest::SpecSignal} prefers a declaration over a name deliberately — *"preferring the name
    # would make annotating a test change nothing"* — so on the annotation run the text representing
    # this test changes from its `full_description` to its triple, and the row it already has is held
    # under a string no run will ever present again. {#identical_text} asks for the triple's digest
    # and misses; {#nearest} misses too, and not by a margin a threshold could close: this
    # repository's own `annotated_spec` fixture — a triple that strictly CONTAINS the whole name —
    # scored 0.8614 against a 0.95 bar on the lexical provider retired on 2026-08-17. Lowering the
    # bar that far
    # would merge tests that merely read alike, which the resolver spec pins separately. So this is
    # not similarity tuned too tight; it is a question similarity cannot answer.
    #
    # ⚠️ That 0.8614 has NOT been re-measured on `VoyageProvider`, and a semantic model may well
    # score a containing triple above 0.95 — see `SpecIdentity::MATCH_SIMILARITY`, which is
    # uncalibrated for the current provider. This path does not depend on the number: it exists so
    # that the transition is answered by evidence rather than by a distance, and it stays correct
    # whichever side of the bar similarity happens to land on.
    #
    # It does not have to. The evidence is already on the row: {Ingest::ObservationRecorder} writes
    # `name` for every example, so at the moment of the miss this resolver is holding the exact
    # string the old identity was built from. Nothing is embedded, inferred or guessed — it is one
    # more digest, and {#lookup_texts} already rode it in on the page's `IN` list.
    #
    # == name → intent only, and never the reverse
    #
    # Guarded twice on purpose: the caller only reaches here for an intent-derived signal, and only a
    # `from_name?` row is taken. A de-annotated test rewriting its identity BACKWARDS would let an
    # ordinary rename masquerade as a de-annotation — the name a test presents after an author edits
    # its `describe` block is not evidence about the triple that used to represent it, and treating
    # it as such would move an identity onto text that has nothing to do with it. De-annotation is
    # out of scope for this slice and is a decision rather than an omission.
    #
    # == This is NOT a re-sighting, and {SpecIdentity::RESIGHTABLE} stays as it is
    #
    # That list is what an ORDINARY re-observation moves, and the four columns written here are
    # excluded from it *"because they are the identity itself"*. Widening it would make every
    # re-sighting start rewriting `text` — the exclusion is load-bearing and is not touched. This is
    # its own statement, made in one place, on one transition, under a `WHERE` that no ordinary
    # re-sighting can satisfy. The SIGHTING is still a re-sighting and still goes through {#resight},
    # so where the test was last seen moves FORWARD only, exactly as everywhere else.
    #
    # == The mirrored unique key, and why a collision falls back rather than raises
    #
    # `(repository_id, text_digest)` is UNIQUE, so if a DIFFERENT identity already holds this
    # triple's digest the `UPDATE` cannot land. The page's map says otherwise or {#identical_text}
    # would have answered already, which makes this a race against a concurrent job rather than a
    # state — and the honest answer to it is today's behaviour, not a 500 on the ingest path. A
    # duplicate identity is a defect; an ingest that fails to resolve is a worse one. So the conflict
    # is contained and {#identity_for} goes on to {#claim_identity}, whose `ON CONFLICT` lands the
    # observation on whichever row won.
    #
    # `requires_new: true` is what makes containing it possible at all: a failed statement poisons
    # the enclosing transaction until something rolls back, so the rescue needs a savepoint to roll
    # back TO. Two extra statements, once per test in its whole lifetime, on the run where it is
    # annotated.
    #
    # == Where the name it looks up is not unambiguously its own
    #
    # The row it takes is whichever this repository holds under that `full_description`, and two
    # examples can share one — a table-driven loop, a shared example group, `it "is valid"` in two
    # files. So an annotated test whose description another, unannotated test also carries takes the
    # row they were both going to share. That is not a new ambiguity introduced here: under this
    # model identity IS the text, and `SpecIdentity::MATCH_SIMILARITY` already states that two
    # examples with the same description collapse onto one row and no threshold can separate them.
    # The upgrade inherits that edge rather than widening it, and it costs one row's history in a
    # case where the model was already holding two tests' measurements on one row. Narrowing it by
    # `file_path` was considered and refused: a test that is annotated and moved in the same commit
    # is the ordinary case, and that guard would send it back to inserting a duplicate — trading a
    # rare ambiguity for a common failure.
    #
    # == Concurrency needs nothing else
    #
    # `signal_source: "name"` in the `WHERE` makes this a compare-and-set in one statement: the
    # shard that gets there first upgrades, and a second shard reaching the same row updates zero
    # rows and falls through to {#claim_identity}, which conflicts onto the row the first one just
    # wrote and re-sights it. Once the upgrade is committed every later run's {#identical_text} hits
    # the triple's digest outright and takes the ordinary path. Self-converging, and idempotent
    # because both writers were writing the same text, digest and vector.
    #
    # What the losing shard must still do is put its OWN page's map right, which is a separate
    # statement from where its own observation lands: the row it was pointed at has moved off the
    # name, so the entry that says otherwise has to go whether or not this shard is what moved it.
    # See the `:conflict` guard below for the one outcome that leaves the entry standing.
    def upgrade_from_name(signal, embedding, observation)
      return nil unless signal.from_intent?

      name = name_signal(observation)
      return nil unless name.present?

      name_digest = SpecIdentity.digest_for(name.text)
      held = @digest_index[name_digest]
      return nil unless held&.from_name?

      # **A row this same page has decided to insert and has not inserted yet cannot be upgraded.**
      # {#upgrade} names its target by id and its id is a {PendingIdentity} — the `UPDATE` would
      # match nothing, and taking `:lost_race` from that would delete a map entry that is still true.
      # Refused here instead, which leaves the entry standing (the pending row genuinely is under
      # that name) and sends this observation on to {#claim_identity} to buffer its own row.
      #
      # What that costs is a name-derived row beside the triple where the per-row path had one row
      # for the length of this page — and it costs it in the case where two observations of ONE test
      # arrive in a single delivery, one before and one after it gained an `@intent`, which the
      # upgrade path was never built for. It is one ingest of earliness rather than a different
      # destination: the per-row path upgrades here and RE-SPLITS on the next ingest, when the
      # unannotated example re-presents a name the upgraded row no longer holds and scores ~0.86
      # against a 0.95 bar. Both paths settle on the same two rows; this one gets there without
      # rewriting a row in between. `identity_resolver_spec.rb`'s "refuses the upgrade when the row
      # under the name is one THIS PAGE has not inserted yet" pins both halves of that.
      #
      # The alternative — flushing the page's inserts mid-walk to get an id — would put a round trip
      # back on the path this slice exists to take one off, and put it there on the say-so of the
      # rarest shape on it.
      return nil if held.id.is_a?(PendingIdentity)

      digest = SpecIdentity.digest_for(signal.text)
      outcome = upgrade(held.id, signal, digest, embedding)

      # The page's map follows the row, and it follows it on **whether the row moved** rather than on
      # whether THIS call is what moved it — which is why the invalidation is keyed on `:conflict`
      # and not on `:upgraded`. The old key is DELETED and not merely superseded: nothing is held
      # under that name any more, and a later row of this same page reading a stale entry would
      # re-sight a row whose text it no longer matches — a name-only example sharing a description
      # with the test that was just annotated is exactly that case, and it must claim its own row.
      #
      # `:lost_race` is that same hazard reached by the other branch, and it is the one this method
      # first got wrong: a concurrent shard has already rewritten the row to a triple, so the row has
      # moved just as surely as on the success path and the map is just as false — the losing shard
      # must not leave the entry behind for its own sibling to read. `:conflict` is the one outcome
      # that keeps the entry, and keeps it because it is still TRUE: the `UPDATE` was refused by the
      # unique key, so the row never left the name and a sibling reading it re-sights correctly.
      @digest_index.delete(name_digest) unless outcome == :conflict
      return nil unless outcome == :upgraded

      @digest_index[digest] = HeldIdentity.new(held.id, signal.source.to_s)

      resight(held.id, observation)
    end

    # The upgrade itself, as one guarded statement.
    #
    # `update_all` and not `update!`: the row is named by id and nothing on it is read first, so
    # loading it would fetch a 1024 element vector to overwrite it — and the model's mirrored
    # `text_digest` uniqueness validation would answer from a SELECT that the unique index has to
    # decide anyway. The index decides it, and the conflict is contained here.
    #
    # @return [Symbol] which of three things happened, because the caller's map invalidation turns on
    #   the difference and a boolean cannot carry it. `:upgraded` — this call moved the row.
    #   `:lost_race` — the guard matched zero rows, so another writer already moved it off the name.
    #   `:conflict` — the unique key refused the target digest, so the row is still on the name. The
    #   last two are both a fall-through to {#claim_identity} for THIS observation and opposite
    #   answers about whether the page's `name_digest` entry is still true; see {#upgrade_from_name}.
    def upgrade(identity_id, signal, digest, embedding)
      updated = SpecIdentity.transaction(requires_new: true) do
        SpecIdentity.where(id: identity_id, signal_source: "name")
                    .update_all(text: signal.text, text_digest: digest,
                                signal_source: signal.source.to_s, embedding: embedding,
                                updated_at: Time.current)
      end

      updated.positive? ? :upgraded : :lost_race
    rescue ActiveRecord::RecordNotUnique
      :conflict
    end

    # **The page's spelling refreshes — the candidates {#note_drift} collected, filtered down to the
    # ones the page's own settled sightings agree with.**
    #
    # @param sightings [Array<(Integer, SpecObservation)>] one observation per identity, already
    #   settled by {#newest_sighting_per_identity} — see {#flush_page} for why it is passed in.
    #
    # == Newest spelling wins, and it is not a second way of asking that
    #
    # A backlog page mixes runs by design ({#retry_backlog}), so two observations of one test can
    # propose two different spellings and one of them is older. {#newest_sighting_per_identity} has
    # ALREADY answered exactly that question — newest run by `(created_at, id)`, ties to the row
    # walked last — in order to decide which sighting the row takes, so the spelling is taken from
    # the observation that won there rather than from a second predicate that could disagree with
    # it. {SpecIdentity::SIGHTING_NOT_OLDER} is deliberately not instantiated a third time for this:
    # it is `private_constant` precisely so a caller cannot format its own copy, and its two public
    # seams are shaped for a `VALUES` join and for an upsert's `excluded`, neither of which is a
    # single-row `UPDATE` by id.
    #
    # A candidate whose observation did NOT win is dropped and not deferred. That is the right
    # answer rather than a lost write: the identity carries the winner's spelling, and if the winner
    # is the row that is already stored then there is nothing to move at all.
    #
    # **Bounded by the ordering it is derived from, not by it being a guard.** An observation of an
    # OLDER run reaching a page alone — a rescued row of a run that has since been superseded — is
    # the winner of that page and does write its spelling, which can move a row backwards onto a
    # spelling a newer run had already replaced. It is contained by construction and it converges:
    # both spellings are the same test and the same vector, so nothing is misattributed, and the
    # next ingest presenting the newer spelling refreshes it forward again. One extra write on a
    # rescued page, against a permanent per-ingest embed — and against a third copy of a predicate
    # {SpecIdentity} states outright must not have one.
    #
    # Sorted by identity id for the reason {#write_page} argues at length: these are row locks on
    # `spec_identities`, and two concurrent jobs over overlapping pages should take the rows they
    # share in the same relative order.
    #
    # == The two PASS-scoped refusals, because a page's bound is one page-boundary short
    #
    # {#note_drift}'s `@drifts` key bounds this to one candidate per identity per PAGE, which settles
    # a page carrying two equivalent spellings and settles nothing at all when they land in different
    # pages — and `#resolve` pages by `BATCH_SIZE`, so at the design point a suite is forty of them
    # and nothing keeps two variants of one test adjacent. Unbounded across pages the row ping-pongs:
    # the earlier page misses on the spelling the row holds and moves it, the later page rebuilds its
    # map, misses on what the earlier page just wrote, and moves it back — forever, and now with two
    # `UPDATE`s an ingest on top of the two embeds it was already paying. That is a net regression in
    # a slice whose whole premise is convergence, so both refusals are scoped to the `#resolve` and
    # not to the page:
    #
    # 1. `@refreshed` — **one spelling write per identity per pass.** The first page to reach a
    #    drifted identity settles it and every later page of the same pass leaves it alone, so the
    #    cycle cannot complete a lap.
    # 2. `@spellings_in_use` — **never move a spelling that is demonstrably still presented.** An
    #    identity some observation matched by exact text ({#identity_for}) is not stale, whatever a
    #    second observation's equivalent spelling proposes; moving it would only make the row that
    #    matched miss next time. This is what makes the pair CONVERGE rather than merely stop
    #    thrashing: once one spelling is stored, the observation presenting it hits the digest
    #    equality on every later ingest, records the identity here, and the other spelling's drift is
    #    refused permanently. The pair settles on the first-walked spelling and costs one embed an
    #    ingest, against the two it costs today.
    #
    # **Both are read at flush time, so a later page's exact hit cannot retroactively refuse an
    # earlier page's refresh** — page 1 has committed before page 40 is walked. That is what makes
    # the convergence take one extra ingest rather than being instant, and it is the whole of the
    # residual: the ingest after the drift settles the spelling, the ingest after that observes the
    # exact hit and refuses the other, and it is stable from there. The same one-ingest lag is what a
    # backlog page costs when it carries an OLD run's observation presenting the spelling the row is
    # being moved off: the drift is refused that pass and applies on the next, by which time the
    # rescued row is resolved and gone from the backlog.
    def refresh_all(sightings)
      return if @drifts.empty?

      settled = sightings.to_h

      @drifts.sort_by(&:first).each do |identity_id, drift|
        next if @refreshed.include?(identity_id) || @spellings_in_use.include?(identity_id)
        next unless settled[identity_id] == drift.observation

        @refreshed << identity_id
        refresh(identity_id, drift)
      end
    end

    # The refresh itself, as one guarded statement — {#upgrade}'s shape, for {#upgrade}'s reasons.
    # `update_all` by id and never a loaded record: the row is named outright and nothing on it is
    # read first, so loading it would fetch a 1024 element vector in order to overwrite it.
    #
    # **`text_digest` is the compare-and-set.** The refresh is only ever correct against the row as
    # it was when {#nearest} matched it, and a concurrent shard resolving the same test — or
    # {#upgrade_from_name} moving this row onto a declaration — changes that digest. Either way the
    # `WHERE` matches nothing, this call writes nothing, and the row keeps whatever the other writer
    # gave it. Nothing is lost: the losing spelling is normalisation-equivalent to the winning one,
    # so the row is on a spelling of the same test either way and the next ingest converges it.
    #
    # `signal_source` is deliberately NOT in the `SET` — {#note_drift} only records a candidate whose
    # source already matches, so there is nothing to move, and this transition must not become a
    # second way to change it.
    #
    # The vector is rewritten alongside the text even though normalisation-equivalence means it is
    # the same vector: the two are written from ONE observation, so the row's text and its embedding
    # cannot disagree by construction rather than by an argument about the provider that has to stay
    # true.
    #
    # `RecordNotUnique` is contained because the unique `(repository_id, text_digest)` key can refuse
    # the target: another identity in this repository may already hold the presented spelling — a
    # row a concurrent shard inserted after this page took its {#digest_index} snapshot, which is why
    # {#identical_text} did not find it. The row is left exactly where it is and the next ingest asks
    # again against a map that now knows about it. `transaction(requires_new: true)` so that refusal
    # is contained here rather than poisoning anything around it, exactly as in {#upgrade}.
    #
    # No {#write_page} wrapper and no deadlock retry, unlike the page's batched statements: this
    # takes ONE row lock, inside one statement, and a transaction that never holds a second lock
    # cannot be half of a cycle — the same argument {#write_page} makes about the per-row path it
    # replaced. That argument covers `Deadlocked` and not every error a statement can raise, which is
    # why {#flush_page} issues this AFTER the page's two required writes: anything this raises that
    # the rescue below does not name costs the ingest its convergence and never the page's sightings
    # or its links.
    def refresh(identity_id, drift)
      SpecIdentity.transaction(requires_new: true) do
        SpecIdentity.where(id: identity_id, text_digest: drift.from_digest)
                    .update_all(text: drift.text, text_digest: drift.digest,
                                embedding: drift.embedding, updated_at: Time.current)
      end
    rescue ActiveRecord::RecordNotUnique
      Rails.logger.info(
        "[IdentityResolver] run=#{@run.id} left identity #{identity_id} on its original spelling: " \
        "another identity in this repository already holds the presented text"
      )
    end

    # An existing test, seen again. Moves only where it was last seen — see
    # {SpecIdentity::RESIGHTABLE} for why the text and the vector are not in that set — and moves it
    # only FORWARD, which is {SpecIdentity::SIGHTING_NOT_OLDER}'s job.
    #
    # **Records the sighting rather than writing it**, because the write is the page's and not the
    # row's since this slice: {#resight_all} spends the buffer on one guarded statement for the whole
    # page. Nothing about WHICH identity this observation re-sights, or about what a re-sighting
    # moves, is decided anywhere but here.
    #
    # The guard still belongs in the statement and not around it, and now in the batched statement's
    # own `WHERE` rather than hoisted out of it — see {#resight_all}. This loop resolves rows of
    # several runs and two jobs run it concurrently, so a read-compare-write in Ruby would be
    # checking a value another job is free to move before the write lands.
    #
    # A guard that fails updates nothing and this still returns the identity — the observation is an
    # observation OF this test whether or not it is the most recent one, and the link is what
    # {#claim} records. No callbacks and no validation pass over a 1024 element vector that has not
    # changed, exactly as before.
    #
    # Takes an ID rather than a record, which is all either caller has now that {#identical_text}
    # answers out of a `pluck`ed map — and all this ever needed: {SpecIdentity::RESIGHTABLE} is the
    # whole of what a re-sighting writes and none of it is read off the row first.
    def resight(identity_id, observation)
      @sightings << [identity_id, observation]

      identity_id
    end

    # **The page's re-sightings, in one guarded `UPDATE`.** This was one statement per row — the
    # first of the two an unchanged re-ingest paid for every example it had already seen, and at the
    # 20,000-example design point 20,000 sequential round trips to write what the page already knew.
    #
    # @param sightings [Array<(Integer, SpecObservation)>] one observation per identity, already
    #   settled by {#newest_sighting_per_identity}. Taken as an argument rather than read here since
    #   {#refresh_all} became a second reader of the same answer — see {#flush_page}.
    #
    # `UPDATE … FROM (VALUES …)` and not an `IN` list, because every row carries its own values:
    # each identity takes ITS observation's path, line and run, so there is nothing to hoist into a
    # single `SET`. {SpecIdentity::RESIGHTABLE} builds both the `SET` and the tuple, so this
    # statement and {#sighting} and the conflict clause in {#claim_identity} stay one definition of
    # what a re-sighting moves rather than three.
    #
    # **The guard stays in the `WHERE`, per row.** {SpecIdentity.sighting_not_older_than_values} is
    # the same `SIGHTING_NOT_OLDER` the per-row path took, instantiated against the `VALUES` alias's
    # own `last_seen_test_run_id` — see that helper for why it has to be a class-level instantiation
    # on the model and not something built here. It compares each identity against the sighting
    # proposed for THAT identity, so hoisting it would be a different predicate and not an
    # optimisation of this one.
    #
    # One `Time.current` for the page rather than one per row, so a page's re-sightings share an
    # `updated_at`. They were microseconds apart before and are now equal; nothing reads that column
    # as an ordering key — {SpecIdentity::SIGHTING_NOT_OLDER} orders by the RUN's `(created_at, id)`
    # and never by this.
    #
    # **Sorted by the identity id**, which is the join key and therefore the key this statement takes
    # its row locks on. Not cosmetic and not for the reader: it makes the tuple list a function of
    # WHICH identities the page holds rather than of the order the work list happened to return them
    # in, so two concurrent jobs over overlapping pages agree about the shared rows. {#write_page}
    # argues why that matters and why it is not sufficient on its own. It has no effect on WHICH
    # sighting lands — {#newest_sighting_per_identity} has already settled that, one row per
    # identity, before there is anything to sort.
    def resight_all(sightings)
      return if sightings.empty?

      now = Time.current
      rows = sightings.map do |identity_id, observation|
        [identity_id, *sighting(observation, now).values_at(*SpecIdentity::RESIGHTABLE)]
      end.sort_by(&:first)
      table = SpecIdentity::SIGHTING_VALUES_ALIAS

      sql = <<~SQL.squish
        UPDATE spec_identities
        SET #{SpecIdentity::RESIGHTABLE.map { |column| "#{column} = #{table}.#{column}" }.join(', ')}
        FROM #{values_clause(rows, SpecIdentity, %i[identity_id] + SpecIdentity::RESIGHTABLE, table)}
        WHERE spec_identities.id = #{table}.identity_id
          AND #{SpecIdentity.sighting_not_older_than_values}
      SQL

      write_page do
        SpecIdentity.connection.exec_update(SpecIdentity.sanitize_sql_array([sql, *rows.flatten]))
      end
    end

    # **A page may re-sight ONE identity from SEVERAL observations, and this is what settles which
    # of them lands.** Not a corner: two examples whose `full_description` is identical resolve to
    # one row (`SpecIdentity::MATCH_SIMILARITY` states why no threshold can separate them), and
    # {#retry_backlog} mixes runs by design, so a backlog page can hold this run's row and an
    # earlier one's for the same test.
    #
    # It settles the identity's SPELLING as well, and by settling nothing extra: {#refresh_all} reads
    # this same answer, so the observation whose path a row takes is the observation whose text it
    # takes. Two questions, one adjudication.
    #
    # Sequential guarded `UPDATE`s settled it by executing: within one run last-writer-wins, which
    # is correct because two examples sharing a description have no order between them; across runs
    # the guard refused the older one whichever order they were walked in. A single statement has no
    # "last" — `UPDATE … FROM (VALUES …)` joined on a DUPLICATED key picks a row **arbitrarily** and
    # applies only that one — so the page has to arrive already deduplicated or the guard is asked
    # about a row nobody chose. Getting this wrong reintroduces exactly the backwards sighting
    # {SpecIdentity::SIGHTING_NOT_OLDER} exists to make structurally impossible, and it does it
    # silently.
    #
    # Newest run wins, by `(created_at, id)` — the ordering that guard is written in and the one
    # every recency question in this application is asked in. Ties inside one run go to the row
    # walked LAST, which is what the sequential path did and is arbitrary either way.
    #
    # The `group_by` size check is not an optimisation of the arithmetic, it is what keeps the
    # ordinary page free of the read below: a page whose identities are distinct — every page of a
    # suite with distinct descriptions — has nothing to settle and is returned untouched.
    def newest_sighting_per_identity
      by_identity = @sightings.group_by(&:first)
      return @sightings if by_identity.size == @sightings.size

      order = sighting_run_order
      by_identity.each_value.map do |group|
        group.each_with_index.max_by { |(_, observation), index| [order[observation.test_run_id], index] }.first
      end
    end

    # `test_run_id => (created_at, id)`, for the runs a duplicated page actually holds.
    #
    # One query and never one per row, and none at all on the case that produces most duplicates: a
    # page whose observations all belong to ONE run — a run's own page, always — has no cross-run
    # question to ask, so every key is equal and the tie-break by position is the whole answer.
    # `[0, 0]` rather than a real key because nothing may distinguish them; see
    # {#newest_sighting_per_identity} for why last-walked wins that tie.
    def sighting_run_order
      run_ids = @sightings.map { |(_, observation)| observation.test_run_id }.uniq
      return run_ids.index_with([0, 0]) if run_ids.one?

      TestRun.where(id: run_ids).pluck(:id, :created_at).to_h { |id, created_at| [id, [created_at, id]] }
    end

    # **The page's links, in one `UPDATE`, counted from the rows it MATCHED.** The second of the two
    # statements an unchanged re-ingest used to pay per row.
    #
    # `RETURNING` and not `@links.size`, and that is the whole of what keeps {#resolve}'s return
    # value meaning what it has always meant. A row can be gone by the time this runs — a concurrent
    # shard redelivery deletes and re-upserts this run's observations, so a read out of the work list
    # can be stale — and the per-row path did not count that row because its `update_column` matched
    # nothing. Nothing is lost when it happens (the redelivered row is unresolved, so the next job
    # picks it up), but the count says "observations that NOW carry an identity", and in that window
    # this one does not. A batched statement that assumed its page size would quietly start counting
    # them.
    #
    # Raw SQL rather than `upsert_all`: an upsert would need every `NOT NULL` column of the row and
    # would move `updated_at`, and this must move exactly one column and disturb nothing else —
    # resolution facts are written this way precisely so they do not touch the row's measurement
    # history, which is the rule {#record_resolve_failure} and `ObservationRecorder::REMEASURABLE`
    # keep from the other side.
    #
    # **Sorted by the observation id**, the join key and the key the row locks are taken on, for the
    # reason {#resight_all} is and {#write_page} argues. A page's links are one per observation
    # already — {#claim} appends exactly one entry per row it resolved — so unlike the sightings
    # there is nothing to deduplicate first and the sort is the whole of what fixes the order.
    #
    # @return [Integer] how many of this page's observations now carry an identity.
    def link_all
      return 0 if @links.empty?

      rows = @links.sort_by(&:first)

      sql = <<~SQL.squish
        UPDATE spec_observations SET spec_identity_id = link.spec_identity_id
        FROM #{values_clause(rows, SpecObservation, %i[id spec_identity_id], 'link')}
        WHERE spec_observations.id = link.id
        RETURNING spec_observations.id
      SQL

      write_page do
        SpecObservation.connection.exec_query(
          SpecObservation.sanitize_sql_array([sql, *rows.flatten])
        ).rows.size
      end
    end

    # A `(VALUES …) AS alias (columns)` join source with a `?` per value, for the two `UPDATE`s above
    # to bind.
    #
    # **The first tuple's holes are CAST and the rest are bare**, which is the minimum that makes
    # the join sound rather than a flourish: Postgres takes an unadorned literal's type from the
    # first row of the `VALUES` list, so without this a `bigint` id would be compared against `text`
    # and an `integer` line number would be one too. Casting only the first row is enough to fix
    # every column's type, and casting all 500 of them would put four figures of redundant SQL on
    # the wire for the same result.
    #
    # The types come off the TARGET MODEL's own columns rather than from a list written here, so a
    # migration that widens a column cannot leave a cast behind naming what it used to be. `id` is
    # taken from the model too — {SpecIdentity}'s join key is its primary key under another name.
    #
    # The holes are counted off `columns` and not off the row, though a correct call has as many
    # values as columns and either would do. `types` is indexed by column, so deriving the hole count
    # from the row would be two indexes that merely happen to agree: a row one value short would
    # produce `CAST(? AS )` or a short tuple, and the first anyone heard of it would be a Postgres
    # syntax error a long way from the caller that built the row.
    def values_clause(rows, model, columns, table)
      types = columns.map { |column| model.columns_hash[column == :identity_id ? "id" : column.to_s].sql_type }
      tuples = Array.new(rows.size) do |index|
        holes = columns.each_index.map { |column| index.zero? ? "CAST(? AS #{types[column]})" : "?" }
        "(#{holes.join(', ')})"
      end

      "(VALUES #{tuples.join(', ')}) AS #{table} (#{columns.join(', ')})"
    end

    # What "seen again" moves, and the only definition of it. Sliced through
    # {SpecIdentity::RESIGHTABLE} so this method and the conflict clause in {#claim_identity} are the
    # *same* list rather than two copies of it: the match path and the conflict path both end in a
    # re-sighting, and one of them quietly moving a column the other does not is exactly the drift a
    # shared constant is for. {SpecIdentity::SIGHTING_NOT_OLDER} is shared by both for the same
    # reason, one level down: it decides WHETHER these values land.
    #
    # `last_seen_test_run_id` comes off the OBSERVATION and never off `@run`, and the two are only
    # equal on the run-scoped half of the work list. A row rescued from the backlog was seen by an
    # EARLIER run, and stamping this ingest's id on it would have the identity claim it was last
    # seen in a run that never contained it. They were the same value until the sweep existed; this
    # is the seam where they stop being.
    #
    # That makes the value honest, which is not the same as making it win — a rescue of run-1 and a
    # rescue of run-2 both produce honest values for the same identity in one pass, and which of the
    # two the row keeps is the guard's decision rather than this method's.
    def sighting(observation, now)
      { file_path: observation.file_path, line_number: observation.line_number,
        last_seen_test_run_id: observation.test_run_id, updated_at: now }.slice(*SpecIdentity::RESIGHTABLE)
    end

    # A test nothing matched: insert it — or lose the race to insert it and take the winner.
    #
    # **Records the row rather than writing it**, because the write is the page's and not the row's
    # since this slice: {#insert_pending_identities} spends the buffer on one `INSERT` for the whole
    # page. This was one round trip per miss, and a repository's FIRST ingest is all misses by
    # construction — 20,000 sequential statements at the design point, to write what one page had
    # already decided. Nothing about WHICH row is inserted, or what its conflict clause does, is
    # decided anywhere but here; everything below is still the statement's contract, stated where the
    # row is built.
    #
    # @return [PendingIdentity] a placeholder, because the id does not exist yet. Nothing in the loop
    #   needs the real one: {#claim} only buffers `[observation.id, identity]` and {#resight} only
    #   buffers `[identity, observation]`, and both buffers are spent after the insert has run — see
    #   {#substitute_pending}, which is the one seam that turns these back into ids.
    #
    # `upsert_all` rather than `create!` because the miss is exactly where two ingests collide. Every
    # shard of a repository's first run resolves for the first time, so two of them reaching the same
    # text and both finding nothing is the ordinary case and not a corner. `ON CONFLICT … DO UPDATE
    # … RETURNING id` makes both of them come away holding the same row: the winner inserts, the
    # loser's values land on the winner as an ordinary re-sighting — guarded exactly as the match
    # path's re-sighting is, see below — and neither raises. A `create!`-and-rescue would reach the
    # same place in two statements and a savepoint; this is one statement and needs neither.
    #
    # It is also what makes the *identical-text* case safe twice over. A test that merely moved
    # embeds to the same vector and is found by {#nearest}; if that lookup ever missed it — an
    # approximate index under-recalling, a threshold raised too far — this key would still land the
    # ingest on the row it belongs to rather than growing the table. The two mechanisms overlap on
    # purpose, and only similarity covers the case where the text is *not* byte-identical.
    #
    # `record_timestamps: false` because the row carries its own — {SpecIdentity::RESIGHTABLE} keeps
    # `created_at` out of the update list, so a row that already existed keeps when the test first
    # appeared and moves only its `updated_at`. `Time.current` is taken per row and not per page for
    # the same reason: it is the moment this test was decided to be new, which is a fact about the
    # row rather than about the statement that carries it.
    #
    # `on_duplicate:` rather than `update_only:` so the conflict branch carries
    # {SpecIdentity::SIGHTING_NOT_OLDER} — the same guard {#resight} takes as a `WHERE`, spelled as
    # a `CASE` per column because `ON CONFLICT DO UPDATE` has nowhere else to put it. The clause is
    # still generated from `RESIGHTABLE`, so this is one list and one guard reaching both paths
    # rather than a second copy of either. See that constant for why the losing side of this race is
    # not the only way an OLDER sighting arrives here.
    #
    # == The row it just created is put back into the page's map
    #
    # {#digest_index} is asked once per page, so it is a SNAPSHOT — and the `find_by` it replaced was
    # not. That one saw identities committed by EARLIER ROWS OF THE SAME PAGE; a map computed up
    # front does not. The case is two observations with byte-identical text on a FIRST run — the pair
    # `identity_resolver_spec.rb`'s "cannot separate two tests whose descriptions are identical"
    # builds — where the second row would now miss the map and fall through to an embed.
    #
    # The OUTCOME would be unchanged either way (identical text embeds to an identical vector,
    # {#nearest} matches at cosine 1.0, and failing even that, this method's conflict key lands them
    # on one row), so this line is not what makes the change correct. What it preserves is the EMBED
    # COUNT, and that is worth a line: the embed is the expensive thing this whole path exists to
    # avoid, the provider is swappable for a billed one, and "batching the lookups made a first run
    # embed more" is a regression no example here would have caught — `:208` asserts identity count,
    # not embed count. So the page's map learns what the page wrote, and the snapshot is a snapshot
    # only of what was there BEFORE the page started.
    #
    # **It has a second job now that the write is deferred, and it is the load-bearing one.** The
    # entry is what stops a second byte-identical row of the same page reaching this method at all —
    # and therefore what stops the page's buffer holding two rows with one conflict key, which is a
    # statement Postgres refuses outright rather than an extra embed. `@pending_identities`' own key
    # is the belt to that brace, so neither the map's job nor the buffer's shape is the whole of the
    # answer alone. The placeholder it carries is the {PendingIdentity}, so a hit on it takes the
    # ordinary re-sighting path with an id that is not yet an id — see {#substitute_pending} for
    # every buffer that then has to be put right, and why they are all put right in one place.
    def claim_identity(signal, embedding, observation)
      now = Time.current
      digest = SpecIdentity.digest_for(signal.text)

      unless @pending_identities.key?(digest)
        @pending_identities[digest] = {
          repository_id: @repository.id,
          text: signal.text,
          text_digest: digest,
          signal_source: signal.source.to_s,
          embedding: embedding
        }.merge(sighting(observation, now), created_at: now)
        # Pushed under the same guard as the row itself and never beside it: `@pending_identities`
        # is a map keyed by digest and this is a list, so a second claim of one digest that the two
        # brace against would leave the list holding the row twice — scored twice by
        # {#nearest_pending} for no change in the answer, and growing a page's worst case past the
        # square it is bounded at above.
        @pending_vectors << pending_vector(digest, embedding)
      end

      pending = PendingIdentity.new(digest)
      @digest_index[digest] = HeldIdentity.new(pending, signal.source.to_s)
      pending
    end

    # @return [Array<Float>, nil] this row's vector out of the page's request — nil when the page
    #   asked for it and the provider could not answer, which is the same nil {#embed} returned when
    #   the ask was per row, and costs the same {#record_resolve_failure} stamp.
    #
    # `fetch` with a block rather than `[]`, because the two absences are different: a text the page
    # embedded and FAILED on is present with a nil value and must stay a failure, while a text no
    # page fetched at all has no answer yet and gets a single embed. Reading a missing key as a
    # failure would strand the second case; reading a nil value as a miss would re-ask the provider
    # for a text it has just refused, once per row, which is the amplification the batch exists to
    # remove. That distinction is load-bearing on the healthy path and is unchanged.
    #
    # == Where the missing key actually comes from
    #
    # **{#upgrade_from_name}, mid-page**, and it is an ordinary path rather than an exotic one. That
    # method DELETES the name entry from `@digest_index` on both `:upgraded` and `:lost_race`, so a
    # name-only sibling later in the SAME page — an example sharing a `full_description` with the
    # test that was just annotated, which its comment names outright — stops matching
    # {#identical_text} and must claim its own row. Its text was never embedded, because
    # {#unheld_texts} correctly skipped it as held when the page was built, and {#lookup_texts} put
    # it in {#digest_index} but not in `@embeddings`. So the lookup lands here with no key.
    #
    # == Why the breaker has to be re-asked here
    #
    # {#embed_page} answers a tripped page with nil-VALUED keys and never `{}` so that no text OF
    # THAT PAGE reaches this block. That bounds the page's own set and nothing else: the key above
    # is one this page never asked for, so it arrives as a miss whatever the page did. Within a
    # single page the two states cannot meet — a dark provider gives the annotated row a nil and
    # {#identity_for} returns at its `embedding.nil?` guard before any upgrade — but the breaker is
    # sited at the provider ask and NOT at {#page_embeddings}, which reads {EmbeddingCacheEntry}
    # first. A later page whose vectors this deployment already owns therefore resolves normally
    # right through an outage, upgrades, evicts the name, and drops its sibling here with the pass
    # long since dark. Unguarded, that is one provider request per such row, invisible: no page-level
    # warn line covers it and {#report} still says `provider_breaker=tripped`.
    #
    # The nil is the fully-handled answer and not a new outcome — {#identity_for} stamps through
    # {#record_resolve_failure} and the row stays retryable for the whole window, byte-identical to
    # every other text this pass skipped.
    def embedding_for(text)
      @embeddings.fetch(text) { @provider_dark ? nil : embed(text) }
    end

    # @return [Array<Float>, nil] nil when the provider failed, which leaves the observation
    #   unresolved and stamped — see {#record_resolve_failure}, which is what the nil now costs.
    #
    # Rescued rather than allowed to propagate so that one unembeddable example does not abandon the
    # other 19,999 — and rescued *here*, around the provider call and nothing else, so the rescue
    # cannot accidentally swallow a failure from the database work around it. `EmbeddingGenerator`
    # promises this is the only class its callers see, whatever the provider did.
    #
    # **The ONE-TEXT path, and it is no longer the ordinary one.** A page asks for its texts
    # together ({#embed_page}) and this is what each of them falls back to: once per text when the
    # batch request failed, and once for a text no page fetched — that second arm only while the pass
    # is not dark, because {#embedding_for} answers such a text nil instead of reaching here once
    # `@provider_dark` is set. It is unchanged in what it does, and
    # it is deliberately still the thing containment is expressed in — the batch has no way to say
    # WHICH input a failed request was refused for, and this does, one text at a time.
    #
    # **This rescue is why a job-level retry policy would reach nothing.** The error is consumed
    # here, so `retry_on EmbeddingGenerator::Error` on {Ingest::IdentityResolutionJob} could never
    # fire and the job reports success having resolved zero rows. Stated at the call that does it,
    # rather than left for a future cycle to derive from an absence.
    #
    # Logged as well as stamped: the log line is what an operator watching a deploy sees, the stamp
    # is what survives to be queried and retried afterwards, and neither is the other.
    def embed(text)
      EmbeddingGenerator.call(text)
    rescue EmbeddingGenerator::Error => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not embed a spec signal: #{e.message}"
      )
      nil
    end
  end
end
