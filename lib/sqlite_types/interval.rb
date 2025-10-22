# frozen_string_literal: true

module SQLiteTypes
  class Interval < ActiveRecord::Type::Value
    def serialize(value)
      case value
      when ::ActiveSupport::Duration
        value.iso8601(precision: precision)
      when ::Numeric
        ActiveSupport::Duration.build(value).iso8601(precision: precision)
      else
        super
      end
    end

    def type_cast_for_schema(value)
      serialize(value).inspect
    end

    private

    def cast_value(value)
      case value
      when ::ActiveSupport::Duration
        value
      when ::String
        begin
          ::ActiveSupport::Duration.parse(value)
        rescue ::ActiveSupport::Duration::ISO8601Parser::ParsingError
          nil
        end
      else
        super
      end
    end
  end
end
