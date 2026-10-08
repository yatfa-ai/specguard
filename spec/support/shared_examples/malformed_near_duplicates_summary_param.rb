# frozen_string_literal: true

# The shapes a `?near_duplicates_summary=` query string can legally parse into that are NOT a
# String, pinned ONCE for every surface that reads the parameter: `?x[]=a` is an Array,
# `?x[a]=b` is an `ActionController::Parameters`, `?x[][a]=b` is an Array of them. All are truthy
# in Ruby, so an unguarded `.present?` would open the block on a query string nobody meant to
# send. The single guard they land on is
# `RequestedNearDuplicatesSummaryParam#requested_near_duplicates_summary?`.
#
# Its own file, one per parameter, on `malformed_near_duplicates_param.rb`'s reasoning. The
# assertion is the host's, in its own vocabulary:
#
#   describe "a near-duplicates-summary parameter that is not a string" do
#     def expect_near_duplicates_summary_param_treated_as_no_ask(query)
#       # request with `params: query`; assert 200 and the key present and null
#     end
#
#     it_behaves_like "a surface that treats a malformed near-duplicates-summary parameter as no ask"
#   end
#
# The host must assert the NO-ASK answer specifically, and keep a positive-path example beside
# the group: the malformed answer and the absent answer are the same `null`.
RSpec.shared_examples "a surface that treats a malformed near-duplicates-summary parameter as no ask" do
  [
    ["an array", { near_duplicates_summary: ["true"] }],
    ["a nested hash", { near_duplicates_summary: { a: "b" } }],
    ["an array of hashes", { near_duplicates_summary: [{ a: "b" }] }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedNearDuplicatesSummaryParam", action: "treat non-string near_duplicates_summary as no ask", behavior: "a near_duplicates_summary parameter in a non-String shape answers 200 with the key null rather than 500, matching an absent parameter", layer: "request" }
    it "answers 200 with no ask when near_duplicates_summary arrives as #{shape}" do
      expect_near_duplicates_summary_param_treated_as_no_ask(query)
    end
  end
end
