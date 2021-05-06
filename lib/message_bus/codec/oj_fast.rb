# frozen_string_literal: true

require 'oj' unless defined? ::Oj
require 'base64'

module MessageBus
  module Codec
    class FastIdList
      def self.from_array(array)
        new(array.sort.pack("V*"))
      end

      def self.from_string(string)
        new(string)
      end

      def initialize(packed)
        @packed = packed
      end

      def include?(id)
        found = (0...length).bsearch do |index|
          @packed.byteslice(index * 4, 4).unpack1("V") >= id
        end

        if found
          found && @packed.byteslice(found * 4, 4).unpack1("V") == id
        end
      end

      def length
        @length ||= @packed.bytesize / 4
      end

      def to_a
        @packed.unpack("V*")
      end

      def to_s
        @packed
      end
    end

    class OjFast < Base
      def encode(data:, user_ids:, group_ids:, client_ids:)

        if user_ids
          user_ids = FastIdList.from_array(user_ids).to_s
        end

        #if group_ids
        #  group_ids = FastIdList.from_array(group_ids).to_s
        #end
        data = ::Oj.dump(data, mode: :compat)

        Marshal.dump(
          "data" => data,
          "user_ids" => user_ids,
          "group_ids" => group_ids,
          "client_ids" => client_ids
        )
      end

      def decode(payload)
        result = Marshal.load(payload)
        result["data"] = ::Oj.load(result["data"], mode: :compat)

        if str = result["user_ids"]
          result["user_ids"] = FastIdList.from_string(str)
        end

        # groups need to implement (-)
        # if str = result["group_ids"]
        #  result["group_ids"] = FastIdList.from_string(str)
        # end
        #

        result
      end
    end
  end
end
