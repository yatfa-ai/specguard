# frozen_string_literal: true

require "rails_helper"

# THE PLACEMENT GUARD for `RepositoriesHelper#no_repositories_match_title` — the file the
# request suite cannot be, because the request suite is structurally blind to WHERE a helper
# method is defined.
#
# The view calls the method with an implicit receiver (`index.html.erb`'s `title:
# no_repositories_match_title`), and a private top-level method on Object — which is what you get
# when the module's closing `end` lands above the method instead of below it — answers an
# implicit-receiver call exactly as happily as a real module method does. That accident shipped
# for one review round of the narrowing-controls PR: every page-level pin green, all 2455 request
# examples passing, while `RepositoriesHelper` did not contain the method at all and loading the
# helper file monkey-patched every object in the process.
#
# Two shapes of call cannot be answered from the Object patch, and both are pinned here:
#
# 1. The introspection the round's reviewer ran live —
#        RepositoriesHelper.instance_methods.include?(:no_repositories_match_title)  # => false
#        Object.private_method_defined?(:no_repositories_match_title)               # => true
#    — asserted as the positive and the negative, so the regression fails on the very example
#    that names it rather than limping through the limb examples below.
# 2. The explicit-receiver call `helper.no_repositories_match_title`. A private method refuses
#    an explicit receiver, so a mis-placed definition raises NoMethodError here and only here —
#    the guard a helper spec gives "for free" once the method is actually in the module, which is
#    why this file exists rather than another rendered-page pin in `repositories_spec.rb`.
#
# The ask-pair the title limbs read (`requested_search`, `requested_role`) reaches a REAL render
# through `RepositoriesController.helper_method` — the promotion that makes controller-concern
# reads callable from the view. That promotion is per-controller, so it is absent from this
# context's helper object, and `verify_partial_doubles` refuses to stub a method the object does
# not carry — correctly, because these limbs want real reads rather than canned answers. Defining
# the pair on the helper's singleton gives the method the same implicit-receiver reads it performs
# in production, with the values each limb renders named in its own example.
#
# A SECOND trap, recorded because the apparently sufficient fix falls into it: the module's tail
# is a `private` section, so "just move the closing `end` below the method" lands the method
# INSIDE the module but behind that `private` — where `instance_methods` still cannot see it and
# explicit receivers still cannot call it, while the template's implicit-receiver call keeps
# working and every request example keeps passing. The page cannot tell you where a helper method
# lives; only this file can. The method therefore sits in the module's PUBLIC section, and both
# checks below fail under either misplacement — outside the module entirely, or inside it but
# private.
RSpec.describe RepositoriesHelper, type: :helper do
  describe "#no_repositories_match_title" do
    def given_asks(search: nil, role: nil)
      helper.singleton_class.define_method(:requested_search) { search }
      helper.singleton_class.define_method(:requested_role) { role }
    end

    # The placement this file exists to pin, in the tooling's own vocabulary: the method is a
    # public instance method of RepositoriesHelper, and nothing defined it onto Object.
    it "is defined on RepositoriesHelper and not on Object" do
      expect(RepositoriesHelper.instance_methods).to include(:no_repositories_match_title)
      expect(Object.private_method_defined?(:no_repositories_match_title)).to be(false)
    end

    context "with a search ask" do
      it "names the search in the reader's own spelling, ownership limb included (owned)" do
        given_asks(search: "Ledger", role: "owned")

        # VERBATIM, capital L and all: the match is case-insensitive in SQL, so re-spelling the
        # ask could not change which rows matched — only what the page would claim was searched.
        expect(helper.no_repositories_match_title)
          .to eq(%(No repositories you registered match “Ledger”))
      end

      it "names the search with the shared limb" do
        given_asks(search: "billing", role: "shared")

        expect(helper.no_repositories_match_title)
          .to eq(%(No shared repositories match “billing”))
      end

      it "names the search alone when no role ask is live" do
        given_asks(search: "ledger", role: nil)

        expect(helper.no_repositories_match_title).to eq(%(No repositories match “ledger”))
      end
    end

    context "with a role ask and no search" do
      it "names the ownership ask alone (owned)" do
        given_asks(search: nil, role: "owned")

        expect(helper.no_repositories_match_title).to eq("No repositories you have registered")
      end

      it "names the shared ask alone" do
        given_asks(search: nil, role: "shared")

        expect(helper.no_repositories_match_title).to eq("No repositories have been shared with you")
      end
    end
  end
end
