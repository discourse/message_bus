# frozen_string_literal: true

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

  def initialize
    @oj_options = { mode: :compat }
  end

  def encode(hash)
    if user_ids = hash["user_ids"]
      hash["user_ids"] = FastIdList.from_array(user_ids).to_s
    end

    ::Oj.dump(hash, @oj_options)
  end

  def decode(payload)
    result = ::Oj.load(payload, @oj_options)

    if str = result["user_ids"]
      result["user_ids"] = FastIdList.from_string(str)
    end

    result
  end
end
