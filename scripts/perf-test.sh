#!/usr/bin/env bash
#
# Runs a comparable set of queries against ignite / postgresql (via Trino)
# on a given table and times each one (wall-clock, includes kubectl exec +
# Trino CLI startup overhead — compare relative differences between
# engines, not absolute numbers).
#
# Redis is intentionally excluded — see docs/lessons-learned.md (section 2-1).
#
# Usage:
#   ./scripts/perf-test.sh <table> <pk_column> <group_by_column>
#   ./scripts/perf-test.sh                      # defaults to the OMOP `measurement` table
#   ./scripts/perf-test.sh iot_events event_id device_id

set -euo pipefail

TABLE="${1:-measurement}"
PK_COL="${2:-measurement_id}"
GROUP_COL="${3:-measurement_concept_id}"

COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')

run_timed() {
  local label="$1" sql="$2"
  local start end elapsed
  start=$(date +%s.%N)
  kubectl exec -n trino "$COORD" -- trino --execute "$sql" > /tmp/perf_out.txt 2>&1
  end=$(date +%s.%N)
  elapsed=$(echo "$end - $start" | bc)
  printf "%-45s %8.3fs\n" "$label" "$elapsed"
}

echo "Table: $TABLE  (pk=$PK_COL, group_by=$GROUP_COL)"
echo "Picking a sample $PK_COL present in the data..."
SAMPLE_PK=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT $PK_COL FROM ignite.public.$TABLE LIMIT 1;" 2>/dev/null | tr -d '"')
echo "  $PK_COL=$SAMPLE_PK"
echo

echo "=== Q1: COUNT(*) full scan ==="
run_timed "ignite"     "SELECT count(*) FROM ignite.public.$TABLE;"
run_timed "postgresql" "SELECT count(*) FROM postgresql.public.$TABLE;"
echo

echo "=== Q2: point lookup by primary key ($PK_COL = $SAMPLE_PK) ==="
run_timed "ignite"     "SELECT * FROM ignite.public.$TABLE WHERE $PK_COL = $SAMPLE_PK;"
run_timed "postgresql" "SELECT * FROM postgresql.public.$TABLE WHERE $PK_COL = $SAMPLE_PK;"
echo

echo "=== Q3: GROUP BY aggregation (top 10 $GROUP_COL) ==="
run_timed "ignite"     "SELECT $GROUP_COL, count(*) c FROM ignite.public.$TABLE GROUP BY $GROUP_COL ORDER BY c DESC LIMIT 10;"
run_timed "postgresql" "SELECT $GROUP_COL, count(*) c FROM postgresql.public.$TABLE GROUP BY $GROUP_COL ORDER BY c DESC LIMIT 10;"
echo

echo "=== Q4: repeat Q1 (warm run) ==="
run_timed "ignite (2nd run)"     "SELECT count(*) FROM ignite.public.$TABLE;"
run_timed "postgresql (2nd run)" "SELECT count(*) FROM postgresql.public.$TABLE;"
