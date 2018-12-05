source 'https://rubygems.org'

# Specify your gem's dependencies in message_bus.gemspec
gemspec

group :test do
  gem 'minitest'
  gem 'minitest-hooks'
  gem 'rake'
  gem 'http_parser.rb'
  gem 'thin'
  gem 'rack-test', require: 'rack/test'
  gem 'jasmine'
  gem 'puma'
end

group :test, :development do
  gem 'byebug'
end

gem 'rack'
gem 'concurrent-ruby' # for distributed-cache

gem 'rubocop'
gem 'yard'
