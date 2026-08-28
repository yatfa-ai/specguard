# frozen_string_literal: true

require "rails_helper"

RSpec.describe GzipRequestBody do
  let(:payload) { { "specs" => Array.new(20) { { "file_path" => "spec/a_spec.rb" } } } }
  let(:json) { JSON.generate(payload) }

  # What the downstream app saw, so an example can assert on the request as it actually arrived
  # rather than on a call. `raw_post`'s own trap — it reads exactly CONTENT_LENGTH bytes — is only
  # visible if the body is read the way Rails reads it.
  Seen = Struct.new(:env, :body, keyword_init: true)

  def call(env)
    seen = nil
    app = lambda { |downstream|
      seen = Seen.new(env: downstream,
                      body: downstream["rack.input"].read(downstream["CONTENT_LENGTH"].to_i))
      [200, { "content-type" => "text/plain" }, ["ok"]]
    }

    [described_class.new(app).call(env), seen]
  end

  def env_for(body, path: "/api/v1/ingest", encoding: "gzip")
    { "PATH_INFO" => path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body) }
      .merge(encoding ? { "HTTP_CONTENT_ENCODING" => encoding } : {})
  end

  describe "a gzipped API body" do
    subject(:seen) { call(env_for(Zlib.gzip(json))).last }

    # @intent: { entity: "GzipRequestBody", action: "inflate body", behavior: "the downstream app reads the original uncompressed JSON bytes from rack.input", layer: "integration" }
    it "hands the downstream app the original bytes" do
      expect(seen.body).to eq(json)
    end

    # Not tidiness. `ActionDispatch::Request#raw_post` reads exactly CONTENT_LENGTH bytes, so
    # leaving the *compressed* length here truncates the body to a fraction of itself and the
    # parser gets a JSON fragment — a 400 that looks like the client's fault and is not.
    # @intent: { entity: "GzipRequestBody", action: "reset content length", behavior: "CONTENT_LENGTH is rewritten to the inflated size so raw_post does not truncate the body", layer: "integration" }
    it "resets CONTENT_LENGTH to the inflated size" do
      expect(seen.env["CONTENT_LENGTH"]).to eq(json.bytesize.to_s)
    end

    # The body downstream is no longer encoded, so the header claiming it is would be a lie — and
    # a lie anything else in the stack is entitled to act on.
    # @intent: { entity: "GzipRequestBody", action: "drop encoding header", behavior: "the consumed Content-Encoding header is absent from the downstream env", layer: "integration" }
    it "removes the Content-Encoding header it consumed" do
      expect(seen.env).not_to have_key("HTTP_CONTENT_ENCODING")
    end

    # @intent: { entity: "GzipRequestBody", action: "forward response", behavior: "the middleware returns the downstream app response status untouched", layer: "integration" }
    it "answers with whatever the downstream app returned" do
      status, = call(env_for(Zlib.gzip(json))).first

      expect(status).to eq(200)
    end
  end

  # The half that is easy to break by widening the guard: every request the platform serves today
  # is one of these, and none of them may notice this class exists.
  describe "a request it must not touch" do
    # @intent: { entity: "GzipRequestBody", action: "pass unencoded body", behavior: "a request without Content-Encoding reaches the app with its bytes unchanged", layer: "integration" }
    it "passes an unencoded API body through with its bytes unchanged" do
      seen = call(env_for(json, encoding: nil)).last

      expect(seen.body).to eq(json)
    end

    # @intent: { entity: "GzipRequestBody", action: "pass content length", behavior: "CONTENT_LENGTH is untouched when no Content-Encoding is present", layer: "integration" }
    it "leaves CONTENT_LENGTH alone when there is no Content-Encoding" do
      seen = call(env_for(json, encoding: nil)).last

      expect(seen.env["CONTENT_LENGTH"]).to eq(json.bytesize.to_s)
    end

    # `identity` is the explicit spelling of "not encoded". Treating it as gzip would 400 a
    # perfectly correct request.
    # @intent: { entity: "GzipRequestBody", action: "treat identity", behavior: "an explicit identity encoding passes the body through unmodified with its header intact", layer: "integration" }
    it "treats an explicit identity encoding as unencoded" do
      seen = call(env_for(json, encoding: "identity")).last

      expect(seen.body).to eq(json)
      expect(seen.env["HTTP_CONTENT_ENCODING"]).to eq("identity")
    end

    # Scoped to /api/ for the same reason JsonParseErrorResponder is: an HTML form post is not
    # this class's business, and a JSON error body would be the wrong answer for one.
    # @intent: { entity: "GzipRequestBody", action: "scope to api", behavior: "a gzipped body on a non-API path reaches the app still compressed", layer: "integration" }
    it "leaves a gzipped body on a non-API path compressed" do
      gzipped = Zlib.gzip(json)
      seen = call(env_for(gzipped, path: "/repositories")).last

      expect(seen.body).to eq(gzipped)
    end

    # @intent: { entity: "GzipRequestBody", action: "tolerate missing input", behavior: "a request with no rack.input still answers the downstream status without raising", layer: "integration" }
    it "does not choke on a request with no rack.input at all" do
      status, = described_class.new(->(_env) { [200, {}, ["ok"]] })
                               .call("PATH_INFO" => "/api/v1/ingest", "HTTP_CONTENT_ENCODING" => "gzip")

      expect(status).to eq(200)
    end
  end

  describe "a body that says gzip and is not" do
    subject(:response) { call(env_for("this is not gzip")).first }

    # @intent: { entity: "GzipRequestBody", action: "reject corrupt body", behavior: "a body claiming gzip that is not answers 400 rather than 500 or an exception", layer: "integration" }
    it "answers 400, not a 500 and not an exception page" do
      expect(response.first).to eq(400)
    end

    # @intent: { entity: "GzipRequestBody", action: "shape corrupt error", behavior: "the 400 body is the API bad_request JSON envelope with the corrupt message", layer: "integration" }
    it "uses the API's own error shape" do
      expect(JSON.parse(response[1..].last.first))
        .to eq("error" => "bad_request",
               "message" => described_class::CORRUPT_MESSAGE,
               "details" => [described_class::CORRUPT_MESSAGE])
    end

    # @intent: { entity: "GzipRequestBody", action: "size error response", behavior: "the error response content-length equals the returned body byte size", layer: "integration" }
    it "sets a content-length matching the body it returns" do
      _, headers, body = response

      expect(headers["content-length"]).to eq(body.first.bytesize.to_s)
    end

    # @intent: { entity: "GzipRequestBody", action: "block corrupt body", behavior: "a corrupt body never reaches the downstream app", layer: "integration" }
    it "never reaches the downstream app" do
      expect(call(env_for("this is not gzip")).last).to be_nil
    end

    # A truncated upload is a different zlib failure from a wrong magic number, and an
    # implementation that rescued only `Zlib::GzipFile::Error.new("not in gzip format")` by
    # message would 500 on this one.
    # @intent: { entity: "GzipRequestBody", action: "reject truncated stream", behavior: "a truncated gzip stream answers 400 the same as a wrong magic number", layer: "integration" }
    it "answers a truncated gzip stream the same way" do
      truncated = Zlib.gzip(json).byteslice(0, 12)

      expect(call(env_for(truncated)).first.first).to eq(400)
    end

    # The CRC is the only thing that catches a body corrupted *in transit*: the header is intact,
    # every byte inflates, and the payload is still garbage.
    # @intent: { entity: "GzipRequestBody", action: "reject broken crc", behavior: "a gzip stream corrupted in transit fails the CRC and answers 400", layer: "integration" }
    it "answers a gzip stream with a broken CRC the same way" do
      corrupted = Zlib.gzip(json).dup
      corrupted.setbyte(corrupted.bytesize - 5, corrupted.getbyte(corrupted.bytesize - 5) ^ 0xff)

      expect(call(env_for(corrupted)).first.first).to eq(400)
    end
  end

  describe "the zip-bomb cap" do
    # 20 MiB of one repeated byte, which gzip takes down to ~20 KB — the shape of the attack the
    # cap exists for, at a size a spec can afford.
    let(:bomb) { Zlib.gzip("a" * (20 * 1024 * 1024)) }

    before { stub_const("#{described_class}::MAX_INFLATED_BYTES", 1024) }

    # @intent: { entity: "GzipRequestBody", action: "cap inflation", behavior: "a body inflating past the cap answers 400 instead of exhausting memory", layer: "integration" }
    it "rejects a body that inflates past the cap with 400" do
      expect(call(env_for(bomb)).first.first).to eq(400)
    end

    # @intent: { entity: "GzipRequestBody", action: "name the cap", behavior: "the rejection message names the inflation limit that was hit", layer: "integration" }
    it "says which limit was hit" do
      body = call(env_for(bomb)).first.last.first

      expect(JSON.parse(body)).to include("error" => "bad_request",
                                          "message" => a_string_matching(/inflates to more than/))
    end

    # @intent: { entity: "GzipRequestBody", action: "block oversized body", behavior: "an over-cap body never reaches the downstream app", layer: "integration" }
    it "never reaches the downstream app" do
      expect(call(env_for(bomb)).last).to be_nil
    end

    # The claim the cap actually rests on, and the one a passing 400 does *not* establish. An
    # implementation that inflated the whole body and then measured it would answer 400 here too —
    # after allocating every byte of the bomb. Streaming is only observable from the input side:
    # the compressed stream is abandoned part-read, so far fewer bytes are consumed than a
    # `Zlib.gunzip(input.read)` would have taken.
    # @intent: { entity: "GzipRequestBody", action: "stream abort", behavior: "the compressed input is abandoned part-read so far fewer bytes are consumed than its full size", layer: "integration" }
    it "abandons the stream part-read instead of inflating it all and then measuring" do
      input = StringIO.new(bomb)
      described_class.new(->(_env) { raise "unreachable" })
                     .call(env_for(bomb).merge("rack.input" => input))

      expect(input.pos).to be < bomb.bytesize
    end
  end

  # Bounds the pathological case that survives the cap: a body that inflates to just under it.
  # @intent: { entity: "GzipRequestBody", action: "inflate across chunks", behavior: "a body spanning several read chunks is reassembled downstream byte for byte", layer: "integration" }
  it "inflates a body far larger than one read chunk without losing bytes" do
    original = "x" * (described_class::READ_CHUNK_BYTES * 3 + 17)

    expect(call(env_for(Zlib.gzip(original))).last.body).to eq(original)
  end

  # The sibling of the example above, at the boundary it does *not* cover. That one pins "no bytes
  # lost across a **chunk** boundary"; these pin the opposite answer at the **member** boundary —
  # bytes *are* dropped there, silently, with a success status.
  #
  # Every example in this group pins a permissiveness the class comment declares DELIBERATE
  # (`lib/middleware/gzip_request_body.rb:53-57`: "if one ever appears, this is the line to
  # revisit"). They are not asserting that today's answer is the right one. If one of them fails,
  # that comment is the thing to revisit — the decision has changed and the comment now lies.
  describe "the deliberate first-member-only read" do
    let(:first) { JSON.generate("specs" => [{ "file_path" => "spec/first_spec.rb" }]) }
    let(:second) { JSON.generate("specs" => [{ "file_path" => "spec/second_spec.rb" }]) }

    # `Zlib::GzipReader#read` returns nil at the end of the first member, so the read loop in
    # `#inflate` stops there and every later member is never read. Both directions are asserted
    # separately and on purpose: the body equality is what catches an implementation that started
    # reading *every* member, and the explicit status check is what catches one that started
    # *refusing* them — without it that direction still fails, but as a NoMethodError on a nil
    # `seen`, which reads like a broken spec rather than a changed decision.
    # @intent: { entity: "GzipRequestBody", action: "read first member", behavior: "a two-member body delivers only the first member downstream and answers 200", layer: "integration" }
    it "delivers only the first member of a two-member body, and answers success" do
      response, seen = call(env_for(Zlib.gzip(first) + Zlib.gzip(second)))

      expect(response.first).to eq(200)
      expect(seen.body).to eq(first)
      expect(seen.body).not_to include("second_spec")
    end

    # The lost bytes are invisible downstream: CONTENT_LENGTH is rewritten to the *short* body, so
    # the request is internally consistent and nothing further down the stack has a way to notice
    # that half of what the client sent is gone.
    # @intent: { entity: "GzipRequestBody", action: "rewrite truncated length", behavior: "CONTENT_LENGTH matches the truncated first member so no trace of the dropped member survives", layer: "integration" }
    it "rewrites CONTENT_LENGTH to the truncated body, leaving no trace of the dropped member" do
      _, seen = call(env_for(Zlib.gzip(first) + Zlib.gzip(second)))

      expect(seen.env["CONTENT_LENGTH"]).to eq(first.bytesize.to_s)
    end

    # The second half of the comment's claim: trailing garbage after a valid member is accepted
    # too, and is not confused with the corrupt-body 400 that garbage *alone* earns.
    # @intent: { entity: "GzipRequestBody", action: "accept trailing garbage", behavior: "a valid member followed by non-gzip bytes still answers 200 with the member delivered", layer: "integration" }
    it "accepts a valid member followed by trailing garbage rather than answering 400" do
      response, seen = call(env_for(Zlib.gzip(first) + "this is not gzip"))

      expect(response.first).to eq(200)
      expect(seen.body).to eq(first)
    end

    # The third unpinned accept-path, and the most extreme reading of the same rule: when the
    # *first* member is empty the whole body is delivered empty, no matter what follows it. A
    # zero-byte body is a 400; a zero-byte *member* is a 200.
    # @intent: { entity: "GzipRequestBody", action: "accept empty member", behavior: "an empty first member delivers an empty body and answers 200 whatever follows", layer: "integration" }
    it "delivers an empty body for an empty first member, whatever follows it" do
      response, seen = call(env_for(Zlib.gzip("") + Zlib.gzip(first)))

      expect(response.first).to eq(200)
      expect(seen.body).to eq("")
    end
  end
end
