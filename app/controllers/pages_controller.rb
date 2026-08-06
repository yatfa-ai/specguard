# frozen_string_literal: true

class PagesController < ApplicationController
  def home
    redirect_to repositories_path if signed_in?
  end
end
