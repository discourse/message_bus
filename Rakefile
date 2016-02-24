require 'rubygems'
require 'rake/testtask'
require 'bundler'
require 'bundler/gem_tasks'
require 'bundler/setup'

Bundler.require(:default, :test)

task :default => [:spec]

run_spec = proc do |backend|
  begin
    ENV['MESSAGE_BUS_BACKEND'] = backend
    sh "#{FileUtils::RUBY} -e \"ARGV.each{|f| load f}\" #{Dir['spec/**/*_spec.rb'].to_a.join(' ')}"
  ensure
    ENV.delete('MESSAGE_BUS_BACKEND')
  end
end

task :spec => [:spec_redis, :spec_postgres]

task :spec_redis do
  run_spec.call('redis')
end

task :spec_postgres do
  run_spec.call('postgres')
end
