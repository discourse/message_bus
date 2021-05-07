# frozen_string_literal: true

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'message_bus', path: '../'
  gem 'benchmark-ips'
  gem 'oj'
end

require 'benchmark/ips'
require 'message_bus'
require_relative 'codecs/all_codecs'

bench_decode({
  "data" => "hello world",
  "user_ids" => (1..10000).to_a,
  "group_ids" => nil,
  "client_ids" => nil
  }, 5000
)

# packed_string_4_bytes:   127176.1 i/s
# packed_string_8_bytes:    94494.6 i/s - 1.35x  (± 0.00) slower
#          string_hack:    26403.4 i/s - 4.82x  (± 0.00) slower
#              marshal:     4985.5 i/s - 25.51x  (± 0.00) slower
#                   oj:     3072.9 i/s - 41.39x  (± 0.00) slower
#                 json:     2222.7 i/s - 57.22x  (± 0.00) slower
