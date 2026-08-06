# frozen_string_literal: true

require "rails_helper"

RSpec.describe JsonParseErrorResponder do
  let(:parse_error) { ActionDispatch::Http::Parameters::ParseError }

  def responder(&downstream)
    described_class.new(downstream)
  end

  def call(path, &downstream)
    responder(&downstream).call("PATH_INFO" => path)
  end

  def raising_app
    error = parse_error
    ->(_env) { raise error.new("Error occurred while parsing request parameters") }
  end

  it "answers an unparseable API body with the API's own error shape" do
    status, headers, body = call("/api/v1/ingest", &raising_app)

    expect(status).to eq(400)
    expect(headers["content-type"]).to eq("application/json; charset=utf-8")
    expect(JSON.parse(body.first)).to include("error" => "bad_request")
  end

  it "sets a content-length matching the body it returns" do
    _, headers, body = call("/api/v1/ingest", &raising_app)

    expect(headers["content-length"]).to eq(body.first.bytesize.to_s)
  end

  # Outside /api an HTML client has no use for a JSON error body, so Rails' own exception handling
  # stays in charge. This is the half that is easy to get wrong by widening the rescue.
  it "re-raises for a non-API path" do
    expect { call("/repositories", &raising_app) }.to raise_error(parse_error)
  end

  it "leaves a healthy response completely alone" do
    downstream = [200, { "content-type" => "text/plain" }, ["ok"]]

    expect(call("/api/v1/ingest") { |_env| downstream }).to eq(downstream)
  end

  it "does not swallow errors it was not written for" do
    expect { call("/api/v1/ingest") { |_env| raise ArgumentError, "unrelated" } }
      .to raise_error(ArgumentError)
  end
end
