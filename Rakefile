# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |t|
  t.framework = %(require_relative "test/test_helper")
  t.test_globs = FileList["test/test_*.rb"].exclude("test/test_helper.rb").to_a
end

require "standard/rake"

desc "Run mutation tests"
task :mutant do
  sh "bundle exec mutant run"
end

task default: %i[test standard mutant]
