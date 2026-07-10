#!/usr/bin/env python3
"""
Schema-driven synthetic data generator. Reads a JSON schema describing a
table's columns/types/value-generation rules and writes a headerless CSV
suitable for native bulk loading (psql \\copy for PostgreSQL, Ignite's
native COPY command for Ignite) — Trino's row-by-row INSERT is far too slow
at millions-of-rows scale, so this file is meant to be loaded by
bulk-load-postgresql.sh / bulk-load-ignite.sh, not through Trino.

Uses only the Python standard library (random, csv, datetime, string) so it
runs unmodified in an airgapped environment with no pip installs needed.

Usage:
  python3 scripts/generate-synthetic-data.py --schema scripts/schema-example.json \
      --rows 9000000 --out /tmp/synthetic.csv

Schema JSON format:
{
  "table": "iot_events",
  "primary_key": "event_id",
  "columns": [
    {"name": "event_id",   "type": "bigint",  "gen": "sequence", "start": 1},
    {"name": "device_id",  "type": "bigint",  "gen": "random_int", "min": 1, "max": 50000},
    {"name": "event_type", "type": "varchar", "gen": "choice", "values": ["TEMP", "HUMIDITY", "PRESSURE"]},
    {"name": "value",      "type": "double",  "gen": "random_float", "min": 0, "max": 1000, "decimals": 2},
    {"name": "event_ts",   "type": "varchar", "gen": "random_datetime", "start": "2026-01-01", "end": "2026-12-31"},
    {"name": "note",       "type": "varchar", "gen": "random_string", "length": 16},
    {"name": "site_code",  "type": "varchar", "gen": "choice", "values": ["A1", "B2", "C3"], "null_rate": 0.1}
  ]
}

Supported "gen" strategies:
  sequence         - incrementing integer, starting at "start" (default 1)
  random_int        - uniform random integer in [min, max]
  random_float       - uniform random float in [min, max], rounded to "decimals" (default 2)
  choice            - uniform random pick from "values"
  random_string      - random alphanumeric string of length "length" (default 10)
  random_date        - random date (YYYY-MM-DD) between "start" and "end" (YYYY-MM-DD)
  random_datetime     - random datetime (YYYY-MM-DD HH:MM:SS) between "start" and "end" (YYYY-MM-DD)

Any column may add "null_rate": 0.0-1.0 to randomly emit empty values (mimics
the real-world sparsity seen in the OMOP sample data - many source columns
were mostly/entirely NULL).
"""
import argparse
import csv
import json
import random
import string
import sys
from datetime import datetime, timedelta

TRINO_TYPE_MAP = {"bigint": "BIGINT", "double": "DOUBLE", "varchar": "VARCHAR"}


def parse_date(s):
    return datetime.strptime(s, "%Y-%m-%d")


def make_generator(col):
    gen = col["gen"]
    null_rate = col.get("null_rate", 0.0)

    if gen == "sequence":
        start = col.get("start", 1)
        counter = {"n": start - 1}

        def f():
            counter["n"] += 1
            return str(counter["n"])
        return f

    if gen == "random_int":
        lo, hi = col["min"], col["max"]

        def f():
            if random.random() < null_rate:
                return ""
            return str(random.randint(lo, hi))
        return f

    if gen == "random_float":
        lo, hi = col["min"], col["max"]
        decimals = col.get("decimals", 2)

        def f():
            if random.random() < null_rate:
                return ""
            return f"{random.uniform(lo, hi):.{decimals}f}"
        return f

    if gen == "choice":
        values = col["values"]

        def f():
            if random.random() < null_rate:
                return ""
            return str(random.choice(values))
        return f

    if gen == "random_string":
        length = col.get("length", 10)
        alphabet = string.ascii_letters + string.digits

        def f():
            if random.random() < null_rate:
                return ""
            return "".join(random.choices(alphabet, k=length))
        return f

    if gen == "random_date":
        start = parse_date(col["start"])
        end = parse_date(col["end"])
        span_days = (end - start).days

        def f():
            if random.random() < null_rate:
                return ""
            d = start + timedelta(days=random.randint(0, span_days))
            return d.strftime("%Y-%m-%d")
        return f

    if gen == "random_datetime":
        start = parse_date(col["start"])
        end = parse_date(col["end"])
        span_seconds = int((end - start).total_seconds())

        def f():
            if random.random() < null_rate:
                return ""
            d = start + timedelta(seconds=random.randint(0, max(span_seconds, 1)))
            return d.strftime("%Y-%m-%d %H:%M:%S")
        return f

    raise ValueError(f"unknown gen strategy: {gen}")


def create_table_sql(schema, catalog):
    cols_def = ", ".join(f"{c['name']} {TRINO_TYPE_MAP[c['type']]}" for c in schema["columns"])
    pk = schema["primary_key"]
    table = schema["table"]
    if catalog == "ignite":
        return f"CREATE TABLE ignite.public.{table} ({cols_def}) WITH (primary_key = ARRAY['{pk}']);"
    return f"CREATE TABLE postgresql.public.{table} ({cols_def});"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", required=True, help="path to schema JSON file")
    ap.add_argument("--rows", type=int, default=9_000_000)
    ap.add_argument("--out", required=True, help="output CSV path (no header row)")
    ap.add_argument("--seed", type=int, default=None, help="random seed for reproducibility")
    ap.add_argument("--progress-every", type=int, default=500_000)
    args = ap.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    with open(args.schema) as f:
        schema = json.load(f)

    generators = [make_generator(c) for c in schema["columns"]]
    col_names = [c["name"] for c in schema["columns"]]

    # Emit the CREATE TABLE statements next to the schema so callers can
    # `trino -f` them before bulk-loading.
    for catalog in ("ignite", "postgresql"):
        ddl_path = args.out + f".{catalog}.create.sql"
        with open(ddl_path, "w") as f:
            f.write(create_table_sql(schema, catalog) + "\n")
        print(f"wrote {ddl_path}")

    with open(args.out, "w", newline="") as f:
        writer = csv.writer(f)
        for i in range(1, args.rows + 1):
            writer.writerow([g() for g in generators])
            if i % args.progress_every == 0:
                print(f"  {i:,} / {args.rows:,} rows generated", file=sys.stderr)

    print(f"\nDone: {args.rows:,} rows -> {args.out}")
    print(f"table={schema['table']} primary_key={schema['primary_key']} columns={','.join(col_names)}")


if __name__ == "__main__":
    main()
