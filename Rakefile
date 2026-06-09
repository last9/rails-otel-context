# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  # inherited_scope_real_ar_test loads real ActiveRecord, which conflicts with
  # the FakeRelation stub other tests rely on when all files share one process.
  # CI runs each test file in its own process, so it is still covered there.
  t.test_files = FileList['test/**/*_test.rb']
                 .exclude('test/railtie_test.rb')
                 .exclude('test/inherited_scope_real_ar_test.rb')
  t.verbose = true
end

task default: :test
