# frozen_string_literal: true

require "test_helper"

class ArrayColumnRecord < ActiveRecord::Base
  include SQLiteTypes::ArrayColumns

  self.table_name = "array_column_records"

  attribute :tags, SQLiteTypes::Array.new(:string)
  attribute :codes, SQLiteTypes::Array.new(:integer)

  array_columns :tags
  array_columns "codes", :tags, nil, ""
end

class TestArrayColumns < Minitest::Test
  cover "SQLiteTypes::ArrayColumns*"

  include DatabaseTestHelpers

  def setup
    super

    ActiveRecord::Schema.define do
      create_table :array_column_records, force: true do |t|
        t.string :name
        t.json :tags
        t.json :codes, default: [], null: false
      end
    end
  end

  def test_array_columns_sanitize_list_normalizes_values_for_storage_and_queries
    assert_equal [], ArrayColumnRecord.array_columns_sanitize_list(nil)
    assert_equal ["1", "alpha", "beta"],
      ArrayColumnRecord.array_columns_sanitize_list(["beta", :alpha, "", nil, "beta", 1, false])
  end

  def test_before_validation_sanitizes_declared_array_columns
    record = ArrayColumnRecord.create!(
      name: "Sanitized",
      tags: ["beta", :alpha, "", nil, "beta"],
      codes: [2, "1", nil, ""]
    )

    assert_equal ["alpha", "beta"], record.reload.tags
    assert_equal [1, 2], record.codes
    assert_equal "[\"alpha\",\"beta\"]", raw_row("array_column_records", record.id).fetch("tags")
    assert_equal "[1,2]", raw_row("array_column_records", record.id).fetch("codes")
  end

  def test_presence_scopes_find_records_with_and_without_array_values
    tagged = ArrayColumnRecord.create!(name: "Tagged", tags: ["alpha"], codes: [])
    empty = ArrayColumnRecord.create!(name: "Empty", tags: [], codes: [])
    null = ArrayColumnRecord.create!(name: "Null", tags: nil, codes: [])

    assert_equal [tagged.id], ArrayColumnRecord.with_tags.pluck(:id)
    assert_equal [empty.id, null.id].sort, ArrayColumnRecord.without_tags.pluck(:id).sort
  end

  def test_query_scopes_match_any_all_and_negative_variants
    alpha_beta = ArrayColumnRecord.create!(name: "Alpha beta", tags: ["alpha", "beta"], codes: [1, 2])
    beta = ArrayColumnRecord.create!(name: "Beta", tags: ["beta"], codes: [2])
    gamma = ArrayColumnRecord.create!(name: "Gamma", tags: ["gamma"], codes: [3])

    assert_equal [alpha_beta.id, beta.id].sort, ArrayColumnRecord.with_any_tags(:beta, "").pluck(:id).sort
    assert_equal [alpha_beta.id], ArrayColumnRecord.with_all_tags("alpha", :beta, "beta").pluck(:id)
    assert_equal [gamma.id], ArrayColumnRecord.without_any_tags("alpha", "beta").pluck(:id)
    assert_equal [beta.id, gamma.id].sort, ArrayColumnRecord.without_all_tags("alpha", "beta").pluck(:id).sort
    assert_equal [alpha_beta.id, beta.id].sort, ArrayColumnRecord.with_any_codes("2").pluck(:id).sort
    assert_equal [alpha_beta.id], ArrayColumnRecord.with_all_codes(1, "2").pluck(:id)
  end

  def test_instance_predicates_match_sanitized_array_values
    record = ArrayColumnRecord.new(tags: ["alpha", "beta"], codes: [1, 2])

    assert record.has_any_tags?(:missing, :alpha)
    assert record.has_all_tags?("beta", "alpha")
    assert record.has_tag?(:alpha)
    refute record.has_any_tags?(:missing, "")
    refute record.has_all_tags?(:alpha, :missing)
    assert record.has_code?("1")
    refute record.has_all_codes?(1, 3)
  end

  def test_aggregate_methods_return_unique_values_and_cloud_counts
    ArrayColumnRecord.create!(name: "First", tags: ["beta", "alpha"], codes: [2, 1])
    ArrayColumnRecord.create!(name: "Second", tags: ["beta", "gamma"], codes: [2, 3])
    ArrayColumnRecord.create!(name: "Empty", tags: [], codes: [])

    assert_equal ["alpha", "beta", "gamma"], ArrayColumnRecord.unique_tags
    assert_equal({"alpha" => 1, "beta" => 2, "gamma" => 1}, ArrayColumnRecord.tags_cloud)
    assert_equal [1, 2, 3], ArrayColumnRecord.unique_codes
    assert_equal({1 => 1, 2 => 2, 3 => 1}, ArrayColumnRecord.codes_cloud)
  end
end
