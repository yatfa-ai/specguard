# frozen_string_literal: true

# Every string a serialized block serves, at any depth — the assertion surface for "operands, never
# the labels".
#
# HERE RATHER THAN IN THE FILE THAT FIRST NEEDED IT, for the reason `ObservationGrainReads` and
# `QueryCapture` both give: RSpec scopes a `def` to its own example group, so a sibling's helper is
# invisible and the only way to reuse it is to copy it. Five request specs — the five
# `repository_directory_*_growth` files — need the same walk, and five copies are five walks free to
# drift.
#
# AND FOR FOUR OF THE FIVE COPIES THE DRIFT WOULD HAVE FAILED VACUOUSLY GREEN — measured, not
# asserted. Most call sites read
#
#   expect(strings_in(rows)).to all(start_with("spec/models/"))
#   expect(strings_in(rows)).not_to include("New file", "File removed", "Not timed", "±0")
#
# and `all` passes on an empty collection, as does `not_to include`. Drop the `when Array` branch and
# such a walk returns `[]` on the drill-in blocks whose rows are nested arrays; every one of those
# assertions still passes, so the guard stops catching label leakage entirely while reporting green.
#
# THE FIFTH IS THE ONE THAT WOULD HAVE CAUGHT IT, and which one that is turns on the OPERAND WALKED,
# not on the matcher. Four files do also assert positively —
# `expect(strings_in(window)).to contain_exactly(...)` at run_growth:173, runtime_growth:190,
# run_file:216 and runtime_file:276 — but `window` was measured to carry no array at all in any of
# the four, so the `Array` branch descends into nothing there and all four survive the mutation.
# Only repository_directory_growth_spec.rb:244 walks a NESTED operand positively: its `block` holds
# a single array, at `rows`, carrying the three area paths, and dropping the branch makes exactly
# those three elements go missing. That one example is the whole of the red.
#
# Which is the argument for defining the walk once, at its strongest: of the 20 invocations across
# these five files, 19 cannot tell a walk that has stopped walking from one that legitimately found
# nothing. A guard that has quietly stopped looking is worse than no guard, because it still reports
# a verdict — so the walk is DEFINED ONCE, here, and all five files stand behind the one invocation
# that can fail.
#
# WALKED RATHER THAN LISTED KEY BY KEY, so a label-shaped value added to a row, or to a block, later
# is caught by the same example rather than by nobody.
module SerializedStrings
  # Recursive on purpose, and the `Array` branch is the load-bearing one: the drill-in blocks nest
  # their rows inside arrays, so a walk that only descends through hashes reaches none of them.
  def strings_in(value)
    case value
    when Hash then value.values.flat_map { |inner| strings_in(inner) }
    when Array then value.flat_map { |inner| strings_in(inner) }
    when String then [value]
    else []
    end
  end
end

RSpec.configure do |config|
  config.include SerializedStrings
end
