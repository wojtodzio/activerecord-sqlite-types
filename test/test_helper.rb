# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "sqlite_types"

require "minitest/autorun"

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
