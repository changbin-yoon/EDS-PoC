#!/usr/bin/env bash
#
# Compares row counts for every table across ignite / postgresql / redis.
#
# Usage: ./scripts/verify-row-counts.sh <generated-files-dir>
# (uses manifest.txt to know which tables + expected counts to check)

set -euo pipefail

GEN_DIR="${1:?usage: $0 <generated-files-dir>}"
COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')

printf "%-25s %10s %10s %10s %10s\n" "table" "expected" "ignite" "postgresql" "redis"
fail=0
while IFS='|' read -r table expected pk cols; do
  ignite=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM ignite.public.$table;" 2>/dev/null | tr -d '"')
  pg=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM postgresql.public.$table;" 2>/dev/null | tr -d '"')
  redis=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM redis.default.$table;" 2>/dev/null | tr -d '"')
  printf "%-25s %10s %10s %10s %10s\n" "$table" "$expected" "$ignite" "$pg" "$redis"
  if [ "$ignite" != "$expected" ] || [ "$pg" != "$expected" ] || [ "$redis" != "$expected" ]; then
    fail=1
  fi
done < "$GEN_DIR/manifest.txt"

if [ "$fail" -eq 1 ]; then
  echo
  echo "MISMATCH detected — see table above. Common causes:" >&2
  echo "  - redis: check the table's *.json key format is <table>:<key>, not <schema>:<table>:<key>" >&2
  echo "  - redis: check for unquoted whitespace values that broke HSET argument pairing" >&2
  echo "  - ignite/postgresql: check trino coordinator logs for OOM during load (kubectl logs -n trino)" >&2
  exit 1
fi
echo
echo "All tables match across all three engines."
