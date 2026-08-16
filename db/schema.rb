# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_16_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id"
    t.datetime "last_used_at"
    t.string "name", default: "Default CI Key"
    t.bigint "repository_id", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_api_keys_on_created_by_user_id"
    t.index ["repository_id"], name: "index_api_keys_on_repository_id"
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
  end

  create_table "embedding_cache_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536, null: false
    t.string "provider_fingerprint", null: false
    t.string "text_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["provider_fingerprint", "text_digest"], name: "index_embedding_cache_entries_on_key", unique: true
    t.index ["updated_at"], name: "index_embedding_cache_entries_on_updated_at"
  end

  create_table "ingest_rejections", force: :cascade do |t|
    t.jsonb "details", default: [], null: false
    t.datetime "occurred_at", null: false
    t.bigint "repository_id", null: false
    t.integer "total_reasons_count", default: 0, null: false
    t.string "user_agent"
    t.index ["repository_id", "occurred_at", "id"], name: "index_ingest_rejections_on_repository_and_recency", order: { occurred_at: :desc, id: :desc }
  end

  create_table "repositories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "github_full_name", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["github_full_name"], name: "index_repositories_on_github_full_name", unique: true
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "repository_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "granted_by_user_id"
    t.text "permissions", default: [], null: false, array: true
    t.bigint "repository_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["granted_by_user_id"], name: "index_repository_memberships_on_granted_by_user_id"
    t.index ["repository_id"], name: "index_repository_memberships_on_repository_id"
    t.index ["user_id", "repository_id"], name: "index_repository_memberships_on_user_and_repository", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "spec_identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536, null: false
    t.string "file_path", null: false
    t.bigint "last_seen_test_run_id"
    t.integer "line_number", null: false
    t.bigint "repository_id", null: false
    t.string "signal_source", null: false
    t.text "text", null: false
    t.string "text_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["embedding"], name: "index_spec_identities_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["last_seen_test_run_id"], name: "index_spec_identities_on_last_seen_test_run_id"
    t.index ["repository_id", "text_digest"], name: "index_spec_identities_on_text", unique: true
    t.index ["repository_id"], name: "index_spec_identities_on_repository_id"
  end

  create_table "spec_intents", force: :cascade do |t|
    t.string "action", null: false
    t.text "behavior", null: false
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536
    t.string "entity", null: false
    t.string "file_path", null: false
    t.string "layer", null: false
    t.integer "line_number", null: false
    t.bigint "repository_id", null: false
    t.string "status", default: "annotated"
    t.bigint "test_run_id"
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_spec_intents_on_action"
    t.index ["embedding"], name: "index_spec_intents_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["entity"], name: "index_spec_intents_on_entity"
    t.index ["repository_id", "entity", "action"], name: "index_spec_intents_on_repository_id_and_entity_and_action"
    t.index ["repository_id", "file_path", "line_number"], name: "index_spec_intents_on_location", unique: true
    t.index ["repository_id"], name: "index_spec_intents_on_repository_id"
    t.index ["test_run_id"], name: "index_spec_intents_on_test_run_id"
  end

  create_table "spec_observations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.datetime "embed_failed_at"
    t.integer "embed_failure_count", default: 0, null: false
    t.string "example_id"
    t.string "file_path", null: false
    t.string "intent_action"
    t.text "intent_behavior"
    t.string "intent_entity"
    t.integer "line_number", null: false
    t.text "name"
    t.string "outcome"
    t.bigint "repository_id", null: false
    t.string "spec_file_path"
    t.bigint "spec_identity_id"
    t.string "status", null: false
    t.bigint "test_run_id", null: false
    t.bigint "test_run_shard_id"
    t.datetime "updated_at", null: false
    t.index ["repository_id", "created_at", "id"], name: "index_spec_observations_on_unattempted_embed_backlog", where: "((embed_failed_at IS NULL) AND (spec_identity_id IS NULL))"
    t.index ["repository_id", "embed_failure_count", "embed_failed_at"], name: "index_spec_observations_on_embed_backlog", where: "((embed_failed_at IS NOT NULL) AND (spec_identity_id IS NULL))"
    t.index ["repository_id", "name"], name: "index_spec_observations_on_repository_id_and_name"
    t.index ["repository_id"], name: "index_spec_observations_on_repository_id"
    t.index ["spec_identity_id"], name: "index_spec_observations_on_spec_identity_id"
    t.index ["test_run_id", "duration_seconds"], name: "index_spec_observations_on_test_run_id_and_duration_seconds"
    t.index ["test_run_id", "example_id"], name: "index_spec_observations_on_test_run_id_and_example_id", unique: true
    t.index ["test_run_id", "outcome"], name: "index_spec_observations_on_test_run_id_and_outcome"
    t.index ["test_run_id", "spec_file_path"], name: "index_spec_observations_on_test_run_id_and_spec_file_path"
    t.index ["test_run_id"], name: "index_spec_observations_on_test_run_id"
    t.index ["test_run_shard_id"], name: "index_spec_observations_on_test_run_shard_id"
  end

  create_table "test_run_shards", force: :cascade do |t|
    t.integer "annotated_specs_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.string "shard_id"
    t.bigint "test_run_id", null: false
    t.integer "total_specs_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["test_run_id", "shard_id"], name: "index_test_run_shards_on_test_run_id_and_shard_id", unique: true, where: "(shard_id IS NOT NULL)"
    t.index ["test_run_id"], name: "index_test_run_shards_on_test_run_id"
  end

  create_table "test_runs", force: :cascade do |t|
    t.integer "annotated_specs_count", default: 0
    t.string "branch"
    t.string "ci_run_id"
    t.string "commit_sha", null: false
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.bigint "repository_id", null: false
    t.integer "total_specs_count", default: 0
    t.datetime "updated_at", null: false
    t.index ["repository_id", "branch", "created_at", "id"], name: "index_test_runs_on_repository_id_and_branch_and_created_at"
    t.index ["repository_id", "ci_run_id"], name: "index_test_runs_on_repository_id_and_ci_run_id", unique: true, where: "(ci_run_id IS NOT NULL)"
    t.index ["repository_id", "commit_sha", "created_at", "id"], name: "index_test_runs_on_repository_id_and_commit_sha"
    t.index ["repository_id"], name: "index_test_runs_on_repository_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "archived_at"
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "email"
    t.text "github_access_token"
    t.string "github_handle", null: false
    t.string "github_token_scopes"
    t.datetime "github_token_updated_at"
    t.string "github_uid", null: false
    t.datetime "updated_at", null: false
    t.index ["github_handle"], name: "index_users_on_github_handle"
    t.index ["github_uid"], name: "index_users_on_github_uid", unique: true
  end

  add_foreign_key "api_keys", "repositories"
  add_foreign_key "api_keys", "users", column: "created_by_user_id"
  add_foreign_key "ingest_rejections", "repositories"
  add_foreign_key "repositories", "users"
  add_foreign_key "repository_memberships", "repositories"
  add_foreign_key "repository_memberships", "users"
  add_foreign_key "repository_memberships", "users", column: "granted_by_user_id"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "spec_identities", "repositories"
  add_foreign_key "spec_identities", "test_runs", column: "last_seen_test_run_id", on_delete: :nullify
  add_foreign_key "spec_intents", "repositories"
  add_foreign_key "spec_intents", "test_runs"
  add_foreign_key "spec_observations", "repositories"
  add_foreign_key "spec_observations", "spec_identities", on_delete: :nullify
  add_foreign_key "spec_observations", "test_run_shards", on_delete: :nullify
  add_foreign_key "spec_observations", "test_runs"
  add_foreign_key "test_run_shards", "test_runs"
  add_foreign_key "test_runs", "repositories"
end
