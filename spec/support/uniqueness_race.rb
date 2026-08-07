# frozen_string_literal: true

# Simulating the race a read-then-write `validates :uniqueness` cannot win.
#
# That validation's SELECT runs before the INSERT, so a competing request that has not committed yet
# is invisible to it: the check passes, and the unique index is what refuses. Reproducing that
# faithfully needs the validation to say nothing while the row is already there — which is exactly
# what it does on its own when it cannot see the winner. Silence it, and the DATABASE is the thing
# that answers.
#
# A spec that merely writes the same row twice in sequence proves nothing about this: the validation
# catches that unaided, so the example passes with or without any database-conflict handling.
module UniquenessRace
  # The validator INSTANCE, so a stub lands on this model's uniqueness check alone rather than on
  # `any_instance` of the class — nothing else in the example, or in a request it drives, is
  # touched. `validates` registers the object once at class-load and the validation callback closes
  # over it, so this is the same instance the save path will consult.
  #
  # `sole` on purpose: if a model ever grows a second uniqueness validation, this raises rather than
  # silently silencing whichever one happens to come first.
  def uniqueness_validator(model_class)
    model_class.validators.grep(ActiveRecord::Validations::UniquenessValidator).sole
  end
end

RSpec.configure do |config|
  config.include UniquenessRace
end
