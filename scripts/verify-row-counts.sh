#!/usr/bin/env bash
#
# Compares row counts for every table across ignite / postgresql.
# Redis is intentionally excluded — see docs/redis-exclusion-rationale.md.
#
# Usage: ./scripts/verify-row-counts.sh <generated-files-dir>
# (uses manifest.txt to know which tables + expected counts to check)

set -euo pipefail

GEN_DIR="${1:?usage: $0 <generated-files-dir>}"
COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')

printf "%-25s %10s %10s %10s\n" "table" "expected" "ignite" "postgresql"
fail=0
while IFS='|' read -r table expected pk cols; do
  ignite=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM ignite.public.$table;" 2>/dev/null | tr -d '"')
  pg=$(kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM postgresql.public.$table;" 2>/dev/null | tr -d '"')
  printf "%-25s %10s %10s %10s\n" "$table" "$expected" "$ignite" "$pg"
  if [ "$ignite" != "$expected" ] || [ "$pg" != "$expected" ]; then
    fail=1
  fi
done < "$GEN_DIR/manifest.txt"

if [ "$fail" -eq 1 ]; then
  echo
  echo "MISMATCH detected — see table above. Common causes:" >&2
  echo "  - ignite/postgresql: check trino coordinator logs for OOM during load (kubectl logs -n trino)" >&2
  echo "  - check bulk-load-*.sh output for COPY errors (column order/type mismatch)" >&2
  exit 1
fi
echo
echo "All tables match across both engines."
