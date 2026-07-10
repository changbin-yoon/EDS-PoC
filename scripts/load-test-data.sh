#!/usr/bin/env bash
#
# Loads the SQL files produced by generate-test-data.py into ignite /
# postgresql (both via Trino). For small/medium datasets (the OMOP sample
# data this was built for tops out around 46K rows/table) Trino INSERT is
# fine; for multi-million-row loads use bulk-load-postgresql.sh /
# bulk-load-ignite.sh instead (native COPY, much faster).
#
# Redis is intentionally excluded — see docs/redis-exclusion-rationale.md.
#
# Usage:
#   python3 scripts/generate-test-data.py --out-dir /tmp/eds-poc-gen
#   ./scripts/load-test-data.sh /tmp/eds-poc-gen
#
# Requires: KUBECONFIG set, kubectl access to the trino namespace.

set -euo pipefail

GEN_DIR="${1:?usage: $0 <generated-files-dir>}"
[ -f "$GEN_DIR/manifest.txt" ] || { echo "manifest.txt not found in $GEN_DIR — run generate-test-data.py first" >&2; exit 1; }

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$1"; }

COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
log "trino coordinator: $COORD"

while IFS='|' read -r table n pk cols; do
  for prefix in ignite pg; do
    log "loading $table into ${prefix} ($n rows)"
    cat "$GEN_DIR/${prefix}_${table}.sql" | kubectl exec -i -n trino "$COORD" -- sh -c "cat > /tmp/load_${prefix}_${table}.sql"
    kubectl exec -n trino "$COORD" -- trino -f "/tmp/load_${prefix}_${table}.sql"
  done
done < "$GEN_DIR/manifest.txt"

log "done. Run verify-row-counts.sh to confirm."
