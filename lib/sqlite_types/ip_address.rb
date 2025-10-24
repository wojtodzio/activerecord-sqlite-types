# frozen_string_literal: true

module SQLiteTypes
  class IpAddress < ActiveRecord::Type::String
    def serialize(value)
      return if value.nil?

      case value
      when ::IPAddr
        "#{value}/#{value.prefix}"
      when ::String
        ip_addr = ::IPAddr.new(value)
        "#{ip_addr}/#{ip_addr.prefix}"
      else
        raise ArgumentError, "Invalid IP address: #{value}"
      end
    end

    private

    def cast_value(value)
      case value
      when ::IPAddr
        value
      when ::String
        ::IPAddr.new(value)
      else
        raise ArgumentError, "Invalid IP address: #{value}"
      end
    end
  end
end
