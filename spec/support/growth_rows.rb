# frozen_string_literal: true

# The row of a serialized growth block whose `path` is `path`, or nil.
# Lives here rather than in the file that first needed it: RSpec scopes a def to
# its example group, so the only way to reuse it is to copy it (see serialized_strings.rb).
module GrowthRows
  def row_at(block, path) = block["rows"].find { |row| row["path"] == path }
end

RSpec.configure { |config| config.include GrowthRows, type: :request }
