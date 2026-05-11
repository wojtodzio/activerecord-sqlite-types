# frozen_string_literal: true

require "date"

module SQLiteTypes
  class Array < ActiveRecord::Type::Json
    SUPPORTED_SUBTYPES = %i[integer string text hash json jsonb datetime].freeze
    POSTGRESQL_TIMESTAMP_JSON_FORMAT = "%Y-%m-%dT%H:%M:%S.%6N"

    def initialize(subtype, nested: false)
      subtype = subtype.to_sym if subtype.respond_to?(:to_sym)
      raise ArgumentError, "Unsupported subtype: #{subtype}" unless SUPPORTED_SUBTYPES.include?(subtype)

      @subtype = subtype
      @nested = nested
      super()
    end

    def deserialize(value)
      return if value.nil?

      array = parse_array(value)

      if @nested
        array.map do |nested_array|
          parse_array(nested_array, nested: true).map { |element| cast_element(element) }
        end
      else
        array.map { |element| cast_element(element) }
      end
    end

    def serialize(value)
      return super if value.nil?

      # Normalize through the same cast path as reads so persisted values and equality queries
      # use one canonical JSON representation for the declared subtype.
      array = deserialize(value)
      array = serialize_datetime_array(array) if @subtype == :datetime
      super(array)
    end

    # Use "=" instead of "IN" in WHERE clause, to match PostgreSQL arrays
    def force_equality?(value)
      value.is_a?(::Array)
    end

    private

    def parse_array(value, nested: false)
      array = case value
      when ::String
        begin
          parsed = ::ActiveSupport::JSON.decode(value)
          parsed if parsed.instance_of?(::Array)
        rescue JSON::ParserError
          nil
        end
      when ::Array
        value
      end

      return array if array

      description = nested ? "nested array" : "array"
      raise ArgumentError, "Invalid #{description} value: #{value.inspect}"
    end

    def cast_element(elem)
      raise ArgumentError, "Invalid #{@subtype} array element: #{elem.inspect}" unless storable_element?(elem)

      case @subtype
      when :integer
        integer_string?(elem) ? cast_integer_element(elem) : elem
      when :string, :text
        elem
      when :hash
        elem.is_a?(::Hash) ? elem.to_h : elem
      when :json, :jsonb
        elem
      when :datetime
        cast_datetime_element(elem)
      else
        raise ArgumentError, "Unsupported subtype: #{@subtype}"
      end
    end

    def storable_element?(elem)
      return true if @subtype == :datetime && datetime_like?(elem)

      json_compatible?(elem)
    end

    def datetime_like?(value)
      value.acts_like?(:time) || value.is_a?(::Date)
    end

    def integer_string?(value)
      value.is_a?(::String) && value.match?(/\A[+-]?\d+\z/)
    end

    def cast_integer_element(value)
      Integer(value, 10)
    end

    def cast_datetime_element(value)
      return value.respond_to?(:in_time_zone) ? value.in_time_zone : value if datetime_like?(value)
      return value unless value.is_a?(::String)

      parse_datetime(value)&.in_time_zone || value
    end

    def parse_datetime(value)
      ::DateTime.parse(value)
    rescue ArgumentError
      nil
    end

    def serialize_datetime_array(array)
      if @nested
        array.map { |nested_array| nested_array.map { |element| serialize_datetime_element(element) } }
      else
        array.map { |element| serialize_datetime_element(element) }
      end
    end

    def serialize_datetime_element(element)
      return element unless element.acts_like?(:time)

      postgresql_timestamp_json(element)
    end

    def postgresql_timestamp_json(element)
      # PostgreSQL to_jsonb(timestamp[]) emits timestamp text without a time-zone suffix,
      # and omits the fractional part when it is zero.
      element.to_time.utc.strftime(POSTGRESQL_TIMESTAMP_JSON_FORMAT).sub(/(\.\d*?)0+\z/, "\\1").delete_suffix(".")
    end

    def json_compatible?(value)
      case value
      when nil, true, false, ::String, ::Integer
        true
      when ::Float
        value.finite?
      when ::Array
        value.all? { |element| json_compatible?(element) }
      when ::Hash
        value.all? do |key, element|
          (key.is_a?(::String) || key.instance_of?(::Symbol)) && json_compatible?(element)
        end
      end
    end
  end
end
