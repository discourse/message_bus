# frozen_string_literal: true

class MarshalCodec
  def encode(hash)
    ::Marshal.dump(hash)
  end

  def decode(payload)
    ::Marshal.load(payload) # rubocop:disable Security/MarshalLoad
  end
end
