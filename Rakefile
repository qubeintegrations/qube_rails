# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "ruby -c on every file the gem ships, under Ruby 2.7 (bin/syntax-check-2.7, in Docker)"
task :syntax_check do
  sh "bin/syntax-check-2.7"
end

task default: :spec
