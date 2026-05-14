# frozen_string_literal: true

module SQLiteTypes
  module ArrayColumns
    extend ActiveSupport::Concern

    class_methods do
      def array_columns_sanitize_list(values = [])
        return [] if values.nil?

        values.select(&:present?).map(&:to_s).uniq.sort
      end

      def array_columns(*column_names)
        @array_columns ||= {}

        array_columns_sanitize_list(column_names).each do |column_name|
          @array_columns[column_name] ||= false
        end

        @array_columns.each do |column_name, initialized|
          next if initialized

          define_array_column_methods(column_name)
          @array_columns[column_name] = true
        end
      end

      private

      def define_array_column_methods(column_name)
        method_name = column_name.downcase
        json_each = Arel::Nodes::NamedFunction.new("JSON_EACH", [arel_table[column_name]])

        define_array_column_aggregate_methods(method_name, json_each)
        define_array_column_presence_scopes(method_name, column_name)
        define_array_column_query_scopes(method_name, json_each)
        define_array_column_predicates(method_name, column_name)
        define_array_column_writer(column_name)

        before_validation -> { self[column_name] = self.class.array_columns_sanitize_list(self[column_name]) }
      end

      def define_array_column_aggregate_methods(method_name, json_each)
        define_singleton_method :"unique_#{method_name}" do |_conditions = "true"|
          select("value")
            .from([arel_table, json_each])
            .distinct
            .pluck("value")
            .sort
        end

        define_singleton_method :"#{method_name}_cloud" do |_conditions = "true"|
          select("value")
            .from([arel_table, json_each])
            .group("value")
            .order("value")
            .pluck(Arel.sql("value, COUNT(*) AS count"))
            .to_h
        end
      end

      def define_array_column_presence_scopes(method_name, column_name)
        scope :"with_#{method_name}", -> {
          where.not(arel_table[column_name].eq(nil))
            .where.not(arel_table[column_name].eq([]))
        }

        scope :"without_#{method_name}", -> {
          where(arel_table[column_name].eq(nil))
            .or(where(arel_table[column_name].eq([])))
        }
      end

      def define_array_column_query_scopes(method_name, json_each)
        overlap_query = ->(items) {
          values = array_columns_sanitize_list(items)

          Arel::SelectManager.new(json_each)
            .project(1)
            .where(Arel.sql("CAST(value AS TEXT)").in(values))
            .take(1)
            .exists
        }

        contains_query = ->(items) {
          values = array_columns_sanitize_list(items)
          count = Arel::SelectManager.new(json_each)
            .project(Arel.sql("value").count(true))
            .where(Arel.sql("CAST(value AS TEXT)").in(values))

          Arel::Nodes::Equality.new(count, values.size)
        }

        scope :"with_any_#{method_name}", ->(*items) {
          where overlap_query.call(items)
        }

        scope :"with_all_#{method_name}", ->(*items) {
          where contains_query.call(items)
        }

        scope :"without_any_#{method_name}", ->(*items) {
          where.not overlap_query.call(items)
        }

        scope :"without_all_#{method_name}", ->(*items) {
          where.not contains_query.call(items)
        }
      end

      def define_array_column_writer(column_name)
        define_method :"#{column_name}=" do |value|
          super(self.class.array_columns_sanitize_list(value))
        end
      end

      def define_array_column_predicates(method_name, column_name)
        define_method :"has_any_#{method_name}?" do |*values|
          values = self.class.array_columns_sanitize_list(values)
          existing = self.class.array_columns_sanitize_list(self[column_name])

          (values & existing).present?
        end

        define_method :"has_all_#{method_name}?" do |*values|
          values = self.class.array_columns_sanitize_list(values)
          existing = self.class.array_columns_sanitize_list(self[column_name])

          (values & existing).size == values.size
        end

        alias_method :"has_#{method_name.singularize}?", :"has_all_#{method_name}?"
      end
    end
  end
end
