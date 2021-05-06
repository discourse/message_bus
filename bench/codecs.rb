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

class StringHack
  class FastIdList
    def self.from_array(array)
      new(",#{array.join(",")},")
    end

    def self.from_string(string)
      new(string)
    end

    def initialize(packed)
      @packed = packed
    end

    def include?(id)
      @packed.include?(",#{id},")
    end

    def to_s
      @packed
    end
  end

  class OjString
    def encode(data:, user_ids:, group_ids:, client_ids:)

      if user_ids
        user_ids = FastIdList.from_array(user_ids).to_s
      end

      ::Oj.dump({
          data: data,
          user_ids: user_ids,
          group_ids: group_ids,
          client_ids: client_ids
        },
        mode: :compat)
    end

    def decode(payload)
      result = ::Oj.load(payload, mode: :compat)

      if str = result["user_ids"]
        result["user_ids"] = FastIdList.from_string(str)
      end

      result
    end
  end
end

json_codec = MessageBus::Codec::Json.new
oj_codec = MessageBus::Codec::Oj.new
oj_fast_codec = MessageBus::Codec::OjFast.new
oj_fast_string_hack = StringHack::OjString.new

json = json_codec.encode(
  data: "hello world",
  user_ids: (1..10000).to_a,
  group_ids: nil,
  client_ids: nil
)

json_fast = oj_fast_codec.encode(
  data: "hello world",
  user_ids: (1..10000).to_a,
  group_ids: nil,
  client_ids: nil
)

json_fast2 = oj_fast_string_hack.encode(
  data: "hello world",
  user_ids: (1..10000).to_a,
  group_ids: nil,
  client_ids: nil
)

Benchmark.ips do |x|
  x.report("json") do |n|
    while n > 0
      decoded = json_codec.decode(json)
      decoded["user_ids"].include?(5000)
      n -= 1
    end
  end

  x.report("oj") do |n|
    while n > 0
      decoded = oj_codec.decode(json)
      decoded["user_ids"].include?(5000)
      n -= 1
    end
  end

  x.report("oj_fast") do |n|
    while n > 0
      decoded = oj_fast_codec.decode(json_fast)
      decoded["user_ids"].include?(5000)
      n -= 1
    end
  end

  x.report("oj_fast string hack") do |n|
    while n > 0
      decoded = oj_fast_string_hack.decode(json_fast2)
      decoded["user_ids"].include?(5000)
      n -= 1
    end
  end
  x.compare!
end

#Comparison:
#             oj_fast:   129350.0 i/s
# oj_fast string hack:    26255.2 i/s - 4.93x  (± 0.00) slower
#                  oj:     3073.5 i/s - 42.09x  (± 0.00) slower
#                json:     2221.9 i/s - 58.22x  (± 0.00) slower
