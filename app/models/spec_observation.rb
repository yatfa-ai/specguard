# frozen_string_literal: true

# One example, in one run. The grain everything the product promises about *tests* — rather than
# about suites — has to be asked at.
#
# A run's headline counters (`TestRun#total_specs_count`, `#annotated_specs_count`) are two
# integers derived from `test_run_shards`, and they stay that way: nothing here re-derives them.
# These rows answer the questions those integers cannot — which examples were slow, which failed,
# how much of the wall clock a given spec file spent — for **one run**. They are per-run facts,
# not a history: "the slowest tests in this run" is a question this table answers with a single
# indexed query; "the slowest tests in this repository" spans runs and belongs to the work that
# settles cross-run identity.
#
# == The key is run-local, and says so
#
# `example_id` is RSpec's `Example#id` (`"./spec/orders_spec.rb[1:2]"`), unique within a run and
# explicitly *not* stable across refactors — `scoped_id` is positional, so reordering examples
# changes it. Uniqueness is `(test_run_id, example_id)` and nothing wider. Deliberately absent:
# any unique index on `(repository_id, file_path, line_number)`. That coordinate identifies the
# *code*, and a table-driven loop or a shared example group puts many examples on one — the
# client measured 7 examples across 3 distinct coordinates on a small probe suite. Collapsing
# those would destroy exactly the grain this table exists to hold.
#
# == Two paths, two meanings
#
# `file_path` / `line_number` are the **definition site**: the line the annotation was read from,
# unchanged in meaning from `spec_intents`. `spec_file_path` is RSpec's `rerun_file_path` — the
# **including** file, equal to `file_path` for an ordinary example and different only for a shared
# example group. Aggregate duration by `spec_file_path`, so a shared group's time lands on the
# file that ran it rather than on a `spec/support/` helper.
class SpecObservation < ApplicationRecord
  belongs_to :test_run
  belongs_to :repository
  # Which delivery brought this row in. Null for a run no CI provider named — those runs have no
  # shard rows at all — and null again if the shard row is later deleted; the observation belongs
  # to its run first.
  belongs_to :test_run_shard, optional: true
  # Which durable test this measurement belongs to — the link that turns a pile of per-run rows into
  # one test's history. Optional, and nothing scopes that nil away, which is the point: see
  # `CreateSpecIdentities` for why the unresolved state was pushed here rather than left to live as
  # a NULL embedding on `spec_identities`, where `neighbor` would have hidden it from resolution.
  #
  # Its nil is **not** a record of WHY the example is unresolved, and used to be the only one there
  # was. Three different things wear it — the job has not reached the row yet, the row has no text to
  # embed, or an attempt to resolve it failed — and `embed_failed_at` below is what tells the third
  # from the other two. `AddEmbedFailureToSpecObservations` sets out all three.
  belongs_to :spec_identity, optional: true

  # Rows this run brought in that no {SpecIdentity} has claimed yet. The resolver's work list, and
  # by construction its own idempotency: a row drops out of this scope the moment it is resolved, so
  # a job that runs twice — two shards of one run each enqueueing one — does the work once between
  # them rather than twice each.
  #
  # Deliberately still the widest predicate, and still one column: this is "has no identity", which
  # is the only question the work list asks. Which KIND of unresolved a row is, is the three scopes
  # below, and they narrow this rather than replacing it.
  scope :unresolved, -> { where(spec_identity_id: nil) }

  # **The rows an attempt to resolve FAILED on**, and the answer to "how many examples did this run
  # reach and fail to resolve?" — a question nothing could ask while the only evidence was a NULL
  # that three states share. The migration asked it in the narrower words the column was introduced
  # for ("fail to embed"); the section below is why the scope now answers the wider one.
  #
  # A positive stamp rather than the absence of one, so this separates a failure from *both* of the
  # other two meanings with one predicate. Note what it is deliberately not paired with: there is no
  # `signalless` scope re-deriving "no intent and no name" in SQL. `#signal` states that the
  # intent-or-name precedence has exactly one owner and that a second implementation of it would
  # drift, and this scope needs none — a row that never had text to embed never reached the embed
  # call, so it never got a stamp.
  #
  # == The column is named for the failure it was introduced for, and now carries one more
  #
  # `AddEmbedFailureToSpecObservations` added it for the embedding failure, which was then the only
  # one that could be recorded. `Ingest::IdentityResolver#claim_inherited` is the second writer: a
  # row of an EARLIER run that raises anywhere on the resolve path — the ANN lookup on a dropped
  # connection, a write that failed — is stamped here too, so that one such row cannot abort the
  # sweep and leave itself findable only in Solid Queue's failed executions.
  #
  # So the honest reading of a stamped row is **"this was reached, something was tried, and it did
  # not land"**, and the column name is narrower than the fact. That is deliberate rather than
  # drift, and `#record_resolve_failure` on the resolver argues it at length: the distinction the
  # pipeline actually leans on is permanently-unresolved (no stamp, nothing to embed) against
  # temporarily-unresolved (stamped, bounded, retried), and both writers are on the same side of it.
  # A rename would move `.embed_retryable`, `.embed_abandoned`, `.embed_unattempted` and the partial
  # index under them for a word.
  #
  # It is therefore not a claim about the PROVIDER. Anything needing that distinction reads the
  # resolver's log lines; this column is the queryable, retryable fact and never the diagnosis.
  #
  # Not cleared when a later attempt succeeds. The row leaves the backlog by leaving `.unresolved`,
  # and what remains is a true statement about it: resolving this measurement failed at least once
  # before it landed.
  scope :embed_failed, -> { where.not(embed_failed_at: nil) }

  # **How long a failed embed stays retryable**, measured from the FIRST failure — the bound on
  # {Ingest::IdentityResolver}'s cross-run sweep, and the reason a permanently-unembeddable row does
  # not re-embed on every future ingest until its retention window deletes it.
  #
  # == Why a window and not an attempt cap
  #
  # An attempt cap is the obvious spelling and it does not survive this pipeline's own shape.
  # `IdentityResolver`'s class comment states it: *"Every shard of a run enqueues a job for the
  # run, so an N-shard delivery schedules N jobs over the same rows"*. Those N jobs read the same
  # work list, so one provider outage on an eight-shard run burns eight attempts on every row before
  # a single later ingest has had a chance to rescue any of them. The cap would be spent by the
  # failure itself rather than by the retrying, and a cap generous enough to survive it would be a
  # number chosen from a client's shard count — which this application never sees.
  #
  # `embed_failure_count` therefore counts attempts BY ANYTHING, not attempts by the retrier, and
  # {Ingest::IdentityResolver#retry_backlog} reads it the same way where it uses the column to ORDER
  # the sweep. That is not the same claim twice with two answers: the inflation is fatal to a
  # calibrated cap and harmless to a ranking, because concurrent sweeps bump roughly the same rows
  # together and leave the order between them where it was.
  #
  # Wall-clock is immune to that: eight concurrent jobs and one job leave the window in the same
  # place, because it is anchored to `embed_failed_at`, which is written once and never refreshed.
  # It is also the bound that matches the failure being recovered from. A provider outage is an
  # interval, not a number of tries.
  #
  # Seven days rather than a day, because the unit of retry is an INGEST and repositories differ by
  # orders of magnitude in how often they produce one: a day is several hundred chances on a busy
  # trunk and possibly zero on a repository whose CI runs weekly. Seven days is at least a few on
  # any repository active enough to be worth the retry.
  #
  # It is NOT claimed to expire before `BRANCH_RETENTION_RUNS` does — the two are in different
  # units and neither dominates. A repository at a hundred runs a day prunes sixty runs of a branch
  # back inside a day, so the row is deleted with its run long before this window closes; a
  # repository at one run a week has the window close first. Whichever comes first ends the
  # retrying, and both are rules that say so: this one gives up and leaves the row queryable as
  # `.embed_abandoned`, and the retention rule deletes the measurement it was trying to rescue,
  # after which there is nothing left to attach an identity to. Neither is a row quietly falling
  # out of a set nobody was watching.
  #
  # What bounds the COST is not this: it is `IdentityResolver::RETRY_SWEEP_LIMIT`, which caps the
  # work any one JOB inherits — per job and not per ingest, for the shard reason above, which that
  # constant states in its own terms. This bounds the LIFETIME of a hopeless row, and the two are
  # separate because they answer separate questions.
  EMBED_RETRY_WINDOW = 7.days

  # The backlog: failed rows still inside the window and still unresolved — exactly what one ingest
  # is entitled to re-attempt on behalf of the runs before it. Repository scoping is the caller's,
  # because the tenant boundary belongs to the caller that has the tenant.
  scope :embed_retryable, lambda {
    unresolved.embed_failed.where(embed_failed_at: EMBED_RETRY_WINDOW.ago..)
  }

  # The rows this rule has GIVEN UP on — failed, never resolved, and now older than the window. Its
  # own scope because a bound that cannot be queried is a bound nobody can audit: "we stopped trying"
  # and "we are still trying" must not be one figure, for the same reason the three meanings of a
  # NULL above must not be.
  scope :embed_abandoned, lambda {
    unresolved.embed_failed.where(embed_failed_at: ...EMBED_RETRY_WINDOW.ago)
  }

  # **The rows NOTHING ever tried** — the exact complement of `.embed_failed`, and the other side of
  # the discriminator `AddEmbedFailureToSpecObservations` introduced.
  #
  # It is the two meanings that migration could not separate, pooled on purpose: *not attempted yet*
  # and *nothing to embed*. Nothing here re-derives which — that would mean a second implementation
  # of the intent-or-name precedence in SQL, and `#signal` states that the precedence has exactly one
  # owner and that a copy of it would drift. `Ingest::IdentityResolver#identity_for` is that owner
  # and it is what tells them apart, one row at a time, at a cost of a row read and zero embeddings
  # for the second kind.
  #
  # That is what makes the pooling affordable rather than sloppy: a sweep does not need to know which
  # of the two a row is in order to do the right thing with it. It embeds the ones that have text and
  # returns nil for the ones that do not, which is the same answer it has always given them.
  scope :embed_unattempted, -> { where(embed_failed_at: nil) }

  # **How old an unattempted row has to be before anything else may touch it** — the floor under the
  # never-attempted sweep, and the reason that sweep is not a race with the job that is already on
  # its way to the same rows.
  #
  # == What it guards, and what it explicitly does not
  #
  # A COST guard, not a correctness one, and the distinction decides how the number is chosen. Two
  # passes over one row converge: `IdentityResolver#claim_identity` upserts onto
  # `(repository_id, text_digest)` and `SpecIdentity::SIGHTING_NOT_OLDER` refuses the older sighting
  # whichever pass arrives second — the same mechanism that already makes N concurrent jobs over one
  # run safe. So a floor set too low costs a duplicated embedding and never a duplicated identity,
  # and a floor set too high costs only latency on a rescue nobody is waiting on by then.
  #
  # Being a cost guard is also why it is a floor on `created_at` rather than a stamp written when the
  # job starts. A "resolution started" column would have to be written on the hot path for every row
  # of every run — 20,000 extra writes per ingest — to buy a guarantee this does not need.
  #
  # == Why an hour
  #
  # It has to clear, with room to spare, the whole interval between the row being COMMITTED and the
  # job reaching it, which is two terms. The resolve itself is round-trip bound and the design point
  # is 20,000 examples, which is minutes; the QUEUE DELAY in front of it is the larger and far less
  # predictable term — a deploy, a saturated worker pool, or the N jobs an N-shard delivery
  # schedules over the same rows all push the last one's start time out, and none of those is a
  # number this application can see.
  #
  # An hour is well past both and is still nothing against the window it sits inside: it removes
  # 1/168th of `EMBED_RETRY_WINDOW`, so a genuinely stranded row is rescuable for essentially the
  # whole seven days regardless. Sized against a job that is LATE rather than against one that is
  # typical, because the failure of being too low — re-embedding rows a live job is about to claim —
  # is paid on every healthy ingest, while the failure of being too high is paid once, on the rare
  # run that actually stranded, in an hour of delay before a rescue that was never going to be
  # instant.
  #
  # Deliberately not derived from `Ingest::IdentityResolver::BATCH_SIZE` or `RETRY_SWEEP_LIMIT`.
  # Those are row counts and this is wall-clock, and the thing it has to outlast is a queue rather
  # than a loop.
  EMBED_ATTEMPT_GRACE = 1.hour

  # The never-attempted backlog: unresolved, unstamped, old enough that no live job is plausibly
  # still on its way to them, and still inside the retry window. What one ingest is entitled to
  # attempt on behalf of a job that died before it got there.
  #
  # Bounded on `created_at` at BOTH ends, and it is the same column at both because it is the only
  # timestamp these rows have to offer: `.embed_retryable` anchors on `embed_failed_at` precisely
  # because a stamp exists there, and the absence of one is what defines this population. The lower
  # bound is `EMBED_RETRY_WINDOW` — the same lifetime bound, for the same reason, so that "we gave
  # up" is a single rule across both backlogs rather than two rules that could drift; the upper bound
  # is `EMBED_ATTEMPT_GRACE`.
  #
  # `updated_at` would be the wrong column and quietly so. `Ingest::ObservationRecorder` keeps
  # `created_at` out of `REMEASURABLE` on purpose, so an example redelivered under a different shard
  # id lands on the conflict branch and moves only `updated_at` — the grace on a row that has been
  # waiting since its original ingest would silently restart, on a redelivery that resolved nothing.
  # `created_at` is the column that says when the row started waiting, and it is the one read here.
  #
  # Repository scoping is the caller's, exactly as it is for `.embed_retryable`: the tenant boundary
  # belongs to the caller that has the tenant.
  scope :embed_unattempted_retryable, lambda {
    unresolved.embed_unattempted.where(created_at: EMBED_RETRY_WINDOW.ago..EMBED_ATTEMPT_GRACE.ago)
  }

  # The unattempted rows this rule has GIVEN UP on — never stamped, never resolved, and now older
  # than the window. `.embed_abandoned`'s counterpart, and here for the reason that scope gives:
  # a bound that cannot be queried is a bound nobody can audit.
  #
  # It is the one place the pooling on `.embed_unattempted` above is visible as a cost. This set is
  # two things at once — rows a dead job stranded and then outlived, and the frozen signalless tail
  # that was never going to resolve and is doing exactly what it should — so a count here is "rows
  # nothing will ever attempt again" and NOT "rows we failed". Nothing in this class can split them,
  # for the reason `.embed_unattempted` states; an operator who needs the split reads `name` and the
  # three `intent_` columns, which is `Ingest::SpecSignal`'s question and not a scope's.
  #
  # Stated rather than left to be discovered, because the alternative reading — an alarming number
  # that is mostly legacy rows behaving correctly — is exactly the kind of figure this table's
  # comments refuse to ship.
  scope :embed_unattempted_abandoned, lambda {
    unresolved.embed_unattempted.where(created_at: ...EMBED_RETRY_WINDOW.ago)
  }

  # What text represents this example, answered by the one class that decides it.
  #
  # `Ingest::SpecSignal` takes a spec hash exactly as it came off the JSON wire — string keys, an
  # `"intent"` sub-hash, a `"name"` — and this rebuilds that shape from the columns. Deliberately
  # NOT a second implementation of "intent first, name otherwise": the precedence lives in one place
  # and a copy of it here would drift, which is the failure `SpecSignal`'s own class comment is
  # about. `SpecSignal` already documents that it answers for rows read back out of storage, and
  # this is that caller.
  #
  # @return [Ingest::SpecSignal] `#present?` is false for a row carrying neither — a shape the
  #   envelope rejects today, but one that rows predating `Ingest::Payload#validate_name` have.
  def signal
    Ingest::SpecSignal.for(
      "intent" => { "entity" => intent_entity, "action" => intent_action,
                    "behavior" => intent_behavior },
      "name" => name
    )
  end

  # How many rows a ranking returns. Named because the panel's caption reports the figure back to
  # the reader, and a sentence explaining a list's length must not be able to disagree with it.
  SLOWEST_LIMIT = 10

  # How many spec FILES a by-file rollup returns. Its own constant rather than a reuse of
  # `SLOWEST_LIMIT`: the two rank different populations — one run has far fewer files than
  # examples — so a suite that wants twenty files ranked has no reason to want twenty examples
  # ranked, and one number standing for both would make that a single edit nobody meant to make.
  HEAVIEST_FILES_LIMIT = 10

  # How many spec DIRECTORIES a by-directory rollup returns. Its own constant for the reason
  # `HEAVIEST_FILES_LIMIT` gives one grain down and by the same rule: a rollup at a different grain
  # ranks a different population. One run has fewer directories than files and far fewer than
  # examples, so a suite that wants twenty files ranked has no reason to want twenty areas ranked,
  # and one number standing for both would make that a single edit nobody meant to make.
  HEAVIEST_DIRECTORIES_LIMIT = 10

  # How many spec DIRECTORIES a by-directory COMPARISON returns. Its own constant, by the same rule
  # the three above it obey and for a difference that is bigger here than any of theirs: those rank
  # ONE run's areas by what they cost, this ranks the areas of TWO runs by how far their example
  # counts MOVED. The population is the union of two runs' directories rather than one run's, and
  # the quantity ranked is a signed change rather than a total — so a suite that wants ten areas by
  # wall clock has no reason to want ten areas by movement, and one number standing for both would
  # make that a single edit nobody meant to make.
  MOVED_DIRECTORIES_LIMIT = 10

  # How many spec DIRECTORIES a by-directory RUNTIME comparison returns. Its own constant, and the
  # closest call of the five — the population it ranks is the same one `MOVED_DIRECTORIES_LIMIT`
  # ranks, the union of two runs' areas, which is exactly why sharing that constant would look
  # harmless and would not be.
  #
  # The two rank that population by INDEPENDENT quantities. Splitting one slow spec into four fast
  # ones is `+3` examples and *less* time; adding a `sleep` to a shared `before` is `0` examples and
  # minutes. So the ten areas whose example count moved most and the ten whose wall clock moved most
  # are two different lists over the same areas, and a suite that wants ten of one has no reason to
  # want ten of the other. One number standing for both would make that a single edit nobody meant
  # to make — the rule the four constants above obey, at the one grain where the coincidence of
  # populations makes it tempting to break.
  RETIMED_DIRECTORIES_LIMIT = 10

  # How many EXAMPLES a single spec file's drill-down returns. Its own constant, by the rule the
  # five above it obey and for a difference that is the reverse of theirs: those cap RANKINGS —
  # lists whose whole purpose is to show the head of a population and stop — and this caps a
  # LISTING, the rows of one file a reader has already picked out of such a ranking. A reader who
  # opened a file to get past a top ten is not served by another top ten, and one file's examples
  # are a far smaller population than the run's, so this sits well above `SLOWEST_LIMIT` and is not
  # it under another name. Named because the panel's caption reports the figure back to the reader,
  # and a sentence explaining a list's length must not be able to disagree with it.
  FILE_EXAMPLES_LIMIT = 50

  # How many spec FILES a single directory's drill-down returns. Its own constant, and it caps the
  # same KIND of thing `FILE_EXAMPLES_LIMIT` caps — a LISTING of one already-picked row's contents,
  # not a ranking of a whole run — which is exactly why sharing that constant would look harmless
  # and would not be.
  #
  # The populations differ by an order of magnitude in the same direction every time. One spec file
  # holding three hundred examples is an ordinary file; one directory holding three hundred spec
  # files is not a directory anybody keeps. So the number that stops a file's example list from
  # running off the page is not the number that stops an area's file list from doing it, and one
  # constant standing for both would make that a single edit nobody meant to make — the rule the six
  # `_LIMIT`s above obey, at the one grain where the similarity of the two lists makes it tempting
  # to break.
  #
  # Named, like its siblings, because the panel's caption reports the figure back to the reader and
  # a sentence explaining a list's length must not be able to disagree with it.
  SPEC_DIRECTORY_FILES_LIMIT = 25

  # How many spec FILES one area's cross-run growth drill-in returns. Its own constant, by the rule
  # the seven above it obey, and it would be the easiest of them all to mistake for a rename of
  # `SPEC_DIRECTORY_FILES_LIMIT` directly above: the same grain, the same area, a list of that
  # area's files either way.
  #
  # The population is not the same population. That constant caps ONE RUN's files in an area; this
  # caps the UNION of two runs' — every file EITHER run recorded there — and the difference is not a
  # rounding error, because the movement this panel exists to make readable is precisely the
  # movement that inflates it. A file that was renamed within the area occupies TWO rows here, its
  # old path at `n → 0` and its new one at `0 → n`, where in a single run's listing it is one row
  # both before and after. An area reorganised wholesale therefore presents twice the file count
  # either run alone would show, on exactly the page a reader opened to see that reorganisation.
  #
  # So it sits ABOVE its neighbour rather than equal to it, and it is deliberately not equal: two
  # lists whose lengths coincide by assignment are one edit away from being one list, and the edit
  # that wants a longer union has no reason to want a longer single-run listing.
  #
  # Named, like its siblings, because the panel's caption reports the figure back to the reader and
  # a sentence explaining a list's length must not be able to disagree with it.
  SPEC_DIRECTORY_FILE_GROWTH_LIMIT = 30

  # How many spec FILES a single directory's RUNTIME drill-down returns — the constant above's
  # sibling, and the same call `RETIMED_DIRECTORIES_LIMIT` is one grain up.
  #
  # Its own constant, and here the coincidence is total rather than merely tempting: this ranks the
  # IDENTICAL population the constant above ranks — the union of two runs' files in one area — so
  # the argument that separates them cannot be about the population at all. It is the one
  # `RETIMED_DIRECTORIES_LIMIT` makes: the two rank that population by INDEPENDENT quantities.
  # Splitting one slow spec file into four fast ones is `+3` examples and *less* time; adding a
  # `sleep` to a shared `before` is `0` examples and minutes. The thirty files whose example count
  # moved most and the thirty whose summed time moved most are two different lists over the same
  # files, and an area that wants thirty of one has no reason to want thirty of the other.
  #
  # So one number standing for both would make that a single edit nobody meant to make — the rule
  # the constants above obey, at the one grain where BOTH the population and the number coincide and
  # sharing would therefore look not merely harmless but obvious.
  #
  # Thirty rather than the ten of the RANKINGS at the top of this list, on the reason its sibling
  # gives: the union of two runs' files inflates precisely where the movement is, because a file
  # renamed within the area occupies TWO rows — its old path at `n → 0` and its new one at `0 → n`.
  # Named, like all of them, because the panel's caption reports the figure back to the reader and a
  # sentence explaining a list's length must not be able to disagree with it.
  SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT = 30

  # How many repeated-DESCRIPTION groups the redundancy ranking returns. Its own constant, by the
  # rule the seven above it obey, and the population it ranks is unlike any of theirs: not files,
  # not areas, not examples, but the DESCRIPTIONS that more than one example of one run recorded.
  # That population is a small and lumpy fraction of a suite — one built without table-driven loops
  # or shared example groups has none at all, and one built around them can have hundreds — so it
  # tracks neither the file count nor the example count the `_LIMIT`s above are sized against, and a
  # suite that wants twenty-five files listed under an area has no reason to want twenty-five
  # repeated descriptions ranked.
  #
  # Ten rather than the twenty-five of the two LISTINGS above, because this is a RANKING: it shows
  # the head of a population ordered by what that population COSTS and stops, exactly as the four
  # rankings at the top of this list do, and it is read at the same glance they are. Named, like all
  # of them, because the panel's caption reports the figure back to the reader and a sentence
  # explaining a list's length must not be able to disagree with it.
  REPEATED_DESCRIPTIONS_LIMIT = 10

  # How many EXAMPLES a single repeated description's drill-down returns. Its own constant, by the
  # rule the eight above it obey, and it caps the same KIND of thing `FILE_EXAMPLES_LIMIT` and
  # `SPEC_DIRECTORY_FILES_LIMIT` cap — a LISTING of one already-picked row's contents, not a ranking
  # of a whole run — which is exactly why sharing either would look harmless and would not be.
  #
  # The population is smaller than a file's by construction and in a way neither of those is. A file
  # holds however many examples somebody wrote in it, with no upper bound in the shape of the thing;
  # a repeated description holds the examples of ONE run that say the same sentence, and the shapes
  # that produce one — a table-driven loop over its cases, a shared example group included by a
  # handful of files — are sized by what a person wrote out, not by how big the suite got. A group
  # of three hundred is a generated matrix rather than anything a reader is going to read.
  #
  # Twenty-five rather than the fifty of `FILE_EXAMPLES_LIMIT`, for that reason and for what the
  # reader is DOING here: they are deciding whether a repetition is a loop, a shared group or the
  # same test written three times, and that decision is made from the first rows — file, line and
  # outcome — not from exhausting the list. Named, like all of them, because the panel's caption
  # reports the figure back to the reader and a sentence explaining a list's length must not be able
  # to disagree with it.
  REPEATED_DESCRIPTION_EXAMPLES_LIMIT = 25

  # What the drill-down's caption has to say ABOUT the rows under it, counted in the SAME read that
  # returns them — `COUNT(*) OVER ()` and `COUNT(duration_seconds) OVER ()`, which count non-nulls.
  #
  # Windows are evaluated after the WHERE and before the LIMIT, so both figures cover the whole
  # FILE however few rows come back: the cap is disclosed against the file's real population rather
  # than against itself, and the timing coverage is the file's rather than the listed head's.
  #
  # Riding on the listed rows rather than taken as a second aggregate, and that is available here
  # in a way it was not for `SlowestExamples`. That panel's ranking EXCLUDES untimed rows in the
  # WHERE clause, so no window over it could ever have counted them and its coverage had to be a
  # second read. This list excludes nothing — the file's untimed examples ARE part of what it shows
  # — so the population the caption describes is exactly the population the window sees, and one
  # round trip gives a caption that cannot come to describe a different row set from the one below
  # it. It also costs nothing: the ORDER BY is on `duration_seconds`, which no index here leads on,
  # so every one of the file's rows is read before the LIMIT can be applied whether these two
  # counters ride along or not.
  FILE_POPULATION_COUNTS = "COUNT(*) OVER () AS file_recorded_count, " \
                           "COUNT(duration_seconds) OVER () AS file_timed_count"

  # The same two figures for the repeated-description drill-down, counted the same way and in the
  # same read, and its OWN constant rather than a reuse of the pair above.
  #
  # Not a style preference: the aliases are read back as record ATTRIBUTES by name, so sharing the
  # constant would have `RepeatedDescriptionExamples` reading `file_recorded_count` off a row that
  # was never narrowed to a file. On a description spanning two files that name is not merely
  # ill-fitting, it is false — the window counts the DESCRIPTION'S rows, which is the population
  # this panel's caption describes and precisely not the file's. A caption is a claim about the
  # list; an attribute name is a claim about what was counted, and the two must not disagree.
  #
  # Windows are evaluated after the WHERE and before the LIMIT, so both figures cover the whole
  # DESCRIPTION however few rows come back: the cap is disclosed against the group's real population
  # rather than against itself, and the timing coverage is the group's rather than the listed head's.
  # Riding on the listed rows rather than taken as a second aggregate, for the reason
  # `FILE_POPULATION_COUNTS` gives — this list excludes nothing, so the population the caption
  # describes is exactly the population the window sees.
  DESCRIPTION_POPULATION_COUNTS = "COUNT(*) OVER () AS description_recorded_count, " \
                                  "COUNT(duration_seconds) OVER () AS description_timed_count"

  # **The retention rule.** How many runs OF ONE BRANCH keep their rows; everything older than the
  # Nth most recent run on that branch is deleted by {Ingest::ObservationPruner} after the ingest
  # that made it the N+1th. Until this constant existed, history here was retained by *omission* —
  # nothing ever deleted a row for age, so the table grew by one row per example per run forever,
  # and on the 46,000-run repository `Repository::BRANCH_HISTORY_LIMIT` was measured against, at
  # the 20,000-example design point, that is ~920M rows serving reads that reach thirty runs back.
  #
  # == The floor, and why this is not a reuse of `Repository::TRAJECTORY_LIMIT`
  #
  # The floor is `Repository::TRAJECTORY_LIMIT`, because that is the DEEPEST READER: SPGD-282's
  # branch-anchored flakiness window is `TRAJECTORY_LIMIT` runs of one branch, at the same 20,000
  # example design point, and a retention rule below the depth a shipping panel reads is that panel
  # rendering blanks. So this may never be lowered beneath it — `spec/services/ingest/
  # observation_pruner_spec.rb` pins that as an assertion rather than leaving it to a comment.
  #
  # But equal to it is wrong too, and quietly: retention of exactly 30 would delete the 30th run's
  # rows the instant a 31st landed, emptying the last point of a 30-deep window *underneath a
  # reader*. A window that is exactly full is the normal state of a busy branch, not an edge case.
  # So the retention is a MULTIPLE of the floor and not the floor — twice it, which leaves a
  # whole window of slack between the deepest read and the first deletion.
  #
  # And it is its own constant rather than a reference at every call site, by the rule the six
  # `_LIMIT`s above already obey: `TRAJECTORY_LIMIT` bounds how far a CHART is DRAWN, this bounds
  # how far the DATA is KEPT. They move for different reasons — a panel showing fifty points is a
  # display decision, keeping fifty runs of 20,000 rows per branch is a storage one — and one
  # number standing for both would make that a single edit nobody meant to make.
  #
  # Per branch and never per repository: recency across a repository is interleaved (see
  # `Api::V1::RepositoriesController#serialized_branches` — on a repository whose CI reports on
  # every PR, the ten most recent runs are routinely all `feature/*`), so a repository-wide bound
  # would evict `main`'s history first, and `main` is what every cross-run read is anchored to.
  BRANCH_RETENTION_RUNS = 2 * Repository::TRAJECTORY_LIMIT

  # The code area a row belongs to: the IMMEDIATE PARENT directory of the including file.
  #
  # Off `spec_file_path` and never `file_path`, for the reason `#file_durations_in` states and the
  # class comment above states first — a shared example group's time has to land on the area that
  # RAN it, not on the `spec/support/` area that defines it.
  #
  # `substring(... from '^(.*)/[^/]*$')` rather than a `regexp_replace` of the trailing segment,
  # because the two differ on the row that has no directory at all. `.*` is greedy, so the capture
  # ends at the LAST separator and the parent is immediate rather than the root. A path carrying no
  # separator — a spec file sitting at the repository root — matches nothing and comes back SQL
  # NULL, which as a GROUP BY key would be an unnamed area on the panel; `COALESCE` names it `.`,
  # which is what `Pathname#dirname` calls that directory and what the reader will recognise.
  # Coalescing rather than filtering, because dropping those rows would silently understate the
  # run's wall clock at the one grain that is supposed to account for all of it.
  #
  # One constant, referenced by the GROUP BY, the ORDER BY tiebreak and the projection alike: three
  # hand-copies of one expression is three definitions of what an area IS, and Postgres would
  # happily group by one and select another.
  DIRECTORY_EXPRESSION = "COALESCE(substring(spec_file_path from '^(.*)/[^/]*$'), '.')"

  # Rows that carry a measurement. **The exclusion is in SQL, and it is load-bearing.**
  #
  # `duration_seconds` is nullable by design: `Ingest::ObservationRecorder#attributes` writes
  # `result&.run_time`, so an example that never ran records a faithful nil rather than a zero. And
  # `duration_seconds: :desc` is **NULLS FIRST** in Postgres — so a naive ordering heads a list
  # captioned "slowest" with the examples that did not run at all.
  #
  # `TestRun#shard_durations` documents this hazard one grain up and ends with the rule this obeys:
  # *"either keep the gate or order `NULLS LAST` first"*. There is no example-grain equivalent of
  # `TestRun#wall_clock_decomposable?` — nothing in the schema establishes that every example
  # reported — so these rows are excluded rather than gated behind a predicate that does not exist.
  #
  # Excluded in the WHERE clause rather than rejected in Ruby afterwards, for two reasons that are
  # both about the same rows. A Ruby filter sorts the run's entire slice before discarding anything,
  # which is the cost `#slowest_in`'s index exists to avoid; and it discards *after* the `LIMIT`,
  # so it hands back fewer than the requested rows on exactly the runs the exclusion matters for.
  scope :timed, -> { where.not(duration_seconds: nil) }

  # The slowest examples of ONE run, slowest first — the question this table's composite index
  # (`index_spec_observations_on_test_run_id_and_duration_seconds`) was built for. Scoped to a
  # single `test_run_id` and capped, it is an indexed backward scan: constant in suite size, which
  # is what makes it safe at the 20,000-example design point rather than a sort over every row the
  # run wrote.
  #
  # One run, never a repository's history. `example_id` is positional and explicitly not stable
  # across refactors (see the class comment above), so a ranking that spanned runs would be
  # comparing rows that are not known to be the same test. That boundary is the model's, and this
  # method stays on the near side of it.
  #
  # `id` breaks ties, so a run whose examples tie to the millisecond has a total, stable order
  # rather than one the query planner picks afresh on each request.
  def self.slowest_in(test_run, limit: SLOWEST_LIMIT)
    where(test_run_id: test_run.id).timed.order(duration_seconds: :desc, id: :asc).limit(limit)
  end

  # Everything a surface has to say ABOUT one run's slice before it is allowed to show ten rows of
  # it, as one SELECT. Ordered, named, and kept in one constant because the names are what the
  # caller destructures and the expressions are what a plan assertion EXPLAINs — two lists that
  # drifted apart would be a caption counting a column nobody selected.
  #
  # `COUNT(duration_seconds)` and `COUNT(outcome)` count NON-NULLS. The first is exactly the
  # population `.timed` selects, so the caption cannot describe a different row set from the one
  # the ranking scanned. The second is the population that said anything at all about how its
  # example ended — and it is separate from the failure count on purpose. `outcome` is nullable and
  # `Ingest::ObservationRecorder#attributes` writes it through `presence_of`, so a run whose client
  # sends no outcomes stores a nil on every row; without this figure the only thing distinguishing
  # that run from a clean one is a zero, and "nothing to check" wearing the spelling of "everything
  # passed" is the one reading this table must not produce.
  #
  # `failed` and `pending` are counted BY NAME, and there is deliberately no third counter for
  # "passed". Nothing platform-side validates the string — `Ingest::Payload` does not, and the
  # client sends `result&.status&.to_s` — so a remainder computed as `reported - failed - pending`
  # is a population this code has not read a verdict into, and that is the honest shape for it.
  #
  # NOT `where(outcome: "failed").count`, even though `index_spec_observations_on_test_run_id_and_outcome`
  # exists and is certified for exactly that predicate. That index is built for NARROWING to the
  # failures — the "which tests failed" list a later slice will want — and using it here would mean
  # a second round trip for a figure the scan below already has the rows for. The one-read rule is
  # `SlowestExamples`': a caption fetched separately from the list it describes is a claim with no
  # structural reason to keep agreeing with it. Leave this as a FILTER aggregate.
  COVERAGE_COUNTS = {
    recorded_count: "COUNT(*)",
    timed_count: "COUNT(duration_seconds)",
    reported_outcome_count: "COUNT(outcome)",
    failed_count: "COUNT(*) FILTER (WHERE outcome = 'failed')",
    pending_count: "COUNT(*) FILTER (WHERE outcome = 'pending')"
  }.freeze

  # One run's slice, counted every way the panel above it has to state — in a single round trip.
  #
  # Deliberately NOT `TestRun#total_specs_count` for any of it. That figure is re-derived by SUM
  # over `test_run_shards` and the class comment above is explicit that nothing here re-derives it;
  # the two can legitimately disagree, since `Ingest::ObservationRecorder#record` writes a row count
  # that is *"not always `specs.size`"*. Coverage of a ranking is a fact about the rows ranked.
  #
  # Every value is `to_i`'d: a run that recorded nothing still returns a row of zeroes from an
  # aggregate, and the caller wants integers rather than a mix of those and nils.
  #
  # @return [Hash{Symbol=>Integer}] keyed by `COVERAGE_COUNTS`' names, in its order.
  def self.coverage_in(test_run)
    counts = where(test_run_id: test_run.id).pick(*COVERAGE_COUNTS.values.map { |sql| Arel.sql(sql) })

    COVERAGE_COUNTS.keys.zip(Array(counts)).to_h { |name, count| [name, count.to_i] }
  end

  # Where ONE run's wall clock went, rolled up by spec file, heaviest first — the question the
  # class comment above says this table exists to answer and which nothing in `app/` had ever
  # asked. A ranking of individual examples cannot answer it: at the 20,000-example design point
  # `SLOWEST_LIMIT` shows 0.05% of the suite ordered by *individual* cost, and a file holding 400
  # examples at 50ms each is twenty seconds of the run with every one of its rows far below the
  # head. Outliers and concentration are different questions.
  #
  # Grouped on `spec_file_path` — the INCLUDING file — so a shared example group's time lands on
  # the file that ran it rather than on a `spec/support/` helper (see "Two paths, two meanings"
  # above, and the end-to-end pin in spec/requests/api/v1/ingest_spec.rb). The key cannot be null:
  # `Ingest::ObservationRecorder#attributes` falls back to `file_path` for a producer old enough
  # not to send one, precisely so no row drops out of a by-file total.
  #
  # @return [Array<Array>] `[spec_file_path, total_seconds, recorded_count, timed_count, file_count]`
  #   per file, where `file_count` is the same figure on every row: how many files the run touched
  #   in total, before the `LIMIT`.
  #
  # == Why four columns and not one SUM
  #
  # `SUM` skips NULLs SILENTLY, and `duration_seconds` is nullable by design — an example that
  # never ran records a faithful nil. Unlike `#slowest_in`, exclusion is not available here:
  # dropping untimed rows changes each surviving group's own POPULATION, so a file with 400
  # examples of which 200 went untimed would report a total that understates by half and say
  # nothing about it. So every group carries how many of its rows reported a timing, counted in
  # the same pass: `COUNT(*)` against `COUNT(duration_seconds)`, which counts non-nulls. One
  # grouped aggregate for the whole panel — a per-file follow-up query would be a trip per row.
  #
  # == `pluck`, deliberately, and `NULLS LAST`
  #
  # Both are about the file whose examples were ALL untimed, whose SUM is SQL NULL:
  #
  # * `group(...).sum(:duration_seconds)` casts that NULL to `0.0` on the way back into Ruby, and
  #   a surface handed a zero renders "0.00s" — a run that measured nothing wearing the spelling
  #   of a measurement. `#duration_label` refuses exactly that reading one grain down. `pluck`
  #   hands the nil back intact so the caller can tell the two apart.
  # * `SUM(...) DESC` is NULLS FIRST in Postgres, so the naive ordering does not merely include
  #   that file — it names it the heaviest file in the suite. Same hazard `scope :timed` documents
  #   at the example grain, and the ordering has to answer it here because the row is not excluded.
  #
  # `spec_file_path` breaks ties, so a run whose files total equally has one stable order rather
  # than one the planner picks afresh per request.
  #
  # == Why the row count comes back on every row
  #
  # This read is `LIMIT`ed, so its own length is the TRUNCATED count and a caller holding it cannot
  # tell "the ten heaviest of three hundred files" from "all three files this run touched". That is
  # the same lie by omission the four columns above exist to refuse, one grain up: a figure that
  # does not state what it was drawn from. A second `COUNT(DISTINCT spec_file_path)` would be a
  # second round trip for one clause of one sentence — the objection `.coverage_in` answers.
  #
  # `COUNT(*) OVER ()` is evaluated AFTER `GROUP BY` and BEFORE `LIMIT`, so it counts groups, not
  # rows, and counts all of them however few are returned. It rides back on every row carrying the
  # same value; the caller reads it off whichever row it has and gets nothing for an empty run,
  # which is the correct answer there.
  def self.file_durations_in(test_run, limit: HEAVIEST_FILES_LIMIT)
    where(test_run_id: test_run.id)
      .group(:spec_file_path)
      .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("spec_file_path ASC"))
      .limit(limit)
      .pluck(Arel.sql("spec_file_path"), Arel.sql("SUM(duration_seconds)"),
             Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
             Arel.sql("COUNT(*) OVER ()"))
  end

  # ONE spec file's examples in ONE run, slowest first — the rung BELOW the rollup above, and the
  # read `index_spec_observations_on_test_run_id_and_spec_file_path` exists for. The by-file rollup
  # says `spec/models/order_spec.rb` cost six minutes across 340 examples; nothing until now could
  # say WHICH 340, at a design point where every panel on the page is a capped ten.
  #
  # == It leads with the by-file index, and must go on doing so
  #
  # `.slowest_in` is a backward scan on `index_spec_observations_on_test_run_id_and_duration_seconds`
  # and its comment calls that plan *"constant in suite size"*. Adding `spec_file_path` to THAT scan
  # would destroy exactly the property the comment claims: the scan would walk the run from its
  # slowest example downward discarding every row belonging to another file, which on a small file
  # in a 20,000-example run is most of the run to fill a page. This narrows on
  # `(test_run_id, spec_file_path)` first — an equality predicate on both columns of the composite
  # index, so the rows read are the file's and only the file's — and sorts that handful. Cost is
  # bounded by the size of the FILE, not of the suite. EXPLAIN-certified against a real planner at
  # the 20-run seed in spec/models/spec_observation_spec.rb.
  #
  # Deliberately an EQUALITY predicate and deliberately not a subtree. "Every row under
  # `spec/models/`" is a PREFIX predicate, which wants a `text_pattern_ops` index and therefore a
  # migration; this read issues none and needs none. That boundary is recorded in the same spec.
  #
  # == Untimed rows are LISTED, which is why the ordering carries `NULLS LAST`
  #
  # `scope :timed` excludes them from every RANKING because a row with nothing to compare cannot be
  # the slowest of anything. This is not a ranking of the suite; it is the file's population, and an
  # example the client never timed is part of that population — hiding it would make a file's list
  # disagree with the `recorded_count` printed above it. So the rows stay, and `duration_seconds:
  # :desc` alone would then be **NULLS FIRST** in Postgres: the examples that reported no duration
  # at the head of a list captioned "slowest first". They sort to the END instead, which is the
  # hazard `scope :timed` documents answered by the other of the two ways it names.
  #
  # `id` breaks ties, so a file whose examples tie — and a file all of whose examples went untimed,
  # where every row ties — has one stable order rather than one the planner picks afresh per
  # request.
  #
  # The projection carries `FILE_POPULATION_COUNTS`, so a caller gets the file's recorded and timed
  # counts off the same read as the rows; see that constant for why they are windows rather than a
  # second aggregate. Those two are ATTRIBUTES of the returned records rather than a separate
  # value, which makes this relation one to load and read — `SpecFileExamples` is its one caller —
  # rather than one to count or paginate further.
  def self.in_file(test_run, spec_file_path, limit: FILE_EXAMPLES_LIMIT)
    where(test_run_id: test_run.id, spec_file_path: spec_file_path)
      .select(Arel.sql("spec_observations.*, #{FILE_POPULATION_COUNTS}"))
      .order(Arel.sql("duration_seconds DESC NULLS LAST"), id: :asc)
      .limit(limit)
  end

  # ONE description's examples in ONE run — the rows behind a single line of the repeated-description
  # ranking, where `.repeated_descriptions_in` returns the group and no member of it.
  #
  # The sibling of `.in_file` above and deliberately shaped identically, because it is the same kind
  # of read one axis over: that one narrows a run to the rows of a FILE, this narrows it to the rows
  # carrying one NAME. `.repeated_descriptions_in` is an aggregate — `[name, SUM, COUNT(*), …,
  # ARRAY_AGG(DISTINCT spec_file_path)]` — out of which no member row escapes, so a reader told that
  # eight examples share a description and cost ninety seconds between them had, until this existed,
  # no way whatever to learn WHICH eight.
  #
  # == Not answerable by `.in_file`, which is the obvious substitute
  #
  # The ranking names the group's files, and those paths are a link into the `?spec_file=` panel. But
  # that panel lists EVERY example of a file, capped at `FILE_EXAMPLES_LIMIT` and ranked by duration:
  # a reader following a two-file group through it gets two lists of up to fifty unrelated rows, and
  # the group's own members need not be among the fifty either list shows. The narrowing this panel
  # needs is by description, and it exists nowhere else.
  #
  # == An EQUALITY predicate on a nullable column, and why no nil ever reaches it
  #
  # `name` is nullable and `Ingest::ObservationRecorder#attributes` writes it through `presence_of`.
  # `.repeated_descriptions_in` excludes null names in SQL, so a group only reaches the ranking if it
  # HAS a name and the drill-down is never legitimately handed a nil; `RequestedRepeatedDescriptionParam`
  # is what keeps a blank ask from arriving as one anyway. Nothing here re-checks it — a nil would
  # answer no rows, which is the same honest empty state a description this run did not record gets.
  #
  # == Untimed rows are LISTED, which is why the ordering carries `NULLS LAST`
  #
  # Verbatim the argument `.in_file` makes: `scope :timed` excludes untimed rows from every RANKING
  # because a row with nothing to compare cannot be the slowest of anything, and this is not a
  # ranking of the suite but the GROUP's population. An example the client never timed is part of
  # what shares this description — hiding it would make the list disagree with the `recorded_count`
  # printed above it, and on this panel it would do worse than that: an untimed member is often
  # exactly the row a reader has come to find, because a test that never ran is one way three
  # examples come to say the same thing. So the rows stay, and `duration_seconds: :desc` alone would
  # then be **NULLS FIRST** in Postgres — the examples that reported no duration at the head of a
  # list captioned "slowest first". They sort to the END instead.
  #
  # `id` breaks ties, so a group whose examples tie — and a group none of whose examples were timed,
  # where every row ties — has one stable order rather than one the planner picks afresh per request.
  #
  # == Query cost
  #
  # Rides `index_spec_observations_on_test_run_id`. There is no `(test_run_id, name)` index and this
  # read does not want one: `index_spec_observations_on_repository_id_and_name` exists and is NOT the
  # path here, for the reason `.repeated_descriptions_in` states at this exact grain — it leads on
  # `repository_id`, which serves a WINDOW of runs, and a single-run narrow does not begin with it.
  # One query, bounded by the size of ONE RUN rather than of the suite, and issued only when a
  # description was asked for. EXPLAIN-certified at the 20-run seed in
  # spec/models/spec_observation_spec.rb rather than argued for here.
  #
  # The projection carries `DESCRIPTION_POPULATION_COUNTS`, so a caller gets the group's recorded and
  # timed counts off the same read as the rows. Those two are ATTRIBUTES of the returned records
  # rather than a separate value, which makes this relation one to load and read —
  # `RepeatedDescriptionExamples` is its one caller — rather than one to count or paginate further.
  def self.with_description(test_run, name, limit: REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
    where(test_run_id: test_run.id, name: name)
      .select(Arel.sql("spec_observations.*, #{DESCRIPTION_POPULATION_COUNTS}"))
      .order(Arel.sql("duration_seconds DESC NULLS LAST"), id: :asc)
      .limit(limit)
  end

  # How many distinct descriptions one narrowing may hand the composition step below.
  #
  # A catastrophe valve, not a display limit. The candidate step asks for the descriptions that
  # failed ANYWHERE in the window, and on a suite that went entirely red — a bad merge, a missing
  # fixture, a service that would not boot — that is every test in it. At the roadmap's 20,000
  # example design point an uncapped candidate list is a 20,000-element `IN` clause handed to the
  # composition query, which is the O(suite) work the two-step shape exists to refuse. So the list
  # stops here, and `UnstableTests#truncated?` carries the fact that it stopped: a cap that does
  # not disclose itself turns "we looked at everything" and "we looked at the first two hundred"
  # into the same panel.
  UNSTABLE_CANDIDATE_LIMIT = 200

  # Which runs of a window recorded example rows at all, and which of them said how any of those
  # examples ended — the two facts a cross-run outcome comparison has to establish BEFORE it is
  # allowed to compare anything.
  #
  # `outcome` is nullable and `Ingest::ObservationRecorder#attributes` writes it through
  # `presence_of`, so a producer that sends no outcomes stores a nil on every row of every run.
  # Such a window yields no failures, therefore no candidates, therefore an empty list — and an
  # empty list rendered as "nothing is unstable" is *Vacuous Green* exactly: "nobody told us"
  # wearing the spelling of "everything is fine". `reported_outcome_count` answers that hazard one
  # grain down for a single run (see `COVERAGE_COUNTS`); this is the same question asked of a
  # window, and its answer is counted in RUNS because the comparison it gates needs two of them.
  #
  # == Why this is an EXISTS per run and not one aggregate over the window
  #
  # `COUNT(DISTINCT test_run_id) FILTER (WHERE outcome IS NOT NULL)` is the obvious spelling and it
  # reads every row in the window to produce two integers — 600,000 of them at thirty runs of a
  # 20,000-example suite, for a question whose answer is decided by the FIRST matching row of each
  # run. The lateral asks the index that question once per run instead: at most `2 × window` index
  # probes, none of which touches a row past the one that answers it, and the cost follows the
  # window's length rather than the suite's size. `index_spec_observations_on_test_run_id_and_outcome`
  # answers the second probe without a heap visit at all.
  WINDOW_OUTCOME_REPORTING_SQL = <<~SQL.squish.freeze
    SELECT COUNT(*) FILTER (WHERE probe.has_rows) AS runs_with_rows,
           COUNT(*) FILTER (WHERE probe.reported_outcome) AS runs_reporting_outcomes
    FROM unnest(ARRAY[:run_ids]::bigint[]) AS window_run(id)
    CROSS JOIN LATERAL (
      SELECT EXISTS (SELECT 1 FROM spec_observations o
                     WHERE o.test_run_id = window_run.id) AS has_rows,
             EXISTS (SELECT 1 FROM spec_observations o
                     WHERE o.test_run_id = window_run.id AND o.outcome IS NOT NULL) AS reported_outcome
    ) probe
  SQL

  private_constant :WINDOW_OUTCOME_REPORTING_SQL

  # @return [Hash{Symbol=>Integer}] `runs_with_rows` and `runs_reporting_outcomes`, both counted in
  #   runs of the window handed in, never in rows.
  def self.window_outcome_reporting(run_ids)
    return { runs_with_rows: 0, runs_reporting_outcomes: 0 } if run_ids.empty?

    row = connection.select_one(sanitize_sql_array([WINDOW_OUTCOME_REPORTING_SQL, { run_ids: run_ids }]))

    { runs_with_rows: row["runs_with_rows"].to_i, runs_reporting_outcomes: row["runs_reporting_outcomes"].to_i }
  end

  # Step one of two: the descriptions that recorded a FAILURE somewhere in the window — the only
  # descriptions whose outcome can have changed within it, since a test that never failed here has
  # nothing to have changed from.
  #
  # This is the read `index_spec_observations_on_test_run_id_and_outcome` was built for and which
  # `COVERAGE_COUNTS` above declines to use, in as many words: *"that index is built for NARROWING
  # to the failures — the 'which tests failed' list a later slice will want"*. This is that later
  # slice, and the narrowing is what makes the whole panel affordable. Grouping the window's rows
  # by `name` directly is 600,000 rows aggregated per page load at the design point; grouping only
  # the failures is a scan of the failures.
  #
  # Nothing correct is lost. A test that reported only non-failing outcomes across the window may
  # well have varied — `pending` one run and `passed` the next — and that variance is deliberately
  # out of this panel's scope, which the panel states rather than leaves to be discovered.
  #
  # A null `name` is excluded HERE rather than after the fact, because a null cannot be matched to
  # itself across runs: two nulls are not known to be one test, and `GROUP BY name` would pool
  # every unnamed example of every run of the window into one fictional test with a fictional
  # history. How many rows that excludes is a separate question, asked by `.unnamed_row_count_in`
  # and stated on the panel — silently dropping them is the reading this must not produce.
  #
  # == The ordering, and what the cap therefore keeps
  #
  # Fewest failures first. The cap is only ever reached by a window in which more than
  # `UNSTABLE_CANDIDATE_LIMIT` distinct descriptions failed — a suite that has gone broadly red —
  # and in that window the descriptions that failed in EVERY run are precisely the ones whose
  # outcome did not change. Keeping the least-failing end of the list therefore keeps the end this
  # panel can still say something true about, and `name` breaks ties so the kept set is stable
  # between two requests rather than whatever the planner returned first.
  #
  # `COUNT(*) OVER ()` is evaluated AFTER `GROUP BY` and BEFORE `LIMIT`, so it counts candidate
  # DESCRIPTIONS and counts all of them however few are returned — the truncation-disclosure shape
  # `#file_durations_in` documents at length, riding back on every row for no second round trip.
  #
  # @return [Array<Array>] `[name, candidate_count]` per kept description, where `candidate_count`
  #   is the same figure on every row: how many descriptions failed in the window in all.
  def self.unstable_candidates_in(run_ids, limit: UNSTABLE_CANDIDATE_LIMIT)
    return [] if run_ids.empty?

    where(test_run_id: run_ids, outcome: "failed")
      .where.not(name: nil)
      .group(:name)
      .order(Arel.sql("COUNT(*) ASC"), Arel.sql("name ASC"))
      .limit(limit)
      .pluck(Arel.sql("name"), Arel.sql("COUNT(*) OVER ()"))
  end

  # Everything the panel has to say about ONE description across the window, as one grouped
  # aggregate over the candidates only — ordered, named, and kept in one constant for the reason
  # `COVERAGE_COUNTS` is: the names are what the caller destructures and the expressions are what a
  # plan assertion EXPLAINs, and two lists that drifted apart would be a row counting a column
  # nobody selected.
  #
  # `run_count` beside `recorded_count` is the load-bearing pair. The grouping key is the
  # description ALONE (see `.unstable_candidates_in`), and a description is not a key within a
  # single run: a table-driven loop, a shared example group or two genuinely identical `it` strings
  # put several examples under one description in the same run. Such a group holds a `failed` and a
  # `passed` in one run and would read, through any figure that did not distinguish them, as a test
  # that flipped between runs. `COUNT(*) > COUNT(DISTINCT test_run_id)` is that distinction, taken
  # in the same pass — see `UnstableTests::Row#shared_description?`, which is what the surface says
  # it with.
  #
  # `failed_run_count` beside `failed_count` for the same reason: "failed in 3 of the 12 runs it
  # appeared in" is a sentence about runs, and counting rows would tell a reader that a description
  # carried by four examples failed four times in one run.
  #
  # `ARRAY_AGG(DISTINCT …) FILTER (WHERE … IS NOT NULL)` for both lists, so a null never arrives as
  # a nil element inside an array the surface iterates. The outcome words are echoed verbatim and
  # never folded into a verdict, for the reason `#outcome_label` gives: nothing platform-side
  # validates that string. The file paths are what makes a MOVED test visible — per the project's
  # semantic-identity rule a test that moved is the same test and keeps its history, so a group
  # spanning two files is a disclosure and not an error, but the reader is told.
  UNSTABLE_COMPOSITION = {
    recorded_count: "COUNT(*)",
    run_count: "COUNT(DISTINCT test_run_id)",
    reported_outcome_count: "COUNT(outcome)",
    failed_count: "COUNT(*) FILTER (WHERE outcome = 'failed')",
    failed_run_count: "COUNT(DISTINCT test_run_id) FILTER (WHERE outcome = 'failed')",
    outcomes: "ARRAY_AGG(DISTINCT outcome) FILTER (WHERE outcome IS NOT NULL)",
    file_paths: "ARRAY_AGG(DISTINCT spec_file_path) FILTER (WHERE spec_file_path IS NOT NULL)"
  }.freeze

  # Step two of two: how each candidate description behaved across the whole window — over the
  # candidates only, which is what keeps this off the whole window's rows.
  #
  # Scoped by `repository_id` as well as by the window's runs, and that is not belt-and-braces: it
  # is the leading column of `index_spec_observations_on_repository_id_and_name`, the index this
  # read rides and the one `SpecObservation`'s own comments have been reserving. Without it there
  # is no index on `name` to walk and the grouping falls back to reading the runs whole.
  #
  # @return [Array<Array>] `[name, *UNSTABLE_COMPOSITION.values]` per description, in that order.
  def self.outcome_composition_in(repository_id:, run_ids:, names:)
    return [] if names.empty? || run_ids.empty?

    where(repository_id: repository_id, test_run_id: run_ids, name: names)
      .group(:name)
      .pluck(Arel.sql("name"), *UNSTABLE_COMPOSITION.values.map { |sql| Arel.sql(sql) })
  end

  # How many rows of the window carried no description at all — the figure the panel states when it
  # excludes them.
  #
  # A null `name` is not a test this read can follow across runs: two nulls in two runs are not
  # known to be one example, so they are dropped from the matching rather than pooled. Dropping
  # them silently is the failure mode — a panel that examined a tenth of the window and said
  # nothing about the other nine is a claim about a population it did not read. `Ingest::Payload`
  # refuses a spec carrying neither intent nor name, but `Ingest::SpecSignal` records that
  # pre-validator rows exist, and an annotated spec from a producer sending no name stores a null
  # here today.
  #
  # `repository_id` leads for the same reason as above: `WHERE repository_id = ? AND name IS NULL`
  # walks `index_spec_observations_on_repository_id_and_name` — a btree indexes its nulls — so the
  # count costs what the unnamed rows cost and not what the window does.
  def self.unnamed_row_count_in(repository_id:, run_ids:)
    return 0 if run_ids.empty?

    where(repository_id: repository_id, test_run_id: run_ids, name: nil).count
  end

  # How many ROWS one description's run sequence returns — the drill-in below the composition above.
  #
  # A catastrophe valve rather than a display limit, which is what makes it 200 and not 30. The
  # sequence is one row per run of a window bounded by `Repository::TRAJECTORY_LIMIT`, so the shape
  # this exists to serve — a test carried by ONE example per run — produces at most thirty rows and
  # never reaches the cap at all. What can exceed it is the shape `UnstableTests::Row#shared_description?`
  # names: a description carried by several examples in a single run, where a table-driven loop over
  # fifty cases is fifty rows per run and the window is fifteen hundred. Those rows are the honest
  # answer to what was asked and are not filtered out — the drill-in exists to SHOW that a
  # description is not a key for its run — but a listing bounded only by how many times somebody
  # looped is not bounded at all.
  #
  # Named rather than inlined, on the rule every `_LIMIT` above obeys: the block reports the figure
  # back to the client, and a number explaining a list's length must not be able to disagree with it.
  UNSTABLE_TEST_RUNS_LIMIT = 200

  # What that drill-in has to say ABOUT the rows under it, counted in the SAME read that returns
  # them — `COUNT(*) OVER ()` and `COUNT(outcome) OVER ()`, which counts non-nulls.
  #
  # Its OWN constant rather than a reuse of `DESCRIPTION_POPULATION_COUNTS`, and for that constant's
  # own reason one rung up rather than for a style preference: the aliases are read back as record
  # ATTRIBUTES by name, and these two windows count a DESCRIPTION'S ROWS ACROSS A WINDOW OF RUNS
  # where that pair counts one run's. Sharing the alias would have this object reading
  # `description_recorded_count` off a row whose population is thirty runs deep — a name that is not
  # merely ill-fitting but false, and false in the one direction that matters here, since the whole
  # point of this drill-in is that the window and the run are different populations.
  #
  # The SECOND figure is `COUNT(outcome)` and deliberately not `COUNT(duration_seconds)`, which is
  # what both sibling pairs count. The sibling drill-ins rank by time and their captions are about
  # timing coverage; this one is read for OUTCOMES, and the coverage that has to be disclosed here is
  # how many of the window's rows said how the test ended at all. A run that recorded the test and
  # reported no outcome is not a pass — `UnstableTests::Row#changed?` refuses that reading one rung
  # up by comparing against `reported_outcome_count` rather than `recorded_count` — and a truncated
  # list whose silence a client could not count would put that separation back out of reach.
  #
  # Windows are evaluated after the WHERE and before the LIMIT, so both figures cover the whole
  # WINDOW however few rows come back: the cap is disclosed against the sequence's real population
  # rather than against itself.
  UNSTABLE_TEST_RUN_POPULATION_COUNTS =
    "COUNT(*) OVER () AS unstable_test_recorded_count, " \
    "COUNT(outcome) OVER () AS unstable_test_reported_outcome_count"

  # ONE description's rows across a window of runs, IN WINDOW ORDER — the rung below
  # `.outcome_composition_in`, and the axis that read has to destroy to do its own job.
  #
  # The composition is `COUNT`s and `ARRAY_AGG(DISTINCT …)` under `GROUP BY name`: one row per
  # description for the whole window, which is exactly right for a RANKING and is why nothing here
  # changes it. What it cannot say is WHEN. "Failed in 4 of 30 runs" is the same pair of integers
  # whether those four were the last four — a regression, whose fix is to find the commit — or runs
  # 3, 11, 19 and 26 — flakiness, whose fix is somewhere else entirely. This read is the same rows
  # ungrouped, so the sequence the aggregate summed over is legible again.
  #
  # ORDERED BY THE WINDOW'S OWN ORDER, not by `created_at` and not by `id`. `array_position` over the
  # ids AS THEY WERE HANDED IN makes this sequence FOLLOW the window the caller already holds, so it
  # reads in the same direction as the `history` rows that same window produced and a reader walking
  # the two is walking them the same way. Ordering by `id` would be ordering by INGEST order, which
  # is the same series only while nothing is backfilled and no run is ingested out of order; ordering
  # by `created_at` would need a join to a table the caller has already loaded.
  #
  # SAME DIRECTION IS NOT SAME INDEX. The join key is the `test_run_id` / `commit_sha` ON THE ROW,
  # never its position: `history` holds one row per RUN and this holds one row per matching
  # OBSERVATION, and three ordinary shapes pull the two out of alignment. A run that recorded nothing
  # under this description contributes NO row — a test added mid-window, renamed, quarantined, or
  # living in a file one shard did not run — a description carried by two examples in one run
  # contributes TWO, and the cap takes rows off the old end. Reading the run off the index is
  # precisely the manoeuvre that names the WRONG culprit commit, which is the one error this drill-in
  # cannot survive.
  #
  # The window's order is newest-first (`Repository#recent_test_runs`), and that decides which end
  # the cap takes off: a truncated sequence keeps the RECENT runs and drops the old ones, which is
  # the survivable direction. "It has failed since some point before this list starts" still names a
  # regression; a list truncated the other way would answer "how is it doing lately" with the state
  # of a month ago. `id ASC` breaks ties WITHIN a run, so a description carried by several examples
  # in one run has one stable order rather than one the planner picks afresh per request.
  #
  # Scoped by `repository_id` as well as by the window's runs, for the reason `.outcome_composition_in`
  # gives verbatim: it is the leading column of `index_spec_observations_on_repository_id_and_name`,
  # and without it there is no index on `name` to walk.
  #
  # == Query cost
  #
  # One statement, and CONSTANT IN THE SIZE OF THE SUITE — it reads one description's rows over at
  # most `Repository::TRAJECTORY_LIMIT` runs, never the window's rows and never the suite's. That is
  # the property that lets it sit under a ranking of 20,000 examples at all. Issued ONLY when the
  # parameter was sent. EXPLAIN-certified in `spec/models/spec_observation_spec.rb` beside the
  # composition's own certification, on the same seed.
  #
  # The ordering INLINES the ids rather than binding them, which is what `array_position` over a
  # literal array costs and is worth naming: the SQL text then varies per window, so each distinct
  # window is its own entry in the connection's prepared-statement cache rather than a re-bind of
  # one. That cache is bounded and LRU-evicting, and this read is issued only on an explicit ask, so
  # the price is an occasional re-prepare and not growth — but it is a price, and it is the reason
  # this ordering is not reached for by the reads that run on every request.
  def self.outcome_sequence_in(repository_id:, run_ids:, name:, limit: UNSTABLE_TEST_RUNS_LIMIT)
    return none if run_ids.empty?

    where(repository_id: repository_id, test_run_id: run_ids, name: name)
      .select(Arel.sql("spec_observations.*, #{UNSTABLE_TEST_RUN_POPULATION_COUNTS}"))
      .order(Arel.sql(sanitize_sql_array(["array_position(ARRAY[?]::bigint[], test_run_id)", run_ids])),
             id: :asc)
      .limit(limit)
  end

  # Where ONE run's wall clock went, rolled up by DIRECTORY — the rung directly above the rollup
  # above, and the grain the question is usually asked in. "Which area of this suite carries the
  # time" is not answerable from a ranked list of files any more than it was from a ranked list of
  # examples: a directory holding forty files at two seconds each is eighty seconds of the run with
  # not one of its files near the head of a by-file top ten. Concentration re-concentrates one rung
  # up, and each rung has to be summed to be seen.
  #
  # Grouped on `DIRECTORY_EXPRESSION` — the immediate parent of the INCLUDING file — so a shared
  # example group's time lands on the area that ran it rather than on `spec/support`, and so the
  # areas listed partition the run rather than nesting inside one another. Depth selection and
  # drill-down trees are a different question and deliberately not this one: every row here is at
  # the same depth as its own file, so the totals are disjoint and sum to the run.
  #
  # NOT a shard. `TestRun#shard_durations` rolls a run up by CI partition and its comment is
  # explicit that "a shard is not a code area" — RSpec/Knapsack partitions are arbitrary with
  # respect to directory structure. That grain answers "which partition ran long"; this one answers
  # "which area of the codebase costs", and neither is derivable from the other.
  #
  # @return [Array<Array>] `[directory, total_seconds, recorded_count, timed_count,
  #   distinct_name_count, named_count, directory_count]` per directory, where `directory_count` is
  #   the same figure on every row: how many directories the run touched in total, before the
  #   `LIMIT`. The window function stays LAST in the tuple, and the two description figures were
  #   inserted BEFORE it rather than appended after — see the note below.
  #
  # == Every hazard the by-file read documents, at this grain
  #
  # The duration columns, `pluck` over `.sum`, and `NULLS LAST` are all here for the reasons
  # spelled out on `.file_durations_in` above — read that comment, it is not repeated. What changes
  # with the grain is only how much each one costs when it is got wrong: an area is a bigger
  # population than a file, so an all-untimed area rendered as `0.00s` is a bigger invented
  # measurement, and `SUM(...) DESC`'s NULLS FIRST would name that area the heaviest in the suite.
  #
  # == How many DISTINCT DESCRIPTIONS an area's examples carry, and the count that rides beside it
  #
  # The third figure of the area-grain reading — "this area carries 340 examples and 6 minutes of
  # wall clock for what looks like ~40 distinct behaviors". It is measured HERE, in the aggregate
  # that already produces the other two, because a caption is a claim about a list: a density
  # counted by a second read is a claim about a population this one did not group. No migration and
  # no new index. It is NOT free, and what it costs is written down below rather than waved at.
  #
  # `COUNT(DISTINCT name)` SKIPS NULLS SILENTLY and `name` is nullable, so on its own it reports an
  # area whose producer sent no descriptions as ZERO distinct behaviors against 340 examples — the
  # most extreme over-coverage reading obtainable, invented out of silence. So `COUNT(name)` rides
  # back beside it and the density is only ever stated over the NAMED rows, with the excluded ones
  # visible: the same `recorded_count` / `timed_count` fraction this method already carries for
  # timings, applied to the second nullable column. `RepeatedDescriptions` draws the same
  # distinction one grain down and `.unnamed_row_count_in` above refuses the same silence for a
  # window. What the ratio MEANS is not decided here or anywhere downstream — repetition is equally
  # the ordinary shape of a table-driven loop or a shared example group.
  #
  # POSITION IS A DECISION, not an accident: `SpecDirectoryDurations.for` reads the window count off
  # the end of the tuple, so appending after `COUNT(*) OVER ()` would have kept every caller running
  # while silently handing it a description count as a directory count. The window stays last, and
  # the caller now reads it by an explicit index rather than by `.last`.
  #
  # == What the DISTINCT aggregate COSTS: the hash strategy, and this read alone pays it
  #
  # A `DISTINCT` aggregate disqualifies hashed aggregation in Postgres, so adding `COUNT(DISTINCT
  # name)` moved this read off `HashAggregate` and onto `Sort` + `GroupAggregate`, sorting the run's
  # rows on the directory expression AND on `name` before grouping them. That is a REAL price and
  # this comment used to deny it: the access path did not change, which is a narrower claim than the
  # plan not changing, and the two were being read as the same sentence.
  #
  # Measured, not asserted — EXPLAIN (ANALYZE, BUFFERS) over one 20,000-example run, the stated
  # design point, at the default `work_mem` of 4MB:
  #
  #     before   HashAggregate           Memory:  145kB   Buffers: shared hit=753
  #     after    Sort + GroupAggregate   Memory: 2911kB   Buffers: shared hit=753
  #
  # What that buys and what it costs. The buffer counts are IDENTICAL — the sort reads no page the
  # hash did not already read, because both sit on the same index scan of the same one run, which is
  # the part "the access path is unchanged" was always about. The sort is bounded by ONE RUN's rows,
  # never by the table, and it is the run's rows this read already had to fetch. What it adds is
  # ~2.8MB of `work_mem` and a sort of 20,000 rows on two text columns, per render of this panel.
  #
  # The wall-clock difference is deliberately NOT quoted as a figure. Repeated on one box it ran
  # 53-58ms before and 57-69ms after — a real cost whose ranges OVERLAP, so any single pair of
  # numbers picked out of that would be a precision this measurement does not have, which is the
  # error this whole section exists to correct. What is stable across every repetition is the
  # strategy, the sort memory and the buffer count above; those are what the claim rests on.
  #
  # Priced as acceptable: the panel is one read on one page load, not a hot path, and tens of
  # milliseconds is well inside the budget for rendering a dashboard. The figure is worth a sort.
  #
  # Where it stops being acceptable: 2911kB sits under the default 4MB with less room than it looks
  # — at `work_mem = 1MB` the same read spills to `external merge Disk: 2040kB`. So a deployment
  # that tightens `work_mem`, or a suite materially past the design point, buys disk I/O rather than
  # CPU here. The strategy is pinned by an EXPLAIN example in spec/models/spec_observation_spec.rb
  # so that an edit which loses the in-memory sort is visible rather than silent.
  #
  # == Why this still needs no index of its own
  #
  # It groups on an EXPRESSION and narrows on a COLUMN, and only the second decides the access
  # path. `where(test_run_id:)` is served by `index_spec_observations_on_test_run_id`, and the
  # aggregation — hash before this change, sort-and-group after it — sits on top of that scan
  # either way. No index available here changes that: the aggregate has to touch the heap for
  # `duration_seconds` whatever it does, so no wider index buys a whole-run grouping anything, and
  # an index leading with `name` would not be read by a grouping keyed on the directory expression.
  # A `text_pattern_ops` index governs a prefix PREDICATE — "every row under `spec/models/`" — and
  # this read has no prefix predicate to serve. All of it is EXPLAIN-certified at the 20-run seed in
  # that spec rather than argued for here.
  def self.directory_durations_in(test_run, limit: HEAVIEST_DIRECTORIES_LIMIT)
    where(test_run_id: test_run.id)
      .group(Arel.sql(DIRECTORY_EXPRESSION))
      .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
      .limit(limit)
      .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql("SUM(duration_seconds)"),
             Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
             Arel.sql("COUNT(DISTINCT name)"), Arel.sql("COUNT(name)"),
             Arel.sql("COUNT(*) OVER ()"))
  end

  # The spec FILES of ONE code area in ONE run, heaviest first — the rung between the by-directory
  # rollup above and `.in_file` below it, and the one that was missing.
  #
  # `.directory_durations_in` names the ten areas the run spent most of its wall clock in and
  # `.in_file` lists one file's examples, but nothing joined the two: the by-file rollup is also a
  # capped ten, and the class comment on `SpecDirectoryDurations` states why that is not a way in —
  # "a directory holding forty files at two seconds each is eighty seconds of the run with not one
  # of its rows in that list". The heaviest AREA is precisely the one whose files are structurally
  # absent from a by-file top ten, so its files could be reached from nowhere. This is that read.
  #
  # == An EQUALITY narrow at one depth, and deliberately not a subtree
  #
  # The predicate is `DIRECTORY_EXPRESSION = ?` — the area a row is IN, compared for equality with
  # the area that was asked for. It is not `spec_file_path LIKE 'spec/models/%'`, and the
  # difference is the whole reason this ships without a migration. A prefix predicate is what a
  # `text_pattern_ops` index serves, and it would also gather `spec/models/orders/` into
  # `spec/models/` — re-opening the drill-down TREE that `.directory_durations_in` above says is
  # "a different question and deliberately not this one". Every row here sits at the same depth as
  # its own file, exactly as every row of the rollup does, so this listing partitions its area the
  # way that rollup partitions the run. An edit that grows a prefix `LIKE` has left what this
  # method is allowed to say.
  #
  # Through `DIRECTORY_EXPRESSION` rather than a hand-copy of it, for the reason that constant's own
  # comment gives: three hand-copies of one expression are three definitions of what an area IS, and
  # this one has to agree with the GROUP BY that produced the path being asked about — a link whose
  # target is computed one way and answered another opens an empty panel on a row that has rows.
  #
  # == Grouped by FILE, and the counts are the file's
  #
  # `SUM(duration_seconds)` per file with `NULLS LAST`, for the reason every read on this table
  # gives: `SUM` skips a missing timing silently, `DESC` alone is NULLS FIRST in Postgres, and a
  # file none of whose examples were timed would otherwise be named the heaviest in the area with a
  # total it did not measure. `COUNT(*)` and `COUNT(duration_seconds)` ride along per group, so each
  # row can state what its own total was summed over.
  #
  # == Three windows, so the caption is counted before the cap
  #
  # `COUNT(*) OVER ()` counts the area's FILES — windows run after `GROUP BY` and before `LIMIT`, so
  # it counts groups rather than rows on the page and counts all of them however few come back. The
  # same trick `FILE_POPULATION_COUNTS` uses one grain down and `.directory_durations_in` uses one
  # grain up, and for the same reason: a capped list whose own length is the only figure available
  # cannot tell three files from three hundred.
  #
  # The other two are `SUM(COUNT(...)) OVER ()` — an aggregate under a window, which is the only
  # spelling that reaches the AREA's example counts from a read grouped by file. They are what lets
  # the panel state its timing coverage over the whole area rather than over the files that fit,
  # which on a truncated area are different populations. `.directory_growth_between` uses the same
  # construct for the same reason: a total that describes the page is a claim about the page.
  #
  # == Why this needs no index of its own
  #
  # It narrows on `test_run_id` — served by `index_spec_observations_on_test_run_id` — and adds an
  # EXPRESSION predicate that no index can serve and that therefore decides nothing about the access
  # path. That is the ACCESS PATH `.file_durations_in` gets, for the reason its comment states: the
  # aggregate has to touch the heap for `duration_seconds` either way, so no wider index buys a
  # whole-run grouping anything. EXPLAIN-certified at the 20-run seed in
  # spec/models/spec_observation_spec.rb rather than argued for here.
  #
  # This comment used to go on to claim "the grouping hash-aggregates on top", and to cite
  # `.directory_durations_in` as the exemplar for that. BOTH halves were wrong and are worth
  # recording as wrong, because the second is a trap. Measured at the 20-run seed: this read gets
  # `Sort` + `GroupAggregate` (the planner estimates three groups, at which size sorting is simply
  # cheaper), while `.file_durations_in` — same table, same absence of a `DISTINCT` aggregate, 25
  # groups — gets `HashAggregate`. So for THIS read the strategy is a cost tiebreak that moves with
  # the data, and no comment here should promise either one.
  #
  # `.directory_durations_in` is not that, and that is why it is no longer cited here: its
  # `COUNT(DISTINCT name)` disqualifies hashed aggregation outright, so its sort is structural
  # rather than a tiebreak, and its own comment prices it in measured milliseconds. A read whose
  # strategy is chosen and a read whose strategy is forced are not exemplars of each other.
  #
  # @return [Array<Array>] `[spec_file_path, total_seconds, recorded_count, timed_count, file_count,
  #   directory_recorded_count, directory_timed_count]` per file, heaviest first. The last three are
  #   the same figures on every row: how many files the area holds, and how many examples it holds
  #   and timed — all counted before the `LIMIT`.
  def self.files_in_directory(test_run, directory, limit: SPEC_DIRECTORY_FILES_LIMIT)
    where(test_run_id: test_run.id)
      .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", directory]))
      .group(:spec_file_path)
      .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), spec_file_path: :asc)
      .limit(limit)
      .pluck(Arel.sql("spec_file_path"), Arel.sql("SUM(duration_seconds)"),
             Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
             Arel.sql("COUNT(*) OVER ()"),
             Arel.sql("SUM(COUNT(*)) OVER ()"),
             Arel.sql("SUM(COUNT(duration_seconds)) OVER ()"))
  end

  # The descriptions that MORE THAN ONE example of ONE run recorded, ranked by the wall clock those
  # examples cost between them — the first read in this application that groups examples by
  # description on a run that is not red.
  #
  # == Why this did not already exist
  #
  # `GROUP BY name` appears exactly twice above, and both are narrowed to failures:
  # `.unstable_candidates_in` selects `outcome: "failed"` before it groups, and
  # `.outcome_composition_in` is scoped to the names that read returned. On a GREEN suite — the
  # normal case — nothing here groups examples by description at all. So the fact that several
  # examples of one run share a description has only ever been reachable as a by-product of the
  # flakiness path, where `UnstableTests::Row#shared_description?` computes it in order to THROW
  # THOSE GROUPS AWAY: there, a description carried by two examples in one run is a matching-rule
  # false positive to be rejected. Here it is the finding.
  #
  # The population is documented on `UNSTABLE_COMPOSITION` above and is not hypothetical: *"a
  # table-driven loop, a shared example group or two genuinely identical `it` strings put several
  # examples under one description in the same run"*. Schema uniqueness is `(test_run_id,
  # example_id)` and nothing wider, so nothing prevents it.
  #
  # == Ranked by summed wall clock, and deliberately not by group size
  #
  # An eight-example group costing two seconds matters less than a three-example group costing
  # ninety, and the question this read exists to serve is redundancy WEIGHED AGAINST duration. So
  # the ordering is the one every duration rollup on this table uses, `NULLS LAST` included, for the
  # reason `.directory_durations_in` gives at length: `SUM(...) DESC` is NULLS FIRST in Postgres, so
  # a group none of whose examples were timed would otherwise be named the most expensive repetition
  # in the suite on the strength of a total nobody measured. `name` breaks ties, so a run whose
  # groups total equally has one stable order rather than one the planner picks afresh per request.
  #
  # == What it does NOT say
  #
  # Nothing here is a verdict that the group is duplicated work. A shared description is evidence of
  # repetition and is also the ordinary shape of a `where` loop over a table of cases; which of the
  # two a group is cannot be decided from these rows, so the surface presents it for review and says
  # so — the echo-don't-judge rule `#outcome_label` states for the outcome word, at this grain.
  #
  # A null `name` is excluded, because a null is not a description and pooling every unnamed example
  # of the run into one group would invent the largest repetition on the page out of rows that share
  # nothing. How many rows that excludes is a separate question, asked by `.description_presence_in`
  # below and stated on the panel; dropping them silently is the reading this must not produce.
  #
  # == Why it needs no index of its own
  #
  # Verbatim the ACCESS PATH argument at `.directory_durations_in`: it narrows on `test_run_id` —
  # served by `index_spec_observations_on_test_run_id` — and GROUPS on a column no index leads on
  # for this predicate, which decides nothing about the access path.
  # `index_spec_observations_on_repository_id_and_name` exists and is NOT the path here: it leads on
  # `repository_id`, which is what `.outcome_composition_in` rides for a WINDOW of runs, and a
  # single-run narrow does not begin with it. EXPLAIN-certified at the 20-run seed in
  # spec/models/spec_observation_spec.rb rather than argued for here.
  #
  # Not "and the grouping hash-aggregates on top", which this comment used to say and which is
  # measurably false: the `ARRAY_AGG(DISTINCT spec_file_path)` in the `pluck` below disqualifies
  # hashed aggregation, so this read sorts on `name, spec_file_path` and group-aggregates — the
  # same price, from the same cause, that `.directory_durations_in` now writes down in full.
  #
  # @return [Array<Array>] `[name, total_seconds, recorded_count, timed_count, file_paths,
  #   group_count, repeated_recorded_count, repeated_timed_count]` per description, costliest first.
  #   `total_seconds` is nil for a group none of whose examples were timed. The last three are the
  #   same figures on every row — how many repeated descriptions the run holds, and how many
  #   examples they cover and timed between them — all counted before the `LIMIT`.
  #
  # `COUNT(*) OVER ()` is evaluated after `GROUP BY` and its `HAVING` and before the `LIMIT`, so it
  # counts repeated DESCRIPTIONS and counts all of them however few come back — the truncation
  # disclosure `.file_durations_in` documents. The two `SUM(COUNT(...)) OVER ()` totals are the
  # `.files_in_directory` construct and are here for the same reason: the panel's timing coverage
  # has to describe the whole repeated population rather than the head of it that fit on the page.
  def self.repeated_descriptions_in(test_run, limit: REPEATED_DESCRIPTIONS_LIMIT)
    where(test_run_id: test_run.id)
      .where.not(name: nil)
      .group(:name)
      .having(Arel.sql("COUNT(*) > 1"))
      .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("name ASC"))
      .limit(limit)
      .pluck(Arel.sql("name"), Arel.sql("SUM(duration_seconds)"),
             Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
             Arel.sql("ARRAY_AGG(DISTINCT spec_file_path) FILTER (WHERE spec_file_path IS NOT NULL)"),
             Arel.sql("COUNT(*) OVER ()"),
             Arel.sql("SUM(COUNT(*)) OVER ()"),
             Arel.sql("SUM(COUNT(duration_seconds)) OVER ()"))
  end

  # Whether ONE run's rows carry descriptions at all, and how many of them do not — the two facts a
  # description-grouped read has to establish BEFORE anything it returns can be read.
  #
  # The run-scoped counterpart of `.unnamed_row_count_in` above, which asks the same question of a
  # WINDOW and is not reusable here: that one narrows on `repository_id` and a list of runs because
  # the cross-run panel's population is a window, and handing it a one-element list would ride the
  # wrong index to answer a question about a single run.
  #
  # Two figures rather than one, and the second is the load-bearing addition. `recorded_count` of
  # zero and `unnamed_count` of zero is a run that wrote no rows at all; the repeated-description
  # read returns exactly the same empty list for it as it does for a suite whose every description
  # is unique. Rendered as "nothing is repeated here" that empty list is *Vacuous Green* — "nobody
  # told us" wearing the spelling of "there is no redundancy" — and `recorded_count` is what lets
  # the surface tell the two apart, exactly as `reported_outcome_count` does for the outcome
  # counters on `COVERAGE_COUNTS`.
  #
  # One aggregate over rows the run wrote, never `TestRun#total_specs_count`: that figure is
  # re-derived by SUM over `test_run_shards` and the class comment above is explicit that nothing
  # here re-derives it. `COUNT(*) FILTER (...)` rather than a second query, for the one-read reason
  # `.coverage_in` gives — a caption fetched separately from the list it describes is a claim with
  # no structural reason to keep agreeing with it.
  #
  # This IS a second round trip beside `.repeated_descriptions_in`, and it has to be: that read
  # excludes null names in its WHERE clause, so no window over it could ever have counted the rows
  # it dropped. `SlowestExamples` pays the same price for the same reason and `FILE_POPULATION_COUNTS`
  # records why the drill-down beside it does not have to.
  #
  # @return [Hash{Symbol=>Integer}] `recorded_count` and `unnamed_count`, both counted in rows.
  def self.description_presence_in(test_run)
    counts = where(test_run_id: test_run.id)
             .pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE name IS NULL)"))

    { recorded_count: counts[0].to_i, unnamed_count: counts[1].to_i }
  end

  # How each code AREA's example count MOVED between two runs — the first read on this table that
  # spans more than one `test_run_id`, and the reason it is allowed to is worth stating precisely.
  #
  # == It compares POPULATIONS, and matches no rows
  #
  # Every other read here is scoped to one run because `example_id` is positional and explicitly
  # not stable across refactors (see the class comment and `.slowest_in`), so a ranking spanning
  # runs would be pairing rows not known to be the same test. **This pairs none.** It counts the
  # rows in each area of run A and the rows in each area of run B and subtracts the two integers.
  # No per-example key crosses the boundary, no example is matched to another example, and nothing
  # here claims a given test is the same test. That caution is about matching ROWS and this read
  # matches none of them — which is why it does not reopen the question the caution closes. A
  # future edit that joins these runs on `example_id`, or on any other per-example key, has left
  # what this method is allowed to say.
  #
  # == What a count here is, and is not
  #
  # `COUNT(*)` over each run's own rows, never `TestRun#total_specs_count`: that column is
  # re-derived by SUM over shard reports and `Ingest::ObservationRecorder#record` returns a row
  # count *"not always `specs.size`"*, so the two can legitimately differ — and there is no
  # by-directory counter anywhere else to borrow in any case. The caller is responsible for having
  # established that a difference between the two runs is a change in the SUITE rather than in how
  # much of it has been reported; `SpecDirectoryGrowth` is where that gate lives.
  #
  # == FILTER aggregates, not a two-key grouping pivoted in Ruby
  #
  # One group per AREA with each side counted by its own `FILTER`, rather than grouping on
  # `(directory, test_run_id)` and pivoting the pairs afterwards. The two read the same rows and
  # cost the same scan; what only this shape can do is rank and cap in SQL. `ABS(...) DESC` needs
  # both sides of the subtraction on ONE row, and with them there the `COUNT(*) OVER ()` counts
  # AREAS before the `LIMIT` — the same total-before-cap the by-directory rollup above uses, for
  # the same reason: a caption reading "the 10 of 63 areas that moved most" cannot then be
  # describing a different row set from the table under it. A pivot would have to take its ranking
  # and its cap in Ruby over every group of both runs, and count its areas off a Hash built after
  # the fact.
  #
  # `FILTER` over `CASE WHEN`/`SUM` because it is the same construct the outcome counters on this
  # table already use, and the plan certification there records what it costs: new expressions over
  # a row set the surrounding `COUNT(*)` already reads add no scan of their own.
  #
  # == An absent area is not a zero, and the caller is told which
  #
  # A group exists here if and only if at least ONE of the two runs wrote a row for that area, so a
  # side reading 0 wrote nothing for it. Whether that means "new area" or "this run recorded
  # nothing at all" is not decidable from the row — so the two `SUM(...) OVER ()` totals report
  # each run's whole recorded population, before the `LIMIT` and independent of it. A caller
  # holding a zero on one of those knows the side is empty and can withhold the comparison instead
  # of rendering an entire suite as deleted.
  #
  # Ranked by ABSOLUTE movement, both directions. A suite that deleted 300 examples from one area
  # answers "which areas moved" exactly as much as one that added them, and a `DESC`-only ranking
  # on the signed change would put every deletion below every addition and off the end of the cap.
  # `DIRECTORY_EXPRESSION` breaks ties, so two areas that moved equally have a stable order rather
  # than one the planner picks afresh per request.
  #
  # == Why this needs no index of its own
  #
  # It narrows on `test_run_id` — an `IN` list of two — and groups on an EXPRESSION, and only the
  # first decides the access path. `index_spec_observations_on_test_run_id` serves it and the
  # grouping hash-aggregates on top; two runs is twice the rows, not a different shape.
  # EXPLAIN-certified at the 20-run seed in spec/models/spec_observation_spec.rb rather than argued
  # for here.
  #
  # This used to add "which is the plan `.directory_durations_in` gets one method up". It is not,
  # any more: that read acquired a `COUNT(DISTINCT name)`, which disqualifies hashed aggregation
  # outright and buys it a sort. This read has no `DISTINCT` aggregate and does still hash — the
  # two facts simply stopped being the same fact, so it is stated here on its own evidence.
  #
  # @return [Array<Array>] `[directory, previous_count, latest_count, directory_count,
  #   previous_recorded, latest_recorded]` per directory, ranked by absolute movement. The last
  #   three are the same figures on every row: how many areas the two runs touched between them,
  #   and how many rows each run recorded in total — all three counted before the `LIMIT`.
  def self.directory_growth_between(test_run, previous_test_run, limit: MOVED_DIRECTORIES_LIMIT)
    latest = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])

    where(test_run_id: [test_run.id, previous_test_run.id])
      .group(Arel.sql(DIRECTORY_EXPRESSION))
      .order(Arel.sql("ABS(#{latest} - #{previous}) DESC"), Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
      .limit(limit)
      .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql(previous), Arel.sql(latest),
             Arel.sql("COUNT(*) OVER ()"),
             Arel.sql("SUM(#{previous}) OVER ()"), Arel.sql("SUM(#{latest}) OVER ()"))
  end

  # How ONE area's individual spec FILES moved between two runs — `.directory_growth_between` above
  # at one grain down, narrowed to the area a reader picked out of it.
  #
  # == What it lets a reader do that the panel above cannot
  #
  # That panel's own caption discloses a doubt it then gives the reader no way to resolve: a test
  # that was MOVED is the same test, so a renamed or relocated directory appears there as one area
  # growing and another shrinking by the same amount, with nothing added and nothing deleted. The
  # disclosure is correct and it is unactionable — an area at `+47` and another at `−47` is the same
  # shape whether somebody moved forty-seven tests or wrote forty-seven and deleted forty-seven
  # others.
  #
  # At the FILE grain the two shapes stop looking alike. `spec/models/user_spec.rb 0 → 47` beside
  # `spec/legacy/user_spec.rb 47 → 0` reads as a relocation at a glance; `billing_spec.rb 3 → 50`
  # does not. This read asserts NEITHER of those readings — it counts rows per file per run exactly
  # as its parent counts them per area, and pairs no example with any other example, which
  # `SpecObservation`'s positional-instability rule forbids at every grain. It puts the operands in
  # front of the reader and lets them do the pairing the application is not allowed to do for them.
  #
  # == The narrow is an EQUALITY, exactly as `.files_in_directory` is
  #
  # Through `DIRECTORY_EXPRESSION` and `= ?`, never a prefix `LIKE`: `spec/models/orders` is its own
  # area here as it is its own row in the panel this drills out of, so these rows partition the area
  # the way that panel's partition the run. `.files_in_directory` carries the full argument,
  # including why a subtree would want the `text_pattern_ops` index — and therefore the migration —
  # that this read does not.
  #
  # It matters twice as much here as it does there, because the link that opens this panel is the
  # SAME `?spec_directory=` the durations drill-down answers. Two reads answering one ask through
  # two different definitions of what an area IS would open one panel with rows beside another that
  # says the area is empty, on one click. Hence the shared constant rather than a second hand-copy
  # of the expression.
  #
  # == Why the totals are the AREA's and not the run's
  #
  # The two `SUM(...) OVER ()` windows here are narrowed by the same predicate the rows are, so they
  # count what each run recorded IN THIS AREA — which is the denominator this panel's caption is
  # spent on and is deliberately not the figure the parent read returns under the same name. The
  # parent compares whole runs and its windows are whole runs'; this compares one area and its
  # windows are that area's. A caller that needs "did this run write per-example rows at all" must
  # ask the parent, and `SpecDirectoryFileGrowth` does exactly that rather than reading it off here
  # — an area only the latest run has would otherwise report the previous run as having recorded
  # nothing, which is a true statement about the area and a false one about the run.
  #
  # == Why this needs no index of its own
  #
  # The same argument `.directory_growth_between` makes, unchanged by the extra predicate: it
  # narrows on `test_run_id` — an `IN` list of two, served by
  # `index_spec_observations_on_test_run_id` — and the area predicate is an EXPRESSION that no index
  # can serve and that therefore decides nothing about the access path. It only ever removes rows
  # from a scan that was already happening. The grouping is on a plain column here rather than on an
  # expression, which is if anything the easier of the two shapes.
  #
  # @return [Array<Array>] `[spec_file_path, previous_count, latest_count, file_count,
  #   previous_recorded, latest_recorded]` per file, ranked by absolute movement with a path
  #   tiebreak. The last three are the same figures on every row: how many files the two runs
  #   touched in this area between them, and how many rows each run recorded in it — all three
  #   counted before the `LIMIT`, so a capped list cannot disagree with the sentence describing it.
  def self.file_growth_between(test_run, previous_test_run, directory,
                               limit: SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
    latest = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])

    where(test_run_id: [test_run.id, previous_test_run.id])
      .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", directory]))
      .group(:spec_file_path)
      .order(Arel.sql("ABS(#{latest} - #{previous}) DESC"), spec_file_path: :asc)
      .limit(limit)
      .pluck(Arel.sql("spec_file_path"), Arel.sql(previous), Arel.sql(latest),
             Arel.sql("COUNT(*) OVER ()"),
             Arel.sql("SUM(#{previous}) OVER ()"), Arel.sql("SUM(#{latest}) OVER ()"))
  end

  # How each code AREA's summed example DURATION moved between two runs — the same two runs and the
  # same areas as `.directory_growth_between` above, ranked by an independent quantity.
  #
  # == Why this is a sibling of that read and not a column added to it
  #
  # An area where somebody made an existing spec slow adds no examples, so its `ABS(latest_count -
  # previous_count)` is 0: it sorts last in that read and falls off its `LIMIT` entirely. The area
  # is not a row missing a column on that panel — it is not on that panel at all. And the two
  # motions are independent in both directions: splitting one slow spec into four fast ones is `+3`
  # examples and *less* time; adding a `sleep` to a shared `before` is `0` examples and minutes.
  #
  # A ranking by one quantity cannot also be a ranking by the other, which is why `SpecFileDurations`
  # and `SlowestExamples` are two objects over one run's rows for this same reason. Widening the
  # count read would silently re-rank a shipped panel; this adds a second one.
  #
  # == What is compared, and what is NOT
  #
  # `SUM(duration_seconds)` over the rows THESE TWO RUNS wrote, per area, per side. Never
  # `test_runs.duration_seconds`: that is a run's wall clock, a MAX over shard reports, and it has
  # no area grain at all. Like the count read beside it this compares POPULATIONS — it sums each
  # side's rows and subtracts two numbers — and pairs no example with any other example, so nothing
  # here asserts that a given test is the same test. A future edit that joins these runs on
  # `example_id` has left what this method is allowed to say.
  #
  # == A NULL sum is not a zero, and that decides the ranking
  #
  # `duration_seconds` is nullable by design (`Ingest::ObservationRecorder` writes `result&.run_time`),
  # so `SUM` over an area none of whose examples were timed is SQL NULL — and so is the subtraction
  # of a NULL, so the whole ordering key for such an area is NULL. `DESC` alone is NULLS FIRST,
  # which would name the area nobody MEASURED the biggest mover in the suite and put it at the head
  # of a panel about slowdowns. `NULLS LAST`, for the reason `.directory_durations_in` needs it one
  # method up. The caller renders the sums through `.humanized_duration`, the one seam that spells
  # an unmeasured total "not reported" rather than "0.00s".
  #
  # == Four counts per row, so every sum states what it was summed over
  #
  # `SUM` skips NULLs silently, so an area whose examples were half untimed reports a total covering
  # half of it — and at THIS grain that has to hold on both sides at once, because an area that
  # "got faster" between two runs may only have stopped reporting timings. So each side carries
  # both its recorded count and its TIMED count, and the two window totals of each say the same
  # thing about the runs as wholes: a run whose client sent no durations at all must read as "this
  # run reported no timings" and never as "every area lost all its time".
  #
  # Window totals over both sides, counted BEFORE the `LIMIT` (`... OVER ()` runs after `GROUP BY`
  # and before `LIMIT`), so a caption built on them cannot describe a different row set from the
  # table under it — the rule `.directory_growth_between` states above and `SpecFileDurations`
  # states first.
  #
  # == Why this needs no index of its own
  #
  # Verbatim the argument at `.directory_growth_between`: it narrows on `test_run_id` (an `IN` list
  # of two) and groups on an EXPRESSION, and only the narrowing decides the access path. The
  # `FILTER` aggregates and window totals are expressions over rows that scan already reads and add
  # no scan of their own. The one honest difference from the count read is that `SUM(duration_seconds)`
  # projects a column outside `index_spec_observations_on_test_run_id_and_spec_file_path`, so this
  # can never be an `Index Only Scan` — neither can `.directory_durations_in`, and
  # spec/models/spec_observation_spec.rb records that tradeoff for both.
  #
  # @return [Array<Array>] `[directory, previous_seconds, latest_seconds, previous_recorded,
  #   latest_recorded, previous_timed, latest_timed, directory_count, previous_recorded_total,
  #   latest_recorded_total, previous_timed_total, latest_timed_total]` per directory, ranked by
  #   absolute movement in seconds. Either `_seconds` is nil where that side timed nothing in that
  #   area. The last five are the same figures on every row, all counted before the `LIMIT`.
  def self.directory_runtime_growth_between(test_run, previous_test_run,
                                            limit: RETIMED_DIRECTORIES_LIMIT)
    latest_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                           previous_test_run.id])
    latest_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])
    latest_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                         previous_test_run.id])

    where(test_run_id: [test_run.id, previous_test_run.id])
      .group(Arel.sql(DIRECTORY_EXPRESSION))
      .order(Arel.sql("ABS(#{latest_seconds} - #{previous_seconds}) DESC NULLS LAST"),
             Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
      .limit(limit)
      .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql(previous_seconds), Arel.sql(latest_seconds),
             Arel.sql(previous_recorded), Arel.sql(latest_recorded),
             Arel.sql(previous_timed), Arel.sql(latest_timed),
             Arel.sql("COUNT(*) OVER ()"),
             Arel.sql("SUM(#{previous_recorded}) OVER ()"), Arel.sql("SUM(#{latest_recorded}) OVER ()"),
             Arel.sql("SUM(#{previous_timed}) OVER ()"), Arel.sql("SUM(#{latest_timed}) OVER ()"))
  end

  # How each spec FILE of ONE area's summed example DURATION moved between two runs — the read above
  # at one grain down, and the last of the four {area,file} × {count,runtime} comparisons this model
  # serves.
  #
  # It is exactly `.directory_runtime_growth_between`'s SELECT LIST over `.file_growth_between`'s
  # GROUPING AND NARROW, and it is written out rather than parameterised for the reason those two
  # are separate methods in the first place: the grain decides the grouping, the ordering expression
  # and the window totals' meaning all at once, and a method taking "group by this or that" would be
  # one read with a branch in it standing where two reads are.
  #
  # == What this answers that no other read can
  #
  # `.directory_runtime_growth_between` names the ten AREAS whose time moved most and then dead-ends
  # on the only question a row like `spec/models 120s → 210s` provokes — WHICH FILE DID THAT. The
  # count-grain drill-in beside it cannot answer it: `.file_growth_between` measures no durations at
  # all, and a file where somebody made an existing example slow adds zero examples, so its
  # `ABS(latest_count - previous_count)` is `0` and it sorts last there and falls off the cap. The
  # two rankings are independent in both directions at this grain exactly as they are one grain up.
  #
  # `.files_in_directory` is the other neighbour and it stops one RUN short: it carries per-file
  # `SUM(duration_seconds)` for ONE run, so it holds this run's per-file seconds and never the
  # previous run's. The subtraction exists nowhere else.
  #
  # == It compares populations; it matches no tests
  #
  # The premise every read in this family stands on, unchanged by the grain: this sums each file's
  # rows in each run and subtracts two numbers. No `example_id` crosses the run boundary and no
  # example is paired with another example — an edit that joins these runs on `example_id` in order
  # to say "this test got slower" has left what this method is allowed to say, whatever the numbers
  # come out as.
  #
  # == The narrow is an EQUALITY, and it is the SAME narrow the count drill-in takes
  #
  # Through `DIRECTORY_EXPRESSION` and `= ?`, never a prefix `LIKE` — `.file_growth_between` carries
  # that argument in full, including why the two reads must share the expression rather than
  # hand-copy it. It matters once more here than it does there, because one `?spec_directory=` now
  # opens THREE blocks: two reads answering one ask through two definitions of what an area IS would
  # list a file's growth beside a panel calling the area empty, on one click.
  #
  # == A NULL sum is not a zero, and that decides the ranking
  #
  # `.directory_runtime_growth_between`'s rule at one grain finer, and the finer grain is where it
  # bites hardest: `duration_seconds` is nullable by design, so `SUM` over a file none of whose
  # examples were timed is SQL NULL, and so is the subtraction — the whole ordering key for such a
  # file is NULL. `DESC` alone is NULLS FIRST, which would name the file nobody MEASURED the biggest
  # mover in the area and put it at the head of a list about slowdowns. Hence `NULLS LAST`, and
  # hence the caller renders both sums through `.humanized_duration` rather than formatting them.
  #
  # == Four counts per row, so every sum states what it was summed over
  #
  # Verbatim the parent read's reason, and the population it is stated over is this AREA's rather
  # than the run's. `SUM` skips NULLs silently, so a file half of whose examples were untimed
  # reports a total covering half of it — and at this grain that has to hold on both sides at once,
  # because a file that "got faster" may only have stopped reporting timings. So each side carries
  # both its recorded count and its TIMED count.
  #
  # == Why the totals are the AREA's and not the run's
  #
  # The five `... OVER ()` windows are narrowed by the same predicate the rows are, so they count
  # what each run recorded and timed IN THIS AREA. Deliberately NOT the figures the parent read
  # returns under the same names, which are whole-run totals — `.file_growth_between` states the
  # hazard in full, and it is sharper here because there are twice as many of them: a caller that
  # needs "did this run report timings AT ALL" must ask the parent, since an area only the latest
  # run timed would otherwise report the previous run as having timed nothing anywhere, which is a
  # true statement about the area and a false one about the run. `SpecDirectoryFileRuntimeGrowth`
  # asks the parent, and reads none of its nine refusals off these figures.
  #
  # Counted BEFORE the `LIMIT` (`... OVER ()` runs after `GROUP BY` and before `LIMIT`), so a
  # caption built on them cannot describe a different row set from the table under it.
  #
  # == Why this needs no index of its own
  #
  # The argument `.file_growth_between` and `.directory_runtime_growth_between` both make, and this
  # read inherits both halves: it narrows on `test_run_id` — an `IN` list of two, served by
  # `index_spec_observations_on_test_run_id` — and the area predicate is an EXPRESSION no index can
  # serve, which therefore decides nothing about the access path and only ever removes rows from a
  # scan that was already happening. The grouping is on a plain column. As with every read that sums
  # durations, `SUM(duration_seconds)` projects a column outside
  # `index_spec_observations_on_test_run_id_and_spec_file_path`, so this can never be an
  # `Index Only Scan`; spec/models/spec_observation_spec.rb records that tradeoff here as it does
  # for its two parents.
  #
  # @return [Array<Array>] `[spec_file_path, previous_seconds, latest_seconds, previous_recorded,
  #   latest_recorded, previous_timed, latest_timed, file_count, previous_recorded_total,
  #   latest_recorded_total, previous_timed_total, latest_timed_total]` per file, ranked by absolute
  #   movement in seconds with a path tiebreak. Either `_seconds` is nil where that side timed
  #   nothing in that file. The last five are the same figures on every row — this AREA's — all
  #   counted before the `LIMIT`.
  def self.file_runtime_growth_between(test_run, previous_test_run, directory,
                                       limit: SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT)
    latest_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                           previous_test_run.id])
    latest_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])
    latest_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
    previous_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                         previous_test_run.id])

    where(test_run_id: [test_run.id, previous_test_run.id])
      .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", directory]))
      .group(:spec_file_path)
      .order(Arel.sql("ABS(#{latest_seconds} - #{previous_seconds}) DESC NULLS LAST"), spec_file_path: :asc)
      .limit(limit)
      .pluck(Arel.sql("spec_file_path"), Arel.sql(previous_seconds), Arel.sql(latest_seconds),
             Arel.sql(previous_recorded), Arel.sql(latest_recorded),
             Arel.sql(previous_timed), Arel.sql(latest_timed),
             Arel.sql("COUNT(*) OVER ()"),
             Arel.sql("SUM(#{previous_recorded}) OVER ()"), Arel.sql("SUM(#{latest_recorded}) OVER ()"),
             Arel.sql("SUM(#{previous_timed}) OVER ()"), Arel.sql("SUM(#{latest_timed}) OVER ()"))
  end

  # What to call this row on a surface that lists it. `name` is what the client sent as the
  # example's full description and is the only label a reader recognises — but it is nullable
  # (`Ingest::ObservationRecorder#attributes` writes it through `presence_of`, so a producer that
  # sends nothing, or sends `""`, stores a nil), and a blank cell in a ranked list is a row the
  # reader can neither identify nor go and find.
  def label = name.presence || location_label

  # Where to go and look. `file_path` and `line_number` are ONE coordinate — the definition site,
  # per the class comment above — and they are rendered as one.
  #
  # Specifically NOT `spec_file_path` + `line_number`. `spec_file_path` is the *including* file and
  # differs from `file_path` only for a shared example group, which is exactly the case where the
  # line number describes a line in the other file: pairing them would print a coordinate whose two
  # halves come from different files and point at whatever happens to sit on that line of the
  # including one. Equal for every ordinary example, so this costs nothing on the common row and
  # stays true on the uncommon one.
  def location_label = "#{file_path}:#{line_number}"

  # This row's duration, rendered.
  #
  # Guarded on nil even though `.timed` excludes those rows from every ranking: the column is
  # nullable and this is a public method on the record, so an ungated `nil` here would format as
  # "0.00s" — "the client sent no timing" made byte-identical to "this test took no time".
  def duration_label = self.class.humanized_duration(duration_seconds)

  # A number of seconds at THIS table's grain, rendered — the one formatting seam for every
  # duration read off these rows, whether it is one example's measurement or a whole file's total.
  #
  # Per-example durations sit two orders of magnitude below the run and shard figures the rest of
  # the dashboard prints, and `TestRun.humanized_seconds` rounds to a tenth of a second: a real
  # 0.04s measurement renders "0.0s" through it. At the head of a list captioned "slowest", a
  # measurement wearing the spelling of a zero is the one reading this must not produce — so
  # sub-minute values carry two decimals, and a value the two decimals cannot separate from zero
  # says that it is below the resolution rather than printing a zero it did not measure.
  #
  # A minute and over delegates to `TestRun.humanized_seconds`, so a four-minute example reads
  # "4m 12s" — the same words this page already gives a run or a shard of that length.
  #
  # A nil says so in words. Both callers can produce one and they mean the same thing: an example
  # the client never timed, and a whole file none of whose examples were timed — in both cases
  # nothing was measured, which is not a zero and must not be spelled like one.
  def self.humanized_duration(seconds)
    return "not reported" if seconds.nil?
    return TestRun.humanized_seconds(seconds) if seconds >= 60
    return "< 0.01s" if seconds.positive? && seconds < 0.01

    format("%.2fs", seconds)
  end

  # How much of a population a figure was measured over, rendered — the one seam every single-sided
  # coverage fraction is spelled through, whatever the method spelling it happens to be called,
  # whether the population is one file's examples, one area's files, one area's NAMED rows, one
  # run's repeated descriptions, or the window a description was seen in and the runs it failed in,
  # so no two of those grains can state the same coverage in two prose inventions that agree today.
  #
  # Single-sided is the boundary, and it is worth saying where it stops rather than leaving the next
  # reader to find the edge with a grep. `SpecDirectoryRuntimeGrowth::Row#coverage_label` states two
  # populations in one string — "12 of 40 → 14 of 41" — because a comparison between two runs is only
  # readable when BOTH sides say what they were summed over, and it renders on the same page as the
  # areas panel that does come through here. That is a different sentence rather than this one said
  # twice, so it is built where it is read and is deliberately not spelled through this seam. A seam
  # that claimed it anyway would be the thing this one exists to retire: a promise kept by hand.
  #
  # The CAPTION sentences stop here too, and for a reason of their own — one worth stating as a TEST
  # rather than as a roster, because the family is larger than a list kept here would stay correct.
  # A caption pairs its fraction with a trailing noun phrase naming what was counted — "3 of 4 added
  # up", "12 of 15 runs plotted", "12 of the 40 examples reported an outcome" — and, load-bearingly,
  # each has a COMPLETE case that is not a fraction at all: "all 4 added up", "every one of the last
  # 15 runs plotted", "Every one of the 40 examples reported an outcome". That completeness rule is
  # the whole point of those labels — a label is the most prominent claim a number wears, so only
  # the complete case is allowed to say "all" — and it is a rule this seam has no way to state,
  # because it cannot see which of two operands being equal means "every" and which means a
  # coincidence. Anything answering that description is a different sentence rather than this one
  # with a noun on the end:
  # `TestRun#machine_seconds_coverage` and `TestRun#wall_clock_coverage`, `SuiteTrajectory#coverage`
  # and `SuiteTrajectory#runtime_coverage`, and several in `RepositoriesHelper` that a grep for two
  # interpolated operands never reaches — their numerator can be a literal ("0 of 4 reported") and
  # their denominator can sit behind an article ("of the 40 examples"), so the census that looks
  # complete is the one to distrust. Adjacency is not the discriminator either: several of these
  # render on the same page as the areas panel that does come through here — `#wall_clock_coverage`
  # and `#machine_seconds_coverage` print side by side out of one helper — so the question the
  # paragraph above answers arises here too, and the answer is the same.
  #
  # Always the fraction and never the bare numerator. "12" in a column of "12 of 40" reads as
  # twelve of something unstated: the denominator is the point of the column, and a fully timed
  # population has to be visibly complete rather than merely unremarked.
  #
  # Both operands are PASSED rather than read off the receiver, and that is the load-bearing part
  # of this signature. The callers do not agree on what to count — a row supplies its own window,
  # while `RepeatedDescriptions` supplies the repeated subset's totals, which are a different
  # population from the `#recorded_count` that same object exposes to decide whether an empty
  # ranking means anything. A seam that reached for those names itself would render one of these
  # captions off the wrong pair of figures, silently and in the correct format.
  def self.coverage_fraction(timed, recorded) = "#{timed} of #{recorded}"

  # What CI said happened to this example, rendered — and NOTHING this application decided.
  # SpecGuard does not run tests; it reports what a client sent, which makes this a stability
  # observation and never a verdict on whether the example is correct.
  #
  # The known names are echoed verbatim rather than reworded, so the cell says the word the reader
  # will see in their own CI log. An UNKNOWN string is echoed too: nothing platform-side validates
  # this column — `Ingest::Payload` does not, and `Ingest::ObservationRecorder#attributes` stores
  # `result&.status&.to_s` through `presence_of` — so quoting what arrived is the only reading that
  # cannot be wrong. What this must not do is fold an unrecognised value into "passed".
  #
  # Nil is the one that decides whether this column is worth having. It is the exact hazard
  # `#duration_label` above carries a guard and a paragraph for, wearing the worse colour: a blank
  # cell, or one silently reading as green, would make "the client sent no outcome" byte-identical
  # to "this test passed" — on a row that is in this list precisely because it was slow, and may
  # have been slow because it was hanging on its way to failing.
  def outcome_label = outcome.presence || "not reported"

  # Which `UI::BadgeComponent` tone that word wears, so the distinction above survives a reader who
  # is scanning the column rather than reading it.
  def outcome_tone = self.class.outcome_tone(outcome)

  # The same decision made about a bare string, for a surface holding outcome words that came back
  # from an aggregate rather than off a row — the cross-run panel lists the DISTINCT words a
  # description was seen wearing, and those arrive as text out of `ARRAY_AGG`. One seam for both,
  # so a word cannot be coloured one way in a single run's column and another way across a window.
  #
  # Only the three RSpec names the producer is known to send are given a colour. Everything else —
  # an unrecognised string AND a nil — is `:neutral`, because a tone is a claim: green over a value
  # nobody validated would be this page asserting a pass it was never told about. The two neutral
  # cases are still distinguishable from each other by their text, which is what `#outcome_label`
  # is for; what they share is that neither of them is a pass.
  def self.outcome_tone(outcome)
    case outcome
    when "failed" then :error
    when "pending" then :warning
    when "passed" then :success
    else :neutral
    end
  end
end
