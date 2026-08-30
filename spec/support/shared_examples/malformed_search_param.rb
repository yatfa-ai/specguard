# frozen_string_literal: true

# The shapes a `?q=` query string can legally parse into that are NOT a search string, pinned ONCE
# for every surface that reads the parameter.
#
# `?q[]=x` is an Array, `?q[a]=b` is an `ActionController::Parameters` and `?q[][a]=b` is an Array
# of them. None is a String, and the single guard they all land on is
# `RequestedSearchParam#requested_search`.
#
# Its own file rather than a widening of any sibling `malformed_*_param.rb`, and one file per
# parameter is the point of the split — each doc comment governs ONE parameter, and folding a
# second into a sibling's would make one list stand for two questions that are free to be answered
# differently.
#
# The consequence this parameter's non-String shapes carry is the SILENT one: on `?branch=` an
# Array reaching the `where` RAISES — a loud 500 — while a search parameter is headed for a
# pattern match that a coerced shape would answer with rows nobody asked about, under a search
# box echoing an ask nobody made. A silent wrong answer needs the guard more than a crash does,
# not less, which is the reason `malformed_spec_file_param.rb` records for its own parameter and
# the reason this file records for this one.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally
# have. Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "a search parameter that is not a search string" do
#     def expect_search_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer: every
#       # repository rendered, in the default order
#     end
#
#     it_behaves_like "a surface that treats a malformed search parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically — every
# card, default order — not merely a 200: a guard that swallowed every value would also answer 200
# on all three shapes, and only the positive-path example beside the host group — the one that
# proves `?q=<text>` IS honoured — separates the two. Keep that example beside the host group.
RSpec.shared_examples "a surface that treats a malformed search parameter as no ask" do
  [
    ["an array", { q: ["acme/billing-service"] }],
    ["a nested hash", { q: { a: "b" } }],
    ["an array of hashes", { q: [{ a: "b" }] }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedSearchParam", action: "treat non-string q as no ask", behavior: "a q parameter in a non-String shape answers 200 with the unfiltered page rather than 500 or a silently coerced match, matching an absent parameter", layer: "request" }
    it "answers 200 rather than 500 when q arrives as #{shape}" do
      expect_search_param_treated_as_no_ask(query)
    end
  end
end
