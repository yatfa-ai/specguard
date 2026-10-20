# frozen_string_literal: true

# THE request+system share of a run's DECLARED-LAYER mix — `(request + system) /
# (unit + integration + request + system)` — as ONE expression every reader of the rule calls.
#
# The rule had one reader for most of its life: the `?sort=pyramid` ordering
# (`RepositoryNarrowing#pyramid_first`), which ranks repositories by the share but states only the
# ORDER — the figure the order was taken on appeared nowhere on the grid, so a reader of a
# pyramid-sorted page could see that a card was first without being able to ask how thin "thin"
# was, or what separated two adjacent cards. The grid card's sentence
# (`ApplicationHelper#test_run_pyramid_share`) is the second reader, and it needs the operands as
# well as the share: the percentage carries its denominator, and the counts state both operands
# with it. Handing both out of here keeps the sort and the sentence on one expression — the card
# cannot word the sort key differently from what the sort computes, and neither can drift about
# WHICH layers are the top of the pyramid.
#
# == The rule, unchanged from where it was first written
#
# The denominator EXCLUDES `undeclared` on purpose ({RepositoryNarrowing} carries the full
# argument): counting it would rank a never-annotated suite as "no request tests" and make this
# share a second spelling of the annotated share's job. A mix whose declared total is 0 — every
# example undeclared — has no share and answers nil rather than 0.0, exactly as the ordering
# ranks it unmeasured rather than first: a suite nobody measured a layer for must never read as
# "all unit". A MEASURED zero (declared examples exist, none of them request or system) IS a real
# `0.0`. Nil counts — a run that recorded no per-example rows — are nil for the same "no
# denominator" reason.
#
# Pure arithmetic over the hash the caller already holds (`TestRun#layer_counts`, primed for the
# whole grid by one grouped read): no query, ever.
module PyramidShare
  # The share as a 0–1 fraction — {RepositoryNarrowing#pyramid_share}'s answer verbatim — or nil
  # when there is nothing declared to take a share of (no mix at all, or a declared total of 0).
  def self.of(layer_counts)
    top, declared = operands(layer_counts)
    return nil unless top

    top.fdiv(declared)
  end

  # The [top, declared] operands the share is taken over, or nil under exactly the conditions
  # {of} answers nil. The sentence prints BOTH — the percentage and its denominator come off the
  # same pair — so the denominator is never re-derived from the fraction.
  def self.operands(layer_counts)
    return nil if layer_counts.nil?

    top = layer_counts.fetch(:request, 0) + layer_counts.fetch(:system, 0)
    declared = top + layer_counts.fetch(:unit, 0) + layer_counts.fetch(:integration, 0)
    declared.zero? ? nil : [top, declared]
  end
end
