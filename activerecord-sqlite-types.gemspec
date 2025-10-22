# frozen_string_literal: true

require_relative "lib/sqlite_types/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord-sqlite-types"
  spec.version = SQLiteTypes::VERSION
  spec.authors = ["Wojtek Wrona"]
  spec.email = ["wojtodzio@gmail.com"]

  spec.summary = "Custom ActiveRecord types for SQLite migrations from PostgreSQL"
  spec.description = "Provides custom ActiveRecord types to handle PostgreSQL-specific data types " \
                     "(inet, interval, arrays) when migrating to SQLite in Rails applications."
  spec.homepage = "https://github.com/wojtodzio/activerecord-sqlite-types"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "sqlite3", ">= 1.6"
end
