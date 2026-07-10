#!/usr/bin/env bash
#
# Native bulk load into PostgreSQL via `psql \copy` — Trino's row-by-row
# INSERT is far too slow at millions-of-rows scale (Trino doesn't expose
# COPY through any connector), so this bypasses Trino for the load step
# and uses the postgres container directly. Trino still sees the result
# immediately afterward since it's the same underlying table.
#
# Usage:
#   python3 scripts/generate-synthetic-data.py --schema scripts/schema-example.json \
#       --rows 9000000 --out /tmp/synthetic.csv
#   ./scripts/bulk-load-postgresql.sh /tmp/synthetic.csv
#
# Expects the sibling DDL file <csv>.postgresql.create.sql (written by
# generate-synthetic-data.py) to exist next to the CSV.

set -euo pipefail

CSV="${1:?usage: $0 <csv-file>}"
DDL="${CSV}.postgresql.create.sql"
[ -f "$DDL" ] || { echo "missing $DDL" >&2; exit 1; }

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$1"; }

COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
PG_POD=$(kubectl get pod -n cnpg -l cnpg.io/cluster=eds-pg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Column list + table name, derived from the CREATE TABLE statement itself
# so this script doesn't need its own copy of the schema.
TABLE=$(grep -oP '(?<=postgresql\.public\.)\w+' "$DDL")
COLS=$(grep -oP '(?<=\().*(?=\))' "$DDL" | tr ',' '\n' | awk '{print $1}' | paste -sd, -)

log "creating table postgresql.public.$TABLE via Trino"
cat "$DDL" | kubectl exec -i -n trino "$COORD" -- sh -c 'cat > /tmp/create_pg.sql'
kubectl exec -n trino "$COORD" -- trino -f /tmp/create_pg.sql

log "copying $(du -h "$CSV" | cut -f1) CSV into $PG_POD:/controller/synthetic.csv"
kubectl cp "$CSV" "cnpg/${PG_POD}:/controller/synthetic.csv"

log "running \\copy (columns: $COLS)"
kubectl exec -n cnpg "$PG_POD" -- psql -U postgres -d eds -c \
  "\\copy ${TABLE} (${COLS}) FROM '/controller/synthetic.csv' WITH (FORMAT csv, NULL '')"

log "cleaning up staged file"
kubectl exec -n cnpg "$PG_POD" -- rm -f /controller/synthetic.csv

log "verifying row count"
kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM postgresql.public.${TABLE};"
