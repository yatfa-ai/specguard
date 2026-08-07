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
  # only malformed ones are — because adoption has to be opt-in and gradual.
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

    # The specs carrying an intent — what slice 3's embed + upsert job will consume. Only
    # meaningful once `valid?`, which is what guarantees every status is one of STATUSES and so
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

    private

    def validate
      return @errors << "the request body must be a JSON object" unless object_body?

      validate_commit_sha
      validate_branch
      validate_ci_run_id
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

    # Names the offending spec by its own coordinates, falling back to the index alone when the
    # entry is malformed enough not to have any.
    def label(spec, index)
      location = spec.is_a?(Hash) ? [spec["file_path"], spec["line_number"]].compact.join(":") : nil

      location.presence ? "specs[#{index}] #{location}" : "specs[#{index}]"
    end
  end
end
