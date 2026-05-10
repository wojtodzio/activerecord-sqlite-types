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
    assert_equal "PT90M", raw.fetch("time_offset")
    assert_equal "PT90M", SQLiteTypes::Interval.new.serialize(reloaded.time_offset)

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
    assert_equal matching.id, SqliteTypeRecord.find_by(time_offset: 15.minutes).id
    assert_equal [matching.id], SqliteTypeRecord.where(string_tags: ["vip", "alpha"]).pluck(:id)
    assert_equal [matching.id], SqliteTypeRecord.where(score_ids: ["1", "2"]).pluck(:id)
    assert_equal [matching.id], SqliteTypeRecord.where(meeting_times: [meeting_time]).pluck(:id)
    assert_empty SqliteTypeRecord.where(string_tags: ["alpha", "vip"])

    matching.update!(score_ids: ["4", "5"], time_offset: "PT45M")
    assert_equal [4, 5], matching.reload.score_ids
    assert_equal "PT45M", SQLiteTypes::Interval.new.serialize(matching.time_offset)

    matching.destroy!
    assert_equal ["Other"], SqliteTypeRecord.order(:name).pluck(:name)
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
  end

  def test_ip_address_dirty_tracking_uses_ipaddr_semantics_without_rewriting_unchanged_raw_values
    type = SQLiteTypes::IpAddress.new
    refute type.changed?(nil, nil, nil)
    refute type.changed_in_place?(nil, nil)
    assert type.changed_in_place?(nil, IPAddr.new("192.0.2.1"))

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

    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).serialize("not an array") }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string, nested: true).serialize(["not nested"]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:integer).serialize([Object.new]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).serialize([Object.new]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:hash).serialize([Object.new]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:datetime).serialize([Object.new]) }
  end

  def test_array_type_supports_migration_subtypes_without_lossy_casts
    assert_equal [-2_147_483_649, 2_147_483_648],
      SQLiteTypes::Array.new(:integer).deserialize("[-2147483649,2147483648]")
    assert_equal [1, "not-an-integer", 1.5, true, {"kind" => "broader"}],
      SQLiteTypes::Array.new(:integer).deserialize('[1,"not-an-integer",1.5,true,{"kind":"broader"}]')
    assert_equal ["not-a-hash"], SQLiteTypes::Array.new(:hash).deserialize('["not-a-hash"]')
    assert_equal ["not-a-date"], SQLiteTypes::Array.new(:datetime).deserialize('["not-a-date"]')
    assert_equal ["alpha"], SQLiteTypes::Array.new(:text).deserialize('["alpha"]')
    assert_equal [{"kind" => "event"}, ["nested"], 1, 1.5, true, nil],
      SQLiteTypes::Array.new(:jsonb).deserialize('[{"kind":"event"},["nested"],1,1.5,true,null]')
    assert_equal SQLiteTypes::Array::SUPPORTED_SUBTYPES,
      SQLiteTypes::MigrationHelpers::SUPPORTED_ARRAY_SUBTYPES

    assert_equal ["not-an-integer"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:integer).serialize(["not-an-integer"]))
    assert_equal ["not-a-hash"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:hash).serialize(["not-a-hash"]))
    assert_equal ["not-a-date"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize(["not-a-date"]))
    assert_equal ["2025-01-09T12:30:00"],
      ActiveSupport::JSON.decode(SQLiteTypes::Array.new(:datetime).serialize([Time.zone.parse("2025-01-09 12:30:00")]))
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Object.new]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Float::NAN]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Float::INFINITY]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([BigDecimal("1.5")]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Rational(1, 3)]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:jsonb).serialize([Complex(1, 2)]) }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string).deserialize('{"not":"array"}') }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(:string, nested: true).deserialize('["not nested"]') }
    assert_raises(ArgumentError) { SQLiteTypes::Array.new(nil) }
  end

  def test_datetime_array_type_matches_postgresql_timestamp_json_across_application_time_zones
    previous_zone = Time.zone
    Time.zone = "Europe/Warsaw"

    type = SQLiteTypes::Array.new(:datetime)
    time = Time.zone.parse("2025-01-09 13:30:00")

    assert_equal ["2025-01-09T12:30:00"], ActiveSupport::JSON.decode(type.serialize([time]))
    assert_equal time.to_i, type.deserialize('["2025-01-09T12:30:00"]').first.to_i
  ensure
    Time.zone = previous_zone
  end
end
