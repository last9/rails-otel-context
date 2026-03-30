#!/usr/bin/env bash
# autoresearch benchmark — outputs METRIC lines consumed by the loop
set -euo pipefail

export RAILS_OTEL_CONTEXT_TEST=true

# Run allocation guard and extract per-call counts
output=$(ruby bench/allocation_guard.rb 2>&1)
echo "$output"

named=$(echo "$output" | grep "named query" | grep -oE '[0-9]+\.[0-9]+' | head -1)
sql=$(echo "$output"   | grep "SQL-named"   | grep -oE '[0-9]+\.[0-9]+' | head -1)

echo ""
echo "METRIC named_allocs_per_call=${named}"
echo "METRIC sql_allocs_per_call=${sql}"
echo "METRIC total_allocs=$( echo "$named + $sql" | bc )"

# Also run tests to catch regressions
ruby -Itest -e "
  require 'minitest/autorun'
  require_relative 'test/activerecord_context_test'
  require_relative 'test/configuration_test'
  require_relative 'test/request_context_test'
" 2>&1 | tail -3

echo "METRIC tests_passed=$(ruby -Itest -e "
  require 'minitest'
  require_relative 'test/activerecord_context_test'
  require_relative 'test/configuration_test'
  require_relative 'test/request_context_test'
  Minitest.run([]) ? 1 : 0
" 2>/dev/null || echo 0)"
