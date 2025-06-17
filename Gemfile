source 'https://rubygems.org/'

gemspec

gem 'debug',         group: [:development, :test]
gem 'cliver',        group: [:development, :test]
gem 'lz4-ruby',      group: [:development, :test]
gem 'rake-compiler', group: [:development, :test]
gem 'snappy',        group: [:development, :test]
gem 'ione', github: "hornet-network/ione", branch: "main"

group :development do
  platforms :mri_19 do
    gem 'perftools.rb'
  end
  gem 'rubocop'
end

group :test do
  gem 'ansi'
  gem 'aruba'
  gem 'cucumber'
  gem 'delorean'
  gem 'minitest'
  gem 'os'
  gem 'rspec'
  gem 'rspec-collection_matchers'
  gem 'rspec-wait'
  gem 'simplecov'
end

group :docs do
  gem 'yard'
end
