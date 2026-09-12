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

  # The public administration guide (SPGD-762). Empty and ungated for the same two reasons
  # `integrate` is, and it wears no signed-in redirect for the same one: the reader most likely to
  # want this page is the person holding an `sgu_` key, and they are signed in.
  #
  # Its subject is the precondition that has until now been communicated only by the 400 that
  # refuses a registration — that registering over the API redeems a snapshot taken in a BROWSER,
  # and that the snapshot expires. A page that required a session to read could not be handed to the
  # agent hitting that refusal.
  def administer; end
end
