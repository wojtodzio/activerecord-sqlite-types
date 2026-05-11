# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "sqlite_types/migration_helpers"

module SQLiteTypes
  module Generators
    class MigrationGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      IDENTIFIER_PATTERN = /\A[a-zA-Z_]\w*\z/
      ARRAY_MODIFIERS = %w[nested].freeze

      namespace "sqlite_types:migration"
      source_root File.expand_path("templates", __dir__)

      class_option :inet,
        type: :array,
        default: [],
        banner: "table.column",
        desc: "inet columns to migrate to string"
      class_option :interval,
        type: :array,
        default: [],
        banner: "table.column",
        desc: "interval columns to migrate to string"
      class_option :array,
        type: :array,
        default: [],
        banner: "table.column:subtype[:nested]",
        desc: "PostgreSQL array columns to migrate to json/jsonb"

      def self.next_migration_number(dirname)
        if timestamped_migrations?
          Time.now.utc.strftime("%Y%m%d%H%M%S")
        else
          "%.3d" % (current_migration_number(dirname) + 1)
        end
      end

      def self.timestamped_migrations?
        return ActiveRecord.timestamped_migrations if ActiveRecord.respond_to?(:timestamped_migrations)
        return ActiveRecord::Base.timestamped_migrations if ActiveRecord::Base.respond_to?(:timestamped_migrations)

        true
      end

      def create_migration_file
        validate_column_options!

        migration_template "migration.rb.tt", "db/migrate/#{file_name}.rb"
      end

      private

      def validate_column_options!
        return if inet_columns.any? || interval_columns.any? || array_columns.any?

        raise Rails::Generators::Error, "Provide at least one --inet, --interval, or --array column"
      end

      def migration_version
        ActiveRecord::Migration.current_version
      end

      def inet_columns
        @inet_columns ||= Array(options[:inet]).map { |spec| parse_column_spec(spec) }
      end

      def interval_columns
        @interval_columns ||= Array(options[:interval]).map { |spec| parse_column_spec(spec) }
      end

      def array_columns
        @array_columns ||= Array(options[:array]).map { |spec| parse_array_spec(spec) }
      end

      def parse_column_spec(spec)
        table_name, column_name = spec.to_s.split(".", 2)
        raise Rails::Generators::Error, "Expected column as table.column, got #{spec.inspect}" if table_name.empty? || column_name.to_s.empty?
        validate_identifier! table_name, "table"
        validate_identifier! column_name, "column"

        ColumnSpec.new(table_name: table_name, column_name: column_name)
      end

      def parse_array_spec(spec)
        column_spec, subtype, *modifiers = spec.to_s.split(":")
        raise Rails::Generators::Error, "Expected array column as table.column:subtype, got #{spec.inspect}" if subtype.to_s.empty?
        validate_array_subtype! subtype
        validate_array_modifiers! modifiers

        column = parse_column_spec(column_spec)
        ArraySpec.new(
          table_name: column.table_name,
          column_name: column.column_name,
          subtype: subtype,
          nested: modifiers.include?("nested")
        )
      end

      def validate_identifier!(value, label)
        return if value.match?(IDENTIFIER_PATTERN)

        raise Rails::Generators::Error, "Invalid #{label} identifier: #{value.inspect}"
      end

      def validate_array_subtype!(subtype)
        return if SQLiteTypes::MigrationHelpers::SUPPORTED_ARRAY_SUBTYPES.include?(subtype.to_sym)

        raise Rails::Generators::Error, "Unsupported array subtype: #{subtype.inspect}"
      end

      def validate_array_modifiers!(modifiers)
        unknown_modifiers = modifiers - ARRAY_MODIFIERS
        return if unknown_modifiers.empty?

        raise Rails::Generators::Error, "Unsupported array modifier: #{unknown_modifiers.first.inspect}"
      end

      ColumnSpec = Struct.new(:table_name, :column_name, keyword_init: true)
      ArraySpec = Struct.new(:table_name, :column_name, :subtype, :nested, keyword_init: true)
    end
  end
end
