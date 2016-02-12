require 'rubygems'
require 'rake/testtask'
require 'bundler'
require 'bundler/gem_tasks'
require 'bundler/setup'

Bundler.require(:default, :test)

task :default => [:spec]

Rake::TestTask.new do |t|
  t.name = :spec
  t.pattern = 'spec/**/*_spec.rb'
end
