# frozen_string_literal: true

module SpecGuard
  # Raised when the signed-in user may see a record but not perform the action they asked for.
  #
  # Mapped to 403 in config/application.rb. It is deliberately distinct from
  # ActiveRecord::RecordNotFound (404), which stays reserved for "you may not even know this
  # exists" — see RepositoryPolicy#member?.
  class NotAuthorized < StandardError
    def initialize(message = "You do not have permission to do that.")
      super
    end
  end
end
