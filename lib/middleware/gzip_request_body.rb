# frozen_string_literal: true

require "json"
require "stringio"
require "zlib"

# Inflates a `Content-Encoding: gzip` request body before anything downstream tries to read it.
#
# == Why this exists
#
# A 20,000-example RSpec run is a 7.01 MiB JSON body; gzipped it is 0.33 MiB, a 21x saving
# (measured by running a real 200-file / 20,000-example suite through the client gem's formatter).
# The client sets a single `write_timeout` for the whole POST, so on a modest CI uplink the
# uncompressed body is the difference between the run landing and the run timing out in the write
# and never arriving at all — 11.8s to write at 5 Mbit/s against a 10s budget, versus 0.55s
# compressed. Compression is what makes the large-suite case shippable, and the client cannot turn
# it on until this side can read it.
#
# == Why at the Rack boundary, and where in it
#
# Nothing in Rails decompresses a request body — `Rack::Deflater` is a *response* middleware. The
# body has to be inflated before `ActionDispatch::Http::Parameters` reads `request.raw_post`, which
# `Api::V1::IngestsController#create` triggers on its first touch of `request.request_parameters`.
# By then the string is already fixed, so a controller-level rescue is too late by construction.
#
# Inserted *after* (and so inside) `JsonParseErrorResponder`, on the rule that an inflater belongs
# as deep as it can go while still preceding the body reader: everything above it then deals only
# with ordinary identity-encoded requests. Note what that ordering does *not* do, so nobody later
# reads a guarantee into it that is not there — the two classes do not compete for a failure and
# would both still work if swapped. They divide by failure *type*, not by stack position: this
# class answers its own 400 by returning it rather than raising, so there is nothing for
# `JsonParseErrorResponder` to catch, and it rescues only `ParseError`, which this class never
# raises. Valid gzip wrapping invalid JSON inflates cleanly here and fails at the parser, which is
# how the client gets told its JSON is broken rather than its gzip.
#
# == The inflate is capped, and capped by streaming
#
# The 21x ratio that makes honest telemetry cheap makes a zip bomb cheap too: a few hundred KiB of
# zeros expands to gigabytes. So the inflated size is bounded, and the bound is enforced *during*
# the inflate rather than after it — a `Zlib.gunzip` followed by a size check would have already
# allocated the very payload the check exists to refuse. Reading a chunk at a time means a bomb is
# abandoned after a couple of KiB of input, holding at most one chunk plus the cap in memory.
#
# The cap is deliberately far above any real run: 20k examples is 7 MiB inflated, so 64 MiB leaves
# an order of magnitude of headroom and will only ever be reached by something pathological.
#
# == Two knowing permissivenesses, so they are inherited on purpose rather than by accident
#
# Both were probed rather than reasoned about, and both are recorded here because the sole client
# today cannot produce either — which is exactly why a future non-Ruby client would find them the
# hard way.
#
#   * *Only the first gzip member is read.* `Zlib.gzip(a) + Zlib.gzip(b)` inflates to `a` alone and
#     the request succeeds; a valid member followed by trailing garbage does the same. That matches
#     `Zlib.gunzip`'s own behavior and this gem emits exactly one member, so it is not a defect
#     today. But "accept, and silently drop half the body" is a bad shape to hand a client that
#     concatenates streams — if one ever appears, this is the line to revisit.
#   * *`x-gzip` is not recognised.* The match is an exact `gzip`, so the legacy synonym falls
#     through un-inflated and dies at the JSON parser, which tells the client its *JSON* is broken
#     when in truth its *encoding* was unsupported. The strictness is deliberate; the misleading
#     diagnosis is a wart. Giving an unrecognised `Content-Encoding` under `/api/` its own 400 would
#     fix it, and is a deliberate non-change here rather than an oversight: it widens this class
#     from "inflate gzip" to "police encodings", which is a contract decision about the public API
#     and wants its own slice.
class GzipRequestBody
  API_PREFIX = "/api/"
  ENCODING = "gzip"

  # Generous on purpose — see the class comment. A 20k-example run is ~9x under this.
  MAX_INFLATED_BYTES = 64 * 1024 * 1024

  # Inflated bytes pulled per iteration. Bounds the transient allocation when the cap is hit.
  READ_CHUNK_BYTES = 64 * 1024

  CORRUPT_MESSAGE = "The request body could not be inflated: Content-Encoding said gzip, " \
                    "but the body is not valid gzip."
  TOO_LARGE_MESSAGE = "The gzipped request body inflates to more than " \
                      "#{MAX_INFLATED_BYTES / (1024 * 1024)} MiB."

  # Raised and caught entirely within this class: the cap is a request-shaping decision, not an
  # application error, and it must never surface as a 500.
  class InflatedBodyTooLarge < StandardError; end

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless gzipped_api_request?(env)

    begin
      inflated = inflate(env["rack.input"])
    rescue InflatedBodyTooLarge
      return error_response(TOO_LARGE_MESSAGE)
    rescue Zlib::Error
      # Covers the whole family: not-gzip magic bytes, a truncated stream, a bad CRC. Every one of
      # them is the client's mistake, so every one of them is a 400 rather than an exception page.
      return error_response(CORRUPT_MESSAGE)
    end

    @app.call(decoded(env, inflated))
  end

  private

  # Only an exact `gzip`, only under `/api/`, and only when there is something to read. An absent
  # or `identity` encoding — which is every request the platform serves today — falls through
  # without this class touching a single env key.
  def gzipped_api_request?(env)
    env["HTTP_CONTENT_ENCODING"].to_s.strip.downcase == ENCODING &&
      env["PATH_INFO"].to_s.start_with?(API_PREFIX) &&
      !env["rack.input"].nil?
  end

  def inflate(input)
    reader = Zlib::GzipReader.new(input)
    buffer = +"".b

    while (chunk = reader.read(READ_CHUNK_BYTES))
      # Checked *before* the append, so the chunk that would breach the cap is never retained.
      raise InflatedBodyTooLarge if buffer.bytesize + chunk.bytesize > MAX_INFLATED_BYTES

      buffer << chunk
    end

    buffer
  ensure
    # Deterministic release of the zstream, which matters most on the cap path: that one abandons
    # the reader mid-stream, so without this the inflate state lives until the GC gets to it — and
    # the cap path is exactly the one an attacker gets to trigger repeatedly.
    #
    # `finish` rather than the more idiomatic `GzipReader.wrap`, and the difference is load-bearing:
    # `wrap` closes the *underlying* IO, which here is `rack.input`. That belongs to the server, and
    # a middleware closing it is out of bounds. `finish` frees the zstream and leaves the IO open.
    # Safe on every path — verified against a complete read, a mid-stream abandon, a truncated
    # stream and a body that is not gzip at all; `reader` is nil when the constructor itself raised.
    reader&.finish
  end

  # The request is handed downstream as though it had arrived identity-encoded. `CONTENT_LENGTH`
  # has to be rewritten too, and not only for tidiness: `ActionDispatch::Request#raw_post` reads
  # exactly `CONTENT_LENGTH` bytes, so leaving the compressed length in place would truncate the
  # body to a fraction of itself and hand the parser a JSON fragment.
  def decoded(env, body)
    env.delete("HTTP_CONTENT_ENCODING")
    env["CONTENT_LENGTH"] = body.bytesize.to_s
    env["rack.input"] = StringIO.new(body)
    env
  end

  # The shape `Api::BaseController#render_bad_request` emits, reproduced here because this runs
  # above the controller stack and cannot call it.
  def error_response(message)
    body = JSON.generate(error: "bad_request", message: message, details: [message])

    [400,
     { "content-type" => "application/json; charset=utf-8", "content-length" => body.bytesize.to_s },
     [body]]
  end
end
