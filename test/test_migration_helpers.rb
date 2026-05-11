# frozen_string_literal: true

require "test_helper"

class TestMigrationHelpers < Minitest::Test
  cover "SQLiteTypes::MigrationHelpers*"

  def test_helpers_fail_loudly_on_non_postgresql_adapters
    migration = FakeMigration.new(adapter_name: "SQLite", direction: :up)

    error = assert_raises(ActiveRecord::MigrationError) do
      migration.change_array_to_json :events, :tags, :string
    end
    assert_includes error.message, "must run on PostgreSQL"

    assert_raises(ActiveRecord::MigrationError) do
      migration.change_inet_to_string :users, :current_sign_in_ip
    end
    assert_raises(ActiveRecord::MigrationError) do
      migration.change_interval_to_string :events, :duration
    end
  end

  def test_postgresql_array_rollback_expression_preserves_nulls_and_empty_arrays
    expression = migration_class.new.send(:postgresql_array_restore_expression, '"tags"', :string, false)

    assert_includes expression, 'WHEN "tags" IS NULL THEN NULL'
    assert_includes expression, "ELSE COALESCE((SELECT array_agg(sqlite_types_element.value ORDER BY sqlite_types_element.ordinality)"
    assert_includes expression, "FROM jsonb_array_elements_text(\"tags\") WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
  end

  def test_postgresql_nested_array_rollback_expression_preserves_element_order
    expression = migration_class.new.send(:postgresql_array_restore_expression, '"nested_tags"', :string, true)

    assert_includes expression, "ORDER BY sqlite_types_outer.ordinality"
    assert_includes expression, "FROM jsonb_array_elements(\"nested_tags\") WITH ORDINALITY AS sqlite_types_outer(value, ordinality)"
    assert_includes expression, "ORDER BY sqlite_types_element.ordinality"
    assert_includes expression, "FROM jsonb_array_elements_text(sqlite_types_outer.value) WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
  end

  def test_postgresql_nested_array_shape_validation_rejects_scalars_without_calling_array_length_on_them
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :summary_points, :string, nested: true

    validation_sql = migration.calls.find do |call|
      call.first == :select_value && call[1].first.include?("jsonb_array_length")
    end[1].first
    assert_includes validation_sql, 'FROM "events" AS sqlite_types_row'
    assert_includes validation_sql, "jsonb_typeof(sqlite_types_row.\"summary_points\") <> 'array'"
    assert_includes validation_sql, "CASE WHEN jsonb_typeof(sqlite_types_outer.value) <> 'array' THEN true"
    assert_includes validation_sql, "ELSE jsonb_array_length(sqlite_types_outer.value) = 0"
  end

  def test_postgresql_nested_array_element_validation_walks_inner_arrays
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :score_matrix, :integer, nested: true

    validation_sql = migration.calls.find do |call|
      call.first == :select_value && call[1].first.include?("jsonb_array_elements(sqlite_types_outer.value) AS sqlite_types_element")
    end[1].first
    cast_validation_sql = migration.calls.reverse.find do |call|
      call.first == :select_value && call[1].first.start_with?("SELECT COUNT(*)")
    end[1].first
    assert_includes validation_sql, 'FROM "events" AS sqlite_types_row'
    assert_includes validation_sql, "FROM jsonb_array_elements(sqlite_types_row.\"score_matrix\") AS sqlite_types_outer(value)"
    assert_includes validation_sql, "FROM jsonb_array_elements(sqlite_types_outer.value) AS sqlite_types_element(value)"
    assert_includes cast_validation_sql, "jsonb_array_elements_text(sqlite_types_outer.value)"
  end

  def test_postgresql_array_rollback_validates_top_level_json_array_shape_before_element_expansion
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :score_ids, :integer

    shape_validation_call = migration.calls.find do |call|
      call.first == :select_value && !call[1].first.include?("jsonb_array_elements")
    end
    element_validation_call = migration.calls.find do |call|
      call.first == :select_value && call[1].first.include?("jsonb_array_elements")
    end
    assert_includes shape_validation_call[1].first, 'FROM "events" AS sqlite_types_row'
    assert_includes shape_validation_call[1].first, "jsonb_typeof(sqlite_types_row.\"score_ids\") <> 'array'"
    assert_includes element_validation_call[1].first, 'FROM "events" AS sqlite_types_row'
    assert_includes element_validation_call[1].first, "jsonb_array_elements(sqlite_types_row.\"score_ids\")"
    assert_operator migration.calls.index(shape_validation_call), :<, migration.calls.index(element_validation_call)
  end

  def test_postgresql_array_migration_uses_to_jsonb_for_upward_conversion
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)

    migration.change_array_to_json :events, :relationship_statuses, :string

    assert_includes migration.calls, [
      :change_column,
      [:events, :relationship_statuses, :jsonb],
      {using: 'to_jsonb("relationship_statuses")'}
    ]
    assert_includes migration.calls, [
      :change_column_default,
      [:events, :relationship_statuses],
      {from: [], to: nil}
    ]
    assert_includes migration.calls, [
      :change_column_default,
      [:events, :relationship_statuses],
      {from: nil, to: []}
    ]
    assert_includes migration.calls, [
      :add_check_constraint,
      [:events, 'jsonb_typeof("relationship_statuses") = \'array\''],
      {name: "events_relationship_statuses_array_check"}
    ]
  end

  def test_postgresql_array_migration_uses_custom_constraint_name
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)
    rollback = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :tags, :string, constraint_name: "custom_tags_array_check"
    rollback.change_array_to_json :events, :tags, :string, constraint_name: "custom_tags_array_check"

    assert_includes migration.calls, [
      :add_check_constraint,
      [:events, 'jsonb_typeof("tags") = \'array\''],
      {name: "custom_tags_array_check"}
    ]
    assert_includes rollback.calls, [
      :remove_check_constraint,
      [:events],
      {name: "custom_tags_array_check"}
    ]
  end

  def test_postgresql_array_migration_normalizes_string_subtype
    rollback = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    rollback.change_array_to_json :events, :tags, "string"

    assert_equal [[:events, :tags, :string, false]], rollback.send(:sqlite_types_array_columns)
    assert_includes rollback.calls, [
      :add_column,
      [:events, "tags_sqlite_types_tmp", :string],
      {array: true, default: []}
    ]
  end

  def test_postgresql_array_rollback_restores_requested_json_array_subtype
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :links, :json

    assert_includes migration.calls, [
      :add_column,
      [:events, "links_sqlite_types_tmp", :json],
      {array: true, default: []}
    ]
    execute_call = migration.calls.find { |call| call.first == :execute && call[1].first.include?("UPDATE") }
    assert_includes execute_call[1].first, 'UPDATE "events" SET'
    assert_includes execute_call[1].first, 'SET "links_sqlite_types_tmp" ='
    assert_includes execute_call[1].first, 'WHEN "links" IS NULL THEN NULL'
    assert_includes execute_call[1].first, "CASE WHEN jsonb_typeof(sqlite_types_element.value) = 'null' THEN NULL ELSE sqlite_types_element.value::json END"
    assert_includes execute_call[1].first, "ORDER BY sqlite_types_element.ordinality) FROM jsonb_array_elements"
  end

  def test_postgresql_jsonb_array_rollback_restores_json_nulls_as_sql_null_elements
    expression = migration_class.new.send(:postgresql_array_restore_expression, '"payloads"', :jsonb, false)

    assert_includes expression, "CASE WHEN jsonb_typeof(sqlite_types_element.value) = 'null' THEN NULL ELSE sqlite_types_element.value END"
  end

  def test_postgresql_hash_array_rollback_restores_jsonb_arrays
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :payloads, :hash

    assert_includes migration.calls, [
      :add_column,
      [:events, "payloads_sqlite_types_tmp", :jsonb],
      {array: true, default: []}
    ]
  end

  def test_postgresql_array_rollback_preflights_actual_restore_cast_before_schema_changes
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :score_ids, :integer

    cast_validation_call = migration.calls.reverse.find { |call| call.first == :select_value }
    remove_constraint_call = migration.calls.find { |call| call.first == :remove_check_constraint }
    assert_includes cast_validation_call[1].first, 'FROM "events" AS sqlite_types_row'
    assert_includes cast_validation_call[1].first, "sqlite_types_row.\"score_ids\""
    assert_includes cast_validation_call[1].first, "sqlite_types_element.value::int"
    assert_operator migration.calls.index(cast_validation_call), :<, migration.calls.index(remove_constraint_call)
  end

  def test_postgresql_array_rollback_locks_registered_tables_before_validation
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)
    migration_with_open_transaction = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, transaction_open: true)

    migration.change_array_to_json :events, :tags, :string
    migration_with_open_transaction.change_array_to_json :events, :tags, :string

    lock_call = migration.calls.find { |call| call.first == :execute && call[1].first.start_with?("LOCK TABLE") }
    first_validation_call = migration.calls.find { |call| call.first == :select_value }
    assert_equal 'LOCK TABLE "events" IN SHARE ROW EXCLUSIVE MODE', lock_call[1].first
    assert_operator migration.calls.index(lock_call), :<, migration.calls.index(first_validation_call)
    assert migration_with_open_transaction.calls.any? { |call| call.first == :execute && call[1].first.start_with?("LOCK TABLE") }
  end

  def test_postgresql_array_rollback_skips_table_locks_outside_transaction
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, transaction_open: false)

    migration.change_array_to_json :events, :tags, :string

    refute migration.calls.any? { |call| call.first == :execute && call[1].first.start_with?("LOCK TABLE") }
    assert migration.calls.any? { |call| call.first == :select_value }
  end

  def test_postgresql_array_rollback_locks_each_registered_table_once
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)
    migration.send(:sqlite_types_array_columns).concat([
      [:events, :tags, :string, false],
      [:events, :score_ids, :integer, false],
      [:users, :flags, :string, false]
    ])

    migration.send(:lock_registered_postgresql_array_tables!)

    lock_sql = migration.calls.select { |call| call.first == :execute }.map { |call| call[1].first }
    assert_equal [
      'LOCK TABLE "events" IN SHARE ROW EXCLUSIVE MODE',
      'LOCK TABLE "users" IN SHARE ROW EXCLUSIVE MODE'
    ], lock_sql
  end

  def test_array_migration_omits_default_change_when_default_is_already_target_value
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)

    migration.change_array_to_json :events, :tags, :string, default: nil

    refute migration.calls.any? { |call| call.first == :change_column_default }
  end

  def test_default_not_provided_omits_default_options
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)
    rollback = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)

    migration.change_array_to_json :events, :tags, :string, default: SQLiteTypes::MigrationHelpers::DEFAULT_NOT_PROVIDED
    rollback.change_array_to_json :events, :tags, :string, default: SQLiteTypes::MigrationHelpers::DEFAULT_NOT_PROVIDED

    refute migration.calls.any? { |call| call.first == :change_column_default }
    assert_includes rollback.calls, [
      :add_column,
      [:events, "tags_sqlite_types_tmp", :string],
      {array: true}
    ]
  end

  def test_array_migration_allows_explicit_nullability
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)

    migration.change_array_to_json :events, :tags, :string, null: false

    assert_includes migration.calls, [
      :change_column,
      [:events, :tags, :jsonb],
      {null: false, using: 'to_jsonb("tags")'}
    ]

    rollback = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)
    rollback.change_array_to_json :events, :tags, :string, null: false

    assert_includes rollback.calls, [
      :add_column,
      [:events, "tags_sqlite_types_tmp", :string],
      {array: true, null: false, default: []}
    ]
  end

  def test_postgresql_array_rollback_resolves_nullability_from_matching_column_metadata
    column = Struct.new(:name, :null)
    rollback = FakeMigration.new(
      adapter_name: "PostgreSQL",
      direction: :down,
      columns: [
        column.new("other_column", true),
        column.new("tags", false)
      ]
    )

    rollback.change_array_to_json :events, :tags, :string

    assert_includes rollback.calls, [
      :add_column,
      [:events, "tags_sqlite_types_tmp", :string],
      {array: true, null: false, default: []}
    ]
  end

  def test_generated_postgresql_identifiers_are_truncated_with_stable_suffixes
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)
    long_column = :top_fitness_and_wellness_interests_for_external_visibility_rules

    migration.change_array_to_json :quiz_responses, long_column, :string

    add_check_call = migration.calls.find { |call| call.first == :add_check_constraint }
    constraint_name = add_check_call.last.fetch(:name)
    assert_operator constraint_name.length, :<=, 63
    assert_match(/\Aquiz_responses_top_fitness_and_wellness_interests_fo_[0-9a-f]{10}\z/, constraint_name)

    rollback = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)
    rollback.change_array_to_json :quiz_responses, long_column, :string

    add_column_call = rollback.calls.find { |call| call.first == :add_column }
    temporary_column_name = add_column_call[1][1]
    assert_operator temporary_column_name.length, :<=, 63
    assert_match(/\Atop_fitness_and_wellness_interests_for_external_visi_[0-9a-f]{10}\z/, temporary_column_name)
  end

  def test_generated_postgresql_identifier_truncation_stringifies_values
    identifier = Object.new
    def identifier.to_s
      "x" * 80
    end

    truncated = migration_class.new.send(:truncate_identifier, identifier)

    assert_operator truncated.length, :<=, 63
    assert_equal "#{"x" * 52}_d929cdeea7", truncated
  end

  def test_generated_postgresql_identifier_truncation_preserves_limit_length_values
    identifier = "x" * 63

    assert_equal identifier, migration_class.new.send(:truncate_identifier, identifier)
  end

  def test_defensive_array_helpers_reject_unsupported_subtypes
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)

    error = assert_raises(ArgumentError) do
      migration.change_array_to_json :events, :tags, :uuid
    end
    assert_equal "Unsupported array subtype: uuid", error.message

    assert_raises(ArgumentError) do
      migration.change_array_to_json :events, :tags, Object.new
    end

    helper = migration_class.new
    error = assert_raises(ArgumentError) { helper.send(:postgresql_array_expression, '"tags"', :uuid, false) }
    assert_equal "Unsupported array subtype: uuid", error.message
    error = assert_raises(ArgumentError) { helper.send(:postgresql_invalid_array_element_condition, "value", :uuid) }
    assert_equal "Unsupported array subtype: uuid", error.message
  end

  def test_postgresql_array_restore_cast_reports_empty_statement_messages
    statement_error = ActiveRecord::StatementInvalid.new("hidden")
    statement_error.define_singleton_method(:message) { "" }
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, select_value_error: statement_error)

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:validate_postgresql_array_restore_cast!, :events, :tags, :string, nested: false)
    end

    assert_includes error.message, "PostgreSQL rejected the rollback cast"
    assert_includes error.message, "PostgreSQL string array"
  end

  def test_postgresql_array_restore_cast_reports_first_statement_error_line
    statement_error = ActiveRecord::StatementInvalid.new("hidden")
    statement_error.define_singleton_method(:message) { "  first database line  \nsecond database line" }
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, select_value_error: statement_error)

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:validate_postgresql_array_restore_cast!, :events, :tags, :string, nested: false)
    end

    assert_includes error.message, "rollback cast: first database line"
    refute_includes error.message, "second database line"
  end

  def test_postgresql_array_element_validation_reports_target_subtype
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, select_value_result: 1)

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:validate_postgresql_array_elements!, :events, :score_ids, :integer, nested: false)
    end

    assert_equal "Cannot restore events.score_ids to a PostgreSQL integer array; JSON elements are not compatible with the target array subtype", error.message.strip
  end

  def test_postgresql_array_shape_validation_reports_target_subtype
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, select_value_result: 1)

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:validate_postgresql_array_shape!, :events, :score_ids, :integer)
    end

    assert_equal "Cannot restore events.score_ids to a PostgreSQL integer array; JSON value is not an array", error.message.strip
  end

  def test_registered_postgresql_array_rollback_validates_shape_with_registered_subtype
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, select_value_result: 1)
    migration.send(:sqlite_types_array_columns) << [:events, :score_ids, :integer, false]

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:validate_registered_postgresql_array_rollbacks!)
    end

    assert_equal "Cannot restore events.score_ids to a PostgreSQL integer array; JSON value is not an array", error.message.strip
  end

  def test_postgresql_nested_array_shape_validation_reports_target_column
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, select_value_result: 1)

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:validate_postgresql_nested_array_shape!, :events, :score_matrix)
    end

    assert_equal "Cannot restore events.score_matrix to a PostgreSQL multidimensional array; nested JSON arrays must be rectangular and inner arrays must be non-empty", error.message.strip
  end

  def test_resolved_null_returns_nil_when_column_metadata_is_missing
    column = Struct.new(:name, :null).new("other_column", false)
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down, columns: [column])

    assert_nil migration.send(:resolved_null, :events, :tags, nil)
  end

  def test_postgresql_inet_and_interval_migrations_use_explicit_casts
    migration = FakeMigration.new(adapter_name: "PostgreSQL", direction: :up)

    migration.change_inet_to_string :users, :current_sign_in_ip
    migration.change_interval_to_string :timings, :time_offset

    assert_includes migration.calls, [
      :change_column,
      [:users, :current_sign_in_ip, :string],
      {using: '"current_sign_in_ip"::text'}
    ]
    assert_includes migration.calls, [
      :change_column,
      [:timings, :time_offset, :string],
      {using: '"time_offset"::text'}
    ]
    refute_includes migration.calls, [
      :change_column,
      [:users, :current_sign_in_ip, :inet],
      {using: '"current_sign_in_ip"::inet'}
    ]
    refute_includes migration.calls, [
      :change_column,
      [:timings, :time_offset, :interval],
      {using: '"time_offset"::interval'}
    ]

    rollback = FakeMigration.new(adapter_name: "PostgreSQL", direction: :down)
    rollback.change_inet_to_string :users, :current_sign_in_ip
    rollback.change_interval_to_string :timings, :time_offset

    refute_includes rollback.calls, [
      :change_column,
      [:users, :current_sign_in_ip, :string],
      {using: '"current_sign_in_ip"::text'}
    ]
    refute_includes rollback.calls, [
      :change_column,
      [:timings, :time_offset, :string],
      {using: '"time_offset"::text'}
    ]
    assert_includes rollback.calls, [
      :change_column,
      [:users, :current_sign_in_ip, :inet],
      {using: '"current_sign_in_ip"::inet'}
    ]
    assert_includes rollback.calls, [
      :change_column,
      [:timings, :time_offset, :interval],
      {using: '"time_offset"::interval'}
    ]
  end

  private

  def migration_class
    Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version]) do
      include SQLiteTypes::MigrationHelpers
    end
  end
