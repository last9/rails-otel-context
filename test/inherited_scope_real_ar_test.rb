# frozen_string_literal: true

# Load real ActiveRecord before test_helper so its FakeRelation stub
# (ActiveRecord::Relation = Class.new) does not pre-empt the real constant.
require 'active_record'
require_relative 'test_helper'

# Real-ActiveRecord regression coverage for inherited-scope receiver preservation.
# The other scope-tracking tests use FakeRelation; this one drives a real
# in-memory SQLite database so the default_scope + STI evaluation path is
# exercised end to end, the way it broke for abstract base classes.
begin
  require 'sqlite3'
  SQLITE3_FOR_SCOPE_TEST = true
rescue LoadError
  SQLITE3_FOR_SCOPE_TEST = false
end

if SQLITE3_FOR_SCOPE_TEST
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table :otel_assessments, force: true do |t|
      t.string   :type
      t.string   :kind
      t.datetime :resolved_at
      t.string   :state
      t.timestamps
    end
  end

  # Abstract-base STI model. ScopeNameTracking is extended directly onto this
  # class tree (rather than the global ActiveRecord::Base) so the patch stays
  # isolated to the test. default_scope calls the abstract `category`, which
  # only resolves correctly when the inherited scope runs with the subclass as
  # the receiver.
  class OtelAssessment < ActiveRecord::Base
    extend RailsOtelContext::ActiveRecordContext::ScopeNameTracking

    self.table_name = 'otel_assessments'

    default_scope { where(kind: category) }
    scope :unresolved, -> { where(resolved_at: nil) }
    scope :critical,   -> { where(state: %w[blocked suspended]) }

    def self.category
      raise NotImplementedError, 'Subclasses must implement category'
    end
  end

  class OtelSecurityAssessment < OtelAssessment
    def self.category = 'security'
  end

  class OtelComplianceAssessment < OtelAssessment
    def self.category = 'compliance'
  end
end

class InheritedScopeRealArTest < Minitest::Test
  def setup
    skip 'sqlite3 not installed' unless SQLITE3_FOR_SCOPE_TEST
    # unscoped bypasses default_scope (which would call the abstract category).
    OtelAssessment.unscoped.delete_all
  end

  def test_inherited_scope_on_sti_subclass_resolves_category_on_subclass
    relation = OtelSecurityAssessment.unresolved.critical

    # The bug raised NotImplementedError here because the scope body ran with
    # self == OtelAssessment, re-evaluating default_scope's abstract category.
    assert_equal [], relation.to_a
    assert_equal 'security', OtelSecurityAssessment.category
    assert_equal OtelSecurityAssessment, relation.klass
  end

  def test_inherited_scope_tags_relation_with_scope_name
    relation = OtelSecurityAssessment.unresolved
    assert_equal 'unresolved', relation.instance_variable_get(:@_otel_scope_name)
  end

  def test_inherited_scope_sql_partitions_by_sti_type_and_kind
    sql = OtelSecurityAssessment.unresolved.critical.to_sql
    assert_match(/"type" = 'OtelSecurityAssessment'/, sql)
    assert_match(/"kind" = 'security'/, sql)
    assert_match(/"resolved_at" IS NULL/, sql)
  end

  def test_inherited_scope_filters_rows_per_subclass
    OtelSecurityAssessment.create!(state: 'blocked', resolved_at: nil)
    OtelSecurityAssessment.create!(state: 'blocked', resolved_at: Time.now)
    OtelSecurityAssessment.create!(state: 'open',    resolved_at: nil)
    OtelComplianceAssessment.create!(state: 'suspended', resolved_at: nil)

    # unresolved + critical: only the blocked, not-yet-resolved security row.
    assert_equal 1, OtelSecurityAssessment.unresolved.critical.count
    # compliance is partitioned out by default_scope kind.
    assert_equal 1, OtelComplianceAssessment.unresolved.count
  end

  def test_querying_abstract_base_directly_raises
    assert_raises(NotImplementedError) { OtelAssessment.unresolved.to_a }
  end

  def test_grandchild_subclass_also_resolves_receiver
    grandchild = Class.new(OtelSecurityAssessment)
    def grandchild.category = 'security'
    assert_equal [], grandchild.unresolved.critical.to_a
  end
end
