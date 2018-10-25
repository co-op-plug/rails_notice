$:.push File.expand_path('lib', __dir__)
require 'rails_notice/version'

Gem::Specification.new do |s|
  s.name = 'rails_notice'
  s.version = RailsNotice::VERSION
  s.authors = ['qinmingyuan']
  s.email = ['mingyuan0715@foxmail.com']
  s.homepage = 'https://github.com/yougexiangfa/rails_notice'
  s.summary = 'Notification Center for Rails Application'
  s.description = 'Description of RailsNotice.'
  s.license = 'LGPL-3.0'

  s.files = Dir[
    '{app,config,db,lib}/**/*',
    'LICENSE',
    'Rakefile',
    'README.md'
  ]

  s.add_dependency 'rails', '>= 5.0', '<= 6.0'
end