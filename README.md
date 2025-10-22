# ActiveRecord SQLite Types

Custom ActiveRecord types for migrating from PostgreSQL to SQLite in Rails applications.

This gem provides drop-in replacements for PostgreSQL-specific data types that don't exist natively in SQLite, allowing you to migrate your Rails application from PostgreSQL to SQLite without changing your application code.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "activerecord-sqlite-types"
```

And then execute:

```bash
bundle install
```

## Available Types

### IpAddress

Replaces PostgreSQL's `inet` type with a string representation that preserves IP address functionality.

**Usage:**

```ruby
class User < ApplicationRecord
  attribute :current_sign_in_ip, SQLiteTypes::IpAddress.new
  attribute :last_sign_in_ip, SQLiteTypes::IpAddress.new
end
```

**Migration:**

```ruby
class MigrateInetToString < ActiveRecord::Migration[7.0]
  def up
    change_column :users, :current_sign_in_ip, :string
    change_column :users, :last_sign_in_ip, :string
  end

  def down
    change_column :users, :current_sign_in_ip, :inet, using: 'current_sign_in_ip::inet'
    change_column :users, :last_sign_in_ip, :inet, using: 'last_sign_in_ip::inet'
  end
end
```

### Array

Replaces PostgreSQL arrays with JSON-backed arrays, supporting querying via SQLite's JSON functions.

**Supported subtypes:** `:integer`, `:string`, `:hash`, `:datetime`

**Usage:**

```ruby
class User < ApplicationRecord
  attribute :personality_traits, SQLiteTypes::Array.new(:string)
  attribute :favorite_numbers, SQLiteTypes::Array.new(:integer)
  attribute :nested_data, SQLiteTypes::Array.new(:integer, nested: true)
end
```

**Migration:**

```ruby
class MigrateArrayToJson < ActiveRecord::Migration[7.0]
  def up
    change_column :users, :personality_traits, :json
    change_column :users, :favorite_numbers, :json
  end

  def down
    change_column :users, :personality_traits, :text, array: true, default: [], using: 'personality_traits::text[]'
    change_column :users, :favorite_numbers, :integer, array: true, default: [], using: 'favorite_numbers::integer[]'
  end
end
```

**Querying arrays:**

For array querying functionality, see [Stephen Margheim's article on enhancing Rails SQLite array columns](https://fractaledmind.github.io/2023/09/12/enhancing-rails-sqlite-array-columns/).

### Interval

Replaces PostgreSQL's `interval` type with ISO8601 duration strings.

**Usage:**

```ruby
class Event < ApplicationRecord
  attribute :duration, SQLiteTypes::Interval.new
end
```

**Migration:**

```ruby
class MigrateIntervalToString < ActiveRecord::Migration[7.0]
  def up
    change_column :events, :duration, :string
  end

  def down
    change_column :events, :duration, :interval, using: 'duration::interval'
  end
end
```

## Migration Strategy

The recommended approach for migrating from PostgreSQL to SQLite is incremental and reversible:

1. **Prepare while still on PostgreSQL:**
   - Add custom type declarations to your models
   - Run migrations to change column types (e.g., `inet` → `string`)
   - Test thoroughly - migrations are reversible!

2. **Switch to SQLite:**
   - Update `database.yml` to point to SQLite
   - Run your data migration script (e.g., [pg-to-sqlite](https://github.com/hirefrank/pg-to-sqlite))
   - Run your test suite

3. **Handle database constraints:**
   - Drop PostgreSQL-specific constraints before switching
   - Add SQLite-compatible constraints after switching

For a detailed migration guide, see [this presentation on migrating from PostgreSQL to SQLite](https://gist.github.com/wojtodzio/538de01f6ba24665fa66d204824ca718).

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/wojtodzio/activerecord-sqlite-types.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
