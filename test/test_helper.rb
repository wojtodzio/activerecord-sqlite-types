# frozen_string_literal: true

unless ENV["SIMPLECOV_DISABLED"] == "1"
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :branch
    add_filter "/test/"
    minimum_coverage line: 100, branch: 100
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "sqlite_types"

require "minitest/autorun"
if ENV["MUTANT_DISABLED"] == "1"
  Minitest::Test.singleton_class.define_method(:cover) { |*| }
else
  require "mutant/minitest/coverage"
end

ActiveRecord::Migration.verbose = false
Time.zone = "UTC"

module DatabaseTestHelpers
  def setup
    super
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  end

  def teardown
    ActiveRecord::Base.connection.disconnect! if ActiveRecord::Base.connected?
    super
  end

  def raw_row(table_name, id)
    ActiveRecord::Base.connection.select_one("SELECT * FROM #{table_name} WHERE id = #{id}")
  end

  def column_for(table_name, column_name)
    ActiveRecord::Base.connection.columns(table_name).find { |column| column.name == column_name.to_s }
  end
end
