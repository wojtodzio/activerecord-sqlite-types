# frozen_string_literal: true

require "test_helper"

class PostgreSQLMigrationRecord < ActiveRecord::Base
  self.table_name = "postgresql_migration_records"

  attribute :ip_address, SQLiteTypes::IpAddress.new
  attribute :time_offset, SQLiteTypes::Interval.new
  attribute :tags, SQLiteTypes::Array.new(:string)
  attribute :score_ids, SQLiteTypes::Array.new(:integer)
  attribute :payloads, SQLiteTypes::Array.new(:hash)
  attribute :json_payloads, SQLiteTypes::Array.new(:json)
  attribute :nested_tags, SQLiteTypes::Array.new(:string, nested: true)
  attribute :optional_tags, SQLiteTypes::Array.new(:string)
  attribute :meeting_times, SQLiteTypes::Array.new(:datetime)
end

class PostgreSQLNativeMigrationRecord < ActiveRecord::Base
  self.table_name = "postgresql_migration_records"
end

class TestPostgreSQLMigrationHelpers < Minitest::Test
  cover "SQLiteTypes::Array*"
  cover "SQLiteTypes::Interval*"
  cover "SQLiteTypes::IpAddress*"
  cover "SQLiteTypes::MigrationHelpers*"

  DATABASE_NAME = "activerecord_sqlite_types_test"

  def setup
    connect_to_postgres!
    reset_schema
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:postgresql_migration_records, if_exists: true) if ActiveRecord::Base.connected?
    ActiveRecord::Base.connection.disconnect! if ActiveRecord::Base.connected?
    super
  end

  def test_helpers_run_reversibly_on_postgresql_and_preserve_data
    before = serialized_rows

    migration_class.migrate(:up)

    assert_equal before, serialized_rows
    assert_equal "character varying", column_data_type(:ip_address)
    assert_equal "character varying", column_data_type(:time_offset)
    assert_equal "jsonb", column_data_type(:tags)
    assert_equal "jsonb", column_data_type(:score_ids)
    assert_equal "jsonb", column_data_type(:payloads)
    assert_equal "jsonb", column_data_type(:json_payloads)
    assert_equal "jsonb", column_data_type(:nested_tags)
    assert_equal "jsonb", column_data_type(:optional_tags)
    assert_equal "jsonb", column_data_type(:meeting_times)
    assert column_nullable?(:optional_tags)
    assert_includes check_constraint_names, "postgresql_migration_records_tags_array_check"

    record = PostgreSQLMigrationRecord.find_by!(name: "full")
    assert_equal "192.0.2.15/24", record.read_attribute_before_type_cast(:ip_address)
    assert_instance_of IPAddr, record.ip_address
    assert_equal "192.0.2.0", record.ip_address.to_s
    assert_equal "192.0.2.0/24", SQLiteTypes::IpAddress.new.serialize(record.ip_address)
    assert_equal "PT20M", SQLiteTypes::Interval.new.serialize(record.time_offset)
    assert_equal ["alpha", nil, "beta"], record.tags
    assert_equal [1, nil, 2], record.score_ids
    assert_equal [{"kind" => "event", "id" => 12}, nil], record.payloads
    assert_equal [{"kind" => "json"}, nil], record.json_payloads
    assert_equal [["north", nil], ["east", "west"]], record.nested_tags
    assert_equal ["optional"], record.optional_tags
    assert_equal [Time.zone.parse("2025-01-09 12:30:00").to_i, nil], record.meeting_times.map { |value| value&.to_i }
    assert_nil PostgreSQLMigrationRecord.find_by!(name: "empty").optional_tags
    complex = PostgreSQLMigrationRecord.find_by!(name: "complex")
    assert_equal "P1Y2M3DT4H5M6S", SQLiteTypes::Interval.new.serialize(complex.time_offset)
    complex.update!(tags: ["delta", "updated"])
    assert_equal "198.51.100.7/25", row_values("complex").fetch("ip_address")
    with_null_elements = PostgreSQLMigrationRecord.find_by!(name: "with_null_elements")
    assert_equal ["with", nil, "nulls"], with_null_elements.tags
    assert_equal [7, nil, 8], with_null_elements.score_ids
    assert_equal [nil, {"kind" => "nullable"}], with_null_elements.payloads
    assert_equal [["left", nil], ["right", "center"]], with_null_elements.nested_tags

    record.update!(
      ip_address: "203.0.113.9/25",
      time_offset: 45.minutes,
      tags: ["gamma"],
      score_ids: [3, 4],
      payloads: [{"kind" => "updated"}],
      json_payloads: [{"kind" => "json-updated"}],
      nested_tags: [["west", "central"]],
      optional_tags: ["changed"],
      meeting_times: [Time.zone.parse("2025-01-10 08:15:00")]
    )
    assert_equal record.id, PostgreSQLMigrationRecord.find_by!(tags: ["gamma"]).id
    ActiveRecord::Base.connection.execute("INSERT INTO postgresql_migration_records (name) VALUES ('defaults_after_up')")

    defaults_after_up = PostgreSQLMigrationRecord.find_by!(name: "defaults_after_up")
    assert_equal "198.51.100.9/25", defaults_after_up.read_attribute_before_type_cast(:ip_address)
    assert_equal "PT15M", SQLiteTypes::Interval.new.serialize(defaults_after_up.time_offset)
    assert_equal [], defaults_after_up.tags
    assert_equal [], defaults_after_up.score_ids
    assert_equal [], defaults_after_up.payloads
    assert_equal [], defaults_after_up.nested_tags
    assert_nil defaults_after_up.optional_tags

    after_update = serialized_rows
    migrate_down

    assert_equal after_update, serialized_rows
    assert_equal "inet", column_user_defined_type(:ip_address)
    assert_equal "interval", column_data_type(:time_offset)
    assert_equal "ARRAY", column_data_type(:tags)
    assert_equal "_text", column_user_defined_type(:tags)
    assert_equal "_int4", column_user_defined_type(:score_ids)
    assert_equal "_jsonb", column_user_defined_type(:payloads)
    assert_equal "_json", column_user_defined_type(:json_payloads)
    assert_equal "_text", column_user_defined_type(:optional_tags)
    assert_equal "_timestamp", column_user_defined_type(:meeting_times)
    assert column_nullable?(:optional_tags)
    restored_nested_tags = ActiveSupport::JSON.decode(
      ActiveRecord::Base.connection.select_value("SELECT to_jsonb(nested_tags)::text FROM postgresql_migration_records WHERE name = 'full'")
    )
    assert_equal [["west", "central"]], restored_nested_tags
    assert payload_element_null?("with_null_elements", 1)
    assert json_payload_element_null?("with_null_elements", 1)

    ActiveRecord::Base.connection.execute("INSERT INTO postgresql_migration_records (name) VALUES ('defaults_after_down')")
    assert_equal default_row_values, row_values("defaults_after_down")
  end

  def test_active_record_array_queries_match_before_and_after_type_preparation
    PostgreSQLNativeMigrationRecord.reset_column_information
    before = array_query_results(PostgreSQLNativeMigrationRecord)

    migration_class.migrate(:up)
    PostgreSQLMigrationRecord.reset_column_information

    assert_equal before, array_query_results(PostgreSQLMigrationRecord)
  end

  def test_nested_json_rollback_rejects_ragged_arrays_before_postgresql_array_cast
    migration_class.migrate(:up)

    assert_nested_tags_rollback_rejected('["not nested"]')
    assert_nested_tags_rollback_rejected('[["north"], ["east", "west"]]')
    assert_nested_tags_rollback_rejected("[[], []]")
  end

  def test_json_rollback_rejects_invalid_array_elements_before_postgresql_array_cast
    migration_class.migrate(:up)

    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE postgresql_migration_records
      SET score_ids = '["not-an-integer"]'::jsonb
      WHERE name = 'full'
    SQL

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migrate_down
    end

    assert_includes error.message, "Cannot restore postgresql_migration_records.score_ids"
    assert_includes error.message, "JSON elements are not compatible"
    assert_array_jsonb_schema_unchanged
  end

  def test_json_rollback_rejects_top_level_non_array_json_before_element_expansion
    migration_class.migrate(:up)
    ActiveRecord::Base.connection.remove_check_constraint :postgresql_migration_records,
      name: "postgresql_migration_records_score_ids_array_check"

    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE postgresql_migration_records
      SET score_ids = '"not-array"'::jsonb
      WHERE name = 'full'
    SQL

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migrate_down
    end

    assert_includes error.message, "Cannot restore postgresql_migration_records.score_ids"
    assert_includes error.message, "JSON value is not an array"
    assert_equal "jsonb", column_data_type(:score_ids)
    refute ActiveRecord::Base.connection.column_exists?(:postgresql_migration_records, :score_ids_sqlite_types_tmp)
  end

  def test_json_rollback_rejects_values_postgresql_cast_would_reject_before_schema_changes
    migration_class.migrate(:up)

    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE postgresql_migration_records
      SET score_ids = '[2147483648]'::jsonb
      WHERE name = 'full'
    SQL

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migrate_down
    end

    assert_includes error.message, "Cannot restore postgresql_migration_records.score_ids"
    assert_includes error.message, "PostgreSQL rejected the rollback cast"
    assert_array_jsonb_schema_unchanged
  end

  def test_json_rollback_rejects_invalid_datetime_values_before_schema_changes
    migration_class.migrate(:up)

    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE postgresql_migration_records
      SET meeting_times = '["not-a-date"]'::jsonb
      WHERE name = 'full'
    SQL

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migrate_down
    end

    assert_includes error.message, "Cannot restore postgresql_migration_records.meeting_times"
    assert_includes error.message, "PostgreSQL rejected the rollback cast"
    assert_array_jsonb_schema_unchanged
  end

  def test_json_rollback_allows_values_postgresql_can_cast_or_textify
    migration_class.migrate(:up)

    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE postgresql_migration_records
      SET tags = '[1, true, null, "kept"]'::jsonb,
        score_ids = '["7", 8, null]'::jsonb,
        payloads = '[1, true, null, {"kept": true}]'::jsonb
      WHERE name = 'full'
    SQL

    migrate_down

    restored = row_values("full")
    assert_equal '["1", "true", null, "kept"]', restored.fetch("tags")
    assert_equal "[7, 8, null]", restored.fetch("score_ids")
    assert_equal [1, true, nil, {"kept" => true}], ActiveSupport::JSON.decode(restored.fetch("payloads"))
    assert payload_element_null?("full", 3)
  end

  def assert_nested_tags_rollback_rejected(value)
    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE postgresql_migration_records
      SET nested_tags = #{ActiveRecord::Base.connection.quote(value)}::jsonb
      WHERE name = 'full'
    SQL

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migrate_down
    end
    assert_includes error.message, "nested JSON arrays must be rectangular and inner arrays must be non-empty"
  ensure
    ActiveRecord::Base.connection.execute <<~SQL if ActiveRecord::Base.connected?
      UPDATE postgresql_migration_records
      SET nested_tags = '[["north", "south"], ["east", "west"]]'::jsonb
      WHERE name = 'full'
    SQL
  end

  private

  def connect_to_postgres!
    require "pg"
    ActiveRecord::Base.establish_connection(postgres_config(DATABASE_NAME))
    ActiveRecord::Base.connection.active?
  rescue LoadError
    raise "pg gem is required for PostgreSQL migration tests"
  rescue ActiveRecord::NoDatabaseError
    create_database!
    retry
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed, PG::Error => error
    raise "PostgreSQL is required for migration tests: #{error.message.lines.first&.strip}"
  end

  def create_database!
    ActiveRecord::Base.establish_connection(postgres_config("postgres"))
    ActiveRecord::Base.connection.create_database(DATABASE_NAME)
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed, PG::Error => error
    raise "PostgreSQL is required for migration tests: #{error.message.lines.first&.strip}"
  ensure
    ActiveRecord::Base.connection.disconnect! if ActiveRecord::Base.connected?
  end

  def postgres_config(database)
    {
      adapter: "postgresql",
      database: database,
      username: ENV["PGUSER"] || ENV["USER"],
      host: ENV["PGHOST"],
      port: ENV["PGPORT"]
    }.compact
  end

  def reset_schema
    ActiveRecord::Base.connection.drop_table(:postgresql_migration_records, if_exists: true)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE postgresql_migration_records (
        id bigserial PRIMARY KEY,
        name varchar NOT NULL,
        ip_address inet DEFAULT '198.51.100.9/25'::inet,
        time_offset interval DEFAULT '15 minutes'::interval,
        tags text[] DEFAULT '{}' NOT NULL,
        score_ids integer[] DEFAULT '{}' NOT NULL,
        payloads jsonb[] DEFAULT '{}' NOT NULL,
        json_payloads json[] DEFAULT '{}' NOT NULL,
        nested_tags text[] DEFAULT '{}' NOT NULL,
        optional_tags text[],
        meeting_times timestamp[] DEFAULT '{}' NOT NULL
      )
    SQL
    ActiveRecord::Base.connection.execute <<~SQL
      INSERT INTO postgresql_migration_records
        (name, ip_address, time_offset, tags, score_ids, payloads, json_payloads, nested_tags, optional_tags, meeting_times)
      VALUES
        (
          'full',
          '192.0.2.15/24'::inet,
          '20 minutes'::interval,
          ARRAY['alpha', NULL, 'beta']::text[],
          ARRAY[1, NULL, 2]::integer[],
          ARRAY['{"kind":"event","id":12}'::jsonb, NULL]::jsonb[],
          ARRAY['{"kind":"json"}'::json, NULL]::json[],
          ARRAY[['north', NULL], ['east', 'west']]::text[],
          ARRAY['optional']::text[],
          ARRAY['2025-01-09 12:30:00'::timestamp, NULL]::timestamp[]
        ),
        (
          'complex',
          '198.51.100.7/25'::inet,
          '1 year 2 mons 3 days 04:05:06'::interval,
          ARRAY['delta']::text[],
          ARRAY[9]::integer[],
          ARRAY['{"kind":"complex"}'::jsonb]::jsonb[],
          ARRAY['{"kind":"complex-json"}'::json]::json[],
          ARRAY[['one', 'two']]::text[],
          ARRAY['complex']::text[],
          ARRAY['2025-02-03 04:05:06'::timestamp]::timestamp[]
        ),
        (
          'empty',
          NULL,
          NULL,
          '{}'::text[],
          '{}'::integer[],
          '{}'::jsonb[],
          '{}'::json[],
          '{}'::text[],
          NULL,
          '{}'::timestamp[]
        ),
        (
          'with_null_elements',
          '203.0.113.8/32'::inet,
          '5 minutes'::interval,
          ARRAY['with', NULL, 'nulls']::text[],
          ARRAY[7, NULL, 8]::integer[],
          ARRAY[NULL, '{"kind":"nullable"}'::jsonb]::jsonb[],
          ARRAY[NULL, '{"kind":"nullable-json"}'::json]::json[],
          ARRAY[['left', NULL], ['right', 'center']]::text[],
          ARRAY['maybe', NULL]::text[],
          ARRAY[NULL, '2025-03-04 05:06:07'::timestamp]::timestamp[]
        )
    SQL
  end

  def migration_class
    Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version]) do
      include SQLiteTypes::MigrationHelpers

      def change
        change_inet_to_string :postgresql_migration_records, :ip_address
        change_interval_to_string :postgresql_migration_records, :time_offset
        change_array_to_json :postgresql_migration_records, :tags, :text
        change_array_to_json :postgresql_migration_records, :score_ids, :integer
        change_array_to_json :postgresql_migration_records, :payloads, :jsonb
        change_array_to_json :postgresql_migration_records, :json_payloads, :json
        change_array_to_json :postgresql_migration_records, :nested_tags, :text, nested: true
        change_array_to_json :postgresql_migration_records, :optional_tags, :text,
          default: SQLiteTypes::MigrationHelpers::DEFAULT_NOT_PROVIDED
        change_array_to_json :postgresql_migration_records, :meeting_times, :datetime
      end
    end
  end

  def migrate_down
    ActiveRecord::Base.connection.transaction(requires_new: true) do
      migration_class.migrate(:down)
    end
  end

  def array_query_results(model)
    {
      text_with_null: model.where(tags: ["alpha", nil, "beta"]).order(:name).pluck(:name),
      text_order_sensitive: model.where(tags: ["beta", nil, "alpha"]).order(:name).pluck(:name),
      integer_with_null: model.where(score_ids: [1, nil, 2]).order(:name).pluck(:name),
      integer_empty: model.where(score_ids: []).order(:name).pluck(:name),
      nested_text: model.where(nested_tags: [["north", nil], ["east", "west"]]).order(:name).pluck(:name),
      nullable_text_null: model.where(optional_tags: nil).order(:name).pluck(:name),
      nullable_text_with_null: model.where(optional_tags: ["maybe", nil]).order(:name).pluck(:name),
      timestamp_with_null: model.where(meeting_times: [Time.zone.parse("2025-01-09 12:30:00"), nil]).order(:name).pluck(:name)
    }
  end

  def serialized_rows
    ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT
        name,
        ip_address::text AS ip_address,
        time_offset::text AS time_offset,
        to_jsonb(tags)::text AS tags,
        to_jsonb(score_ids)::text AS score_ids,
        to_jsonb(payloads)::text AS payloads,
        to_jsonb(json_payloads)::text AS json_payloads,
        to_jsonb(nested_tags)::text AS nested_tags,
        to_jsonb(optional_tags)::text AS optional_tags,
        to_jsonb(meeting_times)::text AS meeting_times
      FROM postgresql_migration_records
      ORDER BY name
    SQL
  end

  def row_values(name)
    ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT
        ip_address::text AS ip_address,
        time_offset::text AS time_offset,
        to_jsonb(tags)::text AS tags,
        to_jsonb(score_ids)::text AS score_ids,
        to_jsonb(payloads)::text AS payloads,
        to_jsonb(json_payloads)::text AS json_payloads,
        to_jsonb(nested_tags)::text AS nested_tags,
        to_jsonb(optional_tags)::text AS optional_tags,
        to_jsonb(meeting_times)::text AS meeting_times
      FROM postgresql_migration_records
      WHERE name = #{ActiveRecord::Base.connection.quote(name)}
    SQL
  end

  def payload_element_null?(name, index)
    ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT payloads[#{index}] IS NULL
      FROM postgresql_migration_records
      WHERE name = #{ActiveRecord::Base.connection.quote(name)}
    SQL
  end

  def json_payload_element_null?(name, index)
    ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT json_payloads[#{index}] IS NULL
      FROM postgresql_migration_records
      WHERE name = #{ActiveRecord::Base.connection.quote(name)}
    SQL
  end

  def default_row_values
    {
      "ip_address" => "198.51.100.9/25",
      "time_offset" => "PT15M",
      "tags" => "[]",
      "score_ids" => "[]",
      "payloads" => "[]",
      "json_payloads" => "[]",
      "nested_tags" => "[]",
      "optional_tags" => nil,
      "meeting_times" => "[]"
    }
  end

  def column_data_type(column_name)
    column_metadata(column_name).fetch("data_type")
  end

  def column_user_defined_type(column_name)
    column_metadata(column_name).fetch("udt_name")
  end

  def column_nullable?(column_name)
    column_metadata(column_name).fetch("is_nullable") == "YES"
  end

  def column_metadata(column_name)
    ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT data_type, udt_name, is_nullable
      FROM information_schema.columns
      WHERE table_name = 'postgresql_migration_records'
        AND column_name = #{ActiveRecord::Base.connection.quote(column_name)}
    SQL
  end

  def check_constraint_names
    ActiveRecord::Base.connection.check_constraints("postgresql_migration_records").map(&:name)
  end

  def assert_array_jsonb_schema_unchanged
    %i[tags score_ids payloads json_payloads nested_tags optional_tags meeting_times].each do |column_name|
      assert_equal "jsonb", column_data_type(column_name)
      assert_includes check_constraint_names, "postgresql_migration_records_#{column_name}_array_check"
      refute ActiveRecord::Base.connection.column_exists?(:postgresql_migration_records, "#{column_name}_sqlite_types_tmp")
    end
  end
end
