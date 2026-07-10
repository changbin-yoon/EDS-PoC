#!/usr/bin/env bash
#
# Loads the SQL/HSET files produced by generate-test-data.py into
# ignite / postgresql (both via Trino) and redis (directly via redis-cli).
#
# Usage:
#   python3 scripts/generate-test-data.py --out-dir /tmp/eds-poc-gen
#   ./scripts/load-test-data.sh /tmp/eds-poc-gen
#
# Requires: KUBECONFIG set, kubectl access to trino/ignite/redis namespaces.

set -euo pipefail

GEN_DIR="${1:?usage: $0 <generated-files-dir>}"
[ -f "$GEN_DIR/manifest.txt" ] || { echo "manifest.txt not found in $GEN_DIR — run generate-test-data.py first" >&2; exit 1; }

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$1"; }

COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
REDIS_POD=$(kubectl get pod -n redis -l app=redis -o jsonpath='{.items[0].metadata.name}')
log "trino coordinator: $COORD"
log "redis pod: $REDIS_POD"

# ── 1. Rebuild the Redis table-description ConfigMap from the generated
#      *.redis.json files (this REPLACES trino-redis-tables entirely, so
#      re-add any manually-created table descriptions to $GEN_DIR first
#      if you need them to survive) ──────────────────────────────────────
TMP_JSON_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_JSON_DIR"' EXIT
while IFS='|' read -r table _ _ _; do
  cp "$GEN_DIR/${table}.redis.json" "$TMP_JSON_DIR/${table}.json"
done < "$GEN_DIR/manifest.txt"

log "rebuilding trino-redis-tables ConfigMap from generated table descriptions"
kubectl create configmap trino-redis-tables -n trino \
  --from-file="$TMP_JSON_DIR" \
  --dry-run=client -o yaml | kubectl apply -f -

log "restarting trino coordinator to pick up new redis table descriptions"
kubectl rollout restart deployment/trino-coordinator -n trino
kubectl rollout status deployment/trino-coordinator -n trino --timeout=180s
COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')

# ── 2. Ignite + PostgreSQL: CREATE TABLE + INSERT via Trino ────────────────
while IFS='|' read -r table n pk cols; do
  for prefix in ignite pg; do
    log "loading $table into ${prefix} ($n rows)"
    cat "$GEN_DIR/${prefix}_${table}.sql" | kubectl exec -i -n trino "$COORD" -- sh -c "cat > /tmp/load_${prefix}_${table}.sql"
    kubectl exec -n trino "$COORD" -- trino -f "/tmp/load_${prefix}_${table}.sql"
  done
done < "$GEN_DIR/manifest.txt"

# ── 3. Redis: HSET via redis-cli ────────────────────────────────────────────
while IFS='|' read -r table n pk cols; do
  log "loading $table into redis ($n rows)"
  cat "$GEN_DIR/${table}.hset.txt" | kubectl exec -i -n redis "$REDIS_POD" -- redis-cli --no-auth-warning -a edsuser123 > /dev/null
done < "$GEN_DIR/manifest.txt"

log "done. Run verify-row-counts.sh to confirm."
