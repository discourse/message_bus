Jasmine.configure do |config|
  # patch for travis
  if ENV['TRAVIS']
    module ::Phantomjs
      def self.version
        @phantom_version ||= `phantomjs --version`.strip
      end
    end
  end
end
