# frozen_string_literal: true

require "rails_helper"
require "stringio"
require "rspec/core/sandbox"

# The failure evidence `spec/support/query_capture.rb` attaches to a `rows_touched` bound: the
# `EXPLAIN (ANALYZE)` plan the helper had already fetched, surfaced on the failure path instead of
# discarded, so a reddening bound arrives with its access method and per-node actual rows rather
# than as a naked number comparison.
#
# Exercised against SANDBOXED inner examples rather than against the production bounds in
# spec/models/spec_observation_spec.rb, and that is the whole shape of this file. What has to be
# certified is what a reader SEES when a bound breaks — which needs a bound that actually breaks,
# and the production bounds are green and must stay both green and unedited. `RSpec::Core::Sandbox`
# runs inner examples under a throwaway configuration and reporter, so a failure in there is an
# OBSERVATION here rather than a failure of this suite, and the rendered output is a String this
# file can assert on.
#
# Here rather than in spec/support on purpose, for the reason
# spec/lib/builders_fixture_identity_spec.rb states for itself: rails_helper blanket-requires every
# file under spec/support at boot, so a `*_spec.rb` placed there is pre-loaded before RSpec collects
# files and runs twice.
#
# ⚠️ ASSERTED ON PRESENCE, NEVER ON A NUMBER. The rows a plan touches move with fixture scale, and
# WHICH plan Postgres picks moves with table bloat and with the order RSpec happens to run in — the
# very variance this evidence exists to explain (`restores_relation_statistics_for` and its file
# document why; knowledge article SPGD-730 records that `--seed` is a dead knob here, so run-to-run
# variance is always state). An assertion on a row figure or on a literal node name would redden on
# exactly that variance. So these examples assert that a plan is THERE and that it names the access
# method it chose, whichever one that is.
RSpec.describe "the rows_touched bound's failure evidence" do
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

  # The read the inner examples bound. Defined here so the inner group closes over one statement
  # shape and the two paths differ ONLY in whether their bound holds.
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

  # @intent: { entity: "QueryCapture", action: "fail a rows_touched bound", behavior: "the rendered failure carries the plan of the statement that produced the number, naming its access method and its per-node actual rows", layer: "unit" }
  it "carries the plan of the statement that produced the number when the bound fails" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "exceeds its bound" do
        touched = rows_touched("spec_observations") { read.call }
        expect(touched).to be < 0
      end
    end

    expect(rendered).to include(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER)
    # The access method the planner chose, whichever it chose: every plan node names one, and the
    # node the helper counted names the relation it was taken against.
    expect(rendered).to match(/(?:Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan).*spec_observations/)
    expect(rendered).to include("actual rows=")
    # The bound's own text survives verbatim above the evidence — the evidence is appended, never
    # substituted.
    expect(rendered).to match(/expected: < 0.*#{Regexp.escape(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER)}/m)
    # And it is attributable: the label says which invocation, against which table, produced it.
    expect(rendered).to include('rows_touched("spec_observations"), invocation')
  end

  # @intent: { entity: "QueryCapture", action: "pass a rows_touched bound", behavior: "a satisfied bound renders no evidence, so the green path is untouched", layer: "unit" }
  it "renders nothing when the bound holds" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "stays inside its bound" do
        touched = rows_touched("spec_observations") { read.call }
        expect(touched).to be >= 0
      end
    end

    expect(rendered).not_to include(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER)
    expect(rendered).to include("0 failures")
  end

  # A retained plan must not colour a later example's failure. RSpec builds a fresh example-group
  # instance per example, so this holds by construction rather than by the helper's `ensure` —
  # which is why it is certified here rather than assumed from the `ensure` being present.
  # @intent: { entity: "QueryCapture", action: "fail an example that never called rows_touched, after one that did", behavior: "no plan retained by an earlier example reaches a later example's failure", layer: "unit" }
  it "does not let a retained plan reach a later example's failure" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "retains a plan and fails" do
        touched = rows_touched("spec_observations") { read.call }
        expect(touched).to be < 0
      end

      it "fails without ever calling the helper" do
        expect("inheriting nothing").to eq("something else")
      end
    end

    # Exactly the example that retained a plan wears one. The second failure is rendered in the
    # same output, so a leak would show up as a second evidence block.
    expect(rendered.scan(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER).length).to eq(1)
  end

  # AC7, asserted as an EQUALITY rather than as an absence: the same failing example rendered with
  # the wiring installed and without it. Anything the hook did to an example that never called the
  # helper would show up as a difference between the two.
  #
  # The two arms are invoked from ONE call site and their wall-clock timings are scrubbed, because
  # both of those vary between any two runs of the same example and neither is what is being
  # compared — a backtrace line that differs because the two arms were typed on different lines
  # would redden a mechanism that did nothing at all.
  # @intent: { entity: "QueryCapture", action: "fail an example that never called rows_touched", behavior: "its rendered failure is what it would have been with the evidence wiring absent", layer: "unit" }
  it "leaves a failure alone when the example never called the helper" do
    body = proc do
      it "fails without the helper" do
        expect("untouched").to eq("something else")
      end
    end

    with_wiring, without_wiring = [true, false].map do |wired|
      rendered_inner_run(install_query_capture: wired, &body).gsub(/[\d.]+ seconds/, "<elapsed>")
    end

    expect(with_wiring).to eq(without_wiring)
  end

  # The aggregate shape, which reaches the hook by a different door: an `aggregate_failures` block
  # written inside a body surfaces as one exception carrying a LIST, so the evidence takes an entry
  # of its own rather than being appended to a message that belongs to only one of the entries.
  # @intent: { entity: "QueryCapture", action: "fail a rows_touched bound inside an aggregate_failures block", behavior: "the plan is carried as its own entry beside the aggregated failures rather than appended to one of them", layer: "unit" }
  it "carries the plan beside an aggregated failure rather than inside one of them" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "exceeds two bounds at once" do
        touched = rows_touched("spec_observations") { read.call }

        aggregate_failures do
          expect(touched).to be < 0
          expect(touched).to be < -1
        end
      end
    end

    expect(rendered).to include(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER)
    # Both bounds are still reported, so the evidence was added beside them and replaced neither.
    expect(rendered).to include("expected: < 0")
    expect(rendered).to include("expected: < -1")
  end

  # AC4's pin, and the one that a well-meaning "fix" would break first: the evidence is the plan
  # ALREADY fetched, so nothing about it may cost a second round trip. Stated as an invariant
  # against the helper's own retained invocations rather than against a figure, because the figure
  # is a property of whatever the example happens to do.
  # @intent: { entity: "QueryCapture", action: "call rows_touched on the green path", behavior: "planning costs one EXPLAIN per invocation and the evidence machinery adds no query of its own", layer: "unit" }
  it "issues no EXPLAIN beyond the one each invocation already makes" do
    read = observation_read_for(run.id)

    explains = queries_against(/EXPLAIN/) do
      rows_touched("spec_observations") { read.call }
      rows_touched("spec_observations") { read.call }
    end

    expect(explains.length).to eq(retained_rows_touched_plans.length)
    expect(explains).to all(include("EXPLAIN (ANALYZE, FORMAT JSON)"))
  end

  # The other half of the same pin: rendering the evidence walks a structure already in hand, so
  # it talks to the database not at all — on the failure path as on the green one.
  # @intent: { entity: "QueryCapture", action: "render the retained plan evidence", behavior: "formatting the evidence issues no query, because every datum was already in hand", layer: "unit" }
  it "issues no query while rendering the evidence it retained" do
    read = observation_read_for(run.id)
    rows_touched("spec_observations") { read.call }

    rendered = nil
    statements = executed_sql { rendered = rows_touched_plan_evidence }

    expect(statements).to be_empty
    expect(rendered).to include(QueryCapture::ROWS_TOUCHED_EVIDENCE_HEADER)
  end

  # @intent: { entity: "QueryCapture", action: "fail a rows_touched bound while rendering the evidence raises", behavior: "the assertion failure survives intact and the message says inline that evidence collection failed", layer: "unit" }
  it "says so inline and leaves the failure intact when collecting the evidence raises" do
    read = observation_read_for(run.id)

    rendered = rendered_inner_run do
      it "exceeds its bound while the collector is broken" do
        define_singleton_method(:rows_touched_plan_evidence) do
          raise "collector is deliberately broken"
        end

        touched = rows_touched("spec_observations") { read.call }
        expect(touched).to be < 0
      end
    end

    # The bound's own failure is what the reader still sees first, and the collector's own trouble
    # is reported beside it rather than in place of it.
    expect(rendered).to match(/expected: < 0.*could not be collected.*collector is deliberately broken/m)
  end
end
