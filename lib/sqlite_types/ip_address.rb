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

    def changed?(old_value, new_value, _new_value_before_type_cast)
      !serialize(old_value).eql?(serialize(new_value))
    end

    def changed_in_place?(raw_old_value, new_value)
      !serialize_raw_value(raw_old_value).eql?(serialize(new_value))
    rescue ArgumentError
      true
    end

    private

    def serialize_raw_value(value)
      return if value.nil?

      serialize(cast_value(value))
    end

    def cast_value(value)
      case value
      when ::IPAddr
        value
      when ::String
        begin
          ::IPAddr.new(value)
        rescue ::IPAddr::InvalidAddressError
          # Rails' PostgreSQL inet type casts invalid string assignments to nil;
          # serialization still raises for invalid query and persistence values.
          nil
        end
      else
        raise ArgumentError, "Invalid IP address: #{value}"
      end
    end
  end
end
