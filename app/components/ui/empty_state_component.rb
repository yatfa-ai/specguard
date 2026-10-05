# frozen_string_literal: true

class UI::EmptyStateComponent < ApplicationComponent
  renders_one :action

  def initialize(title:, description: nil, **options)
    @title = title
    @description = description
    @options = options
    super
  end

  attr_reader :title, :description

  def wrapper_class
    @wrapper_class ||= merge_classes(
      "flex flex-col items-center justify-center gap-3 rounded-card border border-dashed " \
      "border-app-border-strong px-6 py-10 text-center",
      @options.delete(:class)
    )
  end
end
