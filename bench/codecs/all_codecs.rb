# frozen_string_literal: true

require_relative './packed_string'
require_relative './string_hack'
require_relative './marshal'

def all_codecs
  {
    json: MessageBus::Codec::Json.new,
    oj: MessageBus::Codec::Oj.new,
    marshal: MarshalCodec.new,
    packed_string_4_bytes: PackedString.new("V"),
    packed_string_8_bytes: PackedString.new("Q"),
    string_hack: StringHack.new
  }
end

def bench_decode(hash, user_needle)
  encoded_data = all_codecs.map do |name, codec|
    [
      name, codec, codec.encode(hash.dup)
    ]
  end

  Benchmark.ips do |x|

    encoded_data.each do |name, codec, encoded|
      x.report(name) do |n|
        while n > 0
          decoded = codec.decode(encoded)
          decoded["user_ids"].include?(user_needle)
          n -= 1
        end
      end
    end

    x.compare!
  end
end
