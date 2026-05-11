# frozen_string_literal: true

require "active_support/core_ext/string/filters"
require "digest"
require_relative "array"

module SQLiteTypes
  module MigrationHelpers
    DEFAULT_NOT_PROVIDED = Object.new.freeze
    POSTGRESQL_IDENTIFIER_LIMIT = 63
    SUPPORTED_ARRAY_SUBTYPES = SQLiteTypes::Array::SUPPORTED_SUBTYPES

    def change_inet_to_string(table_name, column_name, **options)
      require_postgresql_adapter!

      reversible do |dir|
        dir.up do
          change_column table_name, column_name, :string, **options.merge(using: "#{quote_column_name(column_name)}::text")
        end

        dir.down do
          change_column table_name, column_name, :inet, **options.merge(using: "#{quote_column_name(column_name)}::inet")
        end
      end
    end

    def change_interval_to_string(table_name, column_name, **options)
      require_postgresql_adapter!

      reversible do |dir|
        dir.up do
          change_column table_name, column_name, :string, **options.merge(using: "#{quote_column_name(column_name)}::text")
        end

        dir.down do
          change_column table_name, column_name, :interval, **options.merge(using: "#{quote_column_name(column_name)}::interval")
        end
      end
    end

    def change_array_to_json(
      table_name,
      column_name,
      subtype,
      nested: false,
      null: nil,
      default: [],
      constraint_name: nil
    )
      require_postgresql_adapter!

      subtype = normalize_array_subtype(subtype)
      constraint_name ||= default_array_constraint_name(table_name, column_name)
      sqlite_types_array_columns << [table_name, column_name, subtype, nested]

      reversible do |dir|
        dir.up do
          options = {}
          options[:null] = null unless null.nil?

          change_array_default table_name, column_name, from: default, to: nil
          change_column table_name, column_name, :jsonb, **options.merge(using: "to_jsonb(#{quote_column_name(column_name)})")
          change_array_default table_name, column_name, from: nil, to: default
          add_check_constraint table_name, "jsonb_typeof(#{quote_column_name(column_name)}) = 'array'", name: constraint_name
        end

        dir.down do
          validate_registered_postgresql_array_rollbacks!
          remove_check_constraint table_name, name: constraint_name
          restore_postgresql_array_column table_name, column_name, subtype, nested: nested, null: resolved_null(table_name, column_name, null), default: default
        end
      end
    end

    private

    def require_postgresql_adapter!
      return if connection.adapter_name.downcase.include?("postgresql")

      raise ActiveRecord::MigrationError,
        "SQLiteTypes migration helpers must run on PostgreSQL before migrating data to SQLite"
    end

    def normalize_array_subtype(subtype)
      subtype = subtype.to_sym if subtype.respond_to?(:to_sym)
      raise ArgumentError, "Unsupported array subtype: #{subtype}" unless SUPPORTED_ARRAY_SUBTYPES.include?(subtype)

      subtype
    end

    def change_array_default(table_name, column_name, from:, to:)
      return if from.equal?(DEFAULT_NOT_PROVIDED) || to.equal?(DEFAULT_NOT_PROVIDED)
      return if from == to

      change_column_default table_name, column_name, from: from, to: to
    end

    def restore_postgresql_array_column(table_name, column_name, subtype, nested:, null:, default:)
      temporary_column_name = temporary_array_column_name(column_name)

      add_column table_name, temporary_column_name, postgresql_array_subtype(subtype), **postgresql_array_column_options(null: null, default: default)
      execute "UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(temporary_column_name)} = #{postgresql_array_restore_expression(quote_column_name(column_name), subtype, nested)};"
      remove_column table_name, column_name
      rename_column table_name, temporary_column_name, column_name
    end

    def postgresql_array_restore_expression(column_sql, subtype, nested)
      "CASE WHEN #{column_sql} IS NULL THEN NULL ELSE COALESCE((#{postgresql_array_expression(column_sql, subtype, nested)}), '{}') END"
    end

    def postgresql_array_subtype(subtype)
      case subtype
      when :hash
        :jsonb
      else
        subtype
      end
    end

    def postgresql_array_expression(column_sql, subtype, nested)
      if nested
        inner_expression = postgresql_array_expression("sqlite_types_outer.value", subtype, false)
        return "SELECT array_agg((#{inner_expression}) ORDER BY sqlite_types_outer.ordinality) FROM jsonb_array_elements(#{column_sql}) WITH ORDINALITY AS sqlite_types_outer(value, ordinality)"
      end

      case subtype
      when :string, :text
        "SELECT array_agg(sqlite_types_element.value ORDER BY sqlite_types_element.ordinality) FROM jsonb_array_elements_text(#{column_sql}) WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
      when :integer
        "SELECT array_agg(sqlite_types_element.value::int ORDER BY sqlite_types_element.ordinality) FROM jsonb_array_elements_text(#{column_sql}) WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
      when :datetime
        "SELECT array_agg(sqlite_types_element.value::timestamp ORDER BY sqlite_types_element.ordinality) FROM jsonb_array_elements_text(#{column_sql}) WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
      when :json
        "SELECT array_agg(CASE WHEN jsonb_typeof(sqlite_types_element.value) = 'null' THEN NULL ELSE sqlite_types_element.value::json END ORDER BY sqlite_types_element.ordinality) FROM jsonb_array_elements(#{column_sql}) WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
      when :hash, :jsonb
        "SELECT array_agg(CASE WHEN jsonb_typeof(sqlite_types_element.value) = 'null' THEN NULL ELSE sqlite_types_element.value END ORDER BY sqlite_types_element.ordinality) FROM jsonb_array_elements(#{column_sql}) WITH ORDINALITY AS sqlite_types_element(value, ordinality)"
      else
        raise ArgumentError, "Unsupported array subtype: #{subtype}"
      end
    end

    def validate_postgresql_nested_array_shape!(table_name, column_name)
      column_sql = "sqlite_types_row.#{quote_column_name(column_name)}"
      invalid_row = select_value "SELECT 1 FROM #{quote_table_name(table_name)} AS sqlite_types_row WHERE #{column_sql} IS NOT NULL AND (jsonb_typeof(#{column_sql}) <> 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(#{column_sql}) AS sqlite_types_outer(value) WHERE CASE WHEN jsonb_typeof(sqlite_types_outer.value) <> 'array' THEN true ELSE jsonb_array_length(sqlite_types_outer.value) = 0 END) OR (SELECT COUNT(DISTINCT jsonb_array_length(sqlite_types_outer.value)) FROM jsonb_array_elements(#{column_sql}) AS sqlite_types_outer(value) WHERE jsonb_typeof(sqlite_types_outer.value) = 'array') > 1) LIMIT 1"

      return unless invalid_row

      raise ActiveRecord::IrreversibleMigration,
        "Cannot restore #{table_name}.#{column_name} to a PostgreSQL multidimensional array; nested JSON arrays must be rectangular and inner arrays must be non-empty"
    end

    def validate_postgresql_array_elements!(table_name, column_name, subtype, nested:)
      column_sql = "sqlite_types_row.#{quote_column_name(column_name)}"
      invalid_condition = postgresql_invalid_array_element_condition("sqlite_types_element.value", subtype)
      invalid_row = if nested
        select_value "SELECT 1 FROM #{quote_table_name(table_name)} AS sqlite_types_row WHERE #{column_sql} IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(#{column_sql}) AS sqlite_types_outer(value) WHERE jsonb_typeof(sqlite_types_outer.value) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(sqlite_types_outer.value) AS sqlite_types_element(value) WHERE #{invalid_condition})) LIMIT 1"
      else
        select_value "SELECT 1 FROM #{quote_table_name(table_name)} AS sqlite_types_row WHERE #{column_sql} IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(#{column_sql}) AS sqlite_types_element(value) WHERE #{invalid_condition}) LIMIT 1"
      end

      return unless invalid_row

      raise ActiveRecord::IrreversibleMigration,
        "Cannot restore #{table_name}.#{column_name} to a PostgreSQL #{subtype} array; JSON elements are not compatible with the target array subtype"
    end

    def postgresql_invalid_array_element_condition(element_sql, subtype)
      type_sql = "jsonb_typeof(#{element_sql})"

      case subtype
      when :string, :text
        "false"
      when :datetime
        "#{type_sql} NOT IN ('string', 'null')"
      when :integer
        "CASE WHEN #{type_sql} = 'null' THEN false WHEN #{type_sql} IN ('number', 'string') THEN (#{element_sql} #>> '{}') !~ '^[+-]?[0-9]+$' ELSE true END"
      when :hash, :json, :jsonb
        "false"
      else
        raise ArgumentError, "Unsupported array subtype: #{subtype}"
      end
    end

    def validate_registered_postgresql_array_rollbacks!
      return if @sqlite_types_array_rollbacks_validated

      lock_registered_postgresql_array_tables!

      sqlite_types_array_columns.each do |table_name, column_name, subtype, nested|
        validate_postgresql_array_shape!(table_name, column_name, subtype)
        validate_postgresql_nested_array_shape!(table_name, column_name) if nested
        validate_postgresql_array_elements!(table_name, column_name, subtype, nested: nested)
        validate_postgresql_array_restore_cast!(table_name, column_name, subtype, nested: nested)
      end

      @sqlite_types_array_rollbacks_validated = true
    end

    def lock_registered_postgresql_array_tables!
      return if connection.respond_to?(:transaction_open?) && !connection.transaction_open?

      sqlite_types_array_columns.map(&:first).uniq.each do |table_name|
        execute "LOCK TABLE #{quote_table_name(table_name)} IN SHARE ROW EXCLUSIVE MODE"
      end
    end

    def validate_postgresql_array_shape!(table_name, column_name, subtype)
      column_sql = "sqlite_types_row.#{quote_column_name(column_name)}"
      invalid_row = select_value "SELECT 1 FROM #{quote_table_name(table_name)} AS sqlite_types_row WHERE #{column_sql} IS NOT NULL AND jsonb_typeof(#{column_sql}) <> 'array' LIMIT 1"

      return unless invalid_row

      raise ActiveRecord::IrreversibleMigration,
        "Cannot restore #{table_name}.#{column_name} to a PostgreSQL #{subtype} array; JSON value is not an array"
    end

    def validate_postgresql_array_restore_cast!(table_name, column_name, subtype, nested:)
      column_sql = "sqlite_types_row.#{quote_column_name(column_name)}"
      select_value "SELECT COUNT(*) FROM #{quote_table_name(table_name)} AS sqlite_types_row WHERE #{column_sql} IS NOT NULL AND (#{postgresql_array_restore_expression(column_sql, subtype, nested)}) IS NOT NULL"
    rescue ActiveRecord::StatementInvalid => error
      raise ActiveRecord::IrreversibleMigration,
        "Cannot restore #{table_name}.#{column_name} to a PostgreSQL #{subtype} array; PostgreSQL rejected the rollback cast: #{error.message.lines.first&.strip}"
    end

    def sqlite_types_array_columns
      @sqlite_types_array_columns ||= []
    end

    def postgresql_array_column_options(null:, default:)
      options = {array: true}
      options[:null] = null unless null.nil?
      return options if default.equal?(DEFAULT_NOT_PROVIDED)

      options.merge(default: default)
    end

    def resolved_null(table_name, column_name, null)
      return null unless null.nil?
      return unless connection.respond_to?(:columns)

      connection.columns(table_name).find { |column| column.name == column_name.to_s }&.null
    end

    def default_array_constraint_name(table_name, column_name)
      truncate_identifier("#{table_name}_#{column_name}_array_check")
    end

    def temporary_array_column_name(column_name)
      truncate_identifier("#{column_name}_sqlite_types_tmp")
    end

    def truncate_identifier(identifier)
      identifier = identifier.to_s
      return identifier if identifier.length <= POSTGRESQL_IDENTIFIER_LIMIT

      digest = Digest::SHA256.hexdigest(identifier)[0, 10]
      "#{identifier[0, POSTGRESQL_IDENTIFIER_LIMIT - digest.length - 1]}_#{digest}"
    end
  end
end
