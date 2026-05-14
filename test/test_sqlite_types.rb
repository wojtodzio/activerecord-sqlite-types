# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

class SqliteTypeRecord < ActiveRecord::Base
  self.table_name = "type_records"

  attribute :ip_address, SQLiteTypes::IpAddress.new
  attribute :time_offset, SQLiteTypes::Interval.new
  attribute :string_tags, SQLiteTypes::Array.new(:string)
  attribute :score_ids, SQLiteTypes::Array.new(:integer)
  attribute :metadata_items, SQLiteTypes::Array.new(:hash)
  attribute :meeting_times, SQLiteTypes::Array.new(:datetime)
  attribute :nested_tags, SQLiteTypes::Array.new(:string, nested: true)
end

class TestSqliteTypes < Minitest::Test
  cover "SQLiteTypes::Array*"
  cover "SQLiteTypes::Interval*"
  cover "SQLiteTypes::IpAddress*"

  include DatabaseTestHelpers

  def setup
    super

    ActiveRecord::Schema.define do
      create_table :type_records, force: true do |t|
        t.string :name
        t.string :ip_address
        t.string :time_offset
        t.json :string_tags, default: [], null: false
        t.json :score_ids, default: [], null: false
        t.json :metadata_items, default: [], null: false
        t.json :meeting_times, default: [], null: false
        t.json :nested_tags, default: [], null: false
        t.index :ip_address, unique: true
      end
    end
  end

  def test_that_it_has_a_version_number
    refute_nil ::SQLiteTypes::VERSION
  end

  def test_round_trips_values_through_active_record_and_sqlite_storage
    meeting_time = Time.zone.parse("2025-01-09 12:30:00")

    record = SqliteTypeRecord.create!(
      name: "Ada",
      ip_address: "192.0.2.15",
      time_offset: 90.minutes,
      string_tags: ["leader", "runner"],
      score_ids: [1, "2"],
      metadata_items: [{"kind" => "event", "id" => 12}],
      meeting_times: [meeting_time],
      nested_tags: [["first", "second"], ["third"]]
    )

    reloaded = SqliteTypeRecord.find(record.id)
    raw = raw_row("type_records", record.id)

    assert_instance_of IPAddr, reloaded.ip_address
    assert_equal "192.0.2.15", reloaded.ip_address.to_s
    assert_equal "192.0.2.15/32", raw.fetch("ip_address")

    assert_instance_of ActiveSupport::Duration, reloaded.time_offset
    assert_equal "PT1H30M", raw.fetch("time_offset")
    assert_equal "PT1H30M", SQLiteTypes::Interval.new.serialize(reloaded.time_offset)

    assert_equal ["leader", "runner"], reloaded.string_tags
    assert_equal [1, 2], reloaded.score_ids
    assert_equal [{"kind" => "event", "id" => 12}], reloaded.metadata_items
    assert_equal [meeting_time.to_i], reloaded.meeting_times.map(&:to_i)
    assert_equal [["first", "second"], ["third"]], reloaded.nested_tags
    assert_equal "[\"leader\",\"runner\"]", raw.fetch("string_tags")
    assert_equal "[\"2025-01-09T12:30:00\"]", raw.fetch("meeting_times")
  end

  def test_active_record_queries_and_commands_use_the_custom_types
    meeting_time = Time.zone.parse("2025-01-09 12:30:00")
    matching = SqliteTypeRecord.create!(
      name: "Matching",
      ip_address: IPAddr.new("203.0.113.4"),
      time_offset: 15.minutes,
      string_tags: ["vip", "alpha"],
      score_ids: [1, 2],
      metadata_items: [],
      meeting_times: [meeting_time],
      nested_tags: []
    )
    SqliteTypeRecord.create!(
      name: "Other",
      ip_address: "203.0.113.5",
      time_offset: 30.minutes,
      string_tags: ["vip"],
      score_ids: [3],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )

    assert_equal matching.id, SqliteTypeRecord.find_by(ip_address: IPAddr.new("203.0.113.4")).id
    assert_equal matching.id, SqliteTypeRecord.find_by(ip_address: "203.0.113.4").id
    assert_equal matching.id, SqliteTypeRecord.find_by(time_offset: 15.minutes).id
    assert_equal [matching.id], SqliteTypeRecord.where(string_tags: ["vip", "alpha"]).pluck(:id)
    assert_equal [matching.id], SqliteTypeRecord.where(score_ids: ["1", "2"]).pluck(:id)
    assert_equal [matching.id], SqliteTypeRecord.where(meeting_times: [meeting_time]).pluck(:id)
    assert_equal [matching.id], SqliteTypeRecord.where(ip_address: ["203.0.113.4"]).pluck(:id)
    assert_equal [matching.id], SqliteTypeRecord.where(ip_address: ["203.0.113.4/32"]).pluck(:id)
    assert_empty SqliteTypeRecord.where(string_tags: ["alpha", "vip"])

    matching.update!(score_ids: ["4", "5"], time_offset: "PT45M")
    assert_equal [4, 5], matching.reload.score_ids
    assert_equal "PT45M", SQLiteTypes::Interval.new.serialize(matching.time_offset)

    matching.destroy!
    assert_equal ["Other"], SqliteTypeRecord.order(:name).pluck(:name)
  end

  def test_ip_address_supports_create_or_find_by_with_unique_indexes
    first = SqliteTypeRecord.create_or_find_by!(
      ip_address: IPAddr.new("203.0.113.4"),
      string_tags: [],
      score_ids: [],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )

    second = SqliteTypeRecord.create_or_find_by!(
      ip_address: IPAddr.new("203.0.113.4"),
      string_tags: [],
      score_ids: [],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )

    assert_equal first.id, second.id
    assert_equal "203.0.113.4/32", raw_row("type_records", first.id).fetch("ip_address")
  end

  def test_ip_address_active_record_lookup_helpers_canonicalize_string_values
    first = SqliteTypeRecord.create_or_find_by!(
      ip_address: IPAddr.new("203.0.113.4"),
      string_tags: [],
      score_ids: [],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )

    second = SqliteTypeRecord.create_or_find_by!(
      ip_address: "203.0.113.4",
      string_tags: [],
      score_ids: [],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )
    third = SqliteTypeRecord.find_or_create_by!(ip_address: "203.0.113.4")

    assert_equal first.id, second.id
    assert_equal first.id, third.id
    assert_equal "203.0.113.4/32", raw_row("type_records", first.id).fetch("ip_address")
  end

  def test_ip_address_cast_values_use_the_same_serialization_as_ipaddr_values
    type = SQLiteTypes::IpAddress.new

    assert_equal "192.0.2.1/32", type.serialize("192.0.2.1")
    assert_equal "192.0.2.15/24", type.serialize("192.0.2.15/24")
    assert_equal "192.0.2.0/24", type.serialize_cast_value(type.cast("192.0.2.15/24"))
  end

  def test_array_dirty_tracking_uses_cast_values_and_detects_in_place_mutation
    record = SqliteTypeRecord.create!(
      name: "Arrays",
      string_tags: ["alpha"],
      score_ids: [1],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    ).reload

    record.score_ids = ["1"]
    refute record.score_ids_changed?

    record.string_tags << "beta"
    assert record.string_tags_changed?

    record.save!
    assert_equal "[\"alpha\",\"beta\"]", raw_row("type_records", record.id).fetch("string_tags")
  end

  def test_array_types_preserve_null_elements
    meeting_time = Time.zone.parse("2025-01-09 12:30:00")

    record = SqliteTypeRecord.create!(
      name: "Null elements",
      string_tags: ["alpha", nil, "beta"],
      score_ids: [1, nil, "2"],
      metadata_items: [{"kind" => "event"}, nil],
      meeting_times: [meeting_time, nil],
      nested_tags: [["north", nil], ["east", "west"]]
    )

    reloaded = SqliteTypeRecord.find(record.id)
    raw = raw_row("type_records", record.id)

    assert_equal ["alpha", nil, "beta"], reloaded.string_tags
    assert_equal [1, nil, 2], reloaded.score_ids
    assert_equal [{"kind" => "event"}, nil], reloaded.metadata_items
    assert_equal [meeting_time.to_i, nil], reloaded.meeting_times.map { |value| value&.to_i }
    assert_equal [["north", nil], ["east", "west"]], reloaded.nested_tags
    assert_equal "[\"alpha\",null,\"beta\"]", raw.fetch("string_tags")
    assert_equal "[1,null,2]", raw.fetch("score_ids")
  end

  def test_array_types_persist_broader_json_values_after_migration
    record = SqliteTypeRecord.create!(
      name: "Broader arrays",
      string_tags: [1, true, {"source" => "json"}],
      score_ids: [1, "not-an-integer", 1.5, true, {"kind" => "broader"}],
      metadata_items: ["not-a-hash", {"kind" => "event"}],
      meeting_times: ["not-a-date", "2025-01-09T12:30:00Z"],
      nested_tags: [[1, true], [{"source" => "nested"}]]
    )

    reloaded = SqliteTypeRecord.find(record.id)

    assert_equal [1, true, {"source" => "json"}], reloaded.string_tags
    assert_equal [1, "not-an-integer", 1.5, true, {"kind" => "broader"}], reloaded.score_ids
    assert_equal ["not-a-hash", {"kind" => "event"}], reloaded.metadata_items
    assert_equal "not-a-date", reloaded.meeting_times.first
    assert_equal Time.zone.parse("2025-01-09T12:30:00Z").to_i, reloaded.meeting_times.second.to_i
    assert_equal [[1, true], [{"source" => "nested"}]], reloaded.nested_tags
  end

  def test_array_types_serialize_rails_assignment_values_before_validation
    metadata_item = Struct.new(:uid, :name, keyword_init: true).new(uid: "abc", name: "Variable")

    record = SqliteTypeRecord.create!(
      name: "Assignment values",
      string_tags: [:single, "married"],
      score_ids: [],
      metadata_items: [metadata_item],
      meeting_times: [],
      nested_tags: [[:first, :second]]
    )

    reloaded = SqliteTypeRecord.find(record.id)
    raw = raw_row("type_records", record.id)

    assert_equal ["single", "married"], reloaded.string_tags
    assert_equal [{"uid" => "abc", "name" => "Variable"}], reloaded.metadata_items
    assert_equal [["first", "second"]], reloaded.nested_tags
    assert_equal "[\"single\",\"married\"]", raw.fetch("string_tags")
    assert_equal "[{\"uid\":\"abc\",\"name\":\"Variable\"}]", raw.fetch("metadata_items")
  end

  def test_ip_address_matches_rails_postgresql_inet_casting
    type = SQLiteTypes::IpAddress.new
    record = SqliteTypeRecord.create!(
      name: "CIDR",
      ip_address: "192.0.2.15/24",
      string_tags: [],
      score_ids: [],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )

    assert_equal "192.0.2.0/24", raw_row("type_records", record.id).fetch("ip_address")
    assert_instance_of IPAddr, record.ip_address
    assert_equal "192.0.2.0", record.ip_address.to_s
    assert_equal "192.0.2.0/24", type.serialize(record.ip_address)

    reloaded = SqliteTypeRecord.find(record.id)
    assert_instance_of IPAddr, reloaded.ip_address
    assert_equal "192.0.2.0/24", type.serialize(reloaded.ip_address)
    assert_equal record.id, SqliteTypeRecord.find_by(ip_address: "192.0.2.0/24").id

    ipv6 = type.cast("2001:db8::1/64")
    assert_instance_of IPAddr, ipv6
    assert_equal "2001:db8::/64", type.serialize(ipv6)
    assert_nil type.cast("")
    assert_nil type.cast("not-an-ip")
    assert_raises(ArgumentError) { type.serialize("not-an-ip") }

    invalid_value = Object.new
    def invalid_value.to_s
      "invalid ip object"
    end

    error = assert_raises(ArgumentError) { type.cast(invalid_value) }
    assert_equal "Invalid IP address: invalid ip object", error.message
    error = assert_raises(ArgumentError) { type.serialize(invalid_value) }
    assert_equal "Invalid IP address: invalid ip object", error.message
  end

  def test_ip_address_type_uses_top_level_ipaddr_and_string_namespaces
    type = SQLiteTypes::IpAddress.new
    address = IPAddr.new("192.0.2.1")

    with_shadowed_sqlite_types_constant(:IPAddr, Class.new) do
      assert_same address, type.cast(address)
      assert_equal "192.0.2.1", type.cast("192.0.2.1").to_s
      assert_equal "192.0.2.1/32", type.serialize(address)
      assert_equal "192.0.2.1/32", type.serialize("192.0.2.1")
      assert_equal "192.0.2.15/24", type.serialize("192.0.2.15/24")
    end

    with_shadowed_sqlite_types_constant(:String, Class.new) do
      assert_equal "192.0.2.1", type.cast("192.0.2.1").to_s
      assert_equal "192.0.2.1/32", type.serialize("192.0.2.1")
      assert_equal "192.0.2.15/24", type.serialize("192.0.2.15/24")
    end
  end

  def test_ip_address_dirty_tracking_uses_ipaddr_semantics_without_rewriting_unchanged_raw_values
    type = SQLiteTypes::IpAddress.new
    refute type.changed?(nil, nil, nil)
    refute type.changed?(nil, "not-an-ip", nil)
    refute type.changed?("192.0.2.15/24", "192.0.2.0/24", nil)
    assert type.changed?("192.0.2.0/24", "192.0.2.0/32", nil)
    refute type.changed_in_place?(nil, nil)
    refute type.changed_in_place?("not-an-ip", nil)
    refute type.changed_in_place?("192.0.2.15/24", "192.0.2.0/24")
    assert type.changed_in_place?(nil, IPAddr.new("192.0.2.1"))
    assert type.changed_in_place?(Object.new, IPAddr.new("192.0.2.1"))
    assert type.changed_in_place?(nil, Object.new)
    assert_instance_of IPAddr, type.__send__(:cast_value, "192.0.2.1")
    assert_nil type.__send__(:cast_value, "not-an-ip")

    ActiveRecord::Base.connection.execute <<~SQL
      INSERT INTO type_records (name, ip_address, string_tags, score_ids, metadata_items, meeting_times, nested_tags)
      VALUES ('Dirty', '192.0.2.15/24', '[]', '[]', '[]', '[]', '[]')
    SQL

    record = SqliteTypeRecord.find_by!(name: "Dirty")
    assert_equal "192.0.2.15/24", record.read_attribute_before_type_cast(:ip_address)
    refute record.changed?

    record.update!(name: "Dirty renamed")
    assert_equal "192.0.2.15/24", raw_row("type_records", record.id).fetch("ip_address")

    record.ip_address = "192.0.2.0/24"
    refute record.ip_address_changed?

    record.ip_address = "192.0.2.0/32"
    assert record.ip_address_changed?

    record.ip_address = "198.51.100.4"
    assert record.ip_address_changed?
  end

  def test_ip_address_dirty_tracking_detects_in_place_mutation
    ActiveRecord::Base.connection.execute <<~SQL
      INSERT INTO type_records (name, ip_address, string_tags, score_ids, metadata_items, meeting_times, nested_tags)
      VALUES ('Mutable', '192.0.2.15/24', '[]', '[]', '[]', '[]', '[]')
    SQL

    record = SqliteTypeRecord.find_by!(name: "Mutable")
    record.ip_address.__send__(:mask!, 32)

    assert record.ip_address_changed?
    record.save!
    assert_equal "192.0.2.0/32", raw_row("type_records", record.id).fetch("ip_address")
  end

  def test_invalid_values_are_rejected_before_they_reach_the_database
    blank_ip_record = SqliteTypeRecord.create!(
      name: "Blank IP",
      ip_address: "",
      string_tags: [],
      score_ids: [],
      metadata_items: [],
      meeting_times: [],
      nested_tags: []
    )

    assert_nil blank_ip_record.ip_address
    assert_nil raw_row("type_records", blank_ip_record.id).fetch("ip_address")

    assert_raises(ArgumentError) do
      SqliteTypeRecord.create!(
        name: "Invalid IP",
        ip_address: Object.new,
        string_tags: [],
        score_ids: [],
        metadata_items: [],
        meeting_times: [],
        nested_tags: []
      )
    end

    error = assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).serialize("not an array") }
    assert_includes error.message, "Invalid array value"
    assert_includes error.message, "\"not an array\""
    refute_includes error.message, "Invalid nested array value"
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).deserialize(Object.new) }
    error = assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string, nested: true).serialize(["not nested"]) }
    assert_includes error.message, "Invalid nested array value"
    invalid_element = Object.new
    invalid_element.define_singleton_method(:inspect) { "inspected-invalid-element" }
    invalid_element.define_singleton_method(:to_s) { "stringified-invalid-element" }
    error = assert_raises(ArgumentError) { SQLiteTypes::Array.new(:integer).serialize([invalid_element]) }
    assert_includes error.message, "Invalid integer array element"
    assert_includes error.message, "inspected-invalid-element"
    refute_includes error.message, "stringified-invalid-element"
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).serialize([Object.new]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).serialize([Time.zone.parse("2025-01-09 12:30:00")]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:hash).serialize([Object.new]) }
    non_hash_json_object = Object.new
    non_hash_json_object.define_singleton_method(:as_json) { |_| [] }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:hash).serialize([non_hash_json_object]) }
    invalid_json_object = Object.new
    invalid_json_object.define_singleton_method(:as_json) { |*| raise TypeError, "invalid json" }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:hash).serialize([invalid_json_object]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:datetime).serialize([Object.new]) }

    unsupported_type = SQLiteTypes::Array.new(:string)
    unsupported_type.instance_variable_set(:@subtype, :unsupported)
    error = assert_raises(ArgumentError) { unsupported_type.serialize(["value"]) }
    assert_includes error.message, "Unsupported subtype: unsupported"
    error = assert_raises(ArgumentError) { unsupported_type.deserialize(["value"]) }
    assert_includes error.message, "Unsupported subtype: unsupported"
  end

  def test_array_type_supports_migration_subtypes_without_lossy_casts
    array_type = SQLiteTypes::Array.new(:string)
    assert array_type.force_equality?(["alpha"])
    array_subclass = Class.new(Array)
    assert array_type.force_equality?(array_subclass["alpha"])
    refute array_type.force_equality?("alpha")
    assert_equal [1], SQLiteTypes::Array.new("integer").deserialize(["1"])
    assert_nil SQLiteTypes::Array.new(:string).serialize(nil)
    assert_equal [-2_147_483_649, 2_147_483_648],
      SQLiteTypes::Array.new(:integer).deserialize("[-2147483649,2147483648]")
    assert_nil SQLiteTypes::Array.new(:integer).deserialize(nil)
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:integer).deserialize([Object.new]) }
    assert_equal [{"1" => "bad key"}], ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:hash).serialize([{1 => "bad key"}]))
    integer_string = Class.new(String) do
      def to_i
        99
      end

      def to_s
        "99"
      end
    end
    assert_equal [42], SQLiteTypes::Array.new(:integer).deserialize([integer_string.new("42")])
    assert_equal [10], SQLiteTypes::Array.new(:integer).deserialize(["010"])
    with_shadowed_sqlite_types_constant(:String, Class.new) do
      assert_equal [42], SQLiteTypes::Array.new(:integer).deserialize(["42"])
    end
    assert_equal [1, "not-an-integer", 1.5, true, {"kind" => "broader"}],
      SQLiteTypes::Array.new(:integer).deserialize('[1,"not-an-integer",1.5,true,{"kind":"broader"}]')
    with_shadowed_sqlite_types_constant(:ActiveSupport, Module.new) do
      assert_equal ["alpha"], SQLiteTypes::Array.new(:string).deserialize('["alpha"]')
    end
    assert_nil SQLiteTypes::Array.new(:datetime).serialize(nil)
    assert_nil SQLiteTypes::Array.new(:datetime, nested: true).serialize(nil)
    with_shadowed_sqlite_types_constant(:String, Class.new) do
      assert_equal ["alpha"], SQLiteTypes::Array.new(:string).deserialize('["alpha"]')
    end
    assert_equal ["not-a-hash"], SQLiteTypes::Array.new(:hash).deserialize('["not-a-hash"]')
    hash_subclass = Class.new(Hash) do
      def to_h
        {"normalized" => true}
      end
    end
    assert_equal [{"normalized" => true}],
      SQLiteTypes::Array.new(:hash).deserialize([hash_subclass["source" => "subclass"]])
    with_shadowed_sqlite_types_constant(:Hash, Class.new) do
      assert_equal [{"normalized" => true}],
        SQLiteTypes::Array.new(:hash).deserialize([hash_subclass["source" => "subclass"]])
    end
    assert_equal ["not-a-date"], SQLiteTypes::Array.new(:datetime).deserialize('["not-a-date"]')
    assert_equal ["alpha"], SQLiteTypes::Array.new(:text).deserialize('["alpha"]')
    assert_equal [{"kind" => "event"}, ["nested"], 1, 1.5, true, nil],
      SQLiteTypes::Array.new(:jsonb).deserialize('[{"kind":"event"},["nested"],1,1.5,true,null]')
    assert_equal [[nil], {"maybe" => nil}],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([[nil], {"maybe" => nil}]))
    assert_equal [false, [false], {"flag" => false}],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([false, [false], {"flag" => false}]))
    with_shadowed_sqlite_types_constant(:Integer, Class.new) do
      assert_equal [1], ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([1]))
    end
    with_shadowed_sqlite_types_constant(:Float, Class.new) do
      assert_equal [1.5], ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([1.5]))
    end
    assert_equal [{"answer" => 42}],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([{answer: 42}]))
    string_key = Class.new(String).new("custom")
    assert_equal [{"custom" => 42}],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([{string_key => 42}]))
    time_like_string = Class.new(String) do
      def acts_like?(type)
        type == :time
      end

      def to_time
        Time.utc(2025, 1, 9, 12, 30, 0)
      end
    end
    assert_equal ["literal"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:string).serialize([time_like_string.new("literal")]))
    with_shadowed_sqlite_types_constant(:String, Class.new) do
      assert_equal [{"name" => "Ada"}],
        ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([{"name" => "Ada"}]))
    end
    with_shadowed_sqlite_types_constant(:Symbol, Class.new) do
      assert_equal [{"role" => "admin"}],
        ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:jsonb).serialize([{role: "admin"}]))
    end
    assert_equal SQLiteTypes::Array::SUPPORTED_SUBTYPES,
      SQLiteTypes::MigrationHelpers::SUPPORTED_ARRAY_SUBTYPES

    assert_equal ["not-an-integer"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:integer).serialize(["not-an-integer"]))
    assert_equal ["not-a-hash"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:hash).serialize(["not-a-hash"]))
    assert_equal [12],
      SQLiteTypes::Array.new(:datetime).deserialize("[12]")
    datetime_like_without_time_zone = Object.new
    datetime_like_without_time_zone.define_singleton_method(:acts_like?) { |type| type == :time }
    assert_same datetime_like_without_time_zone,
      SQLiteTypes::Array.new(:datetime).deserialize([datetime_like_without_time_zone]).first
    date_value = SQLiteTypes::Array.new(:datetime).deserialize([Date.new(2025, 1, 9)]).first
    assert_instance_of ActiveSupport::TimeWithZone, date_value
    assert_equal Time.zone.parse("2025-01-09").to_i, date_value.to_i
    with_shadowed_sqlite_types_constant(:Date, Class.new) do
      shadowed_date_value = SQLiteTypes::Array.new(:datetime).deserialize([Date.new(2025, 1, 9)]).first
      assert_instance_of ActiveSupport::TimeWithZone, shadowed_date_value
      assert_equal Time.zone.parse("2025-01-09").to_i, shadowed_date_value.to_i
    end
    date_subclass = Class.new(Date)
    date_subclass_value = SQLiteTypes::Array.new(:datetime).deserialize([date_subclass.civil(2025, 1, 10)]).first
    assert_instance_of ActiveSupport::TimeWithZone, date_subclass_value
    assert_equal Time.zone.parse("2025-01-10").to_i, date_subclass_value.to_i
    string_subclass = Class.new(String)
    assert_equal Time.zone.parse("2025-01-09T12:30:00Z").to_i,
      SQLiteTypes::Array.new(:datetime).deserialize([string_subclass.new("2025-01-09T12:30:00Z")]).first.to_i
    with_shadowed_sqlite_types_constant(:String, Class.new) do
      parsed_string = SQLiteTypes::Array.new(:datetime).deserialize(["2025-01-09T12:30:00Z"]).first
      assert_instance_of ActiveSupport::TimeWithZone, parsed_string
      assert_equal Time.zone.parse("2025-01-09T12:30:00Z").to_i, parsed_string.to_i
    end
    with_shadowed_sqlite_types_constant(:DateTime, Class.new) do
      parsed_datetime = SQLiteTypes::Array.new(:datetime).deserialize(["2025-01-09T12:30:00Z"]).first
      assert_instance_of ActiveSupport::TimeWithZone, parsed_datetime
      assert_equal Time.zone.parse("2025-01-09T12:30:00Z").to_i, parsed_datetime.to_i
    end
    assert_equal ["not-a-date"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize(["not-a-date"]))
    assert_equal ["2025-01-09T12:30:00"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize([Time.zone.parse("2025-01-09 12:30:00")]))
    assert_equal ["2025-01-09T12:30:00.1203"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize([Time.utc(2025, 1, 9, 12, 30, 0, 120_300)]))
    time_like_with_to_time = Object.new
    time_like_with_to_time.define_singleton_method(:acts_like?) { |type| type == :time }
    time_like_with_to_time.define_singleton_method(:to_time) { Time.utc(2025, 1, 9, 12, 30, 0) }
    assert_equal ["2025-01-09T12:30:00"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize([time_like_with_to_time]))
    offset_to_time = Object.new
    offset_to_time.define_singleton_method(:utc) { Time.utc(2025, 1, 9, 12, 30, 0) }
    offset_to_time.define_singleton_method(:strftime) { |format| Time.new(2025, 1, 9, 13, 30, 0, "+01:00").strftime(format) }
    time_like_with_offset_to_time = Object.new
    time_like_with_offset_to_time.define_singleton_method(:acts_like?) { |type| type == :time }
    time_like_with_offset_to_time.define_singleton_method(:to_time) { offset_to_time }
    assert_equal ["2025-01-09T12:30:00"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize([time_like_with_offset_to_time]))
    assert_equal [["2025-01-09T12:30:00", nil]],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime, nested: true).serialize([[Time.zone.parse("2025-01-09 12:30:00"), nil]]))
    assert_equal [[1, 2]], SQLiteTypes::Array.new(:integer, nested: true).deserialize([["1", "2"]])
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Object.new]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([[1, Object.new]]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([{"bad" => Object.new}]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([{"ok" => 1, "bad" => Object.new}]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([{1 => "bad key"}]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Float::NAN]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Float::INFINITY]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([BigDecimal("1.5")]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Rational(1, 3)]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Complex(1, 2)]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).deserialize('{"not":"array"}') }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string, nested: true).deserialize('["not nested"]') }
    error = assert_raises(ArgumentError) { SQLiteTypes::Array.new(nil) }
    assert_includes error.message, "Unsupported subtype:"
    error = assert_raises(ArgumentError) { SQLiteTypes::Array.new("bogus") }
    assert_equal "Unsupported subtype: bogus", error.message
    error = assert_raises(ArgumentError) { SQLiteTypes::Array.new(Object.new) }
    assert_includes error.message, "Unsupported subtype:"
  end

  def test_array_type_delegates_initialization_to_active_record_type_value
    superclass_initialize_called = false
    trace = TracePoint.new(:call) do |event|
      superclass_initialize_called = true if event.defined_class == ActiveModel::Type::Value && event.method_id == :initialize
    end

    trace.enable { SQLiteTypes::Array.new(:string) }

    assert superclass_initialize_called
  end

  def test_array_type_delegates_nil_serialization_to_active_record_json_type
    superclass_serialize_called = false
    trace = TracePoint.new(:call) do |event|
      superclass_serialize_called = true if event.defined_class == ActiveRecord::Type::Json && event.method_id == :serialize
    end

    trace.enable do
      assert_nil SQLiteTypes::Array.new(:string).serialize(nil)
    end

    assert superclass_serialize_called
  end

  def test_datetime_array_type_matches_postgresql_timestamp_json_across_application_time_zones
    previous_zone = Time.zone
    Time.zone = "Europe/Warsaw"

    type = SQLiteTypes::Array.new(:datetime)
    time = Time.zone.parse("2025-01-09 13:30:00")
    offset_time = Time.new(2025, 1, 9, 13, 30, 0, "+01:00")

    assert_equal ["2025-01-09T12:30:00"], ActiveSupport::JSON.decode(type.serialize([time]))
    assert_equal ["2025-01-09T12:30:00"], ActiveSupport::JSON.decode(type.serialize([offset_time]))
    assert_equal time.to_i, type.deserialize('["2025-01-09T12:30:00"]').first.to_i
  ensure
    Time.zone = previous_zone
  end

  def test_interval_type_handles_numeric_and_passthrough_values
    type = SQLiteTypes::Interval.new
    precision_type = SQLiteTypes::Interval.new(precision: 3)
    duration = 15.minutes

    assert_equal "PT1M30S", type.serialize(90)
    assert_equal "PT2H30M", type.serialize(150.minutes)
    assert_equal "PT2H30M", type.serialize(2.hours + 30.minutes)
    assert_equal "P1M", type.serialize(1.month)
    assert_equal "P31D", type.serialize(31.days)
    assert_equal "PT1.234S", precision_type.serialize(1.2345.seconds)
    assert_equal "PT1.234S", precision_type.serialize(1.2345)
    assert_equal "PT15M", type.serialize("PT15M")
    assert_equal "\"PT15M\"", type.type_cast_for_schema(duration)
    assert_same duration, type.cast(duration)
    assert_nil type.cast("not-a-duration")
    assert_equal 90, type.cast(90)
  end

  def test_interval_type_uses_top_level_active_support_namespace
    type = SQLiteTypes::Interval.new
    shadow_duration = Class.new do
      def self.parse(_value)
        "shadow duration"
      end
    end
    shadow_active_support = Module.new do
      const_set :Duration, shadow_duration
    end

    with_shadowed_sqlite_types_constant(:ActiveSupport, shadow_active_support) do
      assert_instance_of ActiveSupport::Duration, type.cast("PT15M")
      assert_equal "PT15M", type.serialize(15.minutes)
      assert_equal "PT15M", type.serialize(900)
    end
  end

  def test_interval_type_uses_top_level_string_namespace
    type = SQLiteTypes::Interval.new

    with_shadowed_sqlite_types_constant(:String, Class.new) do
      assert_instance_of ActiveSupport::Duration, type.cast("PT15M")
    end
  end

  def test_interval_type_uses_top_level_numeric_namespace
    type = SQLiteTypes::Interval.new

    with_shadowed_sqlite_types_constant(:Numeric, Class.new) do
      assert_equal "PT15M", type.serialize(900)
    end
  end

  private

  def with_shadowed_sqlite_types_constant(name, value)
    previously_defined = SQLiteTypes.const_defined?(name, false)
    previous_value = SQLiteTypes.const_get(name, false) if previously_defined
    SQLiteTypes.__send__(:remove_const, name) if previously_defined
    SQLiteTypes.const_set(name, value)
    yield
  ensure
    SQLiteTypes.__send__(:remove_const, name) if SQLiteTypes.const_defined?(name, false)
    SQLiteTypes.const_set(name, previous_value) if previously_defined
  end
end
