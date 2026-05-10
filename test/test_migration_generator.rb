# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/sqlite_types/migration/migration_generator"

class TestMigrationGenerator < Rails::Generators::TestCase
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

  def test_rejects_invalid_column_specs_before_generating_ruby
    generator = SQLiteTypes::Generators::MigrationGenerator.new(["prepare_sqlite_types"])

    assert_raises(Rails::Generators::Error) { generator.send(:parse_column_spec, "users") }
    assert_raises(Rails::Generators::Error) { generator.send(:parse_column_spec, "users.current-sign-in-ip") }
    assert_raises(Rails::Generators::Error) { generator.send(:parse_array_spec, "events.tags") }
    assert_raises(Rails::Generators::Error) { generator.send(:parse_array_spec, "events.tags:uuid") }
    assert_raises(Rails::Generators::Error) { generator.send(:parse_array_spec, "events.tags:string:deeply") }
  end

  def test_migration_number_falls_back_to_sequential_numbers_when_timestamps_are_disabled
    generator = SQLiteTypes::Generators::MigrationGenerator

    generator.stub(:timestamped_migrations?, false) do
      generator.stub(:current_migration_number, 7) do
        assert_equal "008", generator.next_migration_number(destination_root)
      end
    end
  end

  def test_timestamped_migration_setting_falls_back_through_rails_configuration_locations
    generator = SQLiteTypes::Generators::MigrationGenerator

    ActiveRecord.stub(:respond_to?, false) do
      ActiveRecord::Base.stub(:respond_to?, true) do
        ActiveRecord::Base.stub(:timestamped_migrations, false) do
          refute generator.timestamped_migrations?
        end
      end
    end

    ActiveRecord.stub(:respond_to?, false) do
      ActiveRecord::Base.stub(:respond_to?, false) do
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
end
