# frozen_string_literal: true

# The shapes a `?near_duplicate_cluster=` query string can legally parse into that are NOT a
# String (`?x[]=1` an Array, `?x[a]=b` an `ActionController::Parameters`, `?x[][a]=b` an Array of
# them), plus a String carrying a NUL, pinned ONCE for every surface that reads the parameter.
# The guard they land on is `RequestedNearDuplicateClusterParam#requested_near_duplicate_cluster`.
#
# All are NO ASK: the key is present and null, exactly as an absent parameter answers. That is
# deliberately different from a well-shaped String that is not a usable rank (`abc`, `0`, `-1`):
# that IS an ask, answered with `cluster: null` and the ask echoed, and the host pins it
# separately. The assertion below is the host's, in its own vocabulary:
#
#   def expect_near_duplicate_cluster_param_treated_as_no_ask(query)
#     # request with `params: query`; assert 200 and the `near_duplicate_cluster` key null
#   end
#
#   it_behaves_like "a surface that treats a malformed near-duplicate-cluster parameter as no ask"
RSpec.shared_examples "a surface that treats a malformed near-duplicate-cluster parameter as no ask" do
  [
    ["an array", { near_duplicate_cluster: ["1"] }],
    ["a nested hash", { near_duplicate_cluster: { a: "b" } }],
    ["an array of hashes", { near_duplicate_cluster: [{ a: "b" }] }],
    ["a string carrying a NUL", { near_duplicate_cluster: "1\u0000" }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedNearDuplicateClusterParam", action: "treat non-string and NUL-carrying near_duplicate_cluster as no ask", behavior: "a near_duplicate_cluster parameter in a non-String shape or carrying a NUL answers 200 with the key null rather than 500, matching an absent parameter", layer: "request" }
    it "answers 200 with no ask when near_duplicate_cluster arrives as #{shape}" do
      expect_near_duplicate_cluster_param_treated_as_no_ask(query)
    end
  end
end
