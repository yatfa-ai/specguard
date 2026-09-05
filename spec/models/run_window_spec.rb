# frozen_string_literal: true

require "rails_helper"

# The window type that carries its orientation. `RunWindow` reads no run attribute and issues no
# query — it is an ordering over rows already loaded — so bare strings stand in for the runs here:
# what is under test is which end each accessor hands back, and that the rows it was built from
# are never reordered under it. Everything that DECIDES the orientation (the web's
# `.to_a.reverse`, the API's `(created_at, id) DESC`) is pinned where it belongs, in
# spec/models/repository_spec.rb; what is pinned here is that the type holds the fact it is given
# and returns either end without mutating anything.
RSpec.describe RunWindow do
  # Each fixture is named for the orientation it is HANDED IN — the constructors label the order
  # they are given and never re-sort, so a `.newest_first` example hands rows newest first. Both
  # fixtures carry the same three runs with a middle row, so a reversal is visible between the two
  # ends rather than only at them.
  let(:oldest_first_rows) { %w[oldest middle newest] }
  let(:newest_first_rows) { %w[newest middle oldest] }

  describe "constructed .oldest_first" do
    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "a window built oldest_first returns the rows oldest first as the same array and newest first as a fresh reversed copy", layer: "unit" }
    it "answers #oldest_first with the rows as built and #newest_first with them reversed" do
      window = described_class.oldest_first(oldest_first_rows)

      expect(window.oldest_first).to eq(%w[oldest middle newest])
      expect(window.newest_first).to eq(%w[newest middle oldest])
    end

    # Same-object for the orientation the window already carries is deliberate, not an
    # optimisation to preserve by accident: the point of the window is that the rows are the ONE
    # loaded array the surface memoized, and a reader walking that orientation walks those rows —
    # which is also what keeps the API's `history` serialization on the memoized array rather
    # than on a copy of it.
    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "asking for the orientation the window already carries returns the loaded array itself, not a copy", layer: "unit" }
    it "answers the orientation it was built with with the same array object" do
      window = described_class.oldest_first(oldest_first_rows)

      expect(window.oldest_first).to be(oldest_first_rows)
    end
  end

  describe "constructed .newest_first" do
    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "a window built newest_first returns the rows newest first as the same array and oldest first as a fresh reversed copy", layer: "unit" }
    it "answers #newest_first with the rows as built and #oldest_first with them reversed" do
      window = described_class.newest_first(newest_first_rows)

      expect(window.newest_first).to eq(%w[newest middle oldest])
      expect(window.oldest_first).to eq(%w[oldest middle newest])
    end

    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "asking for the orientation the window already carries returns the loaded array itself, not a copy", layer: "unit" }
    it "answers the orientation it was built with with the same array object" do
      window = described_class.newest_first(newest_first_rows)

      expect(window.newest_first).to be(newest_first_rows)
    end
  end

  # THE LOAD-BEARING PIN. The hazard has two directions and both are held. Inside the accessors:
  # `.reverse!` would flip the source array in place and corrupt every other reader of the window —
  # the API's `history` block maps the same memoized array under a declared `ingested_at_desc`
  # contract, so an in-place reversal there would make the endpoint's own ordering contract a lie
  # in the same response body. And at the CALL SITE: the accessor whose orientation the window
  # carries hands back the memoized array ITSELF, so a caller "tidying" what it was handed
  # (`reverse!`, `sort!`, `<<`, `shift`) would corrupt the same rows through the same alias. The
  # first direction is held by the `.reverse`-not-`reverse!` discipline below; the second is
  # structural — the loaded array is frozen at construction, so a mutating caller gets a
  # FrozenError at its own line rather than a window that silently reorders under its readers.
  describe "never mutates the rows it was built from" do
    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "asking for the orientation the window does not carry returns a fresh copy and leaves the source array in its original order", layer: "unit" }
    it "returns a fresh reversed copy and leaves the source order untouched" do
      oldest_first_window = described_class.oldest_first(oldest_first_rows)
      newest_first_window = described_class.newest_first(newest_first_rows)

      expect(oldest_first_window.newest_first).not_to be(oldest_first_rows)
      expect(newest_first_window.oldest_first).not_to be(newest_first_rows)

      expect(oldest_first_window.newest_first).to eq(%w[newest middle oldest])
      expect(oldest_first_window.newest_first).to eq(%w[newest middle oldest])
      expect(newest_first_window.oldest_first).to eq(%w[oldest middle newest])
      expect(newest_first_window.oldest_first).to eq(%w[oldest middle newest])

      expect(oldest_first_rows).to eq(%w[oldest middle newest])
      expect(newest_first_rows).to eq(%w[newest middle oldest])
      expect(oldest_first_window.runs).to eq(%w[oldest middle newest])
      expect(newest_first_window.runs).to eq(%w[newest middle oldest])
    end
  end

  # The caller-mutation direction of the same hazard, now closed by construction: the loaded array
  # is frozen at construction, so a consumer that "tidies" what a `RunWindow` hands back — the
  # exact accident a remembered `.reverse` invited — gets a FrozenError at its own line instead of
  # reordering the memoized window under every other reader of it. Both aliased accessors and
  # `#runs` are pinned; the copied accessor is pinned the other way, because its freshness is the
  # OTHER half of the guarantee — mutating a reversed copy is allowed and reaches nothing.
  describe "hands back rows a caller cannot corrupt" do
    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "mutating the array handed back in the window's own orientation raises FrozenError and leaves the window answering its original order", layer: "unit" }
    it "freezes the array handed back in the orientation the window carries" do
      oldest_first_window = described_class.oldest_first(oldest_first_rows)
      newest_first_window = described_class.newest_first(newest_first_rows)

      expect { oldest_first_window.oldest_first.reverse! }.to raise_error(FrozenError)
      expect { newest_first_window.newest_first.reverse! }.to raise_error(FrozenError)

      expect(oldest_first_window.oldest_first).to eq(%w[oldest middle newest])
      expect(newest_first_window.newest_first).to eq(%w[newest middle oldest])
    end

    # `#runs` is the same loaded array under a different name — the order-propagating reader's
    # accessor — so it carries the same freeze.
    # @intent: { entity: "RunWindow", action: "hand back the rows as handed", behavior: "mutating #runs raises FrozenError; the rows the window answers stay in their constructed orientation", layer: "unit" }
    it "freezes #runs against in-place mutation" do
      window = described_class.oldest_first(oldest_first_rows)

      expect { window.runs << "sneaky" }.to raise_error(FrozenError)
      expect(window.runs).to eq(%w[oldest middle newest])
    end

    # The copy direction is unshared, and that is the guarantee pinned here: a caller mutating the
    # reversed copy is mutating an array nobody else holds, so it neither raises nor reaches the
    # window.
    # @intent: { entity: "RunWindow", action: "hand back either orientation", behavior: "mutating the reversed copy neither raises nor reaches the window — the copy is fresh and unshared", layer: "unit" }
    it "leaves the reversed copy unshared with the window" do
      oldest_first_window = described_class.oldest_first(oldest_first_rows)

      copy = oldest_first_window.newest_first
      copy.reverse!

      expect(oldest_first_window.newest_first).to eq(%w[newest middle oldest])
      expect(oldest_first_window.oldest_first).to eq(%w[oldest middle newest])
    end
  end

  describe "#runs" do
    # `#runs` is "as handed" — the accessor the order-propagating reader (`UnstableTestRuns`) and
    # the order-indifferent one (`UnstableTests`) take. It must never re-sort: whichever
    # orientation the window was built with IS the answer.
    # @intent: { entity: "RunWindow", action: "hand back the rows as handed", behavior: "#runs returns the rows in the orientation the window was constructed with, never re-sorted", layer: "unit" }
    it "returns the rows in their constructed orientation, from either construction" do
      expect(described_class.oldest_first(oldest_first_rows).runs).to eq(%w[oldest middle newest])
      expect(described_class.newest_first(newest_first_rows).runs).to eq(%w[newest middle oldest])
    end
  end

  describe ".wrap" do
    # The presenters' seam. A typed window passes through untouched — re-wrapping it would lose
    # the orientation the surface stated at the load.
    # @intent: { entity: "RunWindow", action: "normalise a presenter's window parameter", behavior: "wrapping a RunWindow returns that same window with its orientation intact", layer: "unit" }
    it "returns a RunWindow unchanged" do
      window = described_class.newest_first(newest_first_rows)

      expect(described_class.wrap(window)).to be(window)
    end

    # The bare-array branch exists for callers that predate the type (the presenter-level specs),
    # and the reading it assumes is the contract those callers' `@param` prose documented:
    # OLDEST FIRST.
    # @intent: { entity: "RunWindow", action: "normalise a presenter's window parameter", behavior: "wrapping a bare array reads it as oldest first, the documented legacy contract", layer: "unit" }
    it "reads a bare array as oldest first" do
      window = described_class.wrap(oldest_first_rows)

      expect(window).to be_a(described_class)
      expect(window.oldest_first).to be(oldest_first_rows)
      expect(window.newest_first).to eq(%w[newest middle oldest])
    end

    # `SuiteTrajectory` folded its parameter through `Array(runs)`, which turns `nil` into an
    # empty series; `.wrap` keeps that behaviour so no caller has to grow a nil guard.
    # @intent: { entity: "RunWindow", action: "normalise a presenter's window parameter", behavior: "wrapping nil folds to an empty window the way Array(nil) does", layer: "unit" }
    it "folds nil to an empty window" do
      expect(described_class.wrap(nil)).to be_empty
    end
  end

  describe "an empty window" do
    # Every presenter already branches on emptiness before it asks for an end; the type's job here
    # is to keep BOTH accessors answerable on the window with no runs, so the empty branch can ask
    # the same question the populated one does.
    # @intent: { entity: "RunWindow", action: "answer on a window with no runs", behavior: "an empty window answers both accessors with an empty array, and size and empty? with zero and true", layer: "unit" }
    it "answers both orientations, size and empty? without runs" do
      window = described_class.oldest_first([])

      expect(window.oldest_first).to eq([])
      expect(window.newest_first).to eq([])
      expect(window.runs).to eq([])
      expect(window.size).to eq(0)
      expect(window.length).to eq(0)
      expect(window).to be_empty
    end
  end

  describe "#size and #length" do
    # @intent: { entity: "RunWindow", action: "count the window", behavior: "size and length both answer the number of runs the window holds", layer: "unit" }
    it "counts the rows either way" do
      expect(described_class.oldest_first(oldest_first_rows).size).to eq(3)
      expect(described_class.oldest_first(oldest_first_rows).length).to eq(3)
      expect(described_class.newest_first(newest_first_rows).size).to eq(3)
    end
  end

  describe "#any? and #empty?" do
    # Size questions, deliberately not orientation questions: `repositories#show` gates four
    # panels on `trajectory_runs.any?`, and that gate must not depend on which end the window
    # starts from.
    # @intent: { entity: "RunWindow", action: "answer the emptiness questions", behavior: "any? and empty? answer about the window's population from either construction, independent of orientation", layer: "unit" }
    it "answers the population without caring about the orientation" do
      expect(described_class.oldest_first(oldest_first_rows)).to be_any
      expect(described_class.newest_first(newest_first_rows)).to be_any
      expect(described_class.oldest_first([])).not_to be_any
      expect(described_class.oldest_first([])).to be_empty
      expect(described_class.newest_first([])).to be_empty
    end
  end
end
