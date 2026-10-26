# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# qube_sync 0.4.0 (the v2 client) isn't on rubygems.org yet. Locally it comes from the v2-client
# worktree beside this repo (or QUBE_SYNC_PATH); anywhere else, from rubygems.org once it's
# published.
qube_sync_path = ENV.fetch("QUBE_SYNC_PATH", File.expand_path("../wt-qube_sync_rb", __dir__))
gem "qube_sync", path: qube_sync_path if File.directory?(qube_sync_path)

# RAILS_VERSION picks the Rails the suite runs on: 8.1 (the default) or 7.0, the oldest the gem
# supports.
rails_version = ENV.fetch("RAILS_VERSION", "8.1")
gem "rails", "~> #{rails_version}.0"

if Gem::Version.new(rails_version) < Gem::Version.new("7.1")
  gem "sqlite3", "~> 1.4"
  # Rails 7.0 predates Ruby 3.4's move of these out of the default gems, and concurrent-ruby
  # 1.3.5's dropping of the logger require it relied on.
  gem "base64"
  gem "bigdecimal"
  gem "concurrent-ruby", "< 1.3.5"
  gem "drb"
  # json 2.10 dropped an option ActiveSupport 7.0's encoder passes.
  gem "json", "< 2.10"
  gem "logger"
  gem "mutex_m"
else
  gem "sqlite3", ">= 2.1"
end

# The specs run on SQLite; DB=postgres or DB=mysql (with DATABASE_URL) runs them on that database.
case ENV["DB"]
when "postgres" then gem "pg"
when "mysql" then gem "mysql2"
end

gem "rake"
gem "rspec-rails"
gem "webmock"
