# frozen_string_literal: true

require "json"

# Turns an unparseable request body into the JSON error shape the API uses everywhere else.
#
# This has to live at the Rack boundary rather than in a controller. A malformed body raises
# `ActionDispatch::Http::Parameters::ParseError` the first time anything touches `params`, and the
# first thing to touch them is Action Controller's own instrumentation — before any `before_action`
# runs. `rescue_from` in a controller therefore never sees it, and the response falls to the
# exception middleware: a bare `400` with a non-JSON body in production, and in development and
# test the debug page, whose template renders the request's parameters and so re-raises the very
# error it is trying to display.
#
# Inserted *inside* `ActionDispatch::DebugExceptions` so it catches the error on the way up before
# either of those happen, and scoped to `/api/` so HTML requests keep Rails' own handling — a form
# post has no use for a JSON error body.
class JsonParseErrorResponder
  API_PREFIX = "/api/"
  MESSAGE = "The request body could not be parsed as JSON."
  BODY = JSON.generate(error: "bad_request", message: MESSAGE, details: [MESSAGE]).freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue ActionDispatch::Http::Parameters::ParseError
    raise unless env["PATH_INFO"].to_s.start_with?(API_PREFIX)

    [400,
     { "content-type" => "application/json; charset=utf-8", "content-length" => BODY.bytesize.to_s },
     [BODY]]
  end
end
