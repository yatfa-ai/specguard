# frozen_string_literal: true

# The shapes a `?compare_to=` query string can legally parse into that are NOT a branch name,
# pinned ONCE for every surface that reads the parameter (SPGD-1981 — today that is the console
# page; the API's growth blocks deliberately take no cross-branch ask).
#
# `?compare_to[]=main` is an Array, `?compare_to[a]=b` is an `ActionController::Parameters` and
# `?compare_to[][a]=b` is an Array of them. None is a String, and an unguarded `.presence` on any
# of them reaches a `where` that raises — a 500 on a URL anyone can type into the bar. The single
# guard they all land on is `RequestedCompareToParam#requested_compare_to`.
#
# A String that carries a NUL is the shape that list cannot see: `?compare_to=ma%00in` parses to
# a String and passes both halves of the guard, but Postgres cannot hold a NUL in a text value,
# so no row could ever match the ask — it is treated as no ask, like the shapes above.
#
# One list per parameter rather than one for the family, on the same grounds the
# `malformed_branch_param` file argues in full: each parameter's host asserts its own unasked
# render, and the guard modules stay free to diverge the day a parameter's shapes stop being
# interchangeable. The hazard is shared; the pin is per-surface.
RSpec.shared_examples "a surface that treats a malformed compare_to parameter as no ask" do
  [
    ["an array", { compare_to: ["main"] }],
    ["a nested hash", { compare_to: { a: "b" } }],
    ["an array of hashes", { compare_to: [{ a: "b" }] }],
    ["a string carrying a NUL", { compare_to: "ma\u0000in" }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedCompareToParam", action: "treat non-string and NUL-carrying compare_to as no ask", behavior: "a compare_to parameter in a non-String shape or carrying a NUL answers 200 with the byte-identical no-ask render rather than 500, matching an absent parameter", layer: "request" }
    it "answers 200 rather than 500 when compare_to arrives as #{shape}" do
      expect_compare_to_param_treated_as_no_ask(query)
    end
  end
end
