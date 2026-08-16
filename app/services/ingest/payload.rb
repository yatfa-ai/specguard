# frozen_string_literal: true

module Ingest
  # One `POST /api/v1/ingest` request body, validated in two independent layers:
  #
  #   1. The **envelope** — run metadata and the shape of each entry in `specs[]`. This is
  #      SpecGuard's own contract (see the SpecGuard API Reference) and is deliberately separate from (2):
  #      the platform owns the transport, `open-test-intent` owns the annotation.
  #   2. Each annotated spec's **intent**, against the vendored OpenTestIntent JSON Schema.
  #
  # Every failure is collected rather than raised on the first one, and every per-spec message
  # names the spec it came from, so a client fixing a malformed suite sees the whole list at once.
  #
  # A run with *zero* annotations is valid. Missing annotations are never an ingestion failure —
  # only malformed ones are — because adoption has to be opt-in and gradual. What every spec does
  # owe is *something that represents it*: an intent or a `name` (see {#validate_name}), the pair
  # `Ingest::SpecSignal` chooses between.
  class Payload
    STATUSES = %w[annotated unannotated].freeze

    attr_reader :errors

    def initialize(body)
      @body = body
      @specs = []
      @errors = []
      validate
    end

    def valid? = @errors.empty?

    # Every spec the client reported, annotated or not — the population `Ingest::RunRecorder`
    # writes one `SpecObservation` per. Distinct from {#annotated_specs}, which is the slice
    # carrying an intent: a run is mostly unannotated for as long as adoption is gradual, and the
    # per-example facts (duration, outcome, name) are worth keeping for every example regardless.
    def specs = @specs

    # The specs carrying an intent — the numerator of the run's annotation ratio, which is the one
    # thing this slice is for. Deliberately *not* what the embedding seam is handed: a spec's
    # representable text can come from its `name` too (`Ingest::SpecSignal`), so narrowing to this
    # slice at that call site would decide that a suite mid-adoption has nothing to say.
    #
    # Only meaningful once `valid?`, which is what guarantees every status is one of STATUSES and so
    # makes "not unannotated" the same set as "annotated".
    def annotated_specs = @specs.reject { |spec| spec["status"] == "unannotated" }

    # Attributes for the `TestRun` this run produces. The counts are **derived** from `specs[]`,
    # never read from the client: a client-supplied total is a number nobody can check, and this
    # is the denominator of the headline dashboard metric.
    #
    # `ci_run_id` is the one field here the client alone can know — the identity its CI provider
    # gave the *build*, which every shard of a sharded run shares. It is what lets
    # `Ingest::RunRecorder` accumulate N shards into one row instead of writing N rows with a
    # split denominator. Nil is the ordinary case (a laptop run, an unrecognised provider) and
    # means "this run is its own run".
    def test_run_attributes
      {
        ci_run_id: @body["ci_run_id"].presence,
        commit_sha: @body["commit_sha"].strip,
        branch: @body["branch"].presence,
        duration_seconds: @body["duration_seconds"],
        total_specs_count: @specs.size,
        annotated_specs_count: annotated_specs.size
      }
    end

    # Which shard of the run this request is, as the client named it. Deliberately **not** part of
    # {#test_run_attributes}: it does not describe the run, it identifies this one contribution to
    # it, and it is stored on `TestRunShard` rather than on `TestRun`.
    #
    # Nil is ordinary and is not an error — an unsharded run, or a runner exposing no index the
    # client recognises. See `Ingest::RunRecorder` for what a nil costs.
    def shard_id = @body["shard_id"].presence

    private

    def validate
      return @errors << "the request body must be a JSON object" unless object_body?

      validate_commit_sha
      validate_branch
      validate_ci_run_id
      validate_shard_id
      validate_duration_seconds
      validate_specs
    end

    # Rails parses a non-object JSON body (an array, a bare string) into `{"_json" => …}` rather
    # than failing, so an object-shaped Hash here is not proof the client sent an object.
    def object_body? = @body.is_a?(Hash) && !@body.key?("_json")

    def validate_commit_sha
      value = @body["commit_sha"]
      return if value.is_a?(String) && value.strip.present?

      @errors << "commit_sha is required and must be a non-empty string"
    end

    def validate_branch
      value = @body["branch"]
      return if value.nil? || value.is_a?(String)

      @errors << "branch must be a string when present"
    end

    # Validated exactly as `branch` is, and for the same reason: an omitted `ci_run_id` is the
    # normal shape of a run nobody's CI provider named, so absence can never be a rejection —
    # only a client sending something that is not a string is.
    #
    # A number is refused rather than coerced on purpose. `GITHUB_RUN_ID` and `CI_PIPELINE_ID` are
    # decimal integers, and a client that sent one as a JSON number would key its shards on
    # `12345` while another client keyed the same build on `"12345"`; splitting a run over a type
    # difference is precisely the failure this field exists to remove. One type, stated up front.
    def validate_ci_run_id
      value = @body["ci_run_id"]
      return if value.nil? || value.is_a?(String)

      @errors << "ci_run_id must be a string when present"
    end

    # Same rule and the same reason as `ci_run_id` above, and the number case matters more here,
    # not less: shard indexes are `0`, `1`, `2` on every runner that publishes one, so a client
    # sending them as JSON numbers is the *likely* mistake rather than an exotic one. `0` and
    # `"0"` keying different shards of one run would let a shard fail to replace itself, which is
    # the whole property these ids exist to provide.
    def validate_shard_id
      value = @body["shard_id"]
      return if value.nil? || value.is_a?(String)

      @errors << "shard_id must be a string when present"
    end

    def validate_duration_seconds
      value = @body["duration_seconds"]
      return if value.nil? || (value.is_a?(Numeric) && !value.negative?)

      @errors << "duration_seconds must be a non-negative number when present"
    end

    def validate_specs
      specs = @body["specs"]
      return @errors << "specs is required and must be an array" unless specs.is_a?(Array)

      specs.each_with_index { |spec, index| validate_spec(spec, index) }
      @specs = specs
    end

    def validate_spec(spec, index)
      return @errors << "#{label(spec, index)}: must be a JSON object" unless spec.is_a?(Hash)

      validate_file_path(spec, index)
      validate_line_number(spec, index)
      validate_status(spec, index)
      validate_intent(spec, index)
      validate_name(spec, index)
      validate_duration(spec, index)
    end

    def validate_file_path(spec, index)
      value = spec["file_path"]
      return if value.is_a?(String) && value.strip.present?

      @errors << "#{label(spec, index)}: file_path is required and must be a non-empty string"
    end

    def validate_line_number(spec, index)
      value = spec["line_number"]
      return if value.is_a?(Integer) && value.positive?

      @errors << "#{label(spec, index)}: line_number is required and must be a positive integer"
    end

    def validate_status(spec, index)
      return if STATUSES.include?(spec["status"])

      @errors << "#{label(spec, index)}: status must be one of #{STATUSES.join(', ')}"
    end

    # `intent` is required and schema-checked when the spec is annotated, and must be absent when
    # it is not — an unannotated spec that carries an intent is a client bug, and silently
    # dropping it would lose an annotation the author thought they had shipped.
    def validate_intent(spec, index)
      intent = spec["intent"]

      case spec["status"]
      when "annotated"
        if intent.nil?
          @errors << "#{label(spec, index)}: intent is required when status is \"annotated\""
          return
        end

        OpenTestIntent.validation_errors(intent).each do |message|
          @errors << "#{label(spec, index)}: intent is invalid — #{message}"
        end
      when "unannotated"
        return if intent.nil?

        @errors << "#{label(spec, index)}: intent must be null when status is \"unannotated\""
      end
    end

    # `name` is the example's `full_description` — the only thing describing a test in a suite that
    # annotates nothing, and therefore the field the cold-start case rests on. The shipped RSpec
    # formatter has always sent it for every example; the envelope simply never looked.
    #
    # Two rules, and a spec breaks at most one of them:
    #
    # 1. Present but not a non-empty string — a client bug, rejected the way every other ill-typed
    #    field is, whether or not the spec also carries an intent that would outrank it.
    # 2. Absent *and* no intent — rejected. Such a test can be counted and nothing else: there is
    #    no text for `Ingest::SpecSignal` to return (its `:none` case), so no consumer could ever
    #    say anything about it, and there is no field on which to record that condition. Accepting
    #    it and flagging it is the alternative, and it needs storage that does not exist.
    #
    # This is deliberately *not* the same rule as "annotations are optional". An unannotated spec
    # carrying a name is accepted, which is the ordinary shape of a suite mid-adoption and what
    # keeps the zero-annotation run valid.
    def validate_name(spec, index)
      value = spec["name"]

      if value.nil?
        return if spec["intent"]

        return @errors << "#{label(spec, index)}: name is required when the spec carries no intent"
      end

      return if value.is_a?(String) && value.strip.present?

      @errors << "#{label(spec, index)}: name must be a non-empty string when present"
    end

    # The per-example sibling of {#validate_duration_seconds}, and deliberately the same rule: a
    # negative duration is refused at this grain for exactly the reason it is refused at the run
    # grain, and nil stays ordinary — the client sends `result&.run_time`, so an example that never
    # ran has no timing and `Ingest::ObservationRecorder` records that nil as a faithful gap.
    #
    # Typed at all — unlike `outcome`, which `SpecObservation` states is deliberately unvalidated —
    # because the two fields are consumed differently. `outcome` is free text echoed back verbatim;
    # `duration` is summed, counted and ranked (`scope :timed`, `file_durations_in`, `slowest_in`),
    # so anything that is not a real measurement enters those aggregates as though it were one.
    # `upsert_all` serializes through `ActiveModel::Type::Float`, whose cast is a bare `to_f`: it
    # turns `"abc"` into `0.0` and `true` into `1.0` — fabricated timings, indistinguishable
    # afterwards from measured ones — and raises `NoMethodError` on a Hash or Array, which would
    # answer 500 from inside `Ingest::RunRecorder`'s transaction where this endpoint promises a
    # per-spec 400. This validator is the only gate: the model declares no `validates`, the schema
    # carries no check constraint, and `upsert_all` runs no validations regardless.
    def validate_duration(spec, index)
      value = spec["duration"]
      return if value.nil? || (value.is_a?(Numeric) && !value.negative?)

      @errors << "#{label(spec, index)}: duration must be a non-negative number when present"
    end

    # Names the offending spec by its own coordinates, falling back to the index alone when the
    # entry is malformed enough not to have any.
    def label(spec, index)
      location = spec.is_a?(Hash) ? [spec["file_path"], spec["line_number"]].compact.join(":") : nil

      location.presence ? "specs[#{index}] #{location}" : "specs[#{index}]"
    end
  end
end