end

class FakeMigration
  include SQLiteTypes::MigrationHelpers

  attr_reader :calls, :connection

  def initialize(adapter_name:, direction:, transaction_open: nil, columns: nil, select_value_error: nil, select_value_result: nil)
    @connection = Object.new
    @connection.define_singleton_method(:adapter_name) { adapter_name }
    @connection.define_singleton_method(:transaction_open?) { transaction_open } unless transaction_open.nil?
    @connection.define_singleton_method(:columns) { |_table_name| columns } unless columns.nil?
    @select_value_error = select_value_error
    @select_value_result = select_value_result
    @direction = direction
    @calls = []
  end

  def reversible
    yield Direction.new(self, @direction)
  end

  def change_column(*args, **options)
    calls << [:change_column, args, options]
  end

  def change_column_default(*args, **options)
    calls << [:change_column_default, args, options]
  end

  def add_check_constraint(*args, **options)
    calls << [:add_check_constraint, args, options]
  end

  def remove_check_constraint(*args, **options)
    calls << [:remove_check_constraint, args, options]
  end

  def add_column(*args, **options)
    calls << [:add_column, args, options]
  end

  def execute(sql)
    calls << [:execute, [sql], {}]
  end

  def select_value(sql)
    calls << [:select_value, [sql], {}]
    raise @select_value_error if @select_value_error

    @select_value_result
  end

  def remove_column(*args, **options)
    calls << [:remove_column, args, options]
  end

  def rename_column(*args, **options)
    calls << [:rename_column, args, options]
  end

  def quote_column_name(name)
    %("#{name}")
  end

  def quote_table_name(name)
    %("#{name}")
  end

  class Direction
    def initialize(migration, direction)
      @migration = migration
      @direction = direction
    end

    def up(&block)
      @migration.instance_eval(&block) if @direction == :up
    end

    def down(&block)
      @migration.instance_eval(&block) if @direction == :down
    end
  end
end
