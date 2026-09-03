# frozen_string_literal: true

# The deliveries this repository's CI made that the endpoint REFUSED, together with the one thing
# the connection indicator has to know about them.
#
# == Why the list and the indicator's verdict are one object
#
# The connection indicator in the repository page header and the "Rejected deliveries" panel are two
# claims about the same fact, and before this they could not disagree because only one of them
# existed. `Api::BaseController#authenticate_api_key!` stamps `api_keys.last_used_at` on the way IN,
# so a delivery that is then refused for its payload records a use — and the indicator, which reads
# exactly that column, rendered `Connected` in success tone over a pipeline whose every run was
# being thrown away. Holding the verdict beside the rows it is a verdict about is what stops the
# headline and the list under it describing different states of the same repository; `SlowestExamples`
# states the same rule for its own caption at the grain below.
#
# == What "still being refused" means, and what it deliberately does not
#
# {#refusing?} is **"the last delivery this repository is known to have completed was refused"** —
# the newest rejection is newer than the newest accepted run. That is a comparison between two
# recorded facts rather than a window in hours, and it is the rule because the failure this exists
# to catch is defined by ordering and not by age: a repository whose gzip payloads are all refused
# has its last accepted run receding into the past while refusals keep landing, which is exactly
# the arrangement this predicate reads. A repository that hit a bad payload yesterday and has
# ingested cleanly since has an accepted run on top, and reads healthy again with no window to
# expire and no threshold to pick.
#
# Two bounds on that, neither of them hidden:
#
# * **The accepted side is the newest run ROW.** A later shard delivered into a run created before
#   the rejection does not move `TestRun#created_at`, so a sharded run that is half-accepted and
#   half-refused reads as refusing. That is the reading this panel wants — a shard being refused is
#   a suite being partly thrown away — but it is a consequence worth naming rather than a claim
#   that every accepted byte is accounted for.
# * **A refusal ages out.** `IngestRejection::REPOSITORY_RETENTION_ROWS` bounds the table, so a
#   repository that was refused and then went silent forever eventually loses the row and the
#   indicator returns to `Connected`. It is reporting what it can still see. {#bounded?} discloses the OTHER
#   bound — the panel's own `limit`, which bites five times sooner — and it says so only when that
#   limit actually left a refusal off the list.
#
# It says nothing about failed AUTHENTICATION. A 401 resolves no repository and writes no row (see
# `IngestRejection`), so neither this object nor the panel may imply it can see one. The one
# exception the platform owns — a REFUSED PRESENTATION of a key it has a row for — is reported by
# `credential_health` (see `RepositoryOverview`), not here: that is a credential fact about a row
# the platform retains, and this remains a delivery fact about payloads.
class RejectedIngests
  # Reads one row PAST the bound and throws it away. That extra row is the only thing that can tell
  # {#bounded?} apart from "the list came back full", and it is what every sibling disclosure object
  # on this page spends a pre-cap population count to learn — `SpecFileExamples#truncated?`,
  # `SpecDirectoryFiles#truncated?`, `RepeatedDescriptions#truncated?` and the rest all compare a
  # figure counted BEFORE the cap against `rows.size`. Here the peek is cheaper than a count and
  # says the same thing: `IngestRejection::REPOSITORY_RETENTION_ROWS` bounds the table at five
  # pages, so the eleventh row is one indexed row off an index this query already walks, in the
  # same round trip. Still one query HERE — the retained-window summary is a SECOND read, one
  # grouped `GROUP BY`, and {#retained_window} issues it LAZILY off the peek this method has
  # already paid for: "nothing peeked" proves the window is empty, so a repository with no
  # refusals — the overwhelmingly common case — summarizes for free, and the page's absolute
  # query budget never sees the second read at all.
  #
  # @param last_accepted_run_at [Time, nil] `Repository#latest_test_run`'s `created_at`, passed in
  #   rather than looked up: the page has already loaded that run for the Overview panel, and a
  #   second read here would be a second answer to "when did CI last succeed" with no structural
  #   reason to keep agreeing with the first. `nil` means no run has ever been accepted.
  def self.for(repository, last_accepted_run_at:, limit: IngestRejection::PANEL_LIMIT)
    peeked = repository.ingest_rejections.most_recent_first.limit(limit + 1).to_a

    new(repository: repository,
        rows: peeked.first(limit),
        bounded: peeked.size > limit,
        last_accepted_run_at: last_accepted_run_at)
  end

  # The same verdict with NO rows behind it, for a caller that wants only {#refusing?}.
  #
  # `.for` above loads `PANEL_LIMIT + 1` rows per repository, which is exactly right for the panel
  # that renders them and exactly wrong for the repositories grid: that page renders N cards and
  # needs no reason text, no `user_agent` and no `bounded?` — only whether each card's pipeline is
  # being refused. Calling `.for` in a card loop would be one bounded row read per card, the N+1
  # shape that page has already been cleaned of twice.
  #
  # So the grid takes ONE grouped `MAX(occurred_at)` for the whole page
  # (`RepositoriesController#last_rejection_times`) and hands each card its two timestamps here.
  # The comparison itself stays in this class — {#refusing?} is unchanged and both constructors
  # reach it — because the class comment's rule is that the verdict lives beside the rows it is a
  # verdict about, and the failure it names (a headline and the list under it describing different
  # states of one repository) is exactly what a second copy of the ordering rule in a controller,
  # helper or view would reintroduce. There is one expression of it, and this is a second way IN.
  #
  # Both `nil` limbs come along unchanged and are the reason this is a constructor rather than a
  # bare `>` at the call site: a `nil` rejection is not refusing, and a `nil` accepted side with a
  # rejection present is the most refusing state there is. A caller spelling the comparison itself
  # would have to re-derive both, and the second one inverts.
  #
  # `rows` is `[]` and NOT the refusals — this object genuinely has none, rather than having them
  # unloaded. So {#any?} reads false and {#last_rejection_at} answers off the timestamp passed in
  # rather than off a head row it does not have. `bounded:` is false for the same reason: nothing
  # was cut from a list that was never fetched. Neither is a claim the grid makes — it renders one
  # marker and no panel — but they are the honest answers for an object built this way, not
  # placeholders that would read as facts if a future caller asked. {#retained_window} is `nil` for
  # the same reason: no repository was handed in, the grid states no population and no composition,
  # and a zeroed summary hanging off a card object would be exactly the placeholder the paragraph
  # above refuses.
  def self.verdict(last_rejection_at:, last_accepted_run_at:)
    new(rows: [],
        bounded: false,
        last_accepted_run_at: last_accepted_run_at,
        last_rejection_at: last_rejection_at)
  end

  # @param last_rejection_at [Time, nil] only for {.verdict}, which has no rows to read the head of.
  #   Left `nil` by `.for`, whose rows ARE the answer — see {#last_rejection_at}.
  # @param repository [Repository, nil] only for {.for}: {#retained_window} reads the window off
  #   the repository it was built from, and {.verdict} has none — it is a grid verdict, not a panel.
  def initialize(repository: nil, rows:, last_accepted_run_at:, bounded:, last_rejection_at: nil)
    @repository = repository
    @rows = rows
    @last_accepted_run_at = last_accepted_run_at
    @bounded = bounded
    @last_rejection_at = last_rejection_at
  end

  # The refusals, newest first, never longer than the limit this was built with. One query.
  attr_reader :rows

  def any? = rows.any?

  # The newest refusal, read off the head of the already-ordered list rather than as its own
  # aggregate — so the time the stat reports and the time at the top of the panel are the same row.
  #
  # `.for`'s objects have rows and always answer off that head, which is the reading the sentence
  # above describes and is unchanged. {.verdict}'s have none — not "none loaded", none — so they
  # answer off the timestamp they were built with. The `||` cannot conflate the two: the passed-in
  # value is `nil` on every `.for` object, and `rows` is empty on every {.verdict} one, so exactly
  # one limb can ever be non-nil and neither constructor can shadow the other's answer.
  def last_rejection_at = rows.first&.occurred_at || @last_rejection_at

  # Whether the connection indicator may still read healthy. See the class comment for the rule and for
  # both of its stated bounds.
  #
  # `nil` on the accepted side is not "no comparison" — it is a repository that has been refused and
  # has never had a run accepted at all, which is the most refusing state there is.
  def refusing?
    return false if last_rejection_at.nil?
    return true if @last_accepted_run_at.nil?

    last_rejection_at > @last_accepted_run_at
  end

  # Whether this repository has refusals the list does not show — a fact about the POPULATION, read
  # off the row `.for` fetched past the bound, not about how long `rows` happens to be.
  #
  # It used to be `rows.size >= IngestRejection::PANEL_LIMIT`, and that is the one instrument this
  # codebase has already ruled out for exactly this job. `RepeatedDescriptions` states it at
  # `:85-89`: a capped list's own length "answers 'how many rows am I looking at' and nothing else",
  # so a list that is merely FULL is indistinguishable from one that was CUT. Read forwards that
  # mistake makes a truncated list wear the shape of a complete one; read backwards — which is what
  # it did here — it made a COMPLETE list wear the shape of a truncated one, and a repository with
  # exactly `PANEL_LIMIT` lifetime refusals was told its whole history was "a recent window". That
  # is the same quiet falsehood one grain in from the stat this panel was built to correct, so it
  # does not get to live at this grain either.
  #
  # Comparing against the CONSTANT was wrong in the other direction as well, and the peek fixes both
  # at once by never mentioning it: a list built with `limit:` below `PANEL_LIMIT` over a larger
  # population used to report `false` — "complete" — over a genuinely cut list.
  def bounded? = @bounded

  # Whether any listed row is showing only PART of what the endpoint said about that one delivery.
  #
  # The bound above is on the number of deliveries; this one is on the number of reasons inside one,
  # and they are independent — a single refusal of a 20,000-example suite is one row, so a list that
  # is nowhere near its window bound can still be hiding almost everything. Both are disclosed for
  # the same reason, one level apart: the panel replaced a stat that read healthy over a pipeline it
  # could not see, and it does not get to inherit that habit at a smaller grain.
  #
  # Reads the rows already in memory — at most `IngestRejection::PANEL_LIMIT` of them, no query.
  def truncated_rows? = rows.any?(&:reasons_truncated?)

  # The retained window's population and composition — the claim `IngestRejection::
  # REPOSITORY_RETENTION_ROWS` has argued for since it was written, performed at last. See
  # {RetainedWindow} for what it reads and what it deliberately is not.
  #
  # LAZY, and the laziness is a query budget, not an optimisation taste: `.for`'s peek has already
  # established whether there is anything to summarize, so the reader issues the grouped read only
  # when there are rows to state it over. A repository with no refusals — the overwhelmingly common
  # case, and the fixture the page's absolute budget in repositories_spec.rb is counted on — answers
  # `RetainedWindow.empty` WITHOUT a query, and a refusing repository pays exactly one grouped read,
  # memoized, however many times the panel or a sibling reaches for it. Loading eagerly would tax
  # every page load with a `GROUP BY` whose result the panel throws away (the panel body renders
  # only inside its `any?` branch), and per-window-reach loading would be the N+1 shape this page
  # has been cleaned of before.
  #
  # `nil` on every {.verdict} object: no repository was handed in and the grid renders one marker
  # and no panel. `nil` is "no claim", which is the honest answer for an object that cannot know;
  # an EMPTY summary, by contrast, IS a claim — "zero refusals retained" — and `.for`'s objects
  # earn the right to state it without reading, because "nothing peeked" over a window the
  # retention rule keeps at fifty proves it.
  def retained_window
    return nil unless @repository

    @retained_window ||= rows.empty? ? RetainedWindow.empty : RetainedWindow.for(@repository)
  end

  # The retained window this panel states above its rows: everything `IngestRejection` still holds
  # for the repository, counted and split by reported client, from ONE grouped query.
  #
  # == Why it exists, and why it does not ride on the rows
  #
  # `REPOSITORY_RETENTION_ROWS` argues its own size from a named diagnosis: fifty rows are kept
  # because they "show the RANGE of `user_agent` across them, which is what turns 'we are being
  # refused' into 'the old gem is being refused'". Nothing performed that reading. The panel lists
  # `PANEL_LIMIT` rows one at a time, so forty of the fifty — 80%, by design — existed on disk and
  # were reachable from no surface, and the two questions the constant was kept to answer went to
  # the reader's eye over one page in five: WHICH client is being refused (one stale runner among
  # five, or every runner on the fleet — different people, different fix), and HOW MANY refusals
  # the window holds (a repository refused eleven times and one refused fifty times rendered
  # identical panels, because `#bounded?` is a peek's boolean and deliberately yields no count).
  #
  # A summary computed off `rows` would be a summary of the PAGE, not of the window, and would fail
  # in exactly the two ways the constant forbids: the population would read as the list's length
  # (`RepeatedDescriptions` states what a capped list's own length answers — "how many rows am I
  # looking at" and nothing else), and a client that appears only in rows eleven-to-fifty would not
  # appear at all — precisely the old-gem client the retention rule exists to surface. So this
  # reads the whole window: `repository_id` leads `index_ingest_rejections_on_repository_and_recency`,
  # so the row set is found without a migration, and the group itself walks at most
  # `REPOSITORY_RETENTION_ROWS` rows because the pruner (`Ingest::RejectionRecorder#prune`) bounds
  # the table — constant in the repository's size and age, whatever its CI frequency.
  #
  # == What it deliberately is not
  #
  # * **Not pagination.** `PANEL_LIMIT`'s comment refuses it on stated grounds — the panel is a
  #   disclosure, not a browsable archive — and a reason stated is an acceptance condition stated.
  #   This adds no page and lists no additional deliveries: it is a verdict about the window the
  #   panel already discloses, disclosure-shaped by construction.
  # * **Not a second count.** `#total` is the sum of the bucket counts, so the population and the
  #   breakdown are one `GROUP BY` and cannot disagree — the failure a second aggregate beside a
  #   list exists to invite.
  # * **Not paid by every caller.** Only a caller that READS {RejectedIngests#retained_window}
  #   triggers the grouped query — the panel's summary, once per page render, memoized. The
  #   repositories grid asks {.verdict} per card and must not pay a grouped read per card, and the
  #   JSON API publishes `retention_rows` and never asks for a composition, so neither does.
  class RetainedWindow
    # One grouped read. `group(:user_agent).count` keys the hash on the STORED value — an
    # ellipsis-truncated string where `MAX_USER_AGENT_LENGTH` bit, `nil` where the client sent no
    # header — because the truncating writer's ellipsis keeps a shortened agent visibly shortened,
    # and a bucket keyed on the stored string cannot pass itself off as the version the client
    # claimed. A repository with no refusals yields `{}`; the panel renders this only when the
    # rows above prove otherwise.
    def self.for(repository)
      new(repository.ingest_rejections.group(:user_agent).count)
    end

    # The zero-refusal window, for a caller that has ALREADY established the window is empty
    # without reading it: `.for`'s peek asked for `PANEL_LIMIT + 1` rows and got none, and the
    # retention rule keeps fifty, so "nothing peeked" PROVES "window empty". That makes this an
    # established fact rather than a placeholder — the exact distinction {.verdict}'s `nil`s turn
    # on, at the other end of the same rule.
    def self.empty = new({})

    # The blank fold is HERE, in Ruby, not left to SQL: `IngestRejection#reported_client` is
    # `user_agent.presence`, so a row with no header reads "Not reported" one panel down — but
    # SQL's `GROUP BY` keeps `NULL` and `''` as two buckets, and a summary that split them would
    # describe a different population than the rows it sits above. That is the exact failure the
    # owning class exists to prevent. The writer stores `presence`, so `''` should never land
    # today; the column is nullable and unconstrained, so the fold does not rely on that.
    #
    # Ordered largest bucket first so the reading order is the importance order, ties alphabetical
    # (the unreported bucket's `nil` label sorts by its empty string) so the render is
    # deterministic rather than index-order.
    def initialize(counts_by_stored_agent)
      @entries = counts_by_stored_agent
                 .group_by { |agent, _count| agent.presence }
                 .transform_values { |bucket| bucket.sum { |_agent, count| count } }
                 .sort_by { |client, count| [-count, client.to_s] }
    end

    # Every refusal the repository still retains — shown or not. The sum of the buckets, never a
    # second aggregate and never `rows.size`.
    def total = @entries.sum { |_client, count| count }

    # `[reported client or nil, count]`, largest first. The view renders `nil` with the rows' own
    # "Not reported" wording, so the summary and the list beneath it speak the same vocabulary.
    attr_reader :entries
  end
end
