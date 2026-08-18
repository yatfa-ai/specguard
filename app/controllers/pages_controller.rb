# frozen_string_literal: true

class PagesController < ApplicationController
  def home
    redirect_to repositories_path if signed_in?
  end

  # The public integration guide. Empty, and deliberately NOT wearing `home`'s redirect: a signed-in
  # reader wants this page as much as a signed-out one — more, since they are the one holding a key
  # — and sending them to their repository list would make the URL in the agent-prompt block work
  # for an agent and fail for the person who copied it.
  def integrate; end
end
