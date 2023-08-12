# frozen_string_literal: true

require File.expand_path('../lib/message_bus/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Sam Saffron"]
  gem.email         = ["sam.saffron@gmail.com"]
  gem.description   = %q{A message bus for rack}
  gem.summary       = %q{}
  gem.homepage      = "https://github.com/discourse/message_bus"
  gem.license       = "MIT"
  gem.files         = `git ls-files`.split($\) +
                      ["vendor/assets/javascripts/message-bus.js", "vendor/assets/javascripts/message-bus-ajax.js"]
  gem.name          = "message_bus"
  gem.require_paths = ["lib"]
  gem.version       = MessageBus::VERSION
  gem.required_ruby_version = ">= 3.0.0"

  gem.add_runtime_dependency 'rack', '>= 1.1.3'

  # Optional runtime dependencies
  gem.add_development_dependency 'redis'
  gem.add_development_dependency 'pg'
  gem.add_development_dependency 'concurrent-ruby' # for distributed-cache

  gem.add_development_dependency 'minitest'
  gem.add_development_dependency 'minitest-hooks'
  gem.add_development_dependency 'minitest-global_expectations'
  gem.add_development_dependency 'rake'
  gem.add_development_dependency 'http_parser.rb'
  gem.add_development_dependency 'thin'
  gem.add_development_dependency 'rack-test'
  gem.add_development_dependency 'puma'
  gem.add_development_dependency 'm'
  gem.add_development_dependency 'byebug'
  gem.add_development_dependency 'oj'
  gem.add_development_dependency 'yard'
  gem.add_development_dependency 'rubocop-discourse'
  gem.add_development_dependency 'rubocop-rspec'
  gem.add_development_dependency 'dotenv', '~> 2.8'
  gem.add_development_dependency 'rails', '> 6'
end
