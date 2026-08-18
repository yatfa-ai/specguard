# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpecIntent do
  let(:repository) { create_repository }

  it "treats (repository, file_path, line_number) as the identity of an intent" do
    create_spec_intent(repository: repository, file_path: "spec/a_spec.rb", line_number: 4)
    duplicate = repository.spec_intents.new(
      file_path: "spec/a_spec.rb", line_number: 4,
      entity: "Invoice", action: "void", behavior: "…", layer: "unit"
    )

    expect(duplicate).not_to be_valid
  end

  it "backstops that identity in the database, not just in the model" do
    create_spec_intent(repository: repository, file_path: "spec/a_spec.rb", line_number: 4)

    expect {
      repository.spec_intents.new(
        file_path: "spec/a_spec.rb", line_number: 4,
        entity: "Invoice", action: "void", behavior: "…", layer: "unit"
      ).save(validate: false)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lets the same location exist in a different repository" do
    other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                              github_full_name: "acme/ledger")
    create_spec_intent(repository: repository, file_path: "spec/a_spec.rb", line_number: 4)

    expect(create_spec_intent(repository: other, file_path: "spec/a_spec.rb", line_number: 4)).to be_persisted
  end

  it "only accepts the four known layers" do
    intent = repository.spec_intents.new(
      file_path: "spec/a_spec.rb", line_number: 1,
      entity: "Invoice", action: "void", behavior: "…", layer: "acceptance"
    )

    expect(intent).not_to be_valid
    expect(intent.errors[:layer]).to be_present
  end

  it "stores a 1024-dimension embedding and finds neighbours through it" do
    intent = create_spec_intent(repository: repository, embedding: Array.new(1024) { 0.1 })

    expect(intent.reload.embedding.size).to eq(1024)
    expect(described_class.nearest_neighbors(:embedding, Array.new(1024) { 0.1 }, distance: "cosine"))
      .to include(intent)
  end

  it "survives its test run being deleted — the run is only an audit trail" do
    run = repository.test_runs.create!(commit_sha: "abc123")
    intent = create_spec_intent(repository: repository, test_run: run)

    run.destroy!

    expect(intent.reload).to be_persisted
    expect(intent.test_run).to be_nil
  end
end
