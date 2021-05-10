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
  "data" => { amazing: "hello world this is an amazing message hello there!!!", another_key: [2, 3, 4] },
  "user_ids" => [1, 2, 3],
  "group_ids" => [1],
  "client_ids" => nil
  }, 2
)

#              marshal:   504885.6 i/s
#                 json:   401050.9 i/s - 1.26x  (± 0.00) slower
#                   oj:   340847.4 i/s - 1.48x  (± 0.00) slower
#          string_hack:   296741.6 i/s - 1.70x  (± 0.00) slower
# packed_string_4_bytes:   207942.6 i/s - 2.43x  (± 0.00) slower
# packed_string_8_bytes:   206093.0 i/s - 2.45x  (± 0.00) slower
