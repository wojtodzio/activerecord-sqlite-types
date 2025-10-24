# frozen_string_literal: true

module SQLiteTypes
  class Array < ActiveRecord::Type::Json
    SUPPORTED_SUBTYPES = %i[integer string hash datetime].freeze

    def initialize(subtype, nested: false)
      raise ArgumentError, "Unsupported subtype: #{subtype}" unless SUPPORTED_SUBTYPES.include?(subtype)

      @subtype = subtype
      @nested = nested
      super()
    end

    def deserialize(value)
      return if value.nil?

      array = parse_to_array(value)

      if @nested
        array.map { |nested_array| parse_to_array(nested_array).map { |element| cast_element(element) } }
      else
        array.map { |element| cast_element(element) }
      end
    end

    def serialize(value)
      raise ArgumentError, "Invalid value: #{value}" if !valid?(value)

      super
    end

    # Use "=" instead of "IN" in WHERE clause, to match PostgreSQL arrays
    def force_equality?(value)
      value.is_a?(::Array)
    end

    private

    def valid?(value)
      return true if value.nil?
      return false if !value.is_a?(::Array)
      return value.all? { |nested_array| nested_array.is_a?(::Array) } if @nested

      true
    end

    def parse_to_array(value)
      case value
      when ::String
        begin
          parsed = ::ActiveSupport::JSON.decode(value)
          parsed.is_a?(::Array) ? parsed : nil
        rescue JSON::ParserError
          nil
        end
      when ::Array
        value
      end
    end

    def cast_element(elem)
      case @subtype
      when :integer
        elem.to_i
      when :string
        elem.to_s
      when :hash
        elem.to_h
      when :datetime
        elem.is_a?(::String) ? ::DateTime.parse(elem).in_time_zone : elem
      else
        raise ArgumentError, "Unsupported subtype: #{@subtype}"
      end
    end
  end
end
