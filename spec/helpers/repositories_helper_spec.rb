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
    # @intent: { entity: "RepositoriesHelper", action: "define the empty-index title method in the module", behavior: "the title method is a public instance method of the helper module and never a private patch on Object, the placement the request suite is blind to", layer: "unit" }
    it "is defined on RepositoriesHelper and not on Object" do
      expect(RepositoriesHelper.instance_methods).to include(:no_repositories_match_title)
      expect(Object.private_method_defined?(:no_repositories_match_title)).to be(false)
    end

    context "with a search ask" do
      # @intent: { entity: "RepositoriesHelper", action: "compose the empty-index title", behavior: "a search ask with the owned limb renders the you-registered wording carrying the search in the reader own verbatim spelling", layer: "unit" }
      it "names the search in the reader's own spelling, ownership limb included (owned)" do
        given_asks(search: "Ledger", role: "owned")

        # VERBATIM, capital L and all: the match is case-insensitive in SQL, so re-spelling the
        # ask could not change which rows matched — only what the page would claim was searched.
        expect(helper.no_repositories_match_title)
          .to eq(%(No repositories you registered match “Ledger”))
      end

      # @intent: { entity: "RepositoriesHelper", action: "compose the empty-index title", behavior: "a search ask with the shared limb renders the shared-repositories wording carrying the search as asked", layer: "unit" }
      it "names the search with the shared limb" do
        given_asks(search: "billing", role: "shared")

        expect(helper.no_repositories_match_title)
          .to eq(%(No shared repositories match “billing”))
      end

      # @intent: { entity: "RepositoriesHelper", action: "compose the empty-index title", behavior: "a search ask with no live role renders the bare no-repositories-match wording with the search alone", layer: "unit" }
      it "names the search alone when no role ask is live" do
        given_asks(search: "ledger", role: nil)

        expect(helper.no_repositories_match_title).to eq(%(No repositories match “ledger”))
      end
    end

    context "with a role ask and no search" do
      # @intent: { entity: "RepositoriesHelper", action: "compose the empty-index title", behavior: "an owned role ask with no search renders the you-have-registered wording alone", layer: "unit" }
      it "names the ownership ask alone (owned)" do
        given_asks(search: nil, role: "owned")

        expect(helper.no_repositories_match_title).to eq("No repositories you have registered")
      end

      # @intent: { entity: "RepositoriesHelper", action: "compose the empty-index title", behavior: "a shared role ask with no search renders the shared-with-you wording alone", layer: "unit" }
      it "names the shared ask alone" do
        given_asks(search: nil, role: "shared")

        expect(helper.no_repositories_match_title).to eq("No repositories have been shared with you")
      end
    end
  end

  # SPGD-989 — the coverage phrase both halves of the agent-key revoke disclosure read, with the
  # count taken off the STORED set. The limb the request suite cannot see is the deleted
  # repository: nothing cascades into the stored array, so a set of three can carry two live
  # names, and the sentence must say so rather than let "3" sit beside two names.
  describe "#agent_key_revoke_confirmation" do
    def key_over(count)
      AgentApiKey.new(name: "Fleet", repository_ids: Array.new(count, 0), permissions: [])
    end

    # @intent: { entity: "RepositoriesHelper", action: "compose the agent-key revoke confirm", behavior: "the confirm names the count and the names of the stored set and cuts across every repository in it", layer: "unit" }
    it "names the full set with count and names" do
      confirmation = helper.agent_key_revoke_confirmation(key_over(2), %w[acme/a acme/b])

      expect(confirmation).to eq("Revoke Fleet? It covers 2 repositories: acme/a, acme/b. " \
        "Revoking it here cuts the token on every repository in that set — anything still " \
        "using it stops working immediately.")
    end

    # @intent: { entity: "RepositoriesHelper", action: "disclose deleted repositories", behavior: "a stored set larger than its live names reads the difference as repositories since deleted", layer: "unit" }
    it "discloses repositories deleted since mint" do
      confirmation = helper.agent_key_revoke_confirmation(key_over(3), ["acme/a"])

      expect(confirmation).to include("3 repositories: acme/a (2 repositories since deleted)")
    end
  end
end
