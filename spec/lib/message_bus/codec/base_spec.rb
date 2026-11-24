# frozen_string_literal: true

require_relative '../../../spec_helper'

describe MessageBus::Codec::Base do
  it "raises ConcreteClassMustImplementError from encode" do
    assert_raises(MessageBus::Codec::Base::ConcreteClassMustImplementError) do
      MessageBus::Codec::Base.new.encode({})
    end
  end

  it "raises ConcreteClassMustImplementError from decode" do
    assert_raises(MessageBus::Codec::Base::ConcreteClassMustImplementError) do
      MessageBus::Codec::Base.new.decode("{}")
    end
  end
end
