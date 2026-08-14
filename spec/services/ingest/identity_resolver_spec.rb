# frozen_string_literal: true

require "rails_helper"

# Driven through the real ingest path — `Ingest::Payload` + `Ingest::RunRecorder` — rather than by
# hand-building `spec_observations`. The columns the resolver reads (`intent_entity`,
# `intent_action`, `intent_behavior`, `name`) are written by `Ingest::ObservationRecorder`, so a
# hand-built row could carry an intent no producer can actually deliver and the suite would go green
# on a state production never reaches (SPGD-91, *The Fixture Can Build What the Producer Cannot*).
RSpec.describe Ingest::IdentityResolver do
  include_context "with lexical embeddings"

  let(:repository) { create_repository }

  # One suite, at a line offset. Three examples: one annotated, two not, so every run exercises both
  # halves of `Ingest::SpecSignal`'s precedence at once.
  def suite(offset: 0, annotated_name: "Invoice#finalize locks the line items",
            renamed: "User#save rejects a duplicate email")
    [
      annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 10 + offset,
                     name: annotated_name),
      unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 20 + offset,
                       name: renamed),
      unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5 + offset,
                       name: "Cart adds an item to the cart")
    ]
  end

  # One CI run, ingested and then resolved, exactly as the endpoint and its job do it.
  def ingest(specs, ci_run_id:)
    record(specs, ci_run_id: ci_run_id).tap { |run| described_class.resolve(run) }
  end

  # The synchronous half alone — the state the endpoint has answered `202` from, before any
  # resolution has run.
  def record(specs, ci_run_id:)
    payload = Ingest::Payload.new(ingest_payload(specs: specs, ci_run_id: ci_run_id).deep_stringify_keys)
    raise "payload invalid: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repository, payload.test_run_attributes,
                               shard_id: payload.shard_id, specs: payload.specs)
  end

  def identity_texts = repository.spec_identities.pluck(:text).sort

  # How many embeddings a block caused, counted through `EmbeddingGenerator.provider=` — the public
  # swap seam `with lexical embeddings` itself uses — rather than by stubbing
  # `EmbeddingGenerator.call`: what is counted is then the real call the resolver makes through the
  # real interface, width validation and all. Delegating to `LocalProvider` rather than returning a
  # fixture vector keeps every fallthrough behaving exactly as it does everywhere else in this file,
  # so the counter can be installed without changing what the example under it measures.
  #
  # Top-level because TWO groups now bound the same figure from opposite ends: "re-ingesting text
  # that has not changed" asserts the embed does not happen on run 2, and "the page map is a
  # snapshot, and what that costs a FIRST run" asserts that batching those lookups did not quietly
  # add one back on run 1. One instrument, so the two cannot disagree about what an embed is.
  #
  # `normalize` is delegated for the same reason `call` is: `EmbeddingGenerator.equivalent?` asks
  # the installed provider whether two spellings collapse together, and a counter that answered
  # differently from `LocalProvider` would change the path it is supposed to be measuring — the
  # drift refresh would go inert exactly in the examples that count what it costs.
  let(:counting_provider) do
    Class.new do
      class << self
        def calls = @calls ||= 0

        def call(text)
          @calls = calls + 1
          EmbeddingGenerator::LocalProvider.call(text)
        end

        def normalize(text) = EmbeddingGenerator::LocalProvider.normalize(text)
      end
    end
  end

  describe "the behaviour this slice exists for: a test that moved is the same test" do
    # A shifted test's text is byte-identical, so two independent mechanisms both land it on the row
    # it already had: similarity (its vector is unchanged, cosine 1.0) and the `(repository_id,
    # text_digest)` conflict key. That overlap is deliberate — see `IdentityResolver#claim_identity`
    # — and it means these examples do not, on their own, isolate the similarity path. The one that
    # does is "still matches text that differs only in punctuation and whitespace" below: different
    # bytes, so the key cannot help, and only the embedding can.
    it "resolves a suite shifted ten lines onto the rows it already had, without growing the table" do
      first = ingest(suite, ci_run_id: "run-1")
      identities = repository.spec_identities.order(:id).pluck(:id)

      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.order(:id).pluck(:id)).to eq(identities)
      expect(second.spec_observations.pluck(:spec_identity_id).sort).to eq(identities)
      expect(first.spec_observations.pluck(:spec_identity_id).sort).to eq(identities)
    end

    it "moves each row's last known path to where the test now is" do
      ingest(suite, ci_run_id: "run-1")
      expect(repository.spec_identities.pluck(:line_number).sort).to eq([5, 10, 20])

      ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.pluck(:line_number).sort).to eq([15, 20, 30])
    end

    it "records the run that last saw the test, so a row says how current it is" do
      ingest(suite, ci_run_id: "run-1")
      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.pluck(:last_seen_test_run_id).uniq).to eq([second.id])
    end

    it "leaves each identity holding both runs' measurements — one test's history, finally" do
      ingest(suite, ci_run_id: "run-1")
      ingest(suite(offset: 10), ci_run_id: "run-2")

      counts = repository.spec_identities.map { |identity| identity.spec_observations.count }

      expect(counts).to eq([2, 2, 2])
    end

    it "keeps the position out of the identity: the same test on a different line is not a new row" do
      # The falsifier for the whole slice. A positional key — `(repository_id, file_path,
      # line_number)`, the one `spec_intents` carries — would make this six rows rather than three.
      ingest(suite, ci_run_id: "run-1")
      ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(3)
    end
  end

  describe "at zero annotations" do
    let(:unannotated) do
      [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 4,
                        name: "User#save rejects a duplicate email")]
    end

    it "gives a name-only test an identity, with no @intent anywhere in the payload" do
      ingest(unannotated, ci_run_id: "run-1")

      identity = repository.spec_identities.sole

      expect(identity.text).to eq("User#save rejects a duplicate email")
      expect(identity).to be_from_name
    end

    it "resolves it again on the next run, from its name alone" do
      ingest(unannotated, ci_run_id: "run-1")
      first = repository.spec_identities.sole.id

      moved = [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 44,
                                name: "User#save rejects a duplicate email")]
      run = ingest(moved, ci_run_id: "run-2")

      expect(repository.spec_identities.sole.id).to eq(first)
      expect(run.spec_observations.sole.spec_identity_id).to eq(first)
    end
  end

  describe "which of the two texts supplied the identity" do
    it "prefers the declared intent over the name, and says so on the row" do
      ingest([annotated_spec(name: "Invoice#finalize locks the line items")], ci_run_id: "run-1")

      identity = repository.spec_identities.sole

      # `Ingest::SpecSignal`'s intent branch: "{entity} {action} {behavior}", not `name`.
      expect(identity.text).to eq("Invoice finalize locks the line items once the invoice is finalized")
      expect(identity).to be_from_intent
    end

    it "keeps an annotated test's identity when its full_description is reworded" do
      ingest([annotated_spec(name: "Invoice#finalize locks the line items")], ci_run_id: "run-1")
      first = repository.spec_identities.sole.id

      ingest([annotated_spec(line_number: 40, name: "Invoice#finalize freezes every line")],
             ci_run_id: "run-2")

      expect(repository.spec_identities.pluck(:id)).to eq([first])
    end

    it "does not let a name-derived match be mistaken for a declared one" do
      ingest(suite, ci_run_id: "run-1")

      expect(repository.spec_identities.group(:signal_source).count).to eq("intent" => 1, "name" => 2)
    end
  end

  describe "a test that gains an @intent is the test it already was" do
    # **The adoption path every customer walks**, and the one transition that changes which text
    # represents a test without changing the test. `Ingest::SpecSignal` prefers a declaration over a
    # name deliberately, so run 2 presents a string this repository has never seen while the row it
    # already has is held under one nothing will ever present again — a miss on both the digest
    # equality and similarity, and yet not a new test.
    #
    # The same example on both runs: one file, one line, one `id`. Only the `@intent` appears.
    def name = "Invoice#finalize locks the line items"

    def triple = "Invoice finalize locks the line items once the invoice is finalized"

    def unannotated_version(line_number: 12)
      unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: line_number, name: name)
    end

    def annotated_version(line_number: 12, **intent)
      annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: line_number, name: name,
                     **intent)
    end

    # A SECOND example of the same page carrying the same `full_description` — a shared example
    # group, the same `it` string under two describes — which never gains an annotation. Run 1
    # collapses the two onto one row, which is `SpecIdentity::MATCH_SIMILARITY`'s stated behaviour
    # and not this slice's doing. It exists here because it is the only row that can READ the page
    # map entry `#upgrade_from_name` writes or removes, and so the only row either race group can
    # observe that decision through.
    def sibling
      unannotated_spec(file_path: "spec/models/other_spec.rb", line_number: 3, name: name)
    end

    it "upgrades the row it already had in place, rather than inserting a second one beside it" do
      ingest([unannotated_version], ci_run_id: "run-1")
      original = repository.spec_identities.sole
      expect(original).to be_from_name

      ingest([annotated_version], ci_run_id: "run-2")

      identity = repository.spec_identities.sole
      # The SAME row — the id is what a history hangs off, so re-creating an equivalent row would
      # satisfy a count and lose everything the count was standing for.
      expect(identity.id).to eq(original.id)
      expect(identity).to be_from_intent
      expect(identity.text).to eq(triple)
    end

    it "leaves both runs' observations pointing at that one identity" do
      first = ingest([unannotated_version], ci_run_id: "run-1")
      second = ingest([annotated_version], ci_run_id: "run-2")
      identity = repository.spec_identities.sole

      expect(first.spec_observations.sole.spec_identity_id).to eq(identity.id)
      expect(second.spec_observations.sole.spec_identity_id).to eq(identity.id)
      # One test, one history, across the annotation boundary — the thing the duplicate row severed.
      expect(identity.spec_observations.count).to eq(2)
    end

    it "keeps when the test first appeared, and moves where it was last seen" do
      # An upgrade is not an insert: `created_at` says when this test first appeared and must not be
      # reset to the run that annotated it. The sighting still moves, and still through `#resight`.
      first = ingest([unannotated_version], ci_run_id: "run-1")
      created_at = repository.spec_identities.sole.created_at

      second = ingest([annotated_version(line_number: 40)], ci_run_id: "run-2")

      identity = repository.spec_identities.sole
      expect(identity.created_at).to eq(created_at)
      expect(identity.line_number).to eq(40)
      expect(identity.last_seen_test_run_id).to eq(second.id)
      expect(first.spec_observations.sole.spec_identity_id).to eq(identity.id)
    end

    it "moves the vector too, so the next run finds the row by its declaration" do
      # The falsifier for a half-done upgrade. Rewriting `text` and `text_digest` while leaving the
      # NAME's embedding on the row goes green on every example above — they all re-find it by the
      # digest equality. This run's triple differs only in punctuation, so its digest does not match
      # and only similarity can answer: against the triple's vector it is cosine 1.0, against the
      # name's it is 0.8614 and this becomes two rows.
      ingest([unannotated_version], ci_run_id: "run-1")
      ingest([annotated_version], ci_run_id: "run-2")
      upgraded = repository.spec_identities.sole.id

      ingest([annotated_version(line_number: 40,
                                behavior: "locks the line items  once the invoice is finalized!")],
             ci_run_id: "run-3")

      expect(repository.spec_identities.pluck(:id)).to eq([upgraded])
    end

    it "upgrades nothing when the name it would upgrade belongs to no row of this repository" do
      # The premise under every example above, stated as its own claim: the upgrade is reached by the
      # NAME's digest, so a test that was annotated from its very first run has nothing to upgrade
      # and takes the ordinary insert.
      ingest([annotated_version], ci_run_id: "run-1")

      identity = repository.spec_identities.sole
      expect(identity).to be_from_intent
      expect(identity.text).to eq(triple)
    end

    it "does not rewrite an identity backwards when a test LOSES its @intent" do
      # **Direction is name→intent only, and this is why.** A de-annotated test presenting its name
      # is indistinguishable from an ordinary rename of an annotated one, so an upgrade that ran in
      # both directions would let a rename quietly rewrite a declaration's identity. De-annotation is
      # out of scope for this slice; today's behaviour — a new identity — is what it must keep.
      ingest([annotated_version], ci_run_id: "run-1")
      declared = repository.spec_identities.sole

      ingest([unannotated_version(line_number: 40)], ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(2)
      expect(declared.reload.text).to eq(triple)
      expect(declared).to be_from_intent
    end

    it "does not touch a name-derived row that is not this test's" do
      # The upgrade is keyed on the annotated example's OWN name and nothing looser. A repository
      # full of name-derived rows must see none of them move when one of its tests is annotated.
      ingest([unannotated_version,
              unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 4,
                               name: "User#save rejects a duplicate email")],
             ci_run_id: "run-1")
      bystander = repository.spec_identities.find_by(text: "User#save rejects a duplicate email")

      ingest([annotated_version,
              unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 4,
                               name: "User#save rejects a duplicate email")],
             ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(2)
      expect(bystander.reload.text).to eq("User#save rejects a duplicate email")
      expect(bystander).to be_from_name
    end

    it "never reaches across the tenant boundary to upgrade another repository's row" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other-service")
      theirs = create_spec_identity(repository: other, text: name)

      ingest([annotated_version], ci_run_id: "run-1")

      expect(theirs.reload.text).to eq(name)
      expect(theirs).to be_from_name
      expect(repository.spec_identities.sole.text).to eq(triple)
    end

    # Matched on the PROJECTION `#digest_index` plucks, and not on "a SELECT naming `text_digest`"
    # the way the round-trip group's helper is. That group's pages never fall through to similarity,
    # so nothing there can be miscounted; every row of THIS page does, and `#nearest` selects every
    # column — `text_digest` among them — so the looser instrument would count five similarity
    # lookups as digest lookups and the claim would be untestable.
    def digest_lookups(&) = executed_sql(&).grep(/\ASELECT "spec_identities"\."text_digest"/)

    def annotated_page
      (1..5).map do |index|
        annotated_spec(file_path: "spec/models/a#{index}_spec.rb", line_number: index,
                       name: "Subject #{index} does the thing", entity: "Subject#{index}",
                       action: "call", behavior: "does the thing it was asked to do")
      end
    end

    def unannotated_page
      (1..5).map do |index|
        unannotated_spec(file_path: "spec/models/a#{index}_spec.rb", line_number: index,
                         name: "Subject #{index} does the thing")
      end
    end

    it "asks one query for a page of annotated rows, though each carries two texts to look up" do
      # The cost of the upgrade, which is the reason it is affordable: the name's digest rides the
      # `IN` list `#digest_index` already issues. A wider list, not a second round trip — and not a
      # lookup per candidate row either.
      ingest(unannotated_page, ci_run_id: "run-1")
      expect(repository.spec_identities.pluck(:signal_source).uniq).to eq(["name"])

      second = record(annotated_page, ci_run_id: "run-2")
      EmbeddingGenerator.provider = counting_provider

      expect(digest_lookups { described_class.resolve(second) }.size).to eq(1)
      # The premise, pinned rather than trusted: every row of this page really did fall through the
      # digest equality to an embed and a similarity lookup, which is what makes "one" a claim about
      # a page of five upgrades rather than about a page nothing happened on.
      expect(counting_provider.calls).to eq(5)
      expect(repository.spec_identities.count).to eq(5)
      expect(repository.spec_identities.pluck(:signal_source).uniq).to eq(["intent"])
    end

    describe "when another identity already holds the declaration's text" do
      # `(repository_id, text_digest)` is UNIQUE, so the upgrade cannot land on a digest another row
      # already holds. The page's map would ordinarily have answered that at `#identical_text`, so
      # reaching the `UPDATE` at all means a concurrent job committed the row in between — the race
      # `spec/support/uniqueness_race.rb` describes, reproduced the way this file's other race group
      # reproduces it: stub the two lookups a loser cannot see a winner through, and let everything
      # after them run for real.
      #
      # What must NOT happen is a `RecordNotUnique` escaping onto the ingest path. A duplicate
      # identity is a defect; a 500 on ingest is a worse one, so the conflict falls back to today's
      # behaviour and `#claim_identity`'s `ON CONFLICT` lands the observation on the winner.
      def resolve_as_the_loser(run)
        resolver = described_class.new(run)
        allow(resolver).to receive(:identical_text).and_return(nil)
        allow(resolver).to receive(:nearest).and_return(nil)
        resolver.resolve
      end

      it "resolves the observation onto the winner without raising or duplicating" do
        ingest([unannotated_version], ci_run_id: "run-1")
        winner = create_spec_identity(repository: repository, text: triple, signal_source: "intent",
                                      file_path: "spec/models/invoice_spec.rb", line_number: 12)
        second = record([annotated_version(line_number: 40)], ci_run_id: "run-2")

        expect { resolve_as_the_loser(second) }.not_to change(SpecIdentity, :count)

        expect(second.spec_observations.sole.spec_identity_id).to eq(winner.id)
        expect(winner.reload.line_number).to eq(40)
      end

      it "leaves the name-derived row exactly as it was rather than half-upgrading it" do
        # The failure mode a partial write invites: `text` moved, the unique `text_digest` refused,
        # and a row describing itself as two different tests. One statement, so there is no half.
        ingest([unannotated_version], ci_run_id: "run-1")
        original = repository.spec_identities.sole
        before = original.reload.slice(:text, :text_digest, :signal_source, :embedding, :created_at)
        create_spec_identity(repository: repository, text: triple, signal_source: "intent",
                             file_path: "spec/models/invoice_spec.rb", line_number: 12)

        resolve_as_the_loser(record([annotated_version(line_number: 40)], ci_run_id: "run-2"))

        expect(original.reload.slice(*before.keys)).to eq(before)
      end

      it "leaves the page still holding the name, which the refused UPDATE kept true" do
        # The half of the map decision that is NOT the lost race. A conflict means the `UPDATE` was
        # REFUSED, so the row never left the name and the page's entry for it is still true — a
        # sibling reading it re-sights the row it really does belong to, for free. Invalidating on
        # this branch as well would still be CORRECT (`#claim_identity`'s `ON CONFLICT` lands the
        # sibling on the same row either way), so the claim here is about cost, and it is asserted as
        # cost: the sibling resolves without embedding anything.
        #
        # Reaching a conflict at all means the winner committed BETWEEN this page's lookups and this
        # row's `UPDATE`, which is why both lookups are stubbed — and stubbed for the intent-derived
        # row ONLY, so the sibling that this example is actually about runs entirely for real.
        ingest([unannotated_version, sibling], ci_run_id: "run-1")
        shared = repository.spec_identities.sole
        create_spec_identity(repository: repository, text: triple, signal_source: "intent",
                             file_path: "spec/models/invoice_spec.rb", line_number: 12)
        triple_embedding = EmbeddingGenerator.call(triple)
        second = record([annotated_version, sibling], ci_run_id: "run-2")

        resolver = described_class.new(second)
        allow(resolver).to receive(:identical_text).and_wrap_original do |original, signal|
          signal.from_intent? ? nil : original.call(signal)
        end
        allow(resolver).to receive(:nearest).and_wrap_original do |original, embedding|
          embedding == triple_embedding ? nil : original.call(embedding)
        end
        EmbeddingGenerator.provider = counting_provider
        resolver.resolve

        # One embed, and it is the annotated row's. The sibling's answer came out of the page map.
        expect(counting_provider.calls).to eq(1)
        expect(second.spec_observations.order(:id).pluck(:spec_identity_id).last).to eq(shared.id)
        expect(shared.reload.text).to eq(name)
        expect(shared).to be_from_name
      end
    end

    describe "when a concurrent shard has already upgraded the row" do
      # The OTHER way the guarded `UPDATE` does not land, and the one that leaves the page holding a
      # lie. `WHERE signal_source = 'name'` matches ZERO rows because another shard rewrote this row
      # to the triple first — so unlike the conflict above, the row HAS moved off the name, and the
      # page's map still pointing `name_digest` at it is now false in exactly the way
      # `#upgrade_from_name`'s invalidation comment describes. Both branches return "did not
      # upgrade"; only one of them leaves the name still held.
      #
      # Two examples of one page share a `full_description` ({#sibling}) and one of them gains the
      # `@intent`. What must not happen on run 2 is the name-only sibling reading the stale entry and
      # re-sighting the row that just became the annotated test's, which would both misattribute its
      # observation AND drag that row's last known path to a file the annotated test is not in.

      # The winner's `UPDATE` runs and THEN the real `#upgrade` does, so the zero-row result is the
      # database's own answer rather than a double's. Stubbing `#upgrade` to simply return
      # `:lost_race` would assert against a value production might never produce; here the guard
      # genuinely fails against genuinely committed state. The winner writes the same text, digest,
      # source and VECTOR, because that is what the real one writes — leaving the name's embedding
      # behind would let similarity rescue the sibling and hide the stale key this is about.
      def resolve_losing_the_upgrade(run)
        resolver = described_class.new(run)
        upgrade = resolver.method(:upgrade)

        allow(resolver).to receive(:upgrade) do |identity_id, signal, digest, embedding|
          SpecIdentity.where(id: identity_id)
                      .update_all(text: signal.text, text_digest: digest, signal_source: "intent",
                                  embedding: embedding, updated_at: Time.current)
          upgrade.call(identity_id, signal, digest, embedding).tap { |outcome| outcomes << outcome }
        end

        resolver.resolve
        resolver
      end

      def outcomes = @outcomes ||= []

      it "really does take the losing branch, so the examples below are about something" do
        # The premise, pinned against the real method's return rather than trusted. If the page ever
        # stopped reaching `#upgrade` at all — a similarity match, a digest hit — every assertion
        # below would go green while testing nothing.
        ingest([unannotated_version, sibling], ci_run_id: "run-1")

        resolve_losing_the_upgrade(record([annotated_version, sibling], ci_run_id: "run-2"))

        expect(outcomes).to eq([:lost_race])
      end

      it "does not resolve the name-only sibling onto the row that moved out from under it" do
        ingest([unannotated_version, sibling], ci_run_id: "run-1")
        shared = repository.spec_identities.sole

        second = record([annotated_version, sibling], ci_run_id: "run-2")
        resolve_losing_the_upgrade(second)

        annotated, unannotated = second.spec_observations.order(:id).pluck(:spec_identity_id)
        # The annotated example still converges onto the row the winner upgraded — `#claim_identity`'s
        # `ON CONFLICT` — which is the half that already worked and must keep working.
        expect(annotated).to eq(shared.id)
        expect(unannotated).not_to eq(shared.id)
      end

      it "leaves the upgraded row's last known path belonging to the test that was annotated" do
        # The consequence a misattribution carries past the observation link: the sibling re-sights
        # through the stale key, and `#resight` moves `file_path`/`line_number`, so the row ends up
        # reporting a location belonging to a different test entirely.
        ingest([unannotated_version, sibling], ci_run_id: "run-1")

        resolve_losing_the_upgrade(record([annotated_version, sibling], ci_run_id: "run-2"))

        upgraded = repository.spec_identities.find_by(text: triple)
        expect(upgraded.file_path).to eq("spec/models/invoice_spec.rb")
        expect(upgraded.line_number).to eq(12)
      end

      it "gives the sibling a row of its own, under the name the upgraded row no longer holds" do
        ingest([unannotated_version, sibling], ci_run_id: "run-1")

        resolve_losing_the_upgrade(record([annotated_version, sibling], ci_run_id: "run-2"))

        expect(repository.spec_identities.count).to eq(2)
        own = repository.spec_identities.find_by(text: name)
        expect(own).to be_from_name
        expect(own.file_path).to eq("spec/models/other_spec.rb")
      end
    end
  end

  describe "a renamed unannotated test is a different test" do
    it "starts a new identity rather than re-pointing the old one" do
      ingest(suite, ci_run_id: "run-1")
      original = repository.spec_identities.find_by(text: "User#save rejects a duplicate email")

      ingest(suite(offset: 10, renamed: "User#save refuses a handle that is already taken"),
             ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(4)
      expect(identity_texts).to include("User#save refuses a handle that is already taken")
      expect(original.reload.text).to eq("User#save rejects a duplicate email")
    end

    it "leaves the old identity's history intact rather than moving it onto the new name" do
      ingest(suite, ci_run_id: "run-1")
      original = repository.spec_identities.find_by(text: "User#save rejects a duplicate email")

      ingest(suite(offset: 10, renamed: "User#save refuses a handle that is already taken"),
             ci_run_id: "run-2")

      expect(original.spec_observations.count).to eq(1)
      expect(original.reload.line_number).to eq(20)
    end
  end

  describe "the threshold, against the vectors it was chosen from" do
    # Not an assertion about a constant's value — an assertion about what the constant DOES to real
    # texts. Changing 0.95 to 0.75 leaves the constant "correct" and breaks these.
    it "does not merge two different tests that merely read alike" do
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Invoice finalize locks the line items"),
              unannotated_spec(file_path: "spec/a_spec.rb", line_number: 2,
                               name: "Invoice finalize locks line items once finalized")],
             ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(2)
    end

    it "keeps a pair inside the duplicate-detection band as two identities" do
      # The invariant that matters between the two thresholds, as behaviour rather than as a claim
      # about a constant. These two score 0.9236 on the shipped provider: at or above the duplicate
      # engine's 0.88, so it is entitled to report them as redundant, and below MATCH_SIMILARITY, so
      # resolution still gives each its own history. Lower the constant to 0.75 and this merges them
      # — which is the failure the "strictly above" rule exists to prevent.
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Order#checkout rejects an expired card"),
              unannotated_spec(file_path: "spec/a_spec.rb", line_number: 2,
                               name: "Order#checkout rejects an expired card token")],
             ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(2)
    end

    it "cannot separate two tests whose descriptions are identical — they collapse onto one row" do
      # Where the threshold stops mattering, demonstrated rather than asserted. The duplicates the
      # shipped surface reports are EXACT ones — `SpecObservation.repeated_descriptions_in` groups
      # on `name` — and identical text embeds to an identical vector, so no value of
      # MATCH_SIMILARITY makes these two examples two identities: `#nearest` matches at cosine 1.0,
      # and the `(repository_id, text_digest)` key would land them together even if it did not.
      # Stated on `SpecIdentity::MATCH_SIMILARITY`; asserted here so SPGD-114 slice 4 inherits it as
      # a known property of these rows rather than a surprise.
      run = ingest([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3,
                                     name: "is valid"),
                    unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7,
                                     name: "is valid")],
                   ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(1)
      # Two different tests, one history: the run's two observations point at the same row.
      expect(run.spec_observations.pluck(:spec_identity_id).uniq.size).to eq(1)
      # And its "last known path" is simply whichever of the two was resolved last — the flip-flop
      # named in the constant's comment, pinned here so it is documented rather than folklore.
      expect(repository.spec_identities.sole.location).to eq("spec/models/user_spec.rb:7")
    end

    it "still matches text that differs only in punctuation and whitespace" do
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Order#checkout rejects an expired card")],
             ci_run_id: "run-1")
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Order  checkout   rejects an expired card!")],
             ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(1)
    end
  end

  # The group above proves the drifted row is FOUND. This one is about what finding it that way
  # costs, and about the fact that — until this slice — it cost that on every ingest forever.
  #
  # The digest is over the raw text and the vector is over a normalised form of it, so a description
  # that gained a comma matches at cosine 1.0 and is re-sighted correctly while the row keeps the
  # ORIGINAL spelling. `#identical_text` then misses on every later ingest too, because neither side
  # ever changes — one embed and one per-row ANN round trip, permanently, for a population that only
  # grows as descriptions are edited. Re-pointing the row at the spelling that was actually presented
  # is one write, once, and it converges.
  describe "a description that drifted only in punctuation, on the ingests after the drift" do
    def original = "Order#checkout rejects an expired card"
    def drifted = "Order  checkout   rejects an expired card!"

    def one(name, line: 1)
      unannotated_spec(file_path: "spec/a_spec.rb", line_number: line, name: name)
    end

    def elsewhere(name, line: 1)
      unannotated_spec(file_path: "spec/b_spec.rb", line_number: line, name: name)
    end

    it "asks the provider nothing at all, where it used to ask on every ingest forever" do
      # **The figure this slice exists to move**, on the instrument that pins the unchanged path's
      # zero, so the two cannot disagree about what an embed is. Run 2 is the drift and still pays
      # for it; run 3 presents exactly what run 2 did and is the ingest that used to pay again.
      ingest([one(original)], ci_run_id: "run-1")
      ingest([one(drifted)], ci_run_id: "run-2")

      EmbeddingGenerator.provider = counting_provider
      ingest([one(drifted, line: 2)], ci_run_id: "run-3")

      expect(counting_provider.calls).to eq(0)
      expect(repository.spec_identities.count).to eq(1)
    end

    it "re-points the row it already had at the spelling that was presented" do
      ingest([one(original)], ci_run_id: "run-1")
      identity = repository.spec_identities.sole

      ingest([one(drifted)], ci_run_id: "run-2")

      # The same row, moved — not a second row, which is what makes this a refresh and not a rename.
      expect(repository.spec_identities.count).to eq(1)
      expect(identity.reload.text).to eq(drifted)
    end

    it "keeps the whole history on that row rather than starting one for the new spelling" do
      ingest([one(original)], ci_run_id: "run-1")
      identity = repository.spec_identities.sole

      ingest([one(drifted, line: 2)], ci_run_id: "run-2")
      third = ingest([one(drifted, line: 3)], ci_run_id: "run-3")

      expect(identity.reload.spec_observations.count).to eq(3)
      expect(identity.line_number).to eq(3)
      expect(identity.last_seen_test_run_id).to eq(third.id)
    end

    it "leaves the text alone for an edit the provider CAN tell apart, inside the match band" do
      # The falsifier for keying this on `SpecIdentity::MATCH_SIMILARITY` instead of on
      # normalisation-equivalence. "card" → "cards" scores 0.9840 on the shipped provider — above
      # the 0.95 bar, so it re-sights the row it already had, exactly as it did before this slice —
      # and it is a genuine edit rather than another spelling of the same string, so the identity
      # must keep its own text. An implementation that refreshed on "anything that matched" passes
      # every other example in this group and fails here.
      ingest([one(original)], ci_run_id: "run-1")
      identity = repository.spec_identities.sole

      ingest([one("Order#checkout rejects an expired cards")], ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(1)
      expect(identity.reload.text).to eq(original)
    end

    it "keeps the page's sightings and its links when the convergence write itself fails" do
      # **The refresh is the only OPTIONAL write on this path and it must not be able to cost the two
      # that are not.** The sightings and the links are what the page decided, and `#resolve_page`
      # flushes on every exit precisely so a page that died still writes them. Issued ahead of them,
      # anything the refresh raises that its own rescue does not name — a deadlock, a lock timeout, a
      # statement timeout on a page carrying many drifts — propagates before either required
      # statement is reached, and a page that had already met an exception discards everything it
      # resolved down the "keep the original" branch. Ordered behind them, the ingest loses its
      # convergence and nothing else.
      ingest([one(original)], ci_run_id: "run-1")
      identity = repository.spec_identities.sole

      second = record([one(drifted, line: 4)], ci_run_id: "run-2")
      resolver = described_class.new(second)
      allow(resolver).to receive(:refresh).and_raise(ActiveRecord::Deadlocked, "deadlock detected")

      expect { resolver.resolve }.to raise_error(ActiveRecord::Deadlocked)

      # Both required writes landed: the observation carries the identity it resolved to, and the
      # identity moved to where the test was last seen. Only the spelling did not move.
      expect(second.spec_observations.unresolved.count).to eq(0)
      expect(identity.reload.line_number).to eq(4)
      expect(identity.text).to eq(original)
    end

    it "settles one spelling for a page that carries both, rather than rewriting on every ingest" do
      # Two examples whose descriptions differ only in punctuation share ONE identity — no threshold
      # can separate them — so one of them presents a spelling the row does not hold, on every
      # ingest, forever. Refreshing per matched row would rewrite the text every time, which is
      # worse than the miss it is meant to fix. The page settles ONE spelling against the sighting it
      # had already settled, and from then on the ingest costs the two statements any page costs.
      page = [one(original, line: 1), one(drifted, line: 2)]
      ingest(page, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(1)

      second = record(page, ci_run_id: "run-2")
      updates = executed_sql { described_class.resolve(second) }.grep(/\AUPDATE\b/)

      # The page's two batched writes and no third one: the re-sighting and the link.
      expect(updates.size).to eq(2)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "settles one spelling for two variants that land in DIFFERENT pages, and stops writing" do
      # **The same hazard one page boundary out, which is where a per-page bound stops working.**
      # `#resolve` pages by `BATCH_SIZE` — forty pages of a suite at the design point — and nothing
      # keeps two spellings of one test adjacent. Bounded per page, the earlier page misses on what
      # the row holds and moves it, the later page rebuilds its map, misses on what the earlier page
      # just wrote, and moves it back: every ingest, forever, and now two `UPDATE`s on top of the two
      # embeds those rows already paid — a net regression in a slice whose premise is convergence.
      #
      # Two pages here rather than forty because the boundary is the whole mechanism and one is
      # enough to cross it; `BATCH_SIZE` is stubbed for the reason the page-seam examples above stub
      # it. Run 2 is the ingest that settles the spelling, so run 3 is the first steady-state one and
      # the figures asserted are the steady state's: no refresh statement at all, and the one embed
      # the variant that lost costs — where the unbounded shape pays two embeds and two `UPDATE`s
      # here and on every ingest after it.
      stub_const("#{described_class}::BATCH_SIZE", 1)
      pages = [one(original), elsewhere(drifted)]

      ingest(pages, ci_run_id: "run-1")
      ingest(pages, ci_run_id: "run-2")
      settled = repository.spec_identities.sole.text

      EmbeddingGenerator.provider = counting_provider
      third = record(pages, ci_run_id: "run-3")
      updates = executed_sql { described_class.resolve(third) }.grep(/\AUPDATE\b/)

      expect(repository.spec_identities.sole.text).to eq(settled)
      expect(updates.size).to eq(4) # Two pages, two statements each. No third statement on either.
      expect(counting_provider.calls).to eq(1)
      expect(third.spec_observations.unresolved.count).to eq(0)
    end
  end

  describe "re-ingesting text that has not changed" do
    # The optimisation itself, asserted as work NOT DONE rather than as a duration. A byte-identical
    # re-ingest is the ordinary case and not a corner — run 2 of an unchanged suite is every row of
    # it — and each of those rows is named outright by the `(repository_id, text_digest)` equality
    # `#claim_identity` already upserts onto, so nothing has to be embedded to find it again.
    #
    # The instrument is `counting_provider`, one level up. What that equality COSTS TO ASK is the
    # group below this one.

    it "embeds nothing at all when every text is byte-identical to a row already held" do
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(counting_provider.calls).to eq(0)
    end

    it "still embeds a text this repository has never seen" do
      # The counter is only worth reading if it can move: same instrument, same three-example suite,
      # one of them renamed. A rename's bytes differ, so the equality cannot answer and today's path
      # runs — which is the fallthrough the whole change depends on, observed rather than assumed.
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      ingest(suite(offset: 10, renamed: "User#save refuses a handle that is already taken"),
             ci_run_id: "run-2")

      expect(counting_provider.calls).to eq(1)
    end

    it "re-sights every row whose embed it skipped, rather than becoming a no-op" do
      # The failure mode a skip invites: returning early and never moving the row. Skipping the
      # EMBED must not skip the SIGHTING — `SpecIdentity::RESIGHTABLE` is what a re-sighting moves,
      # and none of it needs a vector.
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(counting_provider.calls).to eq(0)
      expect(repository.spec_identities.pluck(:line_number).sort).to eq([15, 20, 30])
      expect(repository.spec_identities.pluck(:last_seen_test_run_id).uniq).to eq([second.id])
      expect(repository.spec_identities.count).to eq(3)
    end

    it "counts a skipped row as resolved and links it, exactly as an embedded one" do
      # What `#resolve` returns is unchanged by the shortcut: the row carries an identity, so it is
      # resolved, and it is off the work list for the next job.
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      second = record(suite(offset: 10), ci_run_id: "run-2")

      expect(described_class.resolve(second)).to eq(3)
      expect(counting_provider.calls).to eq(0)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "resolves a known test even while the provider is down, because it never asks it" do
      # A consequence worth pinning rather than leaving to be discovered: the shortcut returns
      # before `#embed`, so an outage stops mattering for every test whose text this repository
      # already holds. Only genuinely new text still needs the provider — and only that text is
      # still left unresolved and stamped, which is the group below this one.
      ingest(suite, ci_run_id: "run-1")

      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(second.spec_observations.unresolved).to be_empty
      expect(second.spec_observations.embed_failed).to be_empty
      expect(repository.spec_identities.count).to eq(3)
    end
  end

  describe "what a page of unchanged text costs in round trips" do
    # The other half of the same optimisation, and the reason it is a separate group: the group above
    # asserts the equality removes the WORK, this one asserts asking it does not cost a round trip
    # per row. Run 2 of an unchanged suite answers every row by an equality now, but a per-row
    # `find_by` still issued 20,000 sequential trips at the design point to rediscover 20,000 rows
    # the database can name a page at a time.
    #
    # **A query count and never a duration.** A duration would go green on a fast machine whatever
    # the resolver did, and red on a slow one whatever it did — the claim is about the NUMBER of
    # statements, so that is what is counted. `count_queries`/`executed_sql` (spec/support/
    # query_capture.rb) drop `payload[:cached]` as well as `SCHEMA`/`TRANSACTION`, so what is counted
    # is round trips actually paid for.
    #
    # **Two instruments, because the page has two costs and they are bounded separately.** The
    # digest lookup is the READ, and it is narrowed to `\ASELECT … text_digest` rather than counted
    # as a page total so it cannot move for reasons that have nothing to do with the claim —
    # `\ASELECT` also excludes the `INSERT … ON CONFLICT` in `#claim_identity`, which names the same
    # column and is not a lookup. The re-sighting and the link are the WRITES, and they used to be
    # O(N) by definition — this group deferred them in as many words, and SPGD-395 is what stopped
    # deferring. They are counted by their own predicate rather than folded into the first, so a
    # slice that batched one of the two and not the other cannot hide inside a total.
    def digest_lookups(&) = executed_sql(&).grep(/\ASELECT\b.*\btext_digest\b/m)
    def update_statements(&) = executed_sql(&).grep(/\AUPDATE\b/)

    # Twelve deliberately UNLIKE descriptions. The count has to be a page-multiple to say anything,
    # and near-identical filler would collapse under `MATCH_SIMILARITY` into fewer identities than
    # examples — which would leave the query count technically green while the fixture no longer
    # meant what it says. Each example below pins that premise before asserting anything.
    #
    # A method and not a constant: a constant assigned in a `describe` block takes the file's
    # lexical cref, not the example group's, so `SUBJECTS = [...]` here would define a GLOBAL
    # `::SUBJECTS` — a name generic enough to collide with the next spec that wants it, and to
    # collide load-order-dependently. Every other fixture in this file (`suite`, `wide_suite`,
    # `record`, `ingest`, `digest_lookups`) is a method for the same reason.
    def subjects
      [
        "Invoice#finalize locks the line items",
        "User#save rejects a duplicate email",
        "Cart adds an item to the cart",
        "Order#checkout rejects an expired card",
        "Payment#refund returns money to the original card",
        "Shipment#dispatch assigns a tracking number",
        "Coupon#apply reduces the total by a percentage",
        "Session#expire logs the visitor out",
        "Ledger#post balances debits against credits",
        "Report#render writes a PDF to disk",
        "Webhook#deliver retries after a server error",
        "Search#query ranks by relevance and then recency"
      ].freeze
    end

    def wide_suite(offset: 0, width: subjects.size)
      subjects.first(width).each_with_index.map do |name, index|
        unannotated_spec(file_path: "spec/models/subject_#{index}_spec.rb",
                         line_number: index + 1 + offset, name: name)
      end
    end

    it "asks one query for a whole page's digests rather than one per example" do
      ingest(wide_suite, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(subjects.size)

      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      # Twelve rows, one page, one lookup. Per row this was twelve; at the 20,000-example design
      # point it was 20,000.
      expect(digest_lookups { described_class.resolve(second) }.size).to eq(1)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "writes what a whole page decided in two statements, not in two per row" do
      # **The WRITE half of the same page seam, and the figure `BATCH_SIZE` now states.** Every row
      # of an unchanged re-ingest is a re-sighting, and a re-sighting is two `UPDATE`s: the
      # identity's last known path, and the observation's link. Per row that is 24 statements for
      # this fixture and 40,000 at the 20,000-example design point — for a run in which, by
      # construction, nothing about the suite changed.
      #
      # Asserted as an EXACT constant rather than as "fewer than twelve": the claim is O(1) per page,
      # and a bound that merely fell would stay green for an implementation that batched the link and
      # left the sighting per row. Two, because those are the two writes — not two because there are
      # twelve rows.
      ingest(wide_suite, ci_run_id: "run-1")
      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      expect(update_statements { described_class.resolve(second) }.size).to eq(2)

      # The premise, pinned rather than trusted: those two statements did the whole page's work. A
      # resolver that simply skipped the writes would answer this count perfectly.
      expect(second.spec_observations.unresolved.count).to eq(0)
      expect(repository.spec_identities.pluck(:last_seen_test_run_id).uniq).to eq([second.id])
      expect(repository.spec_identities.pluck(:line_number).sort).to eq((101..112).to_a)
    end

    it "keeps the page's write cost flat as the page grows" do
      # The falsifier for the example above, which an implementation that issued one statement per
      # row would also pass at a page of ONE. Same two statements over a page a third the size, so
      # the number is a property of the page and not of its width — and a per-row implementation
      # answers four here where it answered twelve above, which is exactly the shape a lone exact
      # count cannot tell from O(1).
      stub_const("#{described_class}::BATCH_SIZE", subjects.size / 3)
      ingest(wide_suite, ci_run_id: "run-1")
      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      # Three pages of four rows: two statements each, and never eight.
      expect(update_statements { described_class.resolve(second) }.size).to eq(6)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "grows with the number of PAGES and not with the number of examples" do
      # The falsifier for the one above, which a resolver that asked once for the whole suite would
      # also pass. `BATCH_SIZE` is what the lookup is grouped by, so shrinking it to a third of the
      # suite must cost exactly three lookups — and an implementation that kept asking per row would
      # answer twelve here whatever this constant said.
      stub_const("#{described_class}::BATCH_SIZE", subjects.size / 3)
      ingest(wide_suite, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(subjects.size)

      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      expect(digest_lookups { described_class.resolve(second) }.size).to eq(3)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "pays one extra read when the page comes back exactly full, and it is the batch probe" do
      # **The figure `BATCH_SIZE`'s comment commits to, for the case that constant is actually
      # about.** Every other example in this group runs an UNDER-full page — 12 rows into a page of
      # 500 — and that is the one width at which `find_in_batches` can tell the relation is
      # exhausted without asking. A page that comes back exactly `batch_size` wide cannot, so it
      # issues one more `SELECT` that returns nothing, and a FULL page therefore costs one round
      # trip more than the under-full fixture above.
      #
      # Pinned rather than left in prose because that paragraph is the tree's committed statement of
      # what a page costs, and its previous revision claimed the full page measured "the same 11" —
      # arithmetic on the under-full case rather than a measurement of the full one.
      #
      # The total is a PAGE total and isolates nothing, so it legitimately carries the pass's other
      # costs too — including the one `DELETE` `Ingest::EmbeddingCachePruner` issues per pass, which
      # is attributed below rather than left inside the number.
      stub_const("#{described_class}::BATCH_SIZE", subjects.size)
      ingest(wide_suite, ci_run_id: "run-1")
      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      sql = executed_sql { described_class.resolve(second) }

      expect(sql.size).to eq(13)
      # And the extra one is the probe and nothing else: two reads of the run's own page, the second
      # of which returns nothing. A total that grew for some other reason would pass the count alone.
      expect(sql.grep(/\ASELECT.*FROM "spec_observations" WHERE "spec_observations"\."test_run_id"/m).size).to eq(2)
      # The pass's retention sweep, once — not once per page and not once per row.
      expect(sql.grep(/\ADELETE\b.*embedding_cache_entries/m).size).to eq(1)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "costs the same full page whatever the page's width is" do
      # The falsifier for the example above, and for the word "flat" in `BATCH_SIZE`'s comment: half
      # the width, exactly full again, same 13. A resolver that had gone back to writing per row
      # answers 23 here and 35 there — the `2N + 10` this slice replaced — so the pair of numbers
      # says O(1)-in-the-width in a way neither says alone. The prune contributes exactly one to
      # both, which is what keeps the pair a statement about the WIDTH.
      stub_const("#{described_class}::BATCH_SIZE", 6)
      ingest(wide_suite(width: 6), ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(6)

      second = record(wide_suite(offset: 100, width: 6), ci_run_id: "run-2")

      sql = executed_sql { described_class.resolve(second) }

      expect(sql.size).to eq(13)
      expect(sql.grep(/\ADELETE\b.*embedding_cache_entries/m).size).to eq(1)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "asks once for the CROSS-RUN BACKLOG's page too, and not once per rescued row" do
      # **The other list.** Both examples above walk a run's OWN rows, and `#resolve` walks two
      # lists: before them comes `#retry_backlog`, the rows of EARLIER runs nothing else will
      # revisit. That list reaches `#claim` by a different route, so a resolver that batched a run's
      # own pages and went back to asking per row for the backlog would answer both examples above
      # correctly — verified, not assumed: replacing `resolve_page(retry_backlog)` with the per-row
      # `retry_backlog.each { claim(...) }` this slice removed leaves the WHOLE suite green without
      # this example. That is the shape SPGD-78 is about, so the backlog page is pinned separately
      # from the run's own.
      #
      # It is also the newer half of the seam. `#retry_backlog` became TWO populations under one
      # budget in SPGD-379, and this is what says the page seam still sits above both of them.
      ingest(wide_suite, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(subjects.size)

      # A whole run stranded before its job reached any of it — unresolved, UNSTAMPED, and waiting
      # longer than the grace, which is exactly `#unattempted_embed_backlog`'s population. Aged by
      # `update_all` rather than by moving the clock, the choice `#strand` states further down.
      stranded = record(wide_suite(offset: 100), ci_run_id: "run-2")
      stranded.spec_observations.unresolved
              .update_all(created_at: (SpecObservation::EMBED_ATTEMPT_GRACE + 1.minute).ago)

      # Run 3 carries text this repository already holds, which keeps the instrument honest in a way
      # the fixture has to arrange: `digest_lookups` matches any SELECT naming `text_digest`, and
      # `#nearest` selects EVERY column. A row that fell through to similarity would therefore be
      # counted here as though it were a lookup. With nothing to embed anywhere, the only statements
      # that can match are the two this example is about.
      third = record([unannotated_spec(file_path: "spec/models/subject_0_spec.rb", line_number: 900,
                                       name: subjects.first)], ci_run_id: "run-3")

      EmbeddingGenerator.provider = counting_provider

      # TWO pages, two lookups: the backlog's twelve rows, then run 3's one. Per row it is thirteen.
      expect(digest_lookups { described_class.resolve(third) }.size).to eq(2)

      # The premise, pinned rather than trusted: nothing was embedded, so nothing reached `#nearest`
      # and neither number above is an artifact of a fallthrough.
      expect(counting_provider.calls).to eq(0)
      expect(stranded.spec_observations.unresolved).to be_empty
    end

    it "still costs nothing when a page carries no text to look up at all" do
      # A page of rows with nothing to embed — `Ingest::SpecSignal`'s `:none` case, the rows
      # `#identity_for` returns nil for — must ask the database nothing.
      #
      # This is a falsifiable guard on `#digest_index`'s `filter_map` and not on an empty-list check:
      # `SpecIdentity.digest_for(nil)` is a perfectly good SHA-256 of the empty string, so a `map`
      # here would send a real digest no row can hold on a real round trip, and this goes red.
      # Asserted as the ABSENCE of the query rather than as the presence of a guard, so it keeps
      # meaning the same thing however `where(text_digest: [])` is answered.
      run = record([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      run.spec_observations.sole.update_columns(name: nil)

      expect(digest_lookups { described_class.resolve(run) }).to be_empty
      expect(run.spec_observations.sole.reload.spec_identity_id).to be_nil
    end
  end

  describe "when one page re-sights the same identity more than once" do
    # **The one way batching a page's re-sightings is silently wrong**, and it is reachable by two
    # ordinary routes rather than one exotic one: two examples whose `full_description` is identical
    # resolve to a single row (`SpecIdentity::MATCH_SIMILARITY` states why no threshold can separate
    # them), and `#retry_backlog` mixes runs by design, so ONE backlog page holds an earlier run's
    # row beside a later one's for the same test.
    #
    # Sequential guarded `UPDATE`s settled that by executing. Within a run whichever landed last had
    # the final word, which is correct because two examples sharing a description have no order
    # between them; across runs `SpecIdentity::SIGHTING_NOT_OLDER` refused the older one whatever
    # order they were walked in. A single statement has no "last": `UPDATE … FROM (VALUES …)` joined
    # on a DUPLICATED key applies exactly one of the duplicates and picks it arbitrarily, so unless
    # the page arrives deduplicated the guard is asked about a row nobody chose — and a sighting
    # travels backwards in time again, which is the failure that guard exists to make structurally
    # impossible.
    def provider_down
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
    end

    def provider_back = RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

    # Two tests, at one line offset, ingested as one run. Two so the example can put the newer
    # sighting FIRST in the page for one of them and LAST for the other — see below for why one
    # would certify nothing.
    def pair(line_number:)
      [unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: line_number,
                        name: "Cart adds an item to the cart"),
       unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: line_number,
                        name: "Order#checkout rejects an expired card")]
    end

    # Where a row sits in the backlog page, written directly onto the key `#failed_embed_backlog`
    # orders by. `update_all` rather than an arrangement of ingests that happens to produce this
    # order: the fact the fixture needs is "this row is walked at this position", and deriving it
    # from the sweep's own fairness counter would make the example a test of that counter.
    def walk_at(run, file_path, position)
      run.spec_observations.where(file_path: file_path).update_all(embed_failure_count: position)
    end

    it "lands the sighting the sequential path would have landed: the newest run wins" do
      provider_down
      older = ingest(pair(line_number: 5), ci_run_id: "run-1")
      newer = ingest(pair(line_number: 90), ci_run_id: "run-2")
      provider_back

      # Identities that exist but have NEVER been sighted, so the guard passes for either candidate
      # and cannot be what decides this. That is deliberate: with a `last_seen_test_run_id` already
      # set, `SIGHTING_NOT_OLDER` would refuse the older row on its own and the example would stay
      # green over a page that was never deduplicated at all.
      cart = create_spec_identity(repository: repository, text: "Cart adds an item to the cart")
      order = create_spec_identity(repository: repository, text: "Order#checkout rejects an expired card")

      # **The newest row first for one identity and last for the other**, which is what makes this
      # falsifying rather than lucky. Postgres picks one of a duplicated join key's rows arbitrarily;
      # whichever end of the list it happens to favour, an implementation that hands it both rows
      # gets exactly one of these two identities wrong.
      walk_at(newer, "spec/models/cart_spec.rb", 1)
      walk_at(older, "spec/models/cart_spec.rb", 2)
      walk_at(older, "spec/models/order_spec.rb", 3)
      walk_at(newer, "spec/models/order_spec.rb", 4)

      # A later ingest of an unrelated test: the production trigger, and the only thing that reads
      # these four rows again. All four are inside one page — `RETRY_SWEEP_LIMIT` is 500 — which is
      # the premise the whole example rests on.
      ingest([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                               name: "User#save rejects a duplicate email")], ci_run_id: "run-3")

      expect(cart.reload.location).to eq("spec/models/cart_spec.rb:90")
      expect(order.reload.location).to eq("spec/models/order_spec.rb:90")
      expect([cart.last_seen_test_run_id, order.last_seen_test_run_id]).to eq([newer.id, newer.id])
    end

    it "still links every observation, including the ones whose sighting it dropped" do
      # De-duplicating the SIGHTINGS must not de-duplicate the ROWS. An observation of a test is an
      # observation of it whether or not it is the most recent one — the same distinction the guard
      # itself draws, applied one step earlier: the page picks one row per identity to write and
      # still links all four.
      provider_down
      older = ingest(pair(line_number: 5), ci_run_id: "run-1")
      newer = ingest(pair(line_number: 90), ci_run_id: "run-2")
      provider_back

      create_spec_identity(repository: repository, text: "Cart adds an item to the cart")
      create_spec_identity(repository: repository, text: "Order#checkout rejects an expired card")

      resolved = described_class.resolve(
        record([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                 name: "User#save rejects a duplicate email")], ci_run_id: "run-3")
      )

      expect(older.spec_observations.unresolved).to be_empty
      expect(newer.spec_observations.unresolved).to be_empty
      # And the count is what NOW carries an identity: four rescued rows plus run 3's own one.
      expect(resolved).to eq(5)
    end
  end

  describe "when two shards' jobs collide on the page's writes" do
    # **The lock footprint is what batching these two statements actually changed**, and this group
    # is that question. Per row, each write ran in autocommit: one row lock, taken and released
    # inside one statement, and a transaction that never holds a second lock cannot be half of a
    # cycle. The batched statements take a page of row locks and hold them to the end of the
    # statement — and the passes that take them overlap by design, because every shard of a run
    # enqueues a job and `#retry_backlog` is repository-scoped rather than run-scoped, so N of them
    # read substantially the same rows.
    #
    # `#write_page` answers it in two parts and both are pinned below: the `VALUES` lists are sorted
    # by the join key, so what a page emits depends on WHICH rows it holds and not on the order its
    # read returned them in; and a statement chosen as the deadlock victim is retried once, because
    # the sort makes agreement likely without Postgres promising to lock in `VALUES` order.
    def provider_down
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
    end

    def provider_back = RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

    def three_specs(offset: 0)
      [["cart", "Cart adds an item to the cart"],
       ["order", "Order#checkout rejects an expired card"],
       ["ledger", "Ledger#post balances debits against credits"]].map.with_index do |(file, name), index|
        unannotated_spec(file_path: "spec/models/#{file}_spec.rb", line_number: index + 1 + offset, name: name)
      end
    end

    # A repository whose whole unresolved population is a BACKLOG page — the list whose order is
    # least stable between two concurrent jobs, since `#failed_embed_backlog` sorts by the very
    # column those jobs increment. `embed_failure_count` is written straight onto the rows, as the
    # group above does it, so the fixture asserts the fact it needs — these rows are walked in this
    # order — rather than testing the fairness counter that would otherwise produce it.
    def stranded_backlog_walked_in_reverse
      provider_down
      run = ingest(three_specs, ci_run_id: "run-1")
      provider_back
      three_specs.each { |spec| create_spec_identity(repository: repository, text: spec[:name]) }

      run.spec_observations.order(id: :desc).each_with_index do |observation, position|
        observation.update_column(:embed_failure_count, position)
      end

      run
    end

    # A later ingest of an unrelated test: the only thing that reads a backlog page again.
    def sweep(ci_run_id:)
      record([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                               name: "User#save rejects a duplicate email")], ci_run_id: ci_run_id)
    end

    # The join key of every tuple in a statement's `VALUES` list, in the order the statement presents
    # them. An assertion about the SQL and not about the data, deliberately: sorting the list changes
    # nothing anyone can read off a row afterwards — it changes the order the locks are ASKED for,
    # and in a single-process test the statement's text is the only artifact of that there is.
    def values_join_keys(statement)
      statement[/\(VALUES (.+?)\) AS \w+/m, 1].split(/\),\s*\(/).map { |tuple| tuple[/\d+/].to_i }
    end

    it "presents both statements' rows in join-key order, whatever order the page was read in" do
      run = stranded_backlog_walked_in_reverse
      walked = repository.spec_observations.embed_retryable
                         .order(:embed_failure_count, :embed_failed_at, :id).pluck(:id)

      statements = executed_sql { described_class.resolve(sweep(ci_run_id: "run-2")) }.grep(/\AUPDATE/)
      links = statements.grep(/\AUPDATE spec_observations/).first
      sightings = statements.grep(/\AUPDATE spec_identities/).first

      # The premise, pinned rather than assumed, or this asserts nothing at all: the work list hands
      # this page over in the OPPOSITE order to the one the statement must emit. A fixture whose
      # walk order already happened to be ascending would leave the example green with no sort.
      expect(walked.size).to eq(3)
      expect(walked).to eq(walked.sort.reverse)
      expect(values_join_keys(links)).to eq(walked.sort)
      expect(values_join_keys(sightings)).to eq(values_join_keys(sightings).sort)
    end

    # Postgres chooses one side of a lock cycle and aborts it; this injects that abort at the
    # statement rather than provoking a real cycle. Two connections, two threads and a barrier would
    # assert that the DETECTOR works — which is Postgres's business — instead of what this class does
    # when it is the side that was chosen.
    def deadlock_on(model, method, prefix, times: 1)
      attempts = []

      allow(model.connection).to receive(method).and_wrap_original do |original, *args, **kwargs|
        next original.call(*args, **kwargs) unless args.first.to_s.start_with?(prefix)

        attempts << args.first
        raise ActiveRecord::Deadlocked, "deadlock detected" if attempts.size <= times

        original.call(*args, **kwargs)
      end

      attempts
    end

    it "retries the page's write once and lands it, rather than losing the pass to a collision" do
      ingest(three_specs, ci_run_id: "run-1")
      second = record(three_specs(offset: 50), ci_run_id: "run-2")
      attempts = deadlock_on(SpecObservation, :exec_query, "UPDATE spec_observations")

      expect(described_class.resolve(second)).to eq(3)

      # Issued twice and the second one landed: the count is what the retry MATCHED, not the page
      # size, so a retry that quietly returned nothing would answer 0 above.
      expect(attempts.size).to eq(2)
      expect(second.spec_observations.unresolved).to be_empty
    end

    it "retries the re-sighting too, and the guard still decides what lands" do
      # The other statement, and it must survive a retry differently: the link sets one column to one
      # value, while the re-sighting is guarded per row. A second attempt writes what the first would
      # have — nothing was applied, because a deadlocked statement is rolled back whole — and the
      # identities end where an uncontended pass would have left them.
      ingest(three_specs, ci_run_id: "run-1")
      second = record(three_specs(offset: 50), ci_run_id: "run-2")
      attempts = deadlock_on(SpecIdentity, :exec_update, "UPDATE spec_identities")

      described_class.resolve(second)

      expect(attempts.size).to eq(2)
      expect(repository.spec_identities.pluck(:last_seen_test_run_id).uniq).to eq([second.id])
      expect(repository.spec_identities.pluck(:line_number).sort).to eq([51, 52, 53])
    end

    it "gives up after one retry and leaves the pass in the state a died pass leaves" do
      # **Once, and not a loop.** A page that deadlocks twice is under contention this class cannot
      # resolve by trying harder, and there is already a recovery for a pass that dies: the rows stay
      # unresolved and unstamped, and the next ingest's cross-run sweep reads them. What a retry loop
      # would buy is a delivery spent on contention while the page it holds goes stale.
      ingest(three_specs, ci_run_id: "run-1")
      second = record(three_specs(offset: 50), ci_run_id: "run-2")
      attempts = deadlock_on(SpecObservation, :exec_query, "UPDATE spec_observations", times: 2)

      expect { described_class.resolve(second) }.to raise_error(ActiveRecord::Deadlocked)

      expect(attempts.size).to eq(2)
      expect(second.spec_observations.unresolved.count).to eq(3)
      expect(second.spec_observations.pluck(:embed_failed_at).uniq).to eq([nil])
    end
  end

  describe "the page map is a snapshot, and what that costs a FIRST run" do
    # Its own group rather than a fourth example in the round-trip group above: this one is a FIRST
    # run over text that is not unchanged, and it asserts an EMBED COUNT rather than a round trip.
    # It answers a different question from the group it used to sit in, so it is filed under the
    # question it actually answers.

    it "does not make a first run embed twice for two examples carrying the same text" do
      # **The cost of a page map being a SNAPSHOT, resolved deliberately rather than discovered.**
      # The per-row `find_by` this replaced saw identities committed by EARLIER ROWS OF THE SAME
      # PAGE; a map read once up front does not, so the second of two byte-identical descriptions
      # would miss it and fall through to an embed that today it never pays.
      #
      # The OUTCOME is the same either way — identical text embeds to an identical vector, `#nearest`
      # matches at cosine 1.0, and the conflict key would land them together regardless — which is
      # exactly why this needs its own example: "cannot separate two tests whose descriptions are
      # identical" asserts the identity COUNT and stays green under both. The embed is the expensive
      # thing the whole path exists to avoid and the provider is swappable for a billed one, so
      # `#claim_identity` puts the row it just created back into the page's map, and this is the
      # assertion that says so.
      EmbeddingGenerator.provider = counting_provider

      run = ingest([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3,
                                     name: "is valid"),
                    unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7,
                                     name: "is valid")],
                   ci_run_id: "run-1")

      expect(counting_provider.calls).to eq(1)
      expect(repository.spec_identities.count).to eq(1)
      expect(run.spec_observations.pluck(:spec_identity_id).uniq.size).to eq(1)
    end
  end

  describe "what a page of CHANGED text costs in provider REQUESTS" do
    # The complement of the two groups above, and the last cost `SPGD-72` names. They are about text
    # that has NOT changed — the identical-text equality answers it, so nothing is embedded and
    # nothing is asked. This one is about the case that equality cannot answer at all: a first run, a
    # rename, anything whose bytes are new. Every one of those rows still needs a vector, and the
    # question here is how many REQUESTS a page of them costs.
    #
    # `counting_provider` cannot answer it. It counts TEXTS, which is the right figure for the
    # shipped `LocalProvider` (hashing in this process, N times, is the cheapest shape there is) and
    # the wrong one for `OpenAIProvider`, where the bill and the latency are per REQUEST. So this
    # group installs a provider that implements the batch entry point and counts both.
    let(:batching_provider) do
      Class.new do
        class << self
          def calls = @calls ||= 0
          def batches = @batches ||= 0
          def batched = @batched ||= []

          def call(text)
            @calls = calls + 1
            EmbeddingGenerator::LocalProvider.call(text)
          end

          def embed_many(texts)
            @batches = batches + 1
            batched.concat(texts)
            texts.map { |text| EmbeddingGenerator::LocalProvider.call(text) }
          end

          # Delegated for the same reason the two above are: an instrument must not change the path
          # it measures. `EmbeddingGenerator.equivalent?` asks the INSTALLED provider which spellings
          # collapse together, so a counter that stayed silent about normalisation would take the
          # punctuation-drift example below down a branch production never takes.
          def normalize(text) = EmbeddingGenerator::LocalProvider.normalize(text)
        end
      end
    end

    # Five tests this repository has never seen, each lexically distinct from the others so that
    # nothing here is resolved by a similarity coincidence.
    def new_page
      ["Order#checkout rejects an expired card",
       "User#save refuses a duplicate email",
       "Cart#add appends the item to the cart",
       "Invoice#finalize locks the line items",
       "Report#export streams the CSV in batches"].each_with_index.map do |name, index|
        unannotated_spec(file_path: "spec/models/a#{index}_spec.rb", line_number: index + 1, name: name)
      end
    end

    # Which identity each run's row actually landed on, named by the text that identity is held
    # under — the pairing itself, rather than a count that a shifted pairing would also satisfy.
    def identity_by_file(run)
      run.spec_observations.includes(:spec_identity).to_h { |row| [row.file_path, row.spec_identity&.text] }
    end

    it "asks the provider ONCE for a page of five tests it has never seen" do
      # **The slice, stated as the figure it moves.** Five new tests were five sequential provider
      # requests — 20,000 of them for a changed suite at the design point, against an endpoint that
      # takes the whole array in one. The assertion is the REQUEST count and not the text count:
      # five texts still get embedded, and that was never the expensive part.
      run = record(new_page, ci_run_id: "run-1")
      EmbeddingGenerator.provider = batching_provider

      described_class.resolve(run)

      expect(batching_provider.batches).to eq(1)
      # And not one per row on the side: a batch that also fell through to `.call` would be the
      # same round trips plus one.
      expect(batching_provider.calls).to eq(0)
      # The premise, pinned rather than trusted: all five really did fall through the digest
      # equality to an embed, so "one" is a claim about a page of five and not about a page where
      # nothing happened.
      expect(batching_provider.batched.size).to eq(5)
      expect(repository.spec_identities.count).to eq(5)
    end

    it "still asks for nothing at all when the page's every text is already held" do
      # The identical-text shortcut runs BEFORE a text joins the request, so the optimisation the
      # two groups above assert is not undone by a batch that embeds its page indiscriminately.
      ingest(new_page, ci_run_id: "run-1")

      EmbeddingGenerator.provider = batching_provider
      ingest(new_page, ci_run_id: "run-2")

      expect(batching_provider.batches).to eq(0)
      expect(batching_provider.calls).to eq(0)
      expect(repository.spec_identities.count).to eq(5)
    end

    it "asks once for two examples carrying the same text, not once each" do
      # The page's request is deduped for the reason `#digest_index`'s `IN` list is: the vector is a
      # pure function of the text, so two examples with one description are one thing to ask about.
      run = record([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3, name: "is valid"),
                    unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7, name: "is valid")],
                   ci_run_id: "run-1")
      EmbeddingGenerator.provider = batching_provider

      described_class.resolve(run)

      expect(batching_provider.batched).to eq(["is valid"])
    end

    it "gives each test the vector for its own text, and not its neighbour's" do
      # **The ORDER CONTRACT, consumed.** The page's vectors come back positionally and are pinned
      # to rows positionally, so a page paired one place out would give every test its neighbour's
      # vector — and would look like a pass to anything that counted rows, or identities, or even
      # re-resolution: a CONSISTENT shift is self-consistent, so run 2 lands every row back on the
      # row it had while every one of those rows holds the wrong vector. That is the mis-pairing
      # this example is really for, and only the vector itself can see it.
      #
      # Asserted against `LocalProvider`'s answer for each row's OWN text rather than against a
      # fixture, so what has to line up is the provider's real output. Compared within a tolerance
      # because pgvector stores four-byte floats and Ruby's are eight — an exact `eq` would fail on
      # the storage round trip rather than on the pairing.
      EmbeddingGenerator.provider = batching_provider
      first = ingest(new_page, ci_run_id: "run-1")

      repository.spec_identities.each do |identity|
        own = EmbeddingGenerator::LocalProvider.call(identity.text)
        drift = own.zip(identity.embedding.to_a).map { |mine, stored| (mine - stored).abs }.max

        expect(drift).to be < 1e-5
      end

      # And the consequence that mis-pairing would have on the product: run 2's text differs from
      # run 1's in punctuation and whitespace only, so the digest equality cannot answer any of it
      # and every row is resolved by the vector it holds and nothing else.
      punctuated = new_page.map { |spec| spec.merge(name: "#{spec[:name].gsub(' ', '  ')}!") }
      second = ingest(punctuated, ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(5)
      expect(identity_by_file(second)).to eq(identity_by_file(first))
      # Each file's row is held under ITS OWN text — the presented spelling now, because a
      # normalisation-equivalent match re-points the row it matched (see "a description that drifted
      # only in punctuation"). Asserted on run ONE's rows, which the line above pins as the same rows:
      # run 1's identities holding run 2's spellings is the stronger statement and the new truth. A
      # page paired one place out puts a NEIGHBOUR's name here, which is the whole failure this
      # example exists to catch, and it catches it either way.
      expect(identity_by_file(first)).to eq(punctuated.to_h { |spec| [spec[:file_path], spec[:name]] })
    end

    it "contains a failed page to the row that caused it, rather than stamping all five" do
      # **SPGD-367 through a batch, which is the whole risk of batching this call.** A request fails
      # as a request: the provider cannot say WHICH input it refused, because one unembeddable text
      # and a dropped connection arrive identically. Reading that as "the page failed" would stamp
      # 20,000 rows for one bad one and undo the guarantee that one unembeddable example does not
      # abandon the other 19,999 — so the page falls back to asking one text at a time and each text
      # fails, or does not, on its own.
      poison = new_page.first[:name]
      provider = batching_provider
      provider.define_singleton_method(:embed_many) do |texts|
        @batches = batches + 1
        raise EmbeddingGenerator::Error, "cannot embed the page" if texts.include?(poison)

        texts.map { |text| EmbeddingGenerator::LocalProvider.call(text) }
      end
      provider.define_singleton_method(:call) do |text|
        @calls = calls + 1
        raise EmbeddingGenerator::Error, "cannot embed #{text}" if text == poison

        EmbeddingGenerator::LocalProvider.call(text)
      end

      run = record(new_page, ci_run_id: "run-1")
      EmbeddingGenerator.provider = provider
      described_class.resolve(run)

      # Four rows resolved on the fallback, and the fifth left exactly as a per-row failure leaves
      # it: unresolved, stamped, and retryable by the cross-run sweep.
      expect(repository.spec_identities.pluck(:text)).to match_array(new_page.drop(1).map { |spec| spec[:name] })
      failed = run.spec_observations.embed_failed
      expect(failed.pluck(:name)).to eq([poison])
      expect(failed.sole.embed_failure_count).to eq(1)
      # What the containment COSTS, stated rather than left to be discovered: one wasted request,
      # then the five per-text asks that were the price before this slice.
      expect(provider.batches).to eq(1)
      expect(provider.calls).to eq(5)
    end
  end

  describe "what a page of changed text costs the SECOND time this deployment sees it" do
    # The complement of every group above, and the last of the three cost levers `SPGD-72` names.
    #
    # "Changed" is answered by `#identical_text`, which reads `#digest_index`, which is built from
    # **`@repository.spec_identities`**. So the question that shortcut can answer is *"is this text
    # on one of THIS repository's identity rows"* — and the set that misses it is strictly wider
    # than the set this deployment has never embedded. Two things live in that gap and both are
    # billed today: another repository's copy of the same string, and this repository's own text
    # from before a rename moved the row out from under it. `EmbeddingCacheEntry` is keyed
    # `(provider_fingerprint, text_digest)` with no repository in it, so both become hits.
    #
    # These examples also discharge the substrate criterion by simply running: the cache is an
    # ActiveRecord table in the primary database, so it works here with no special-casing, no
    # `cache_store` change and no second database. A `Rails.cache` implementation could not have
    # been tested at all — `config/environments/test.rb` sets `:null_store` — which is why it is
    # not the substrate.

    # `batching_provider` plus the one thing the cache turns on: a published fingerprint.
    #
    # A separate instrument rather than a `fingerprint` bolted onto that one, because that one is
    # the control. Every other embedding example in this suite — and the whole rest of the suite
    # via `spec/support/embedding_generator.rb` — runs on a provider that publishes NO fingerprint
    # and is therefore uncached, which is what keeps those examples measuring what they always
    # measured. Adding the key there would have quietly moved 186 examples onto a new path.
    #
    # `call`, `embed_many` and `normalize` all delegate to `LocalProvider` for the reason
    # `batching_provider` states: an instrument must not change the path it measures.
    let(:caching_provider) do
      Class.new do
        class << self
          attr_writer :fingerprint

          def fingerprint = @fingerprint ||= "test-provider:v1"
          def calls = @calls ||= 0
          def batches = @batches ||= 0
          def batched = @batched ||= []

          def call(text)
            @calls = calls + 1
            EmbeddingGenerator::LocalProvider.call(text)
          end

          def embed_many(texts)
            @batches = batches + 1
            batched.concat(texts)
            texts.map { |text| EmbeddingGenerator::LocalProvider.call(text) }
          end

          def normalize(text) = EmbeddingGenerator::LocalProvider.normalize(text)
        end
      end
    end

    # The control: the same instrument with the fingerprint withheld. What every other embedding
    # example in this file runs on, and what the whole suite runs on via
    # `spec/support/embedding_generator.rb` — kept here so the "no fingerprint means no caching"
    # example measures the difference against a provider identical in every other respect.
    let(:uncached_provider) do
      Class.new do
        class << self
          def batches = @batches ||= 0

          def call(text) = EmbeddingGenerator::LocalProvider.call(text)

          def embed_many(texts)
            @batches = batches + 1
            texts.map { |text| EmbeddingGenerator::LocalProvider.call(text) }
          end

          def normalize(text) = EmbeddingGenerator::LocalProvider.normalize(text)
        end
      end
    end

    # A second tenant, so that "this deployment has embedded it" can be demonstrated without
    # "this repository has an identity row for it" also being true — which is the only way to show
    # the cache reaching past what `#digest_index` can answer.
    let(:other_repository) do
      create_repository(user: create_user(github_uid: "3003", github_handle: "second-tenant"),
                        github_full_name: "acme/second-service")
    end

    # Which identity each run's row landed on, named by the text that identity is held under — the
    # pairing itself, rather than a count that a shifted pairing would also satisfy.
    def identity_by_file(run)
      run.spec_observations.includes(:spec_identity).to_h { |row| [row.file_path, row.spec_identity&.text] }
    end

    # `ingest`/`record` are bound to the `repository` let; these are the same two steps against
    # whichever tenant an example names.
    def ingest_into(target, specs, ci_run_id:)
      payload = Ingest::Payload.new(ingest_payload(specs: specs, ci_run_id: ci_run_id).deep_stringify_keys)
      raise "payload invalid: #{payload.errors.inspect}" unless payload.valid?

      run = Ingest::RunRecorder.record(target, payload.test_run_attributes,
                                       shard_id: payload.shard_id, specs: payload.specs)
      described_class.resolve(run)
      run
    end

    # Five tests, each lexically distinct from the others so nothing here is resolved by a
    # similarity coincidence — the same shape `new_page` uses in the group above.
    def shared_page
      ["Session#create rejects a bad password",
       "Payment#refund restores the balance",
       "Token#expire revokes the session",
       "Upload#scan rejects an oversized file",
       "Search#query paginates the results"].each_with_index.map do |name, index|
        unannotated_spec(file_path: "spec/models/b#{index}_spec.rb", line_number: index + 1, name: name)
      end
    end

    # Statements this deployment issued against the cache table, in the order it issued them.
    # Every statement of the pass that names this table, whatever issued it.
    #
    # ⚠️ **THREE rules write to `embedding_cache_entries` and only two of them are caching.** The
    # read (`\ASELECT`) and the write (`\AINSERT … ON CONFLICT`) are the cache; the `\ADELETE` is
    # `Ingest::EmbeddingCachePruner` enforcing the retention window against the disk, which is a
    # different rule on a different trigger — it is not gated on the fingerprint, it is issued per
    # PASS rather than per page, and its own bound is graded in
    # `spec/services/ingest/embedding_cache_pruner_spec.rb`.
    #
    # ⚠️ **Per pass is not the same as ONCE per pass.** The pruner issues at most one DELETE per
    # batch, up to `Ingest::EmbeddingCachePruner::MAX_BATCHES_PER_RESOLVE`, breaking early on a
    # short batch. These examples see exactly one because they run against an EMPTY cache table, so
    # the first batch comes back short — not because the code guarantees one. An example here that
    # pinned a DELETE count would be pinning that fixture state, not the class's contract.
    #
    # So the examples below classify POSITIVELY by which rule issued the statement and pin the total
    # beside the parts, rather than folding the prune into a caching figure or filtering it out of
    # one. Absorbing it would leave a per-page caching count that could double while the prune's
    # dropped and still read green; filtering it out would leave a statement no example counts. An
    # unclassified statement belongs to no bucket and is caught by the total.
    #
    # `\A`-anchored, and that anchor is load-bearing rather than tidy: the prune's statement is
    # `DELETE … WHERE id IN (SELECT … LIMIT n)`, so an unanchored `/SELECT/` counts it as a read.
    def cache_statements(&) = executed_sql(&).grep(/embedding_cache_entries/i)

    it "asks the provider NOTHING for a page another repository has already paid to embed" do
      # **The slice, stated as the figure it moves.** These five texts are new to
      # `other_repository` in every sense `#digest_index` can see: it has no identity rows at all,
      # so the digest equality misses all five and every one of them would have been embedded.
      # They are not new to the DEPLOYMENT, and that is the distinction this table exists to draw.
      EmbeddingGenerator.provider = caching_provider
      ingest(shared_page, ci_run_id: "run-1")

      expect(caching_provider.batches).to eq(1) # the premise: the first tenant really did pay.

      ingest_into(other_repository, shared_page, ci_run_id: "run-2")

      # Zero REQUESTS, by either entry point — a cache that fell through to `.call` on the side
      # would be the same bill with an extra table.
      expect(caching_provider.batches).to eq(1)
      expect(caching_provider.calls).to eq(0)
      expect(caching_provider.batched.size).to eq(5)

      # And the resolve is a real one, not a page that was skipped: the second tenant ends with its
      # own five identities, built from vectors it never asked for.
      expect(other_repository.spec_identities.count).to eq(5)
      expect(other_repository.spec_identities.pluck(:text)).to match_array(shared_page.pluck(:name))
    end

    it "asks nothing again for text THIS repository's rows no longer hold" do
      # The second half of the gap, and the one that needs no second tenant.
      #
      # **A re-point is what actually moves a text out from under `#digest_index`, and a rename is
      # not.** `spec_identities` rows are never pruned, so a test renamed by SUFFIX leaves its old
      # row standing and the old text stays answerable by the digest equality forever — an example
      # built that way would embed nothing on run 3 whether or not this cache existed, and would
      # pass with the cache read deleted. What genuinely removes the digest is the punctuation-drift
      # re-point: run 2's spelling is normalisation-equivalent to run 1's, so `#resight` re-points
      # the row ONTO the new spelling (see "a description that drifted only in punctuation") and the
      # repository now holds no row under the original digest at all.
      #
      # So run 3 presents text this repository cannot answer for and this DEPLOYMENT bought on run
      # 1. Today that is five vectors paid for twice.
      EmbeddingGenerator.provider = caching_provider
      ingest(shared_page, ci_run_id: "run-1")
      drifted = shared_page.map { |spec| spec.merge(name: "#{spec[:name].gsub(' ', '  ')}!") }
      ingest(drifted, ci_run_id: "run-2")

      # The premise, pinned rather than trusted: the originals really are gone from this
      # repository's rows, so run 3 cannot be answered by the digest equality.
      expect(repository.spec_identities.count).to eq(5)
      expect(repository.spec_identities.pluck(:text)).to match_array(drifted.pluck(:name))

      asked_before = caching_provider.batched.size
      ingest(shared_page, ci_run_id: "run-3")

      expect(caching_provider.batched.size).to eq(asked_before)
      expect(repository.spec_identities.count).to eq(5)
    end

    it "buys nothing at all when the provider publishes no fingerprint" do
      # **The conservative default, which is what the whole existing suite runs on.** A provider
      # that will not say what it is gets no caching rather than a guessed key — the alternative
      # would attach a vector from one model to a text embedded by another, silently. Asserted as
      # the absence of both statements, so it stays true if the table's shape ever changes.
      EmbeddingGenerator.provider = uncached_provider # publishes no `fingerprint`

      statements = cache_statements { ingest(shared_page, ci_run_id: "run-1") }

      # Neither CACHING statement is issued. The prune's `DELETE` is on this table and is
      # deliberately outside this claim: an expired row is expired whoever wrote it, so reclaiming
      # it must not depend on the current provider being willing to say what it is — see
      # "prunes even though this provider publishes no fingerprint and the cache is inert".
      expect(statements.grep(/\ASELECT|\AINSERT/i)).to be_empty
      expect(statements.grep(/\ADELETE/i).size).to eq(1)
      expect(EmbeddingCacheEntry.count).to eq(0)
      # And the page behaves exactly as it did before this slice: one request, five texts.
      expect(uncached_provider.batches).to eq(1)
      expect(repository.spec_identities.count).to eq(5)
    end

    describe "when the provider fingerprint moves" do
      it "re-embeds the page rather than serving vectors the old model produced" do
        # **Unreadable rather than stale, which is the difference between a cache and a bug.** A
        # `text-embedding-3-small` vector handed to a deployment now running `-3-large` is a
        # perfectly valid vector of the wrong function, and nothing downstream could ever notice:
        # `#nearest` would rank it, `EmbeddingGenerator.validate` would pass it, and the identity it
        # produced would look exactly like a correct one. So the model is IN the key, and a key that
        # moved cannot be hit.
        EmbeddingGenerator.provider = caching_provider
        ingest(shared_page, ci_run_id: "run-1")
        expect(EmbeddingCacheEntry.count).to eq(5)

        caching_provider.fingerprint = "test-provider:v2"
        ingest_into(other_repository, shared_page, ci_run_id: "run-2")

        # Asked in full, exactly as if the cache were empty.
        expect(caching_provider.batches).to eq(2)
        expect(caching_provider.batched.size).to eq(10)
        expect(other_repository.spec_identities.count).to eq(5)
      end

      it "leaves the old entries in place, unreadable, rather than deleting them" do
        # The distinction the sentence above turns on, asserted rather than implied. Nothing sweeps
        # on a fingerprint change: the old rows are simply unreachable by any key the deployment
        # now asks with. That matters because a fingerprint can move BACK — an environment variable
        # set by mistake and reverted an hour later — and a delete would have made that hour cost a
        # full re-embed of every repository. It is also what makes the change atomic and free:
        # there is no migration of entries, no sweep to schedule, and no window in which the cache
        # is half one model and half another.
        EmbeddingGenerator.provider = caching_provider
        ingest(shared_page, ci_run_id: "run-1")

        caching_provider.fingerprint = "test-provider:v2"
        ingest_into(other_repository, shared_page, ci_run_id: "run-2")

        expect(EmbeddingCacheEntry.where(provider_fingerprint: "test-provider:v1").count).to eq(5)
        expect(EmbeddingCacheEntry.where(provider_fingerprint: "test-provider:v2").count).to eq(5)

        # And reverting reaches the originals again, at no cost — the reason they were kept.
        caching_provider.fingerprint = "test-provider:v1"
        asked_before = caching_provider.batched.size
        third = create_repository(user: create_user(github_uid: "4004", github_handle: "third-tenant"),
                                  github_full_name: "acme/third-service")
        ingest_into(third, shared_page, ci_run_id: "run-3")

        expect(caching_provider.batched.size).to eq(asked_before)
        expect(third.spec_identities.count).to eq(5)
      end
    end

    describe "the cache is read and written ONCE PER PAGE" do
      # The same bound `SPGD-382`, `-395` and `-406` assert for the three statements before it, and
      # for the same reason: a lookup driven from `#embedding_for` would be correct, would pass
      # every example above, and would be a round trip per row — which on the 20,000-example suite
      # this class is designed around is the cost the whole lineage exists to remove. Only a query
      # count can tell the two apart.

      it "reads once and writes once for a page of five texts it has never seen" do
        EmbeddingGenerator.provider = caching_provider
        run = record(shared_page, ci_run_id: "run-1")

        statements = cache_statements { described_class.resolve(run) }

        expect(statements.grep(/\ASELECT/i).size).to eq(1)
        expect(statements.grep(/\AINSERT/i).size).to eq(1)
        # The prune, attributed rather than absorbed into either caching figure: once per PASS,
        # where the two above are once per page.
        expect(statements.grep(/\ADELETE/i).size).to eq(1)
        expect(statements.size).to eq(3)
      end

      it "reads once and writes NOTHING for a page that hits on every text" do
        # The write is skipped entirely rather than issued empty: a page that bought nothing has
        # nothing to remember, and `upsert_all` of an empty list is a statement with no rows.
        EmbeddingGenerator.provider = caching_provider
        ingest(shared_page, ci_run_id: "run-1")
        run = Ingest::Payload.new(ingest_payload(specs: shared_page, ci_run_id: "run-2").deep_stringify_keys)
                             .then do |payload|
          Ingest::RunRecorder.record(other_repository, payload.test_run_attributes,
                                     shard_id: payload.shard_id, specs: payload.specs)
        end

        statements = cache_statements { described_class.resolve(run) }

        expect(statements.grep(/\ASELECT/i).size).to eq(1)
        expect(statements.grep(/\AINSERT/i)).to be_empty
        expect(statements.grep(/\ADELETE/i).size).to eq(1)
        expect(statements.size).to eq(2)
      end

      it "asks nothing at all when the page carries no text to look up" do
        # The counterpart of `#digest_index`'s "still costs nothing when a page carries no text at
        # all", and asserted the same way — as the ABSENCE of the statement rather than the
        # presence of a guard, so it stays honest if the guard is ever replaced by relying on
        # `where(text_digest: [])` compiling to `1=0`.
        #
        # Both CACHING statements, and not the pass's prune: that one is issued whatever the page
        # carries, because what is past the retention window has nothing to do with what this page
        # is asking for.
        EmbeddingGenerator.provider = caching_provider
        run = record(shared_page, ci_run_id: "run-1")
        run.spec_observations.update_all(name: nil, intent_entity: nil, intent_action: nil,
                                         intent_behavior: nil)

        statements = cache_statements { described_class.resolve(run) }

        expect(statements.grep(/\ASELECT|\AINSERT/i)).to be_empty
        # Pinned beside the parts, like the sibling above: the prune is the only statement left, so
        # an unclassified one cannot hide behind the grep. One rather than up to
        # `MAX_BATCHES_PER_RESOLVE` because the cache table is empty here, which is fixture state
        # and not a guarantee — see the `cache_statements` doc.
        expect(statements.size).to eq(1)
      end
    end

    describe "a cache failure costs the ingest nothing but money" do
      # **Criterion 3, and the property that makes this table safe to add at all.** A cache is not
      # allowed to become load-bearing: the vector is reproducible by asking the provider, which is
      # exactly what a miss does, so every failure mode here has the same correct answer and it is
      # not an incident.
      #
      # The rescue in `#cached_embeddings` is deliberately WIDE IN CLASS — these failures are not
      # `EmbeddingGenerator::Error`, they are ActiveRecord's — and NARROW IN SCOPE, wrapping the
      # cache call and nothing else. It does not widen what `#page_embeddings` may swallow; the
      # provider request inside it still fails exactly as loudly as it did.

      it "embeds the page normally when the READ fails" do
        # `StatementInvalid` specifically, because the realistic instance of this is a deployment
        # that shipped the code before running the migration. That must degrade to the previous
        # release's behaviour, not fail every ingest.
        EmbeddingGenerator.provider = caching_provider
        allow(EmbeddingCacheEntry).to receive(:vectors_for)
          .and_raise(ActiveRecord::StatementInvalid, 'relation "embedding_cache_entries" does not exist')

        expect { ingest(shared_page, ci_run_id: "run-1") }.not_to raise_error

        expect(caching_provider.batches).to eq(1)
        expect(caching_provider.batched.size).to eq(5)
        expect(repository.spec_identities.count).to eq(5)
      end

      it "resolves the page normally when the WRITE fails" do
        # The rows are already resolved by the time the write is attempted, so the only thing lost
        # is that the next page pays again.
        EmbeddingGenerator.provider = caching_provider
        allow(EmbeddingCacheEntry).to receive(:store).and_raise(ActiveRecord::StatementInvalid, "disk full")

        run = nil
        expect { run = ingest(shared_page, ci_run_id: "run-1") }.not_to raise_error

        expect(repository.spec_identities.count).to eq(5)
        expect(run.spec_observations.unresolved).to be_empty
      end

      it "embeds the page normally when the provider cannot say what its fingerprint is" do
        # A provider that raises where it should have answered is the same situation as one that
        # declines to answer, and it costs the ingest the same nothing.
        EmbeddingGenerator.provider = caching_provider
        allow(caching_provider).to receive(:fingerprint).and_raise(RuntimeError, "config unreadable")

        expect { ingest(shared_page, ci_run_id: "run-1") }.not_to raise_error

        expect(caching_provider.batches).to eq(1)
        expect(repository.spec_identities.count).to eq(5)
        expect(EmbeddingCacheEntry.count).to eq(0)
      end

      it "still lets a PROVIDER failure behave exactly as it did" do
        # The other half of "narrow in scope", and the regression the wide rescue could have caused.
        # `EmbeddingGenerator::Error` must still reach `#embed_page`'s fallback and still stamp the
        # one row that caused it — a cache rescue that had been placed around the provider call
        # would have swallowed it and silently resolved nothing.
        poison = shared_page.first[:name]
        provider = caching_provider
        provider.define_singleton_method(:embed_many) do |texts|
          @batches = batches + 1
          raise EmbeddingGenerator::Error, "cannot embed the page" if texts.include?(poison)

          texts.map { |text| EmbeddingGenerator::LocalProvider.call(text) }
        end
        provider.define_singleton_method(:call) do |text|
          @calls = calls + 1
          raise EmbeddingGenerator::Error, "cannot embed #{text}" if text == poison

          EmbeddingGenerator::LocalProvider.call(text)
        end

        run = record(shared_page, ci_run_id: "run-1")
        EmbeddingGenerator.provider = provider
        described_class.resolve(run)

        failed = run.spec_observations.embed_failed
        expect(failed.pluck(:name)).to eq([poison])
        expect(provider.batches).to eq(1)
        expect(provider.calls).to eq(5)
        # And the four that DID succeed on the fallback are cached, while the refused one is not —
        # a nil is the absence of an answer, not an answer to remember.
        expect(EmbeddingCacheEntry.count).to eq(4)
        expect(EmbeddingCacheEntry.where(text_digest: SpecIdentity.digest_for(poison))).to be_empty
      end
    end

    it "gives a cached row the same identity a freshly embedded row gets" do
      # **The correctness backstop for every count above.** Each of those asserts that a request was
      # not made; none of them would notice if the vector served in its place were the wrong one —
      # a mis-keyed cache returns a valid vector and the resolve completes, silently pairing tests
      # with each other's histories. So this pairs the two paths against each other: the second
      # tenant, resolved entirely from cache, must land on the same text-to-file mapping the first
      # tenant got from the provider.
      EmbeddingGenerator.provider = caching_provider
      first = ingest(shared_page, ci_run_id: "run-1")
      second = ingest_into(other_repository, shared_page, ci_run_id: "run-2")

      expect(identity_by_file(second)).to eq(identity_by_file(first))
      expect(identity_by_file(second).values).to match_array(shared_page.pluck(:name))

      # And the vectors themselves agree with what the provider would have returned, within the
      # four-byte float the column stores — the same tolerance the order-contract example uses, and
      # for the same reason.
      other_repository.spec_identities.each do |identity|
        own = EmbeddingGenerator::LocalProvider.call(identity.text)
        drift = own.zip(identity.embedding.to_a).map { |mine, stored| (mine - stored).abs }.max

        expect(drift).to be < 1e-5
      end
    end
  end

  describe "the tenant boundary" do
    it "never resolves a test onto another repository's identity" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other-service")
      create_spec_identity(repository: other, text: "Cart adds an item to the cart")

      ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(1)
      expect(other.spec_identities.count).to eq(1)
      expect(repository.spec_identities.sole.id).not_to eq(other.spec_identities.sole.id)
    end
  end

  describe "two ingests that both miss on the same test" do
    # The race the conflict key exists for, and the ordinary case rather than a corner: every shard
    # of a repository's first run resolves for the first time, so two of them reaching the same text
    # and both finding nothing is what normally happens.
    #
    # Reproduced the way `spec/support/uniqueness_race.rb` describes the shape — the loser's lookups
    # cannot see a winner that has not committed, so they return nothing and it goes to insert while
    # the row is already there. That is stubbed at the two methods whose answer the race changes —
    # `#identical_text`, the digest equality, and `#nearest`, the similarity lookup — rather than by
    # racing threads a transactional example cannot run; everything after them (the upsert, the
    # conflict, the link) is the real code path. Without the `ON CONFLICT` clause these examples
    # raise `ActiveRecord::RecordNotUnique` rather than merely counting wrong.
    #
    # BOTH stubs are load-bearing, and the second one is why: these fixtures build the winner with
    # the SAME text the observation carries, so the digest lookup would find it, `#identity_for`
    # would return at the fast path, and every example below would stay green while testing the
    # re-sighting path instead of the conflict path it names. That is also what genuinely happens to
    # a loser — an uncommitted winner is invisible to an equality exactly as it is to an index scan
    # — so stubbing both is the faithful reproduction, not a workaround for one.
    #
    # `#identical_text` is STILL the right seam for the first stub now that the digest question is
    # answered a page at a time: the query moved to `#digest_index`, the DECISION did not, and this
    # is the method that makes it for one row. Stubbing the page builder instead would be stubbing
    # further from what the loser actually experiences, and dropping the stub because the examples
    # stay green without it would silently retire the race coverage — the winner IS committed before
    # `#resolve` runs here, so the page's map finds it just as the per-row `find_by` did.
    def resolve_as_the_loser(run)
      resolver = described_class.new(run)
      allow(resolver).to receive(:identical_text).and_return(nil)
      allow(resolver).to receive(:nearest).and_return(nil)
      resolver.resolve
    end

    it "converges on one row instead of raising or duplicating" do
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart",
                                    file_path: "spec/models/cart_spec.rb", line_number: 5)
      run = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 40,
                                     name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      expect { resolve_as_the_loser(run) }.not_to change(SpecIdentity, :count)

      expect(SpecIdentity.sole.id).to eq(winner.id)
    end

    it "lands the loser's sighting on the winner and hands it the same link" do
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart",
                                    file_path: "spec/models/cart_spec.rb", line_number: 5)
      run = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 40,
                                     name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      resolve_as_the_loser(run)

      expect(winner.reload.line_number).to eq(40)
      expect(winner.last_seen_test_run_id).to eq(run.id)
      expect(run.spec_observations.sole.spec_identity_id).to eq(winner.id)
    end

    it "refuses a losing sighting from a run older than the one the winner already names" do
      # The conflict branch is a re-sighting, so it is monotonic for the reason `#resight` is. And it
      # is reachable outside a race: `#nearest` is an approximate index lookup, so an under-recalled
      # miss on text that already HAS an identity arrives here rather than there — carrying, if the
      # row came out of the cross-run backlog, a run older than the one the identity already names.
      older = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                       name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      newer = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                       name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart",
                                    file_path: "spec/models/cart_spec.rb", line_number: 90,
                                    last_seen_test_run_id: newer.id)

      resolve_as_the_loser(older)

      expect(winner.reload.location).to eq("spec/models/cart_spec.rb:90")
      expect(winner.last_seen_test_run_id).to eq(newer.id)
      # Refused the sighting, not the row: the older observation still gets its link.
      expect(older.spec_observations.sole.spec_identity_id).to eq(winner.id)
    end

    it "leaves the winner's own identity untouched — a conflict re-sights, it does not overwrite" do
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart")
      # Read back from the column rather than held from the insert: pgvector stores float4, so the
      # stored vector is not the float64 array that was written and comparing the two would fail on
      # rounding rather than on anything this example is about.
      before = winner.reload.slice(:created_at, :text, :text_digest, :signal_source, :embedding)
      run = record([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      resolve_as_the_loser(run)

      expect(winner.reload.slice(*before.keys)).to eq(before)
    end
  end

  describe "an example the provider cannot embed" do
    # The provider, down and back. `reset` on the proxy rather than a second `allow`, so the "back"
    # state is the real `LocalProvider` this group installed and not another stub.
    def provider_down
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
    end

    def provider_back = RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

    # A LATER ingest of this repository, carrying a test that has nothing to do with the failed one.
    # This is the production trigger under test everywhere below: nothing it contains can create the
    # failed row's identity, so if that row resolves, the cross-run sweep is what resolved it.
    def unrelated_ingest(ci_run_id:)
      ingest([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                               name: "User#save rejects a duplicate email")], ci_run_id: ci_run_id)
    end

    it "leaves the observation unresolved rather than writing an identity nothing can find again" do
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")

      run = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(0)
      expect(run.spec_observations.sole.spec_identity_id).to be_nil
    end

    it "does not abandon the rest of the run" do
      texts = ["Cart adds an item to the cart", "User#save rejects a duplicate email"]
      allow(EmbeddingGenerator).to receive(:call).and_wrap_original do |original, text|
        raise EmbeddingGenerator::Error, "provider down" if text == texts.first

        original.call(text)
      end

      run = ingest(texts.each_with_index.map do |name, index|
        unannotated_spec(file_path: "spec/a_spec.rb", line_number: index + 1, name: name)
      end, ci_run_id: "run-1")

      expect(repository.spec_identities.pluck(:text)).to eq([texts.last])
      expect(run.spec_observations.where.not(spec_identity_id: nil).count).to eq(1)
    end

    it "records that the embedding was attempted and failed, rather than leaving a bare NULL" do
      provider_down

      run = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      observation = run.spec_observations.sole
      expect(observation.embed_failed_at).to be_present
      expect(observation.embed_failure_count).to eq(1)
    end

    it "tells a failed embed apart from a row with nothing to embed and from one not yet attempted" do
      # The three populations one NULL `spec_identity_id` used to pool, built through the real path
      # in the order that keeps each in its own state. The signalless row's name is nulled by hand
      # because `Ingest::Payload#validate_name` refuses that shape today — which is exactly what
      # `IdentityResolver#identity_for` says its `:none` branch is for, a row written before the
      # validator existed — and it goes FIRST so no later sweep can be what left it alone.
      signalless = record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                            name: "Order#checkout rejects an expired card")],
                          ci_run_id: "run-1")
      signalless.spec_observations.sole.update_columns(name: nil)
      described_class.resolve(signalless)

      provider_down
      failed = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      provider_back

      # Recorded and not resolved: the state the endpoint answers `202` from, and the state every
      # row passes through. It is transient only if the job arrives — nothing guarantees that, which
      # is why it is a QUERYABLE state now rather than a NULL nobody was looking at.
      unattempted = record([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                             name: "User#save rejects a duplicate email")],
                           ci_run_id: "run-3")

      expect(repository.spec_observations.unresolved.pluck(:test_run_id))
        .to contain_exactly(signalless.id, failed.id, unattempted.id)
      # One predicate, and it picks the recoverable one out of the three.
      expect(repository.spec_observations.embed_failed.pluck(:test_run_id)).to eq([failed.id])
      expect(repository.spec_observations.embed_retryable.pluck(:test_run_id)).to eq([failed.id])
      # And its complement picks the other two — which is all one predicate over `embed_failed_at`
      # can do. Which of THOSE two a row is stays `Ingest::SpecSignal`'s question, asked one row at
      # a time by `#identity_for`, because a second implementation of the intent-or-name precedence
      # in SQL is the drift `SpecObservation#signal` exists to prevent.
      expect(repository.spec_observations.unresolved.embed_unattempted.pluck(:test_run_id))
        .to contain_exactly(signalless.id, unattempted.id)
      # Neither of them is in a BACKLOG yet, and for the same reason: both were created just now, so
      # `EMBED_ATTEMPT_GRACE` still reads them as rows a live job may be on its way to. "Nothing is
      # wrong; wait" is the correct answer here — the defect was that it stayed the answer forever.
      expect(repository.spec_observations.embed_unattempted_retryable).to be_empty
    end

    it "resolves it on the next run once the provider is back — nothing is permanently lost" do
      provider_down
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      provider_back

      unrelated_ingest(ci_run_id: "run-2")

      # No `described_class.resolve` by hand anywhere in this example. That line used to be here and
      # was the only thing in the world that did this; the ingest above is now what does it.
      identity = first.spec_observations.sole.reload.spec_identity
      expect(identity.text).to eq("Cart adds an item to the cart")
      # And the rescued row's own run is what the identity says last saw the test, not the run whose
      # ingest happened to perform the rescue.
      expect(identity.last_seen_test_run_id).to eq(first.id)
    end

    it "does not let a rescued older run overwrite a newer run's last known path" do
      provider_down
      ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                               name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      provider_back

      second = ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-2")

      # The backlog row and the newer run's own row, in one pass, resolved in that order. The
      # falsifier for `SpecIdentity::SIGHTING_NOT_OLDER` on the half of the work list where the
      # newer sighting arrives second.
      identity = repository.spec_identities.sole
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
    end

    it "keeps the newest run's path when an outage spanning two runs is rescued in one sweep" do
      # The shape the whole slice exists to recover from — a provider down across MORE than one
      # ingest — and the case iteration order alone never covered. Both rows are failed, both are in
      # the backlog, and they are walked least-tried-first: run-1's row was already swept once by
      # run-2's ingest, so it carries a HIGHER failure count than run-2's own row and is therefore
      # walked LAST. Ordering cannot fix that without giving up the fairness key; the guard makes it
      # not matter.
      provider_down
      first = ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                       name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      second = ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      provider_back

      # Pin the premise rather than trusting it: this example is only about the newest-last order if
      # the older row really does sort after the newer one.
      expect(repository.spec_observations.embed_retryable.order(:embed_failure_count).pluck(:test_run_id))
        .to eq([second.id, first.id])

      unrelated_ingest(ci_run_id: "run-3")

      identity = repository.spec_identities.find_by!(text: "Cart adds an item to the cart")
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
      # Both rows are still rescued — refusing the older sighting is not refusing the older row.
      expect(first.spec_observations.sole.reload.spec_identity_id).to eq(identity.id)
      expect(second.spec_observations.sole.reload.spec_identity_id).to eq(identity.id)
    end

    it "keeps the first failure's timestamp, so re-attempting cannot push the window forward" do
      provider_down
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      stamped = first.spec_observations.sole.embed_failed_at

      # Still down: the sweep re-attempts the row and fails again.
      unrelated_ingest(ci_run_id: "run-2")

      observation = first.spec_observations.sole.reload
      expect(observation.embed_failed_at).to eq(stamped)
      expect(observation.embed_failure_count).to eq(2)
    end

    it "stops re-attempting a row once the window has closed on it" do
      provider_down
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      provider_back

      # `update_all` rather than a time-travel helper, the choice
      # spec/requests/api/v1/repository_latest_run_spec.rb states: assert the fact the fixture needs
      # — this row first failed longer ago than the window — rather than moving the clock underneath
      # everything else in the example.
      first.spec_observations.update_all(embed_failed_at: SpecObservation::EMBED_RETRY_WINDOW.ago - 1.second)

      unrelated_ingest(ci_run_id: "run-2")

      expect(first.spec_observations.sole.reload.spec_identity_id).to be_nil
      expect(repository.spec_observations.embed_retryable.count).to eq(0)
      # Given up on, and queryable as such: "we stopped trying" is not the same figure as "we are
      # still trying", which is the whole reason the bound is a scope and not a bare comparison.
      expect(repository.spec_observations.embed_abandoned.count).to eq(1)
    end

    it "caps how much of a backlog one ingest inherits, and drains the rest across later ones" do
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)
      provider_down
      first = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                       name: "Cart adds an item to the cart"),
                      unannotated_spec(file_path: "spec/a_spec.rb", line_number: 2,
                                       name: "Invoice#finalize locks the line items")],
                     ci_run_id: "run-1")
      provider_back

      unrelated_ingest(ci_run_id: "run-2")
      expect(first.spec_observations.unresolved.count).to eq(1)

      unrelated_ingest(ci_run_id: "run-3")
      expect(first.spec_observations.unresolved.count).to eq(0)
    end
  end

  describe "a resolve that died before it reached the rest of the run" do
    # The failure this whole group is about, reproduced at the place it actually happens.
    # `IdentityResolver`'s loop has exactly one rescue and it is around the embed call, scoped to
    # `EmbeddingGenerator::Error`. An `ActiveRecord::StatementInvalid` out of the ANN lookup — a
    # dropped connection, a database blip, the tail of a deploy — propagates out of `#resolve`
    # instead, and `ApplicationJob` declares no `retry_on` to catch it. Rows already claimed keep
    # their identity, because `#claim` commits per row; rows not yet reached are left unresolved and
    # UNSTAMPED, because `#record_resolve_failure` only runs where the row was actually reached.
    #
    # Stubbed at `#nearest` rather than at `EmbeddingGenerator`, so the error class is one the
    # rescue genuinely does not cover. Raising a non-`EmbeddingGenerator::Error` from the provider
    # would reach the same state through a path the provider contract says cannot happen.
    def die_after(run, rows:)
      resolver = described_class.new(run)
      reached = 0
      allow(resolver).to receive(:nearest).and_wrap_original do |original, *args|
        reached += 1
        raise ActiveRecord::StatementInvalid, "server closed the connection unexpectedly" if reached > rows

        original.call(*args)
      end

      expect { resolver.resolve }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # Put a row's wait far enough behind it that `EMBED_ATTEMPT_GRACE` no longer reads it as one a
    # live job may be on its way to. `update_all` rather than a time-travel helper, the choice
    # spec/requests/api/v1/repository_latest_run_spec.rb states and the window example above already
    # follows: assert the fact the fixture needs — this row has been waiting longer than the grace —
    # rather than moving the clock underneath everything else in the example.
    def strand(run, ago: SpecObservation::EMBED_ATTEMPT_GRACE + 1.minute)
      run.spec_observations.unresolved.update_all(created_at: ago.ago)
    end

    # A LATER ingest of this repository, under a DIFFERENT run. The production trigger under test:
    # the original run is never redelivered and its job is never re-enqueued, so if the stranded
    # rows resolve, the cross-run sweep is the only thing that can have resolved them.
    def later_ingest(specs = [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                               name: "User#save rejects a duplicate email")],
                     ci_run_id:)
      ingest(specs, ci_run_id: ci_run_id)
    end

    it "keeps the cause when the page's flush fails on the way out too" do
      # **The `ensure` must not cost the diagnosis it exists for.** `#resolve_page` flushes on every
      # exit so a page that dies keeps what it had already decided — but an `ensure` that raises
      # replaces the exception already propagating, and since the flush is now where this path's
      # database errors surface, the masking case is the likely one rather than an exotic one: a page
      # that died on `#nearest` and then met a deadlock in its flush would report the deadlock and
      # lose the cause.
      run = record(suite, ci_run_id: "run-1")
      resolver = described_class.new(run)
      allow(resolver).to receive(:nearest).and_raise(ActiveRecord::StatementInvalid,
                                                     "server closed the connection unexpectedly")
      flushes = 0
      allow(resolver).to receive(:flush_page).and_wrap_original do |original, *args|
        flushes += 1
        # The first flush is the (empty) backlog page, which is not the one under test — the failure
        # this example is about needs a page whose BODY has already raised.
        raise ActiveRecord::Deadlocked, "deadlock detected" if flushes > 1

        original.call(*args)
      end
      messages = []
      allow(Rails.logger).to receive(:error) { |message| messages << message }

      expect { resolver.resolve }.to raise_error(ActiveRecord::StatementInvalid, /server closed/)

      # Dropped, never swallowed: "the page failed twice" is a different event from either failure
      # alone, and the line that says so is the only place it is recorded.
      expect(messages.grep(/page flush failed with ActiveRecord::Deadlocked.*StatementInvalid/)).not_to be_empty
    end

    it "leaves the unreached rows unresolved with no stamp — the state nothing could describe" do
      run = record(suite, ci_run_id: "run-1")

      die_after(run, rows: 1)

      stranded = run.spec_observations.unresolved
      expect(stranded.count).to eq(2)
      # Not a failure, and nothing may read it as one: nothing was tried on these at all.
      expect(stranded.pluck(:embed_failed_at).uniq).to eq([nil])
      expect(stranded.pluck(:embed_failure_count).uniq).to eq([0])
      expect(repository.spec_observations.embed_failed).to be_empty
      expect(repository.spec_observations.embed_retryable).to be_empty
    end

    it "makes them findable once no live job could still be on its way to them" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)

      # Inside the grace they are indistinguishable from the rows of an ingest that landed a second
      # ago, and are deliberately left alone: "nothing is wrong; wait" is still the right answer.
      expect(repository.spec_observations.embed_unattempted_retryable).to be_empty

      strand(run)

      expect(repository.spec_observations.embed_unattempted_retryable.pluck(:test_run_id))
        .to eq([run.id, run.id])
    end

    it "resolves them on the next ingest of a different run, without redelivering the original" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)
      strand(run)

      # No `described_class.resolve(run)` by hand anywhere: nothing in production would ever call it
      # again for this run, which is precisely the defect. The ingest below is what does it.
      later_ingest(ci_run_id: "run-2")

      expect(run.spec_observations.unresolved).to be_empty
      expect(identity_texts).to contain_exactly(
        "Cart adds an item to the cart",
        "Invoice finalize locks the line items once the invoice is finalized",
        "User#save rejects a duplicate email"
      )
    end

    it "lands a stranded row on the identity the test already had, rather than starting a second" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)
      strand(run)

      # The rescuing ingest carries the SAME test as one of the stranded rows, so the two must come
      # away holding one identity between them — the semantic-identity rule, reached through the
      # sweep instead of through a run's own list.
      second = later_ingest(ci_run_id: "run-2")

      identity = second.spec_observations.sole.reload.spec_identity
      expect(identity.text).to eq("User#save rejects a duplicate email")
      expect(run.spec_observations.find_by(file_path: "spec/models/user_spec.rb").reload.spec_identity_id)
        .to eq(identity.id)
      expect(repository.spec_identities.where(text: identity.text).count).to eq(1)
    end

    it "does not let a rescued older run overwrite a newer run's last known path" do
      # `SIGHTING_NOT_OLDER` over the never-attempted half of the backlog, which is the half where
      # the stranded row is walked FIRST and the newer sighting therefore arrives second.
      run = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                     name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      die_after(run, rows: 0)
      strand(run)

      second = later_ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                              name: "Cart adds an item to the cart")],
                            ci_run_id: "run-2")

      identity = repository.spec_identities.sole
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
      # Refused the sighting, not the row: the stranded observation still gets its link.
      expect(run.spec_observations.sole.reload.spec_identity_id).to eq(identity.id)
    end

    it "never gives an identity to a row with nothing to embed, however many ingests sweep past it" do
      # The population the sweep now reads on every ingest and must go on doing nothing with. Its
      # name is nulled by hand because `Ingest::Payload#validate_name` refuses that shape today —
      # which is exactly why it is a frozen legacy set rather than a growing cost.
      run = record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                     name: "Order#checkout rejects an expired card")],
                   ci_run_id: "run-1")
      run.spec_observations.sole.update_columns(name: nil)
      described_class.resolve(run)
      strand(run)

      # It IS in the work list now — that is the change — and it costs no embedding, because
      # `#identity_for` returns before the embed for a signal that is not present.
      expect(repository.spec_observations.embed_unattempted_retryable.count).to eq(1)

      3.times { |index| later_ingest(ci_run_id: "sweep-#{index}") }

      expect(run.spec_observations.sole.reload.spec_identity_id).to be_nil
      # And still no stamp after three sweeps: a row with nothing to embed never reaches the
      # provider, so it can never come to look like a failure that somebody should act on.
      expect(run.spec_observations.sole.embed_failed_at).to be_nil
      expect(identity_texts).to eq(["User#save rejects a duplicate email"])
    end

    it "is not starved by the rows that can never leave the backlog" do
      # The reason this list is ordered NEWEST first while the failure backlog is ordered
      # least-tried first. A signalless row is swept forever and resolves never — it returns from
      # `#identity_for` before the embed, so it takes no stamp and no attempt count, and there is no
      # counter that could demote it. Oldest-first would park that population permanently at the
      # head of the list and no genuinely stranded row would ever be reached.
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)

      signalless = record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                            name: "Order#checkout rejects an expired card")],
                          ci_run_id: "run-1")
      signalless.spec_observations.sole.update_columns(name: nil)
      described_class.resolve(signalless)

      stranded = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                          name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      die_after(stranded, rows: 0)

      # The signalless row is the OLDER of the two, which is the only shape it can have in
      # production: `Ingest::Payload#validate_name` has refused that payload since before any row
      # written after it, so the population that cannot resolve is by construction the oldest one.
      # That is what makes newest-first a structural answer to starvation rather than a hopeful one.
      strand(signalless, ago: 3.hours)
      strand(stranded, ago: 2.hours)

      later_ingest(ci_run_id: "run-3")

      expect(stranded.spec_observations.sole.reload.spec_identity_id).to be_present
      expect(signalless.spec_observations.sole.reload.spec_identity_id).to be_nil
    end

    it "gives up on it once the window has closed, and leaves it queryable as such" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)
      strand(run, ago: SpecObservation::EMBED_RETRY_WINDOW + 1.second)

      later_ingest(ci_run_id: "run-2")

      expect(run.spec_observations.unresolved.count).to eq(2)
      expect(repository.spec_observations.embed_unattempted_retryable).to be_empty
      # "We stopped trying" is not the same figure as "we are still trying", which is the whole
      # reason the bound is a scope and not a bare comparison — `embed_abandoned`'s rule, applied to
      # the population that never carried a stamp to anchor it.
      expect(repository.spec_observations.embed_unattempted_abandoned.count).to eq(2)
    end

    # `RETRY_SWEEP_LIMIT` bounds what ONE JOB inherits from the deliveries before it, and
    # `#retry_backlog` spends that one allowance across two lists. It does so in two distinct
    # behaviours, and they need an example each, because the one below cannot reach the other:
    #
    # * The failures SATURATE the budget — nothing is left, so the never-attempted list is not
    #   queried at all (the early return).
    # * The failures fill it PARTIALLY — the never-attempted list is asked for the REMAINDER (the
    #   subtraction).
    #
    # The second is the arithmetic that actually enforces one budget, and it is the ordinary
    # production shape rather than the exotic one: a saturated failure backlog is the provider
    # outage, while a handful of failed rows beside a stranded backlog is the everyday state of a
    # repository that has lost a job. An example seeded at a limit of 1 can only ever certify the
    # first — "partial" does not exist there — so a `RETRY_SWEEP_LIMIT`-for-`remaining` mutant
    # survives it while turning one budget back into two.
    it "does not query the never-attempted list at all when the failures have taken the whole budget" do
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)

      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      failed = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

      stranded = record([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                          name: "Invoice#finalize locks the line items")],
                        ci_run_id: "run-2")
      strand(stranded)

      # One slot, and the failures take it — a row something has already tried and failed to rescue
      # has the stronger claim on a scarce one.
      later_ingest(ci_run_id: "run-3")
      expect(failed.spec_observations.unresolved).to be_empty
      expect(stranded.spec_observations.unresolved.count).to eq(1)

      # Drained across the ingest that follows, exactly as an over-cap failure backlog is.
      later_ingest(ci_run_id: "run-4")
      expect(stranded.spec_observations.unresolved).to be_empty
    end

    it "gives the never-attempted list only what the failures left, not a second full budget" do
      # The partial branch, and the one that pins the SUBTRACTION rather than the guard in front of
      # it. Three slots, one of them spent on a failure, three rows stranded: the sweep is entitled
      # to exactly two of them. Two independently capped lists would take all three here and the
      # example above would not notice, because at a limit of 1 the remainder is always zero.
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 3)

      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      failed = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

      # Three rows of one run, none of them reached: `die_after(rows: 0)` raises on the first ANN
      # lookup, so nothing is claimed and nothing is stamped — the whole run is stranded.
      stranded = record([
                          unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                           name: "Invoice#finalize locks the line items"),
                          unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                           name: "Order#checkout rejects an expired card"),
                          unannotated_spec(file_path: "spec/d_spec.rb", line_number: 4,
                                           name: "Session#destroy clears the remember token")
                        ], ci_run_id: "run-2")
      die_after(stranded, rows: 0)
      strand(stranded)

      later_ingest(ci_run_id: "run-3")

      # One slot to the failure, and the OTHER TWO — not another three — to the stranding.
      expect(failed.spec_observations.unresolved).to be_empty
      expect(stranded.spec_observations.unresolved.count).to eq(1)

      # And the row the budget refused is deferred rather than dropped: with the failure backlog now
      # empty, the next ingest has the whole allowance to spend and drains it.
      later_ingest(ci_run_id: "run-4")
      expect(stranded.spec_observations.unresolved).to be_empty
    end

    # The poison row. The group above is about a pass that DIED; this one is about the row that
    # killed it still being there on the next pass, and the one after that.
    #
    # `#resolve` walks the inherited backlog BEFORE this run's own list, and until `#claim_inherited`
    # existed a row that raised there ended the delivery before `@run`'s observations were reached at
    # all. A deterministic failure — a stored vector of the wrong dimension, a row whose text trips a
    # provider bug — fails identically on every attempt, and the backlog is re-read by every later
    # ingest of that repository, so one row left every subsequent run's observations unresolved and
    # UNSTAMPED: the exact population the sweep above exists to rescue, defeated by the one row that
    # kills the sweep.
    describe "when one inherited row raises every time anything reaches it" do
      # A row of an EARLIER run, in the backlog, that nothing can resolve. Built by the group's own
      # `die_after` + `strand` rather than by hand: it is a genuinely stranded row and it reaches the
      # sweep through `embed_unattempted_retryable`, which is how one actually gets there.
      def poisoned_backlog_row
        run = record([unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 7,
                                       name: "Order#checkout rejects an expired card")],
                     ci_run_id: "run-1")
        die_after(run, rows: 0)
        strand(run)
        run.spec_observations.sole
      end

      # A later ingest whose resolver this example holds. `record` then `resolve` is exactly what
      # `ingest` does; the two halves are split only because the stub has to be attached between
      # them, and `#resolve` is called by the example so the raise — or its absence — is the
      # assertion rather than a side effect.
      #
      # Poisoned at `#nearest`, the same production site and the same error class `die_after` uses,
      # for the reason stated there: it is an error the one live rescue genuinely does not cover.
      # Keyed to ONE OBSERVATION rather than to a call count, because what is under test here is the
      # blast radius of a single row and not the death of a pass — and keyed through `#identity_for`,
      # which is the seam that still knows which row the lookup below is being made for.
      #
      # `poison_own:` additionally poisons THIS run's own rows, which is how one pass can carry a
      # failure on each side of the asymmetry at once.
      def sweeping_run(ci_run_id:, poison:, specs: nil, poison_own: false)
        run = record(specs || [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                                name: "User#save rejects a duplicate email")],
                     ci_run_id: ci_run_id)
        poisoned_ids = [poison.id] + (poison_own ? run.spec_observations.pluck(:id) : [])
        resolver = described_class.new(run)
        resolving = nil
        allow(resolver).to receive(:identity_for).and_wrap_original do |original, observation|
          resolving = observation
          original.call(observation)
        end
        allow(resolver).to receive(:nearest).and_wrap_original do |original, *args|
          raise ActiveRecord::StatementInvalid, "server closed the connection" if poisoned_ids.include?(resolving.id)

          original.call(*args)
        end

        [run, resolver]
      end

      it "does not abort the delivery: this run's own rows are still reached and resolved" do
        poisoned = poisoned_backlog_row
        run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)

        expect { resolver.resolve }.not_to raise_error

        # The backlog is walked FIRST, so this assertion is the whole ticket: the delivery got past
        # the row that used to end it.
        expect(run.spec_observations.unresolved).to be_empty
        expect(poisoned.reload.spec_identity_id).to be_nil
        # And the row that could not be resolved produced no identity standing for nothing.
        expect(identity_texts).to eq(["User#save rejects a duplicate email"])
      end

      it "leaves it findable by a scope rather than only in Solid Queue's failed executions" do
        poisoned = poisoned_backlog_row
        # The premise, pinned: before the sweep this row is the unstamped kind, so a stamp after it
        # is this containment's doing and not something the fixture arrived with.
        expect(repository.spec_observations.embed_failed).to be_empty

        _run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        resolver.resolve

        expect(poisoned.reload.embed_failed_at).to be_present
        expect(poisoned.embed_failure_count).to eq(1)
        expect(repository.spec_observations.embed_retryable.pluck(:id)).to eq([poisoned.id])
      end

      it "counts as nothing, because the count is what NOW carries an identity and it does not" do
        poisoned = poisoned_backlog_row
        _run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)

        # One row of its own, and zero for the contained one. Containment must not inflate the
        # figure `#resolve` reports — see its `@return`.
        expect(resolver.resolve).to eq(1)
      end

      it "sinks below a backlog row that has been tried less, so a scarce slot goes to that one" do
        poisoned = poisoned_backlog_row
        _second, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        resolver.resolve

        # A provider failure on a later run: a backlog row of the SAME standing — stamped, retryable
        # — carrying one fewer attempt than the contained row now does.
        allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
        failed = ingest([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 9,
                                          name: "Invoice#finalize locks the line items")],
                        ci_run_id: "run-3")
        RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

        # Asserted off the relation the resolver ACTUALLY walks rather than a hand-written copy of
        # its ORDER BY, which would be a second definition of the query certifying nothing about the
        # sweep — the same choice the plan example below makes.
        backlog = described_class.new(create_test_run(repository: repository)).send(:failed_embed_backlog)

        expect(backlog.pluck(:id)).to eq([failed.spec_observations.sole.id, poisoned.id])
      end

      it "still lets the repository make progress on every ingest, for as long as it is retryable" do
        poisoned = poisoned_backlog_row

        # Three deliveries, each with the poison row sitting at the head of its backlog. Each one
        # resolves its own suite, and the row is re-attempted and re-contained rather than skipped —
        # a dropped connection is transient, and the bound on being wrong about that is the window
        # below, not a guess made here.
        3.times do |index|
          run, resolver = sweeping_run(
            ci_run_id: "sweep-#{index}", poison: poisoned,
            specs: [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3 + index,
                                     name: "User#save rejects a duplicate email")]
          )
          resolver.resolve
          expect(run.spec_observations.unresolved).to be_empty
        end

        expect(poisoned.reload.embed_failure_count).to eq(3)
        # One identity across all three, not three: the deliveries did their real work, and the
        # contained row never grew the table.
        expect(identity_texts).to eq(["User#save rejects a duplicate email"])
      end

      it "keeps the first containment's timestamp, so re-attempting cannot push the window forward" do
        poisoned = poisoned_backlog_row
        _first, first_resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        first_resolver.resolve
        stamped = poisoned.reload.embed_failed_at

        _second, second_resolver = sweeping_run(ci_run_id: "run-3", poison: poisoned)
        second_resolver.resolve

        # `COALESCE`, and it is what makes the bound below a window that CLOSES rather than one every
        # containment pushes forward — a hopeless row would otherwise stay retryable for exactly as
        # long as anything kept retrying it.
        expect(poisoned.reload.embed_failed_at).to eq(stamped)
        expect(poisoned.embed_failure_count).to eq(2)
      end

      it "gives up on it once the window has closed, and leaves it queryable as such" do
        poisoned = poisoned_backlog_row
        _second, resolver = sweeping_run(ci_run_id: "run-3", poison: poisoned)
        resolver.resolve

        # `update_all` rather than a time-travel helper, the choice this file makes throughout:
        # assert the fact the fixture needs — this row was first contained longer ago than the
        # window — rather than moving the clock underneath everything else in the example.
        SpecObservation.where(id: poisoned.id)
                       .update_all(embed_failed_at: SpecObservation::EMBED_RETRY_WINDOW.ago - 1.second)

        later_ingest(ci_run_id: "run-4")

        # No longer swept at all: the count did not move, so nothing reached it. The bound is the
        # ordinary one `EMBED_RETRY_WINDOW` already applies to a provider failure, reached by a row
        # that got its stamp from containment instead.
        expect(poisoned.reload.embed_failure_count).to eq(1)
        expect(repository.spec_observations.embed_retryable).to be_empty
        # "We stopped trying" and "we are still trying" stay two figures.
        expect(repository.spec_observations.embed_abandoned.pluck(:id)).to eq([poisoned.id])
      end

      it "contains the INHERITED half only: a failure in this run's own list still ends the pass" do
        # The asymmetry, and the reason it is one. An inherited row is work this delivery volunteered
        # for on an earlier one's behalf, so its failure is contained; this run's rows are what the
        # caller actually asked for, so their failure is still a report. `die_after(rows: 1)` lets
        # the ONE backlog row through and raises on the first row of `@run`'s own list.
        stranded = poisoned_backlog_row.test_run

        run = record(suite, ci_run_id: "run-2")
        die_after(run, rows: 1)

        # The inherited row was rescued on the way past — containment did not turn the backlog into
        # something the pass skips — and then this run's own failure escaped, exactly as it did
        # before this change.
        expect(stranded.spec_observations.sole.reload.spec_identity_id).to be_present
        expect(run.spec_observations.unresolved).not_to be_empty
      end

      it "contains the inherited row and lets this run's own out, in ONE pass" do
        # The asymmetry as a single event rather than as two examples of one side each. The example
        # above pins it with an inherited row that SUCCEEDS on the way past, which is a fair
        # regression pin but survives the mutation this group is written against. This one does not:
        # it is the shape that breaks if someone later routes the run-scoped loop through
        # `#claim_inherited` too, because then the raise below is swallowed and the pass reports a
        # clean delivery over a row the caller actually asked about.
        poisoned = poisoned_backlog_row
        run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned, poison_own: true)

        expect { resolver.resolve }.to raise_error(ActiveRecord::StatementInvalid)

        # Inherited: contained and stamped, so the pass got past it to reach this run's list at all.
        expect(poisoned.reload.embed_failed_at).to be_present
        expect(poisoned.embed_failure_count).to eq(1)
        # This run's own: left exactly as a died pass leaves it — unresolved and UNSTAMPED, the
        # state the group at the top of this file documents and which must keep holding.
        expect(run.spec_observations.unresolved).not_to be_empty
        expect(run.spec_observations.pluck(:embed_failed_at).uniq).to eq([nil])
      end

      it "does not manufacture a clean sweep out of a database it cannot even stamp" do
        # The documented non-promise on `#claim_inherited`. The containment is itself an UPDATE, so a
        # failure broad enough to take the connection with it raises from inside the rescue and
        # propagates as before. A database that cannot be written to must not produce a delivery that
        # reports a clean pass.
        poisoned = poisoned_backlog_row
        _run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        allow(resolver).to receive(:record_resolve_failure)
          .and_raise(ActiveRecord::StatementInvalid, "server closed the connection unexpectedly")

        expect { resolver.resolve }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end

    # The cost half of the slice, and the reason it came with a migration. The failure backlog's
    # index is partial on `embed_failed_at IS NOT NULL AND spec_identity_id IS NULL`; this sweep's
    # predicate is the COMPLEMENT of its leading clause, so that index cannot serve it at all. The
    # sweep runs on every ingest — the hottest path in the application — and unindexed it is a
    # repository-wide scan of a table holding `BRANCH_RETENTION_RUNS` runs of a 20,000-example suite
    # per branch, to find nothing on a healthy repository.
    describe "the plan Postgres chooses for it" do
      let(:resolved_runs) { 10 }
      let(:rows_per_run) { 500 }
      # A backlog LARGER than one sweep may take — the shape the ordering keys are in the index for,
      # and the design point `RETRY_SWEEP_LIMIT` is written against: *"a provider outage across a
      # 20,000-example run leaves 20,000 failed rows"*, and a job that died mid-resolve leaves as
      # many unattempted ones.
      let(:stranded_rows) { 4 * described_class::RETRY_SWEEP_LIMIT }

      # What the sweep asks for, and deliberately far below the backlog above. `#retry_backlog`
      # hands this list the REMAINDER of the shared budget, so a small number here is an ordinary
      # production call and not a contrivance — it is what every ingest issues while a failure
      # backlog is draining.
      #
      # It is small for a second reason, and that one is about keeping this example honest rather
      # than about fidelity. The margin between the two candidate plans narrows as the suite's own
      # rolled-back inserts bloat the table: an index scan's per-row cost rises with the heap it has
      # to fetch from, so at a cap near the backlog size the planner's choice comes down to a
      # tiebreak that RSpec's ordering decides — which is exactly the flakiness
      # spec/models/spec_observation_spec.rb records having been bitten by, and it certified nothing
      # while it lasted. The property under test is that the cap STOPS the read early, and asking
      # for a small slice of a large backlog is where that property is worth orders of magnitude
      # rather than percent.
      let(:sweep_limit) { 25 }

      # Seeded by `insert_all` rather than through the ingest path. These rows are BALLAST for the
      # planner and nothing reads their content, so the rule the file header states (SPGD-91 — a
      # fixture must not build a state the producer cannot) is not what is at stake: the columns
      # that decide this plan are `repository_id`, `created_at`, `spec_identity_id` and
      # `embed_failed_at`, all of which production writes exactly as this does.
      def seed(test_run, identity:, created_at:, rows:)
        SpecObservation.insert_all((1..rows).map do |index|
          path = "spec/f#{index % 25}_spec.rb"
          { test_run_id: test_run.id, repository_id: repository.id,
            example_id: "./#{path}[1:#{index}]", spec_file_path: path, file_path: path,
            line_number: index, name: "example #{index}", status: "unannotated",
            spec_identity_id: identity&.id, created_at: created_at, updated_at: created_at }
        end)
      end

      # A repository with history behind it and one run stranded in it. Three properties of this
      # seed are each load-bearing, and the assertion certifies nothing without all three — every
      # one of them was found by a spelling of this example that passed or failed for the wrong
      # reason:
      #
      # * **Most rows resolved**, so the partial index is a small fraction of the table. A planner
      #   handed a table where every row matches the partial predicate has no reason to prefer it.
      # * **The runs spread over TIME** rather than all written at `Time.current`. `created_at` and
      #   `spec_identity_id` are perfectly correlated in a single-instant seed — every unresolved
      #   row is also the only old row — and Postgres multiplies the two selectivities as though
      #   they were independent, underestimating the backlog by 20×. The plan it then picks is
      #   chosen against a row count production never has.
      # * **A backlog larger than `RETRY_SWEEP_LIMIT`**, which is what makes the ORDERING half of
      #   the index matter. Below the cap the sweep needs every row it can find and sorting a few
      #   hundred of them is nearly free, so the planner may reasonably narrow on
      #   `index_spec_observations_on_spec_identity_id` — a plain index on a nullable column, whose
      #   btree indexes its NULLs — and sort. Above the cap that plan has to read and sort the WHOLE
      #   backlog to hand back 500 rows, while this index yields them already ordered and stops. The
      #   cost it avoids grows with the backlog, which is precisely when it is worth avoiding.
      before do
        identity = create_spec_identity(repository: repository)
        resolved_runs.times do |index|
          seed(create_test_run(repository: repository), identity: identity,
               created_at: (index * 7).hours.ago, rows: rows_per_run)
        end
        seed(create_test_run(repository: repository), identity: nil,
             created_at: (SpecObservation::EMBED_ATTEMPT_GRACE + 1.hour).ago, rows: stranded_rows)

        # Without stats the planner works off hard-coded defaults and its choice says nothing about
        # the data. `ANALYZE` is legal inside the transaction the suite wraps each example in.
        ActiveRecord::Base.connection.execute("ANALYZE spec_observations")
      end

      it "reads the never-attempted backlog off its own partial index, in order, and stops at the cap" do
        # EXPLAINed from the relation the resolver ACTUALLY walks rather than from a hand-written
        # copy of it — a copy is a second definition of the query, and a plan assertion against the
        # copy would be asserting nothing about the sweep.
        relation = described_class.new(create_test_run(repository: repository))
                                  .send(:unattempted_embed_backlog, sweep_limit)
        plan = ActiveRecord::Base.connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")

        expect(plan).to include("index_spec_observations_on_unattempted_embed_backlog")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
        # No `Sort` node, which is the half of the criterion the index name alone does not carry:
        # the rows come back in the sweep's own order, so the `LIMIT` stops after 500 of them rather
        # than after the whole backlog has been read and ordered.
        expect(plan).not_to match(/Sort Key:/)
      end
    end
  end

  describe "running twice over the same run" do
    it "is a no-op the second time, because the work list is the unresolved rows" do
      run = ingest(suite, ci_run_id: "run-1")

      expect { described_class.resolve(run) }.not_to change(SpecIdentity, :count)
      expect(described_class.resolve(run)).to eq(0)
    end
  end

  describe "what it reports" do
    it "counts the observations it gave an identity to" do
      expect(described_class.resolve(record(suite, ci_run_id: "run-1"))).to eq(3)
    end

    it "counts a rescued row of an earlier run, because this invocation is what resolved it" do
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

      second = record([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                        name: "User#save rejects a duplicate email")],
                      ci_run_id: "run-2")

      # One row of its own and one rescued. Counting only `second`'s rows would report a sweep that
      # did real work as a no-op — see the `@return` on `IdentityResolver#resolve`.
      expect(described_class.resolve(second)).to eq(2)
    end
  end

  # The count above had exactly one caller before this slice and that caller discarded it, so the
  # pipeline knew the number and told nobody. These examples are about the line that now says it —
  # and about the four bounded figures beside it, whose scopes shipped to be read and had, until
  # now, no production reader at all.
  describe "the completion report" do
    # Every line a block emitted, in order, as `[level, message]`. Captured at `Rails.logger`
    # because the properties under test are about WHAT WAS SAID AND HOW MANY TIMES: "exactly one
    # summary per pass, whatever happened" is a count, and a count needs every emission to pass
    # through one place. `warn` is captured alongside `info` for the outage example, which has to
    # show the per-row warnings still there and the summary not one of them.
    def logged
      lines = []
      allow(Rails.logger).to receive(:info) { |message| lines << [:info, message] }
      allow(Rails.logger).to receive(:warn) { |message| lines << [:warn, message] }
      yield
      lines
    end

    def summaries(lines) = lines.select { |level, _| level == :info }.map(&:last)

    def summary_of(&) = summaries(logged(&)).sole

    # A row nothing ever attempted, old enough that no live job is plausibly still on its way to it.
    # `update_all` rather than a time-travel helper, the choice this file already makes twice: assert
    # the fact the fixture needs rather than moving the clock underneath everything else.
    def strand(run, ago:)
      run.spec_observations.unresolved.update_all(created_at: ago.ago)
    end

    it "says what the pass resolved, once, however many rows that was" do
      run = record(suite, ci_run_id: "run-1")

      lines = logged { described_class.resolve(run) }

      # Once — not once per row, which is the shape the pipeline's only other voice has and the
      # reason a 20,000-row outage says everything and reports nothing.
      expect(summaries(lines).sole).to include("run=#{run.id}", "resolved=3")
    end

    # The figure an operator most needs, and the one a "log it only when it is interesting" report
    # would drop. A pass that resolved nothing and a pass that never ran are the same observable
    # event without this line, which is the defect the whole slice exists for.
    it "still says so when it resolved nothing" do
      run = ingest(suite, ci_run_id: "run-1")

      expect(summary_of { described_class.resolve(run) }).to include("resolved=0")
    end

    it "reports the repository's figures beside the run's, named as the repository's" do
      run = record(suite, ci_run_id: "run-1")

      # The counts are a snapshot of the REPOSITORY read at the end of the pass, not a tally of what
      # the pass did — `resolved` is that — so the line carries the repository they belong to. Every
      # shard of a run enqueues a job for the run, so N of these are emitted over largely the same
      # rows; a reader has to be able to tell which half of the line is which.
      expect(summary_of { described_class.resolve(run) })
        .to include("repository=#{repository.id}")
    end

    it "never reports a raw unresolved count, so a concurrent delivery's rows are not a problem" do
      ingest(suite, ci_run_id: "run-1")
      # Another delivery, mid-flight: recorded and committed, not yet resolved. This is the ordinary
      # state of every healthy ingest between the commit and its job's pass, and at the design point
      # it is 20,000 rows.
      in_flight = record(suite(offset: 40), ci_run_id: "run-2")

      summary = summary_of { described_class.resolve(record(suite(offset: 80), ci_run_id: "run-3")) }

      # The falsifier for the whole criterion: a raw `.unresolved.count` would have reported these.
      expect(in_flight.spec_observations.unresolved.count).to eq(3)
      expect(summary).to include("embed_failed_retrying=0", "embed_failed_gave_up=0",
                                 "never_attempted_retrying=0", "never_attempted_gave_up=0")
      expect(summary).not_to match(/\bunresolved=/)
    end

    it "separates the failed backlog's 'still trying' from its 'stopped trying'" do
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      still_trying = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                              name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      gave_up = ingest([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                         name: "Invoice#finalize locks the line items")], ci_run_id: "run-2")
      gave_up.spec_observations.update_all(embed_failed_at: SpecObservation::EMBED_RETRY_WINDOW.ago - 1.second)

      # The outage is still going, which is the only shape in which both figures are non-zero at
      # once: a recovered provider empties the retryable half on the very next ingest, because that
      # is what the sweep is for. So run-3 fails on its own row and fails again re-attempting
      # run-1's, while run-2's is past the window and nothing touches it any more.
      summary = summary_of do
        described_class.resolve(record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                                         name: "Order#checkout rejects an expired card")],
                                       ci_run_id: "run-3"))
      end

      # Two figures and never one. `SpecObservation.embed_abandoned` exists because *"a bound that
      # cannot be queried is a bound nobody can audit"*, and summing it back into its sibling here
      # would spend that separation on the way out.
      expect(still_trying.spec_observations.sole.reload.spec_identity_id).to be_nil
      expect(summary).to include("resolved=0", "embed_failed_retrying=2", "embed_failed_gave_up=1")
    end

    it "separates the never-attempted backlog's two bounds, and calls neither of them a failure" do
      # One slot in the sweep, so one of the two rows still inside the window is rescued and the
      # other is still waiting when the count is taken — the ordinary state of a repository whose
      # backlog is draining across the ingests that follow.
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)

      # No stamp anywhere in this example: `#record_embed_failure` only runs where the provider was
      # actually asked, and nothing here asked it. These are runs whose jobs never arrived.
      strand(record([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                      name: "Cart adds an item to the cart")], ci_run_id: "run-1"),
             ago: SpecObservation::EMBED_ATTEMPT_GRACE + 1.minute)
      strand(record([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                      name: "Invoice#finalize locks the line items")], ci_run_id: "run-2"),
             ago: SpecObservation::EMBED_ATTEMPT_GRACE + 2.minutes)
      strand(record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                      name: "Order#checkout rejects an expired card")], ci_run_id: "run-3"),
             ago: SpecObservation::EMBED_RETRY_WINDOW + 1.second)
      # A SECOND row past the window, and the reason it is here is the assertion below rather than
      # the scenario: with one row on each side the two figures are both 1, and `1 == 1` cannot tell
      # the labels apart from the sets beneath them. Wiring `never_attempted_retrying` to
      # `.embed_unattempted_abandoned` and its sibling to `.embed_unattempted_retryable` — the exact
      # inversion criterion 3 forbids — leaves a symmetric fixture green while the report tells an
      # operator "nothing will ever attempt this again" about a row we are still trying. The figures
      # have to DIFFER for the assertion to reach the wiring, which is the discipline the failed
      # backlog's example above already applies with its 2 and its 1.
      strand(record([unannotated_spec(file_path: "spec/d_spec.rb", line_number: 4,
                                      name: "Report#export streams the CSV in batches")], ci_run_id: "run-4"),
             ago: SpecObservation::EMBED_RETRY_WINDOW + 2.seconds)

      summary = summary_of do
        described_class.resolve(record([unannotated_spec(file_path: "spec/e_spec.rb", line_number: 5,
                                                         name: "Session#destroy clears the remember token")],
                                       ci_run_id: "run-5"))
      end

      expect(summary).to include("never_attempted_retrying=1", "never_attempted_gave_up=2")
      # `.embed_unattempted_abandoned` is two populations at once — rows a dead job stranded and
      # then outlived, AND the frozen signalless tail doing exactly what it should — so its figure
      # is "rows nothing will ever attempt again" and NOT "rows we failed". The model says so
      # outright; a label claiming otherwise ships the alarming reading it refuses.
      expect(summary).not_to match(/never_attempted\w*fail/)
    end

    it "reports the population an outage leaves, and leaves the per-row warnings exactly as they were" do
      run = record(suite, ci_run_id: "run-1")
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")

      lines = logged { described_class.resolve(run) }

      # The per-row voice, byte-identical to what `#embed` has always said. An outage now reaches
      # the provider a page at a time, so the failure is ANNOUNCED once for the page and then
      # CONTAINED one row at a time exactly as before — three rows, three lines, three stamps. The
      # page line is additive and is asserted separately below rather than folded in here, so this
      # stays an assertion about the per-row voice.
      warnings = lines.select { |level, _| level == :warn }.map(&:last)

      expect(warnings.grep(/could not embed a spec signal/))
        .to eq(["[IdentityResolver] run=#{run.id} could not embed a spec signal: provider down"] * 3)
      # The page's own line, said once, and the fallback it announces is what keeps the three above
      # per-row rather than one verdict on the whole page.
      expect(warnings.grep(/could not embed a page/))
        .to eq(["[IdentityResolver] run=#{run.id} could not embed a page of 3 spec signals in one " \
                "request: provider down; falling back to one request per signal"])
      # And the total those three lines never carried, said once.
      expect(summaries(lines).sole).to include("resolved=0", "embed_failed_retrying=3")
    end

    # The cost half. Four counts per pass is nothing against the 20,000 round trips the pass already
    # makes — but "nothing" is a claim about the PLAN, and a plan is the only instrument that grades
    # it. Seeded and certified exactly as "the plan Postgres chooses for it" above does, against the
    # relations the report actually counts rather than against copies of them.
    describe "the plan Postgres chooses for its counts" do
      let(:resolved_runs) { 10 }
      let(:rows_per_run) { 500 }

      # Deliberately SMALL, and this is the one seed property that differs from the sweep's — so it
      # is argued rather than copied.
      #
      # That example asserts a capped, ORDERED read and needs a backlog larger than the cap for the
      # ordering half of the index to be worth anything. A count has no cap and no order, so that
      # property has no counterpart here; what decides this plan instead is the FRACTION of the
      # table each partial index holds. Small is the honest fixture because small is the case that
      # runs: both indexes are partial on `spec_identity_id IS NULL`, the report fires on every
      # ingest forever, and on a healthy repository it is asking four questions whose answer is
      # zero.
      #
      # A repository genuinely sitting on thousands of abandoned rows gets a sequential scan for
      # these counts, and that is the planner being right rather than a regression: counting a large
      # matching set costs less by reading the table than by chasing that many index entries back
      # into the heap. The claim this example certifies is the one worth having — the four counts do
      # not scan the table to find NOTHING.
      let(:backlog_rows) { 25 }

      def seed(test_run, identity:, created_at:, rows:, embed_failed_at: nil)
        SpecObservation.insert_all((1..rows).map do |index|
          path = "spec/f#{index % 25}_spec.rb"
          { test_run_id: test_run.id, repository_id: repository.id,
            example_id: "./#{path}[1:#{index}]", spec_file_path: path, file_path: path,
            line_number: index, name: "example #{index}", status: "unannotated",
            spec_identity_id: identity&.id, embed_failed_at: embed_failed_at,
            created_at: created_at, updated_at: created_at }
        end)
      end

      def backlog(created_at:, embed_failed_at: nil)
        seed(create_test_run(repository: repository), identity: nil, created_at: created_at,
             rows: backlog_rows, embed_failed_at: embed_failed_at)
      end

      # Two of the three load-bearing properties of the sweep's own seed, unchanged and for the
      # reasons it states at length: most rows resolved, so the partial indexes are a small fraction
      # of the table; and the runs spread over TIME, because `created_at` and `spec_identity_id` are
      # perfectly correlated in a single-instant seed and the planner then works from a row count
      # production never has. The third — a backlog larger than the cap — is the one `backlog_rows`
      # above explains has no counterpart in a count.
      #
      # Extended by one thing this report needs and that sweep does not: a FAILED population, on
      # both sides of `EMBED_RETRY_WINDOW`. Two of the four counts read the failure index, and a
      # count certified over an empty set certifies the emptiness rather than the read.
      before do
        identity = create_spec_identity(repository: repository)
        resolved_runs.times do |index|
          seed(create_test_run(repository: repository), identity: identity,
               created_at: (index * 7).hours.ago, rows: rows_per_run)
        end

        backlog(created_at: (SpecObservation::EMBED_ATTEMPT_GRACE + 1.hour).ago)
        backlog(created_at: (SpecObservation::EMBED_RETRY_WINDOW + 1.day).ago)
        backlog(created_at: 2.days.ago, embed_failed_at: 2.days.ago)
        backlog(created_at: 30.days.ago, embed_failed_at: (SpecObservation::EMBED_RETRY_WINDOW + 1.day).ago)

        ActiveRecord::Base.connection.execute("ANALYZE spec_observations")
      end

      # The plan for the count the report ACTUALLY issues. The relation comes out of the reporting
      # method itself rather than being rewritten here — a copy is a second definition of the query
      # and a plan assertion against the copy certifies the copy — and `COUNT(*)` is AR's own
      # projection for `#count` on exactly this relation.
      def plan_for(relation)
        sql = relation.select(Arel.star.count).to_sql
        ActiveRecord::Base.connection.select_values("EXPLAIN #{sql}").join("\n")
      end

      def bounds
        described_class.new(create_test_run(repository: repository)).send(:unresolved_bounds)
      end

      it "reads all four through an index rather than by scanning the table" do
        # The reach of this guard is measured rather than assumed, and what the measurement found is
        # worth recording because it is not symmetric. Re-seeded at `backlog_rows` of 2,000 instead
        # of 25: the two never-attempted counts flip to `Seq Scan on spec_observations` and fail
        # this example, while the two failed counts stay on their partial index and merely drop
        # from an Index Only Scan to a Bitmap Heap Scan — indexed still, but paying the heap.
        #
        # So this assertion has real reach on one pair and is carried by the seed on the other. The
        # example below is what holds the failed pair to something a larger seed would move.
        bounds.each do |label, relation|
          plan = plan_for(relation)

          expect(plan).to match(/Index (Only )?Scan using/), "#{label} used no index:\n#{plan}"
          expect(plan).not_to match(/Seq Scan on spec_observations/), "#{label} was scanned:\n#{plan}"
        end
      end

      # The one place a plan SHAPE is claimed, and it is claimed because the plan grants it — not
      # because the schema implied it. It is worth pinning precisely because reading the schema
      # predicts the opposite: this index is `(repository_id, embed_failure_count, embed_failed_at)`
      # and both scopes range on `embed_failed_at`, which is not the column after `repository_id`,
      # so the expected plan was a partial-index read with `embed_failed_at` as a FILTER. Postgres
      # instead takes it as an `Index Cond` and — since a count needs no columns off the heap —
      # gets an Index ONLY Scan out of it. A cost claim is graded by the plan and this is the plan.
      #
      # `Index Only Scan` and not merely the index name, because the name alone survives the thing
      # worth catching: at a 2,000-row backlog this same read stays on this same index and becomes a
      # Bitmap Heap Scan, which is the version that goes back to the heap for every matching row.
      it "counts the failed backlog off the partial index built for it, touching no heap" do
        %i[embed_failed_retrying embed_failed_gave_up].each do |label|
          plan = plan_for(bounds.fetch(label))

          expect(plan).to include("Index Only Scan using index_spec_observations_on_embed_backlog"),
                          "#{label}:\n#{plan}"
        end
      end

      # And the two never-attempted counts are deliberately left WITHOUT a name assertion, which is
      # the honest end of the same discipline.
      #
      # They are served here by `index_spec_observations_on_spec_identity_id` — a plain index on a
      # nullable column, whose btree indexes its NULLs — with everything else as a filter, rather
      # than by `index_spec_observations_on_unattempted_embed_backlog`, which is a genuine prefix
      # range for both of them and is the index they were expected to use. Nothing is wrong: at this
      # fixture's size the WHOLE TABLE holds ~100 unresolved rows, so narrowing on
      # `spec_identity_id IS NULL` alone already reaches almost the whole answer. The partial index
      # wins once that population is large across every tenant, which is the scale it was added for
      # and one this seed cannot have without making THIS repository's counts large too — at which
      # point the planner correctly stops using any index for them at all.
      #
      # Asserting either name here would pin a fixture-scale accident, and asserting the intended
      # one would fail against a correct implementation. The example above certifies what is true at
      # both sizes: these counts do not scan the table to find nothing.
    end
  end

  describe "reclaiming the disk the retention window has already stopped serving from" do
    # `EmbeddingCacheEntry::RETENTION_WINDOW` bounded what was SERVED and nothing enforced it
    # against the table, so the cache grew forever at ~8.5KB of disk per distinct text per
    # fingerprint. The
    # rule itself — batching, the ceiling, convergence, what survives — is graded in
    # `spec/services/ingest/embedding_cache_pruner_spec.rb`. What is graded HERE is the seam: which
    # path pays for it, and what it may cost that path when it fails.

    let(:stale_vector) { Array.new(EmbeddingGenerator::DIMENSIONS) { |index| (index % 7) / 7.0 } }

    # One entry past the window, written under a fingerprint this deployment no longer runs — the
    # ordinary shape of a reclaimable row. `update_all` rather than moving the clock, the choice
    # this file already makes elsewhere.
    def expired_cache_entry
      EmbeddingCacheEntry.store("retired-provider:v0", { "embedded a quarter ago" => stale_vector })
      EmbeddingCacheEntry.update_all(updated_at: (EmbeddingCacheEntry::RETENTION_WINDOW + 1.day).ago)
    end

    def warnings
      lines = []
      allow(Rails.logger).to receive(:warn) { |message| lines << message }
      yield
      lines
    end

    # ⭐ **The seam decision, discriminated rather than asserted in a comment.** Two paths were
    # defensible — this class, which is the table's ONLY writer, and `Ingest::RunRecorder`, where
    # the sibling `Ingest::ObservationPruner` is called after each commit. The reason this one was
    # chosen is argued on `Ingest::EmbeddingCachePruner`; this example is what makes the choice a
    # fact about the code. `#record` here is `RunRecorder` alone — the synchronous half the endpoint
    # answers `202` from — so the first assertion is also the whole of the "no 202 is affected"
    # claim: the ingest request never issues this delete at all.
    it "prunes on the RESOLVE pass and not on the ingest write path" do
      expired_cache_entry

      run = record(suite, ci_run_id: "run-1")

      # The write path ran in full — it recorded the run, and it called the OTHER pruner — and left
      # this table alone.
      expect(EmbeddingCacheEntry.count).to eq(1)

      described_class.resolve(run)

      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    it "prunes even though this provider publishes no fingerprint and the cache is inert" do
      # The prune is deliberately NOT gated on `#cache_fingerprint`. Under `with lexical
      # embeddings` the provider publishes no fingerprint, so this whole pass reads nothing from the
      # cache and writes nothing to it — and the expired rows still go. Gating on the fingerprint
      # would strand the table of exactly the deployment that has stopped being able to use it.
      expired_cache_entry
      expect(EmbeddingGenerator.fingerprint).to be_nil

      described_class.resolve(record(suite, ci_run_id: "run-1"))

      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    # ⚠️ **The failure policy is `Ingest::ObservationPruner`'s INVERTED, and that is the point of
    # this example.** That class lets a prune failure fail the ingest on purpose. Here the table is
    # a cache that every caller is required to be able to lose, so the same failure must cost this
    # resolve nothing: the rows still resolve, the pass still reports, and nothing raises. Asserted
    # in a spec rather than promised in a comment, because the containment is the whole claim.
    it "resolves the whole run anyway when the prune fails, and says so at warn" do
      allow(Ingest::EmbeddingCachePruner).to receive(:prune)
        .and_raise(ActiveRecord::StatementInvalid, "PG::UndefinedTable: relation does not exist")

      run = record(suite, ci_run_id: "run-1")
      lines = warnings { expect(described_class.resolve(run)).to eq(3) }

      expect(run.spec_observations.unresolved.count).to eq(0)
      expect(repository.spec_identities.count).to eq(3)
      # `warn` and not `error`, the register `#cached_embeddings` and `#store_embeddings` already
      # use for this table: the resolve is correct and the deployment is merely holding disk its own
      # rule says it should not.
      expect(lines.grep(/could not reclaim expired cache entries/).size).to eq(1)
    end

    it "does not let a prune failure discard what the pass already resolved" do
      # The ordering half of the containment. The prune runs after both work lists have been walked,
      # so a raising prune cannot reach past the writes those lists made — but a prune placed ahead
      # of them, or one allowed to propagate out of `#resolve`, would abandon a page of rows that
      # had already been embedded and paid for. Pinned against the identities rather than the count.
      expired_cache_entry
      allow(Ingest::EmbeddingCachePruner).to receive(:prune).and_raise(ActiveRecord::Deadlocked, "deadlock detected")

      run = record(suite, ci_run_id: "run-1")
      described_class.resolve(run)

      # Every row of the page carries the identity it resolved to, and the identities are on the
      # repository — the two writes `#resolve_page` flushes, both landed and neither rolled back.
      expect(run.spec_observations.unresolved.count).to eq(0)
      expect(run.spec_observations.count).to eq(3)
      expect(repository.spec_identities.count).to eq(3)
      # And the row the prune failed to reclaim is still there, rather than half-deleted.
      expect(EmbeddingCacheEntry.count).to eq(1)
    end
  end
end
