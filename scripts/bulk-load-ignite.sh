#!/usr/bin/env bash
#
# Native bulk load into Ignite via its SQL `COPY` command (through sqlline,
# bundled in the Ignite image) — Trino's connector doesn't support COPY and
# row-by-row INSERT is far too slow at millions-of-rows scale.
#
# Usage:
#   python3 scripts/generate-synthetic-data.py --schema scripts/schema-example.json \
#       --rows 9000000 --out /tmp/synthetic.csv
#   ./scripts/bulk-load-ignite.sh /tmp/synthetic.csv
#
# Expects the sibling DDL file <csv>.ignite.create.sql (written by
# generate-synthetic-data.py) to exist next to the CSV.

set -euo pipefail

CSV="${1:?usage: $0 <csv-file>}"
DDL="${CSV}.ignite.create.sql"
[ -f "$DDL" ] || { echo "missing $DDL" >&2; exit 1; }

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$1"; }

COORD=$(kubectl get pod -n trino -l app=trino -o jsonpath='{.items[0].metadata.name}')
IGNITE_POD=$(kubectl get pod -n ignite -l app=ignite -o jsonpath='{.items[0].metadata.name}')

TABLE=$(grep -oP '(?<=ignite\.public\.)\w+' "$DDL")
COLS=$(grep -oP '(?<=\().*(?=\) WITH)' "$DDL" | tr ',' '\n' | awk '{print $1}' | paste -sd, -)

log "creating table ignite.public.$TABLE via Trino"
cat "$DDL" | kubectl exec -i -n trino "$COORD" -- sh -c 'cat > /tmp/create_ignite.sql'
kubectl exec -n trino "$COORD" -- trino -f /tmp/create_ignite.sql

log "copying $(du -h "$CSV" | cut -f1) CSV into $IGNITE_POD:/opt/ignite/work/synthetic.csv"
kubectl cp "$CSV" "ignite/${IGNITE_POD}:/opt/ignite/work/synthetic.csv"

log "running native COPY (columns: $COLS) via sqlline"
kubectl exec -n ignite "$IGNITE_POD" -- /opt/ignite/apache-ignite/bin/sqlline.sh \
  -u "jdbc:ignite:thin://127.0.0.1:10800/" \
  -n ignite -p ignite \
  --connectInteractionMode=notAskCredentials \
  -e "COPY FROM '/opt/ignite/work/synthetic.csv' INTO PUBLIC.${TABLE} (${COLS}) FORMAT CSV;"

log "cleaning up staged file"
kubectl exec -n ignite "$IGNITE_POD" -- rm -f /opt/ignite/work/synthetic.csv

log "verifying row count"
kubectl exec -n trino "$COORD" -- trino --execute "SELECT count(*) FROM ignite.public.${TABLE};"
