# frozen_string_literal: true
require 'rubygems'
require 'rake/testtask'
require 'bundler'
require 'bundler/gem_tasks'
require 'bundler/setup'
require 'rubocop/rake_task'
require 'yard'

Bundler.require(:default, :test)

RuboCop::RakeTask.new
YARD::Rake::YardocTask.new

BACKENDS = Dir["lib/message_bus/backends/*.rb"].map { |file| file.match(%r{backends/(?<backend>.*).rb})[:backend] } - ["base"]
SPEC_FILES = Dir['spec/**/*_spec.rb']
INTEGRATION_FILES = Dir['spec/integration/**/*_spec.rb']

module CustomBuild
  def build_gem
    `cp assets/message-bus* vendor/assets/javascripts`
    super
  end
end

module Bundler
  class GemHelper
    prepend CustomBuild
  end
end

desc "Generate documentation for Yard, and fail if there are any warnings"
task :test_doc do
  sh "yard --fail-on-warning #{'--no-progress' if ENV['CI']}"
end

namespace :jasmine do
  desc "Run Jasmine tests in headless mode"
  task 'ci' do
    if !system("npx jasmine-browser-runner runSpecs")
      exit 1
    end
  end
end

namespace :spec do
  BACKENDS.each do |backend|
    desc "Run tests on the #{backend} backend"
    task backend do
      begin
        ENV['MESSAGE_BUS_BACKEND'] = backend
        Rake::TestTask.new(backend) do |t|
          t.test_files = SPEC_FILES - INTEGRATION_FILES
        end
        Rake::Task[backend].invoke
      ensure
        ENV.delete('MESSAGE_BUS_BACKEND')
      end
    end
  end

  desc "Run integration tests"
  task :integration do
    require "socket"

    def port_available?(port)
      server = TCPServer.open("0.0.0.0", port)
      server.close
      true
    rescue Errno::EADDRINUSE
      false
    end

    begin
      ENV['MESSAGE_BUS_BACKEND'] = 'memory'
      pid = spawn("bundle exec puma -p 9292 spec/fixtures/test/config.ru")
      sleep 1 while port_available?(9292)
      Rake::TestTask.new(:integration) do |t|
        t.test_files = INTEGRATION_FILES
      end
      Rake::Task[:integration].invoke
    ensure
      ENV.delete('MESSAGE_BUS_BACKEND')
      Process.kill('TERM', pid) if pid
    end
  end
end

desc "Run tests on all backends, plus client JS tests"
task spec: BACKENDS.map { |backend| "spec:#{backend}" } + ["jasmine:ci", "spec:integration"]

desc "Run performance benchmarks on all backends"
task :performance do
  begin
    ENV['MESSAGE_BUS_BACKENDS'] = BACKENDS.join(",")
    sh "#{FileUtils::RUBY} -e \"ARGV.each{|f| load f}\" #{Dir['spec/performance/*.rb'].to_a.join(' ')}"
  ensure
    ENV.delete('MESSAGE_BUS_BACKENDS')
  end
end

desc "Run all tests, link checks and confirms documentation compiles without error"
task default: [:spec, :rubocop, :test_doc]
