require 'rubygems'
require 'rake/testtask'
require 'bundler'
require 'bundler/gem_tasks'
require 'bundler/setup'
require 'jasmine'

ENV['JASMINE_CONFIG_PATH'] ||= File.join(Dir.pwd, 'spec', 'assets', 'support', 'jasmine.yml')
load 'jasmine/tasks/jasmine.rake'

require 'rubocop/rake_task'
RuboCop::RakeTask.new

require 'yard'
YARD::Rake::YardocTask.new

desc "Generate documentation for Yard, and fail if there are any warnings"
task :test_doc do
  sh "yard --fail-on-warning #{'--no-progress' if ENV['CI']}"
end

Bundler.require(:default, :test)

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

task spec_client_js: 'jasmine:ci'

backends = Dir["lib/message_bus/backends/*.rb"].map { |file| file.match(%r{backends/(?<backend>.*).rb})[:backend] } - ["base"]

namespace :spec do
  spec_files = Dir['spec/**/*_spec.rb']
  integration_files = Dir['spec/integration/**/*_spec.rb']

  backends.each do |backend|
    desc "Run tests on the #{backend} backend"
    task backend do
      begin
        ENV['MESSAGE_BUS_BACKEND'] = backend
        sh "#{FileUtils::RUBY} -e \"ARGV.each{|f| load f}\" #{(spec_files - integration_files).to_a.join(' ')}"
      ensure
        ENV.delete('MESSAGE_BUS_BACKEND')
      end
    end
  end

  desc "Run integration tests"
  task :integration do
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
      sh "#{FileUtils::RUBY} -e \"ARGV.each{|f| load f}\" #{integration_files.to_a.join(' ')}"
    ensure
      ENV.delete('MESSAGE_BUS_BACKEND')
      Process.kill('TERM', pid) if pid
    end
  end
end

desc "Run tests on all backends, plus client JS tests"
task spec: backends.map { |backend| "spec:#{backend}" } + [:spec_client_js, "spec:integration"]

desc "Run performance benchmarks on all backends"
task :performance do
  begin
    ENV['MESSAGE_BUS_BACKENDS'] = backends.join(",")
    sh "#{FileUtils::RUBY} -e \"ARGV.each{|f| load f}\" #{Dir['spec/performance/*.rb'].to_a.join(' ')}"
  ensure
    ENV.delete('MESSAGE_BUS_BACKENDS')
  end
end

desc "Run all tests, link checks and confirms documentation compiles without error"
task default: [:spec, :rubocop, :test_doc]
