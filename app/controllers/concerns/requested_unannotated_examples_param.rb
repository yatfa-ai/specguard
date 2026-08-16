# frozen_string_literal: true

# `?unannotated_examples=` read as a REQUEST FOR THE BLOCK — the predicate answers `false` when there
# is no ask. NOT a boolean cast of the value: `?unannotated_examples=false` opens the block like any
# other non-blank string. See the ⭐ section below, which exists to prevent exactly that misreading.
#
# The siblings' summary lines each name their reader's no-ask return (`nil`) and this one names its
# own, but `false` is the one such token a client can also SEND here, so naming it alone would hand a
# reader the wrong inference in the file's most-read position.
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one module
# per parameter is the point of the split — the argument `RequestedSpecFileParam` makes for itself and
# `RequestedRepeatedDescriptionParam` and `RequestedUnstableTestParam` make again. The parameters mean
# different things, are read by different blocks, and one guard answering several of them would make
# "which shapes does each tolerate" a single question nobody asked. What they share is the hazard, and
# the guard for it is the same two lines in the same order.
#
# == ⭐ THE FIRST FLAG-STYLE PARAMETER ON THIS ENDPOINT, and why this one has no value to carry
#
# The six shipped parameters all name a WHICH: which branch, which commit, which area, which file,
# which description, which test. Each opens the rows behind a LINE of a ranking the client had already
# read, so the ask is the line's own key and the block restates it back — `path`, `name`, `branch`.
#
# This one opens a POPULATION rather than a pick. The figure it drills out of is not a ranking at all
# but a subtraction on the run itself (`total_specs_count - annotated_specs_count`, rendered on the
# dashboard as *"SpecGuard cannot see the other N tests"*), and a subtraction has no rows to have keys.
# There is exactly one answer the client can be asking for, so there is nothing for the parameter to
# carry and nothing for the block to restate. The predicate spelling here — `requested_unannotated_examples?`
# rather than a `requested_*` reader — is what says so at every call site: the six siblings answer
# "which one", and this answers "at all".
#
# **THE VALUE IS NOT READ, AND THAT INCLUDES `false`.** `?unannotated_examples=false` opens the block,
# exactly as `?unannotated_examples=true` and `?unannotated_examples=x` do, because what is being
# tested is that the client NAMED the parameter. The alternative — a truthiness vocabulary, `"true"`
# and `"1"` in and everything else out — was rejected twice over: it would be a third line of guard
# and a vocabulary no sibling on this endpoint has, and it would spell "I sent a word you do not
# recognise" and "I sent a shape that is not a String" the same way, which is precisely the collapse
# the two lines below exist to avoid. A client that does not want the block omits the parameter, which
# is how it declines the other six — none of which has an "off" value either.
#
# `is_a?(String)` FIRST, and it is not defensive noise even though nothing here reaches SQL:
# `?unannotated_examples[]=x` parses to an Array, `?unannotated_examples[a]=b` to
# `ActionController::Parameters` and `?unannotated_examples[][a]=b` to an Array of them. The hazard is
# the mirror of the siblings' rather than a weaker version of it — they risk a silent WRONG answer,
# where an Array becomes an `IN` list under a caption naming one thing, and this one risks a silent
# EXTRA answer: every one of those three shapes is truthy in Ruby, so an unguarded `params[:unannotated_examples].present?`
# would open a hundred-row block on a query string the client did not mean to send, and go on doing it
# on every request a broken serializer makes. Anything that is not a String is treated as no ask, which
# is the same answer an absent param gets — the response is exactly what it was before the parameter
# existed. All three shapes are pinned; see
# `spec/support/shared_examples/malformed_unannotated_examples_param.rb`.
#
# `.presence` SECOND, and what it buys here is different from what it buys the siblings. There it stops
# an empty ask becoming `WHERE column = ''`, a query for a value no row can carry; there is no column
# to compare against here at all. It stops `?unannotated_examples=` — which is what a browser sends for
# an unfilled form field, and what a client building a query string from a nil variable sends — from
# opening the block, so an ask has to be affirmative rather than merely present in the URL.
#
# No validation branch and no 400: there is no malformed value to correct, because there is no value.
# And no 404 on the empty answer, which at this parameter is the reverse of the siblings' reasoning
# rather than a copy of it — a run with no unannotated examples is not a stale bookmark or a typo, it
# is the SUCCESS state the metric exists to reach, and `UnannotatedExamples` returns an object with no
# rows and an honest zero for it.
module RequestedUnannotatedExamplesParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, for the reason every sibling gives and one this
  # spelling makes sharper: `||=` re-reads the params on every call whenever the memo is FALSY, and
  # here the falsy answer — no ask — is not merely the common one, it is the only one a client that
  # never sends the parameter can get. The same idiom, for the same reason, as
  # `RequestedSpecFileParam#requested_spec_file`.
  def requested_unannotated_examples?
    return @requested_unannotated_examples if defined?(@requested_unannotated_examples)

    raw = params[:unannotated_examples]
    @requested_unannotated_examples = raw.is_a?(String) && raw.present?
  end
end
