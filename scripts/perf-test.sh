#!/usr/bin/env bash
#
# Runs the same set of queries against ignite / postgresql / redis (all via
# Trino) on the `measurement` table and times each one (wall-clock, includes
# kubectl exec + Trino CLI startup overhead — compare relative differences
# between engines, not absolute numbers).
#
# Usage: ./scripts/perf-test.sh
# Requires measurement to already be loaded in all three catalogs
# (see load-test-data.sh).

set -euo pipefail

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

echo "Picking a sample person_id / measurement_id present in the data..."
SAMPLE_PERSON_ID=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT person_id FROM ignite.public.measurement LIMIT 1;" 2>/dev/null | tr -d '"')
SAMPLE_MEASUREMENT_ID=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT measurement_id FROM ignite.public.measurement LIMIT 1;" 2>/dev/null | tr -d '"')
echo "  person_id=$SAMPLE_PERSON_ID measurement_id=$SAMPLE_MEASUREMENT_ID"
echo

echo "=== Q1: COUNT(*) full scan ==="
run_timed "ignite.public.measurement"     "SELECT count(*) FROM ignite.public.measurement;"
run_timed "postgresql.public.measurement" "SELECT count(*) FROM postgresql.public.measurement;"
run_timed "redis.default.measurement"     "SELECT count(*) FROM redis.default.measurement;"
echo

echo "=== Q2: filter on non-indexed column (person_id = $SAMPLE_PERSON_ID) ==="
run_timed "ignite"     "SELECT count(*) FROM ignite.public.measurement WHERE person_id = $SAMPLE_PERSON_ID;"
run_timed "postgresql" "SELECT count(*) FROM postgresql.public.measurement WHERE person_id = $SAMPLE_PERSON_ID;"
run_timed "redis"      "SELECT count(*) FROM redis.default.measurement WHERE person_id = $SAMPLE_PERSON_ID;"
echo

echo "=== Q3: point lookup by primary key (measurement_id = $SAMPLE_MEASUREMENT_ID) ==="
run_timed "ignite"     "SELECT * FROM ignite.public.measurement WHERE measurement_id = $SAMPLE_MEASUREMENT_ID;"
run_timed "postgresql" "SELECT * FROM postgresql.public.measurement WHERE measurement_id = $SAMPLE_MEASUREMENT_ID;"
run_timed "redis"      "SELECT * FROM redis.default.measurement WHERE measurement_id = $SAMPLE_MEASUREMENT_ID;"
echo

echo "=== Q4: GROUP BY aggregation (top 10 measurement_concept_id) ==="
run_timed "ignite"     "SELECT measurement_concept_id, count(*) c, avg(value_as_number) FROM ignite.public.measurement GROUP BY measurement_concept_id ORDER BY c DESC LIMIT 10;"
run_timed "postgresql" "SELECT measurement_concept_id, count(*) c, avg(value_as_number) FROM postgresql.public.measurement GROUP BY measurement_concept_id ORDER BY c DESC LIMIT 10;"
run_timed "redis"      "SELECT measurement_concept_id, count(*) c, avg(value_as_number) FROM redis.default.measurement GROUP BY measurement_concept_id ORDER BY c DESC LIMIT 10;"
echo

echo "=== Q5: JOIN measurement x person (same catalog) ==="
run_timed "ignite"     "SELECT p.gender_concept_id, count(*) FROM ignite.public.measurement m JOIN ignite.public.person p ON m.person_id = p.person_id GROUP BY p.gender_concept_id;"
run_timed "postgresql" "SELECT p.gender_concept_id, count(*) FROM postgresql.public.measurement m JOIN postgresql.public.person p ON m.person_id = p.person_id GROUP BY p.gender_concept_id;"
run_timed "redis"      "SELECT p.gender_concept_id, count(*) FROM redis.default.measurement m JOIN redis.default.person p ON m.person_id = p.person_id GROUP BY p.gender_concept_id;"
echo

echo "=== Q6: repeat Q1 (warm run) ==="
run_timed "ignite (2nd run)"     "SELECT count(*) FROM ignite.public.measurement;"
run_timed "postgresql (2nd run)" "SELECT count(*) FROM postgresql.public.measurement;"
run_timed "redis (2nd run)"      "SELECT count(*) FROM redis.default.measurement;"
