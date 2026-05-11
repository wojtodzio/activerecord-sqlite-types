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

## Migration Generator

Generate a rollback-aware type-preparation migration while your application is still running on PostgreSQL:

```bash
bin/rails generate sqlite_types:migration prepare_sqlite_types \
  --inet users.current_sign_in_ip users.last_sign_in_ip \
  --interval timings.time_offset \
  --array events.relationship_statuses:string event_classes.summary_points:text:nested email_notification_logs.attachments:hash
```

The generator creates a migration that includes `SQLiteTypes::MigrationHelpers`:

```ruby
class PrepareSqliteTypes < ActiveRecord::Migration[7.1]
  include SQLiteTypes::MigrationHelpers

  def change
    change_inet_to_string :users, :current_sign_in_ip
    change_inet_to_string :users, :last_sign_in_ip
    change_interval_to_string :timings, :time_offset
    change_array_to_json :events, :relationship_statuses, :string
    change_array_to_json :event_classes, :summary_points, :text, nested: true
    change_array_to_json :email_notification_logs, :attachments, :hash
  end
end
```

The generated migration is PostgreSQL-only. Run it while the application is still backed by PostgreSQL, then keep the app on PostgreSQL long enough to verify the SQLite-compatible column types with your normal Rails code, staging traffic, and test suite. After that, copy the prepared data to SQLite with a separate data migration tool.

On the way up, `change_array_to_json` converts PostgreSQL array columns to `jsonb` and adds a `jsonb_typeof(...) = 'array'` check constraint. On PostgreSQL rollback, it rebuilds the original array column through a temporary column so data compatible with the original PostgreSQL type remains reversible. Nullability is preserved unless you pass `null:` explicitly. The default assumes PostgreSQL-style empty-array defaults; if a column has different default semantics, edit the generated migration and pass `default:` explicitly. Use `:text` when the original column was `text[]`; `:string` restores a Rails `string`/`varchar[]` column. Array element order and SQL `NULL` elements are preserved. Rollbacks lock affected array tables when running inside Rails' default PostgreSQL migration transaction, preflight JSON shape, element compatibility, and the actual PostgreSQL target casts before changing schema, then raise `ActiveRecord::IrreversibleMigration` for incompatible values. Nested PostgreSQL arrays must remain rectangular with non-empty inner arrays because PostgreSQL multidimensional arrays cannot represent ragged JSON arrays or preserve empty inner arrays.

## Available Types

### IpAddress

Replaces PostgreSQL's `inet` type with a string representation that preserves IP address functionality.
The Ruby value is an `IPAddr`, matching Rails' PostgreSQL `inet` type. `IPAddr` normalizes CIDR host bits when casting values like `192.0.2.15/24`; the migration helper preserves existing database text during the SQL type change, but new model assignments follow Rails' `IPAddr` semantics.
Blank or invalid string assignments cast to `nil`, matching Rails' PostgreSQL `inet` type. Invalid strings passed directly to query/persistence serialization are rejected instead of being stored as text.

**Usage:**

```ruby
class User < ApplicationRecord
  attribute :current_sign_in_ip, SQLiteTypes::IpAddress.new
  attribute :last_sign_in_ip, SQLiteTypes::IpAddress.new
end
```

**Migration:**

```ruby
class MigrateInetToString < ActiveRecord::Migration[7.1]
  include SQLiteTypes::MigrationHelpers

  def change
    change_inet_to_string :users, :current_sign_in_ip
    change_inet_to_string :users, :last_sign_in_ip
  end
end
```

### Array

Replaces PostgreSQL arrays with JSON-backed arrays, supporting querying via SQLite's JSON functions.

**Supported subtypes:** `:integer`, `:string`, `:text`, `:hash`, `:json`, `:jsonb`, `:datetime`

All subtypes preserve `nil` elements, matching PostgreSQL array `NULL` elements. At runtime, `SQLiteTypes::Array` casts values only when they already fit the declared subtype; for example, integer strings become integers and datetime strings become `Time` values. Values outside the declared subtype are still allowed when they are native JSON values, because SQLite JSON storage can hold broader data after migration.

For example, `:integer` can store integers outside PostgreSQL `integer[]`/`int4[]` bounds and even non-integer JSON values; those values are valid for SQLite but can make a future rollback to the original PostgreSQL column type fail cleanly before schema changes. The same broader-value rule applies to `:string`, `:text`, `:hash`, and `:datetime`; rollback restores `:string` and `:text` through PostgreSQL text conversion, while incompatible values in other subtypes can block rollback. `:datetime` serializes time values in the same timestamp string shape PostgreSQL `to_jsonb(timestamp[])` uses, so equality queries can match migrated rows. The `:json` and `:jsonb` subtypes accept native JSON values only; non-finite floats and Ruby numerics that Rails would encode as strings, such as `BigDecimal`, `Rational`, and `Complex`, are rejected to avoid silent type changes or `null` writes.

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
class MigrateArrayToJson < ActiveRecord::Migration[7.1]
  include SQLiteTypes::MigrationHelpers

  def change
    change_array_to_json :users, :personality_traits, :string
    change_array_to_json :users, :favorite_numbers, :integer
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
class MigrateIntervalToString < ActiveRecord::Migration[7.1]
  include SQLiteTypes::MigrationHelpers

  def change
    change_interval_to_string :events, :duration
  end
end
```

## Migration Strategy

The recommended approach for migrating from PostgreSQL to SQLite is incremental and reversible while data remains compatible with the original PostgreSQL column types:

1. **Prepare while still on PostgreSQL:**
   - Add custom type declarations to your models
   - Run migrations to change column types (e.g., `inet` → `string`)
   - Test thoroughly; rollbacks are preflighted and reversible for compatible data.

2. **Switch to SQLite:**
   - Update `database.yml` to point to SQLite
   - Run your data migration script (e.g., [pg-to-sqlite](https://github.com/hirefrank/pg-to-sqlite))
   - Run your test suite

3. **Handle database constraints:**
   - Drop PostgreSQL-specific constraints before switching
   - Add SQLite-compatible constraints after switching

For a detailed migration guide, see [this presentation on migrating from PostgreSQL to SQLite](https://gist.github.com/wojtodzio/538de01f6ba24665fa66d204824ca718).

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests with SimpleCov's 100% line and branch coverage gates. Run `bundle exec standardrb` for style checks and `bundle exec mutant run` for the mutation test suite. The default `rake` task runs all three gates.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/wojtodzio/activerecord-sqlite-types.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
