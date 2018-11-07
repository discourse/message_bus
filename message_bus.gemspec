# frozen_string_literal: true
# -*- encoding: utf-8 -*-

require File.expand_path('../lib/message_bus/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Sam Saffron"]
  gem.email         = ["sam.saffron@gmail.com"]
  gem.description   = %q{A message bus for rack}
  gem.summary       = %q{}
  gem.homepage      = "https://github.com/SamSaffron/message_bus"
  gem.license       = "MIT"
  gem.files         = `git ls-files`.split($\) +
                      ["vendor/assets/javascripts/message-bus.js", "vendor/assets/javascripts/message-bus-ajax.js"]
  gem.executables   = gem.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "message_bus"
  gem.require_paths = ["lib"]
  gem.version       = MessageBus::VERSION
  gem.required_ruby_version = ">= 2.3.0"
  gem.add_runtime_dependency 'rack', '>= 1.1.3'
  gem.add_development_dependency 'redis'
  gem.add_development_dependency 'pg'
end
