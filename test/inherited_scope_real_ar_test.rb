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
    scope :in_state,   ->(state:) { where(state: state) } # keyword-arg scope

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

  # Enables scope-key capture for aggregate/existence paths (count/pluck/exists?)
  # in addition to record loading.
  ActiveRecord::Relation.prepend(RailsOtelContext::ActiveRecordContext::RelationScopeCapture)

  # Reads the captured scope name at sql.active_record start, exactly as the gem's
  # own Subscriber does (the key is cleared in ensure before a block subscriber's
  # finish callback fires, so a start-reading object subscriber is required).
  SCOPE_PROBE = Object.new
  def SCOPE_PROBE.start(_name, _id, _payload)
    (@captured ||= []) << Thread.current[:_rails_otel_ctx_scope]
  end

  def SCOPE_PROBE.finish(_name, _id, _payload); end

  def SCOPE_PROBE.captured = (@captured ||= [])

  def SCOPE_PROBE.reset = (@captured = [])

  ActiveSupport::Notifications.subscribe('sql.active_record', SCOPE_PROBE)
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

  # Returns the distinct scope names captured during the SQL fired by the block.
  def scopes_seen(&)
    SCOPE_PROBE.reset
    yield
    SCOPE_PROBE.captured.compact.uniq
  end

  def test_aggregate_and_existence_queries_carry_scope_name
    OtelSecurityAssessment.create!(state: 'blocked')

    count_scopes  = scopes_seen { OtelSecurityAssessment.unresolved.count }
    sum_scopes    = scopes_seen { OtelSecurityAssessment.unresolved.sum(:id) }
    max_scopes    = scopes_seen { OtelSecurityAssessment.unresolved.maximum(:id) }
    pluck_scopes  = scopes_seen { OtelSecurityAssessment.unresolved.pluck(:id) }
    exists_scopes = scopes_seen { OtelSecurityAssessment.unresolved.exists? }
    load_scopes   = scopes_seen { OtelSecurityAssessment.unresolved.to_a }

    # count/sum/maximum all route through #calculate — one hook covers them.
    assert_equal ['unresolved'], count_scopes
    assert_equal ['unresolved'], sum_scopes
    assert_equal ['unresolved'], max_scopes
    assert_equal ['unresolved'], pluck_scopes
    assert_equal ['unresolved'], exists_scopes
    assert_equal ['unresolved'], load_scopes # record loading was already tagged
  end

  def test_aggregate_values_are_unchanged_by_scope_capture
    OtelSecurityAssessment.create!(state: 'blocked', resolved_at: nil)
    OtelSecurityAssessment.create!(state: 'blocked', resolved_at: Time.now)

    assert_equal OtelSecurityAssessment.unresolved.to_a.size, OtelSecurityAssessment.unresolved.count
    assert OtelSecurityAssessment.unresolved.exists?
    assert_equal 1, OtelSecurityAssessment.unresolved.pluck(:id).size
  end

  def test_bare_where_is_not_scope_tagged
    OtelSecurityAssessment.create!(state: 'blocked')
    # A bare relation has no scope name, so its span must not be scope-tagged.
    seen = scopes_seen { OtelSecurityAssessment.where(state: 'blocked').to_a }
    assert_empty seen
  end

  def test_inherited_scope_forwards_keyword_arguments
    OtelSecurityAssessment.create!(state: 'blocked')

    relation = OtelSecurityAssessment.in_state(state: 'blocked')
    assert_equal 1, relation.count
    assert_equal 'in_state', relation.instance_variable_get(:@_otel_scope_name)
  end
end
