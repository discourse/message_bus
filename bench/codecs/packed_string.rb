# frozen_string_literal: true

class PackedString
  class FastIdList
    def self.from_array(array, pack_with)
      new(array.sort.pack("#{pack_with}*"), pack_with)
    end

    def self.from_string(string, pack_with)
      new(string, pack_with)
    end

    def initialize(packed, pack_with)
      raise "unknown pack format, expecting Q or V" if pack_with != "V" && pack_with != "Q"
      @packed = packed
      @pack_with = pack_with
      @slot_size = pack_with == "V" ? 4 : 8
    end

    def include?(id)
      found = (0...length).bsearch do |index|
        @packed.byteslice(index * @slot_size, @slot_size).unpack1(@pack_with) >= id
      end

      found && @packed.byteslice(found * @slot_size, @slot_size).unpack1(@pack_with) == id
    end

    def length
      @length ||= @packed.bytesize / @slot_size
    end

    def to_a
      @packed.unpack("#{@pack_with}*")
    end

    def to_s
      @packed
    end
  end

  def initialize(pack_with = "V")
    @pack_with = pack_with
    @oj_options = { mode: :compat }
  end

  def encode(hash)

    if user_ids = hash["user_ids"]
      hash["user_ids"] = FastIdList.from_array(hash["user_ids"], @pack_with).to_s
    end

    hash["data"] = ::Oj.dump(hash["data"], @oj_options)

    Marshal.dump(hash)
  end

  def decode(payload)
    result = Marshal.load(payload) # rubocop:disable Security/MarshalLoad
    result["data"] = ::Oj.load(result["data"], @oj_options)

    if str = result["user_ids"]
      result["user_ids"] = FastIdList.from_string(str, @pack_with)
    end

    result
  end
end
