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

    it "hands the downstream app the original bytes" do
      expect(seen.body).to eq(json)
    end

    # Not tidiness. `ActionDispatch::Request#raw_post` reads exactly CONTENT_LENGTH bytes, so
    # leaving the *compressed* length here truncates the body to a fraction of itself and the
    # parser gets a JSON fragment — a 400 that looks like the client's fault and is not.
    it "resets CONTENT_LENGTH to the inflated size" do
      expect(seen.env["CONTENT_LENGTH"]).to eq(json.bytesize.to_s)
    end

    # The body downstream is no longer encoded, so the header claiming it is would be a lie — and
    # a lie anything else in the stack is entitled to act on.
    it "removes the Content-Encoding header it consumed" do
      expect(seen.env).not_to have_key("HTTP_CONTENT_ENCODING")
    end

    it "answers with whatever the downstream app returned" do
      status, = call(env_for(Zlib.gzip(json))).first

      expect(status).to eq(200)
    end
  end

  # The half that is easy to break by widening the guard: every request the platform serves today
  # is one of these, and none of them may notice this class exists.
  describe "a request it must not touch" do
    it "passes an unencoded API body through with its bytes unchanged" do
      seen = call(env_for(json, encoding: nil)).last

      expect(seen.body).to eq(json)
    end

    it "leaves CONTENT_LENGTH alone when there is no Content-Encoding" do
      seen = call(env_for(json, encoding: nil)).last

      expect(seen.env["CONTENT_LENGTH"]).to eq(json.bytesize.to_s)
    end

    # `identity` is the explicit spelling of "not encoded". Treating it as gzip would 400 a
    # perfectly correct request.
    it "treats an explicit identity encoding as unencoded" do
      seen = call(env_for(json, encoding: "identity")).last

      expect(seen.body).to eq(json)
      expect(seen.env["HTTP_CONTENT_ENCODING"]).to eq("identity")
    end

    # Scoped to /api/ for the same reason JsonParseErrorResponder is: an HTML form post is not
    # this class's business, and a JSON error body would be the wrong answer for one.
    it "leaves a gzipped body on a non-API path compressed" do
      gzipped = Zlib.gzip(json)
      seen = call(env_for(gzipped, path: "/repositories")).last

      expect(seen.body).to eq(gzipped)
    end

    it "does not choke on a request with no rack.input at all" do
      status, = described_class.new(->(_env) { [200, {}, ["ok"]] })
                               .call("PATH_INFO" => "/api/v1/ingest", "HTTP_CONTENT_ENCODING" => "gzip")

      expect(status).to eq(200)
    end
  end

  describe "a body that says gzip and is not" do
    subject(:response) { call(env_for("this is not gzip")).first }

    it "answers 400, not a 500 and not an exception page" do
      expect(response.first).to eq(400)
    end

    it "uses the API's own error shape" do
      expect(JSON.parse(response[1..].last.first))
        .to eq("error" => "bad_request",
               "message" => described_class::CORRUPT_MESSAGE,
               "details" => [described_class::CORRUPT_MESSAGE])
    end

    it "sets a content-length matching the body it returns" do
      _, headers, body = response

      expect(headers["content-length"]).to eq(body.first.bytesize.to_s)
    end

    it "never reaches the downstream app" do
      expect(call(env_for("this is not gzip")).last).to be_nil
    end

    # A truncated upload is a different zlib failure from a wrong magic number, and an
    # implementation that rescued only `Zlib::GzipFile::Error.new("not in gzip format")` by
    # message would 500 on this one.
    it "answers a truncated gzip stream the same way" do
      truncated = Zlib.gzip(json).byteslice(0, 12)

      expect(call(env_for(truncated)).first.first).to eq(400)
    end

    # The CRC is the only thing that catches a body corrupted *in transit*: the header is intact,
    # every byte inflates, and the payload is still garbage.
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

    it "rejects a body that inflates past the cap with 400" do
      expect(call(env_for(bomb)).first.first).to eq(400)
    end

    it "says which limit was hit" do
      body = call(env_for(bomb)).first.last.first

      expect(JSON.parse(body)).to include("error" => "bad_request",
                                          "message" => a_string_matching(/inflates to more than/))
    end

    it "never reaches the downstream app" do
      expect(call(env_for(bomb)).last).to be_nil
    end

    # The claim the cap actually rests on, and the one a passing 400 does *not* establish. An
    # implementation that inflated the whole body and then measured it would answer 400 here too —
    # after allocating every byte of the bomb. Streaming is only observable from the input side:
    # the compressed stream is abandoned part-read, so far fewer bytes are consumed than a
    # `Zlib.gunzip(input.read)` would have taken.
    it "abandons the stream part-read instead of inflating it all and then measuring" do
      input = StringIO.new(bomb)
      described_class.new(->(_env) { raise "unreachable" })
                     .call(env_for(bomb).merge("rack.input" => input))

      expect(input.pos).to be < bomb.bytesize
    end
  end

  # Bounds the pathological case that survives the cap: a body that inflates to just under it.
  it "inflates a body far larger than one read chunk without losing bytes" do
    original = "x" * (described_class::READ_CHUNK_BYTES * 3 + 17)

    expect(call(env_for(Zlib.gzip(original))).last.body).to eq(original)
  end
end
