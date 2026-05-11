# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/sqlite_types/migration/migration_generator"

class TestMigrationGenerator < Rails::Generators::TestCase
  cover "SQLiteTypes::Generators::MigrationGenerator*"

  tests SQLiteTypes::Generators::MigrationGenerator
  destination File.expand_path("../tmp/generators", __dir__)

  setup :prepare_destination
  teardown { FileUtils.rm_rf(destination_root) }

  def test_generator_is_discoverable_through_the_documented_rails_namespace
    assert_equal SQLiteTypes::Generators::MigrationGenerator,
      Rails::Generators.find_by_namespace("sqlite_types:migration")
  end

  def test_generates_a_reversible_type_preparation_migration
    run_generator [
      "prepare_sqlite_types",
      "--inet", "users.current_sign_in_ip", "users.last_sign_in_ip",
      "--interval", "timings.time_offset",
      "--array", "events.relationship_statuses:string", "event_classes.summary_points:text:nested", "email_notification_logs.attachments:hash"
    ]

    migration_path = generated_migration_path
    assert_file migration_path
    migration = File.read(migration_path)

    assert_includes migration, "require \"sqlite_types/migration_helpers\""
    assert_includes migration, "class PrepareSqliteTypes < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]"
    assert_includes migration, "change_inet_to_string :users, :current_sign_in_ip"
    assert_includes migration, "change_inet_to_string :users, :last_sign_in_ip"
    assert_includes migration, "change_interval_to_string :timings, :time_offset"
    assert_includes migration, "change_array_to_json :events, :relationship_statuses, :string"
    refute_includes migration, "change_array_to_json :events, :relationship_statuses, :string, nested: true"
    assert_includes migration, "change_array_to_json :event_classes, :summary_points, :text, nested: true"
    assert_includes migration, "change_array_to_json :email_notification_logs, :attachments, :hash"
  end

  def test_requires_at_least_one_column
    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])

    error = assert_raises(Rails::Generators::Error) do
      generator.send(:validate_column_options!)
    end

    assert_includes error.message, "Provide at least one"
  end

  def test_each_column_option_satisfies_required_column_options
    [
      {inet: ["users.current_sign_in_ip"], interval: [], array: []},
      {inet: [], interval: ["timings.time_offset"], array: []},
      {inet: [], interval: [], array: ["events.tags:string"]}
    ].each do |options|
      generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])

      generator.stub(:options, options) do
        assert_nil generator.send(:validate_column_options!)
      end
    end
  end

  def test_create_migration_file_rejects_no_column_options_before_writing_migration
    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])

    error = assert_raises(Rails::Generators::Error) do
      generator.stub(:migration_template, ->(*) { flunk "migration_template should not be called" }) do
        generator.create_migration_file
      end
    end

    assert_includes error.message, "Provide at least one"
  end

  def test_rejects_invalid_column_specs_before_generating_ruby
    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_column_spec, "users") }
    assert_includes error.message, "Expected column as table.column"
    assert_includes error.message, "\"users\""

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_column_spec, ".current_sign_in_ip") }
    assert_includes error.message, "Expected column as table.column"
    assert_includes error.message, "\".current_sign_in_ip\""

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_column_spec, "bad-table.current_sign_in_ip") }
    assert_includes error.message, "Invalid table identifier"
    assert_includes error.message, "\"bad-table\""

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_column_spec, "users.current-sign-in-ip") }
    assert_includes error.message, "Invalid column identifier"
    assert_includes error.message, "\"current-sign-in-ip\""

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_array_spec, "events.tags") }
    assert_includes error.message, "Expected array column as table.column:subtype"
    assert_includes error.message, "\"events.tags\""

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_array_spec, "events.tags:uuid") }
    assert_includes error.message, "Unsupported array subtype"
    assert_includes error.message, "\"uuid\""

    error = assert_raises(Rails::Generators::Error) { generator.send(:parse_array_spec, "events.tags:string:deeply:widely") }
    assert_equal 'Unsupported array modifier: "deeply"', error.message
  end

  def test_array_subtype_validation_uses_runtime_migration_helpers_namespace
    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])
    shadow_helpers = Module.new do
      const_set :SUPPORTED_ARRAY_SUBTYPES, []
    end

    with_shadowed_generator_constant(:MigrationHelpers, shadow_helpers) do
      spec = generator.send(:parse_array_spec, "events.tags:string")

      assert_equal "string", spec.subtype
    end
  end

  def test_column_option_helpers_treat_nil_options_as_empty
    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])

    generator.stub(:options, {inet: nil, interval: nil, array: nil}) do
      assert_empty generator.send(:inet_columns)
      assert_empty generator.send(:interval_columns)
      assert_empty generator.send(:array_columns)
    end

    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])
    generator.stub(:options, {}) do
      assert_empty generator.send(:inet_columns)
      assert_empty generator.send(:interval_columns)
      assert_empty generator.send(:array_columns)
    end
  end

  def test_migration_number_falls_back_to_sequential_numbers_when_timestamps_are_disabled
    generator = SQLiteTypes::Generators::MigrationGenerator

    generator.stub(:timestamped_migrations?, false) do
      generator.stub(:current_migration_number, ->(dirname) {
        assert_equal destination_root, dirname
        7
      }) do
        assert_equal "008", generator.next_migration_number(destination_root)
      end
    end
  end

  def test_migration_number_uses_utc_timestamp_when_timestamps_are_enabled
    generator = SQLiteTypes::Generators::MigrationGenerator

    generator.stub(:timestamped_migrations?, true) do
      Time.stub(:now, Time.new(2025, 1, 9, 13, 30, 45, "+01:00")) do
        assert_equal "20250109123045", generator.next_migration_number(destination_root)
      end
    end
  end

  def test_timestamped_migration_setting_falls_back_through_rails_configuration_locations
    generator = SQLiteTypes::Generators::MigrationGenerator

    ActiveRecord.stub(:respond_to?, ->(method_name, *) { method_name == :timestamped_migrations }) do
      ActiveRecord.stub(:timestamped_migrations, false) do
        refute generator.timestamped_migrations?
      end

      ActiveRecord.stub(:timestamped_migrations, true) do
        assert generator.timestamped_migrations?
      end
    end

    ActiveRecord.stub(:respond_to?, false) do
      ActiveRecord::Base.stub(:respond_to?, ->(method_name, *) { method_name == :timestamped_migrations }) do
        ActiveRecord::Base.stub(:timestamped_migrations, false) do
          refute generator.timestamped_migrations?
        end

        ActiveRecord::Base.stub(:timestamped_migrations, true) do
          assert generator.timestamped_migrations?
        end
      end
    end

    ActiveRecord.stub(:respond_to?, false) do
      ActiveRecord::Base.stub(:respond_to?, ->(method_name, *) {
        assert_equal :timestamped_migrations, method_name
        false
      }) do
        assert generator.timestamped_migrations?
      end
    end
  end

  def test_gemspec_packages_generator_and_runtime_files_without_local_environment_files
    spec = Gem::Specification.load(File.expand_path("../activerecord-sqlite-types.gemspec", __dir__))

    assert_includes spec.files, "lib/sqlite_types.rb"
    assert_includes spec.files, "lib/sqlite_types/migration_helpers.rb"
    assert_includes spec.files, "lib/generators/sqlite_types/migration/migration_generator.rb"
    assert_includes spec.files, "lib/generators/sqlite_types/migration/templates/migration.rb.tt"
    refute_includes spec.files, ".envrc"
    refute_includes spec.files, "devenv.nix"
    refute_includes spec.files, "devenv.lock"
    refute_includes spec.files, "Rakefile"
  end

  private

  def generated_migration_path
    Dir[File.join(destination_root, "db/migrate/*_prepare_sqlite_types.rb")].first
  end

  def with_shadowed_generator_constant(name, value)
    container = SQLiteTypes::Generators
    previously_defined = container.const_defined?(name, false)
    previous_value = container.const_get(name, false) if previously_defined

    container.__send__(:remove_const, name) if previously_defined
    container.const_set(name, value)
    yield
  ensure
    container.__send__(:remove_const, name) if container.const_defined?(name, false)
    container.const_set(name, previous_value) if previously_defined
  end
end
