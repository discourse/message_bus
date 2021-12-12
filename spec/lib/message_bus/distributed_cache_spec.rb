# frozen_string_literal: true

require_relative '../../spec_helper'
require 'minitest/hooks/default'
require 'message_bus'
require 'message_bus/distributed_cache'

describe MessageBus::DistributedCache do
  before do
    @bus = MessageBus::Instance.new
    @bus.configure(backend: :memory)
    @manager = MessageBus::DistributedCache::Manager.new(@bus)
    @cache1 = cache(cache_name)
    @cache2 = cache(cache_name)
  end

  after do
    @bus.reset!
    @bus.destroy
  end

  def cache(name)
    MessageBus::DistributedCache.new(name, manager: @manager)
  end

  let :cache_name do
    SecureRandom.hex
  end

  it 'supports arrays with hashes' do
    c1 = cache("test1")
    c2 = cache("test1")

    c1["test"] = [{ test: :test }]

    wait_for do
      c2["test"] == [{ test: :test }]
    end

    expect(c2[:test]).must_equal([{ test: :test }])
  end

  it 'allows us to store Set' do
    c1 = cache("test1")
    c2 = cache("test1")

    set = Set.new
    set << 1
    set << "b"
    set << 92803984
    set << 93739739873973

    c1["cats"] = set

    wait_for do
      c2["cats"] == set
    end

    expect(c2["cats"]).must_equal(set)

    set << 5

    c2["cats"] = set

    wait_for do
      c1["cats"] == set
    end

    expect(c1["cats"]).must_equal(set)
  end

  it 'does not leak state across caches' do
    c2 = cache("test1")
    c3 = cache("test1")
    c2["hi"] = "hi"
    wait_for do
      c3["hi"] == "hi"
    end

    Thread.pass
    assert_nil(@cache1["hi"])
  end

  it 'allows coerces symbol keys to strings' do
    @cache1[:key] = "test"
    expect(@cache1["key"]).must_equal("test")

    wait_for do
      @cache2[:key] == "test"
    end
    expect(@cache2["key"]).must_equal("test")
  end

  it 'sets other caches' do
    @cache1["test"] = "world"
    wait_for do
      @cache2["test"] == "world"
    end
  end

  it 'deletes from other caches' do
    @cache1["foo"] = "bar"

    wait_for do
      @cache2["foo"] == "bar"
    end

    @cache1.delete("foo")
    assert_nil(@cache1["foo"])

    wait_for do
      @cache2["foo"] == nil
    end
  end

  it 'clears cache on request' do
    @cache1["foo"] = "bar"

    wait_for do
      @cache2["foo"] == "bar"
    end

    @cache1.clear
    assert_nil(@cache1["foo"])
    wait_for do
      @cache2["boom"] == nil
    end
  end
end
