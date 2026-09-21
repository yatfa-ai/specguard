# frozen_string_literal: true

require "rails_helper"
require "stringio"
require "rspec/core/sandbox"

# The relation-statistics evidence `spec/support/query_capture.rb` attaches to a failing
# `plan_for_actual_sql` assertion: the `pg_class.reltuples`/`relpages` snapshot of the captured
# table and every index on it, taken at the moment the helper ran its EXPLAIN and surfaced on the
# failure path, so a reddening plan assertion arrives with the numbers that decided the access
# method rather than with the plan alone.
#
# Exercised against SANDBOXED inner examples rather than against the production assertions in
# spec/models/spec_observation_spec.rb, and that is the whole shape of this file — the same shape
# its sibling spec/lib/rows_touched_failure_evidence_spec.rb argues for the plan leg. What has to
# be certified is what a reader SEES when a plan assertion breaks — which needs an assertion that
# actually breaks, and the production assertions are green and must stay both green and unedited.
# `RSpec::Core::Sandbox` runs inner examples under a throwaway configuration and reporter, so a
# failure in there is an OBSERVATION here rather than a failure of this suite, and the rendered
# output is a String this file can assert on.
#
# Here rather than in spec/support on purpose, for the reason
# spec/lib/builders_fixture_identity_spec.rb states for itself: rails_helper blanket-requires every
# file under spec/support at boot, so a `*_spec.rb` placed there is pre-loaded before RSpec collects
# files and runs twice.
#
# ⚠️ ASSERTED ON PRESENCE, NEVER ON A NUMBER. The statistics the evidence carries are exactly the
# figures that move plan choice, and they move with fixture scale, with `ANALYZE`-perturbed
# `pg_class` state, and with whatever the catalog happens to carry when this file runs — the very
# variance the evidence exists to explain (`restores_relation_statistics_for` and its file document
# why; knowledge article SPGD-730 records that `--seed` is a dead knob here, so run-to-run variance
# is always state). An assertion on a reltuples or relpages figure would redden on exactly that
# variance. So these examples assert that a snapshot is THERE and that it names the table and the
# indexes whose numbers it carries — schema-stable names, not plan- or scale-dependent figures.
RSpec.describe "the plan_for_actual_sql assertion's relation-statistics failure evidence" do
  let(:repository) { create_repository }
  let(:run) { create_test_run(repository: repository) }

  before do
    2.times do |index|
      SpecObservation.create!(
        test_run: run, repository: repository, example_id: "./spec/a_spec.rb[1:#{index}]",
        file_path: "spec/a_spec.rb", spec_file_path: "spec/a_spec.rb",
        line_number: index + 1, status: "unannotated"
      )
    end
  end

  # The read the inner examples plan. Defined here so the inner group closes over one statement
  # shape and the two paths differ ONLY in whether their assertion holds.
  def observation_read_for(run_id)
    -> { SpecObservation.where(test_run_id: run_id).to_a }
  end

  # Runs `group_body` as inner examples under a throwaway RSpec configuration and hands back what
  # the inner reporter RENDERED. The sandbox resets `RSpec.configuration` and `RSpec.world` for the
  # duration, so the inner group is invisible to the outer run and an inner failure never reddens
  # this one.
  #
  # The wiring is installed through the one definition `spec/support/query_capture.rb` exposes, so
  # this file cannot drift from what the suite runs. `install_query_capture: false` is the CONTROL
  # arm — the same inner example rendered by a configuration that has never heard of this
  # mechanism, which is what makes "unchanged" assertable rather than merely asserted-about.
  def rendered_inner_run(install_query_capture: true, &group_body)
    output = StringIO.new

    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = output
      config.formatter = :progress
      QueryCapture.install_into(config) if install_query_capture

      RSpec.describe("inner", &group_body)
      RSpec.world.example_groups.each { |group| group.run(config.reporter) }
      config.reporter.report(0) { |_reporter| }
    end

    output.string
  end

  # An assertion no plan can ever satisfy, so a failing inner example fails INDEPENDENTLY of
  # whichever plan Postgres chooses — the rendered evidence is about the stats, and the assertion
  # that forced the failure must not depend on the plan content it is explaining. A CONSTANT rather
  # than a helper method, deliberately: the inner sandbox examples run on a different example-group
  # instance than this outer file, so a method defined here is invisible in there (it NameErrors
  # instead of failing the assertion, and the rendered red then cannot contain what these examples
  # assert about it) — a constant resolves lexically in both.
  IMPOSSIBLE_PLAN = /NO PLAN CAN EVER CONTAIN THIS SIGNATURE/

  # @intent: { entity: "QueryCapture", action: "fail a plan_for_actual_sql assertion", behavior: "the rendered failure carries the pg_class statistics snapshot of the captured table and its indexes, taken when the EXPLAIN ran", layer: "unit" }
  it "carries the catalog statistics behind the plan when the assertion fails" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "asserts an access method that cannot exist" do
        plan = plan_for_actual_sql("spec_observations") { read.call }
        expect(plan).to match(IMPOSSIBLE_PLAN)
      end
    end

    expect(rendered).to include(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER)
    # The captured table and every index on it are named as the holders of the figures — schema
    # names, which db/schema.rb fixes, rather than the figures themselves.
    expect(rendered).to include("── plan_for_actual_sql(\"spec_observations\"), invocation 1 ──")
    expect(rendered).to include("spec_observations: reltuples=")
    expect(rendered).to include("index_spec_observations_on_test_run_id: reltuples=")
    expect(rendered).to include("index_spec_observations_on_repository_id_and_name: reltuples=")
    expect(rendered).to match(/reltuples=\S+ relpages=\S+/)
    # The assertion's own text survives verbatim above the evidence — the evidence is appended,
    # never substituted.
    expect(rendered).to match(
      /#{Regexp.escape(IMPOSSIBLE_PLAN.source)}.*#{Regexp.escape(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER)}/m
    )
  end

  # @intent: { entity: "QueryCapture", action: "pass a plan_for_actual_sql assertion", behavior: "a satisfied assertion renders no evidence, so the green path is untouched", layer: "unit" }
  it "renders nothing when the assertion holds" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "asserts something every plan contains" do
        plan = plan_for_actual_sql("spec_observations") { read.call }
        expect(plan).to be_present
      end
    end

    expect(rendered).not_to include(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER)
    expect(rendered).to include("0 failures")
  end

  # A retained snapshot must not colour a later example's failure. RSpec builds a fresh
  # example-group instance per example, so this holds by construction rather than by the helper's
  # `ensure` — which is why it is certified here rather than assumed from the `ensure` being
  # present. The leak this exists to catch is one snapshot's worth of a PREVIOUS example's catalog
  # state rendered as if it explained THIS example's failure.
  # @intent: { entity: "QueryCapture", action: "fail an example that never called plan_for_actual_sql, after one that did", behavior: "no snapshot retained by an earlier example reaches a later example's failure", layer: "unit" }
  it "does not let a retained snapshot reach a later example's failure" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "retains a snapshot and fails" do
        plan = plan_for_actual_sql("spec_observations") { read.call }
        expect(plan).to match(IMPOSSIBLE_PLAN)
      end

      it "fails without ever calling the helper" do
        expect("inheriting nothing").to eq("something else")
      end
    end

    # Exactly the example that retained a snapshot wears one. The second failure is rendered in the
    # same output, so a leak would show up as a second evidence block.
    expect(rendered.scan(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER).length).to eq(1)
  end

  # The two legs of this file's evidence machinery are sibling `after` hooks, and the composition
  # between them is a real property rather than an accident: the hook that runs second dups the
  # FIRST hook's enriched exception, so an example that used both helpers fails with BOTH sections
  # and neither leg is lost to the other.
  # @intent: { entity: "QueryCapture", action: "fail an example that called both rows_touched and plan_for_actual_sql", behavior: "the rendered failure carries both evidence sections, neither clobbering the other", layer: "unit" }
  it "carries both evidence legs when one example used both helpers" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "uses both helpers and fails" do
        touched = rows_touched("spec_observations") { read.call }
        plan = plan_for_actual_sql("spec_observations") { read.call }
        expect(plan).to match(IMPOSSIBLE_PLAN)
        expect(touched).to be < 0
      end
    end

    expect(rendered).to include(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER)
    expect(rendered).to include(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER)
  end

  # AC7's shape, asserted as an EQUALITY rather than as an absence: the same failing example
  # rendered with the wiring installed and without it. Anything either hook did to an example
  # that never called a helper would show up as a difference between the two.
  #
  # The two arms are invoked from ONE call site and their wall-clock timings are scrubbed, because
  # both of those vary between any two runs of the same example and neither is what is being
  # compared — a backtrace line that differs because the two arms were typed on different lines
  # would redden a mechanism that did nothing at all.
  # @intent: { entity: "QueryCapture", action: "fail an example that never called a helper", behavior: "its rendered failure is what it would have been with the evidence wiring absent", layer: "unit" }
  it "leaves a failure alone when the example never called a helper" do
    body = proc do
      it "fails without the helpers" do
        expect("untouched").to eq("something else")
      end
    end

    with_wiring, without_wiring = [true, false].map do |wired|
      rendered_inner_run(install_query_capture: wired, &body).gsub(/[\d.]+ seconds/, "<elapsed>")
    end

    expect(with_wiring).to eq(without_wiring)
  end

  # The aggregate shape, which reaches the hooks by a different door: an `aggregate_failures` block
  # written inside a body surfaces as one exception carrying a LIST, so the evidence takes an entry
  # of its own rather than being appended to a message that belongs to only one of the entries.
  # @intent: { entity: "QueryCapture", action: "fail a plan_for_actual_sql assertion inside an aggregate_failures block", behavior: "the statistics are carried as their own entry beside the aggregated failures rather than appended to one of them", layer: "unit" }
  it "carries the statistics beside an aggregated failure rather than inside one of them" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "fails two plan assertions at once" do
        plan = plan_for_actual_sql("spec_observations") { read.call }

        aggregate_failures do
          expect(plan).to match(IMPOSSIBLE_PLAN)
          expect(plan).to match(/A SECOND IMPOSSIBLE SIGNATURE/)
        end
      end
    end

    expect(rendered).to include(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER)
    # Both assertions are still reported, so the evidence was added beside them and replaced
    # neither.
    expect(rendered).to include("NO PLAN CAN EVER CONTAIN THIS SIGNATURE")
    expect(rendered).to include("A SECOND IMPOSSIBLE SIGNATURE")
  end

  # The capture leg's cost pin, stated as an INVARIANT against the helper's own retained
  # invocations rather than against a figure: the capture-time snapshot pays one catalog SELECT per
  # `plan_for_actual_sql` invocation BY DESIGN — it is what makes the evidence immune to the
  # restore/autovacuum ordering a failure-path re-read would race — and the design's claim is that
  # it pays exactly one, and nothing beyond it.
  # @intent: { entity: "QueryCapture", action: "call plan_for_actual_sql", behavior: "capturing the snapshot costs exactly one pg_class catalog SELECT per invocation and nothing more", layer: "unit" }
  it "pays exactly one catalog SELECT per invocation for the snapshot" do
    read = observation_read_for(run.id)

    catalog_selects = queries_against(/pg_class/) do
      plan_for_actual_sql("spec_observations") { read.call }
      plan_for_actual_sql("spec_observations") { read.call }
    end

    expect(catalog_selects.length).to eq(retained_plan_relation_statistics.length)
    expect(catalog_selects).to all(include("FROM pg_class"))
  end

  # The other half of the same pin: rendering the evidence walks a structure already in hand, so
  # it talks to the database not at all — on the failure path as on the green one.
  # @intent: { entity: "QueryCapture", action: "render the retained relation statistics evidence", behavior: "formatting the evidence issues no query, because every datum was already in hand at capture", layer: "unit" }
  it "issues no query while rendering the evidence it retained" do
    read = observation_read_for(run.id)
    plan_for_actual_sql("spec_observations") { read.call }

    rendered = nil
    statements = executed_sql { rendered = plan_relation_statistics_evidence }

    expect(statements).to be_empty
    expect(rendered).to include(QueryCapture::PLAN_RELATION_STATISTICS_EVIDENCE_HEADER)
  end

  # @intent: { entity: "QueryCapture", action: "fail a plan_for_actual_sql assertion while rendering the evidence raises", behavior: "the assertion failure survives intact and the message says inline that evidence collection failed", layer: "unit" }
  it "says so inline and leaves the failure intact when collecting the evidence raises" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "asserts an impossible plan while the collector is broken" do
        define_singleton_method(:plan_relation_statistics_evidence) do
          raise "collector is deliberately broken"
        end

        plan = plan_for_actual_sql("spec_observations") { read.call }
        expect(plan).to match(IMPOSSIBLE_PLAN)
      end
    end

    # The assertion's own failure is what the reader still sees first, and the collector's own
    # trouble is reported beside it rather than in place of it.
    expect(rendered).to match(
      /NO PLAN CAN EVER CONTAIN THIS SIGNATURE.*could not be collected.*collector is deliberately broken/m
    )
  end
end
