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
# AND THE DRIFT HERE FAILS VACUOUSLY GREEN, which is why one copy each was the wrong shape. The call
# sites read
#
#   expect(strings_in(rows)).to all(start_with("spec/models/"))
#   expect(strings_in(rows)).not_to include("New file", "File removed", "Not timed", "±0")
#
# and `all` passes on an empty collection, as does `not_to include`. Drop the `when Array` branch
# from one copy and that file's walk returns `[]` on the drill-in blocks whose rows are nested
# arrays — every assertion still passes, the guard stops catching label leakage entirely, and it
# reports green while doing it. A guard that has quietly stopped looking is worse than no guard,
# because it still reports a verdict. So the walk is DEFINED ONCE, here.
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
