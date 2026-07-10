#!/usr/bin/env python3
"""
Generate CREATE TABLE / INSERT SQL (for Ignite & PostgreSQL via Trino) and
Redis HSET commands + table-description JSON from the CSV files under sample/.

Column types are inferred per-file: BIGINT if every non-empty value parses as
an integer, DOUBLE if every non-empty value parses as a float, otherwise
VARCHAR. An all-empty column defaults to VARCHAR.

Usage:
  python3 scripts/generate-test-data.py [--sample-dir sample] [--out-dir /tmp/gen]

Output per table (in --out-dir):
  <table>.manifest        one line: table|row_count|primary_key_column|column_defs
  ignite_<table>.sql      CREATE TABLE ignite.public.<table> ... + batched INSERT
  pg_<table>.sql          CREATE TABLE postgresql.public.<table> ... + batched INSERT
  <table>.hset.txt        one HSET command per row, key = "<table>:<pk_value>"
  <table>.redis.json      Trino Redis connector table-description JSON
"""
import argparse
import csv
import os

# Tables whose row width/size warrant a smaller INSERT batch to avoid
# overloading the Trino coordinator's query-parsing memory (see docs/ —
# a 500-row batch on the widest table OOMKilled a 2Gi coordinator once).
LARGE_TABLE_BATCH = 150
DEFAULT_BATCH = 500


def is_int(v):
    if v == "":
        return True
    try:
        int(v)
        return True
    except ValueError:
        return False


def is_float(v):
    if v == "":
        return True
    try:
        float(v)
        return True
    except ValueError:
        return False


def infer_types(header, rows):
    types = []
    for i in range(len(header)):
        non_empty = [r[i] for r in rows if r[i] != ""]
        if not non_empty:
            types.append("VARCHAR")
        elif all(is_int(v) for v in non_empty):
            types.append("BIGINT")
        elif all(is_float(v) for v in non_empty):
            types.append("DOUBLE")
        else:
            types.append("VARCHAR")
    return types


def sql_lit(val, typ):
    if val == "":
        return "NULL"
    if typ in ("BIGINT", "DOUBLE"):
        return val
    return "'" + val.replace("'", "''") + "'"


def hset_token(val):
    # Quote values containing whitespace so redis-cli doesn't split them into
    # extra tokens, which breaks HSET's field/value pairing.
    return f'"{val}"' if " " in val else val


def process_file(path, out_dir):
    fname = os.path.basename(path)
    table = fname.split(".", 1)[1].rsplit(".csv", 1)[0].lower() if fname[0].isdigit() else fname.rsplit(".csv", 1)[0].lower()

    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = [h.lower() for h in next(reader)]
        rows = [r for r in reader if len(r) == len(header) and r and r[0] != ""]

    types = infer_types(header, rows)
    pk = header[0]
    cols_def = ", ".join(f"{c} {t}" for c, t in zip(header, types))
    batch_size = LARGE_TABLE_BATCH if len(rows) > 10000 or len(header) > 18 else DEFAULT_BATCH

    # CREATE + INSERT (generic, {TABLE} placeholder substituted per-catalog)
    insert_path = os.path.join(out_dir, f"{table}.insert.sql")
    with open(insert_path, "w") as f:
        for i in range(0, len(rows), batch_size):
            batch = rows[i:i + batch_size]
            values = ", ".join(
                "(" + ", ".join(sql_lit(v, t) for v, t in zip(r, types)) + ")"
                for r in batch
            )
            f.write("INSERT INTO {TABLE} VALUES " + values + ";\n")

    for catalog, prefix in (("ignite", "ignite"), ("postgresql", "pg")):
        create = (
            f"CREATE TABLE {catalog}.public.{table} ({cols_def})"
            + (f" WITH (primary_key = ARRAY['{pk}'])" if catalog == "ignite" else "")
            + ";\n"
        )
        with open(os.path.join(out_dir, f"{prefix}_{table}.sql"), "w") as out:
            out.write(create)
            with open(insert_path) as ins:
                out.write(ins.read().replace("{TABLE}", f"{catalog}.public.{table}"))

    # Redis HSET commands
    with open(os.path.join(out_dir, f"{table}.hset.txt"), "w") as f:
        for r in rows:
            key = f"{table}:{r[0]}"
            parts = [f"HSET {key}"]
            for c, v in zip(header, r):
                if v != "":
                    parts.append(c)
                    parts.append(hset_token(v))
            if len(parts) > 1:
                f.write(" ".join(parts) + "\n")

    # Redis table-description JSON
    fields = []
    for c, t in zip(header, types):
        rtype = {"BIGINT": "bigint", "DOUBLE": "double"}.get(t, "varchar")
        fields.append(f'          {{\n            "name": "{c}",\n            "type": "{rtype}",\n            "mapping": "{c}"\n          }}')
    json_str = (
        "{\n"
        f'      "tableName": "{table}",\n'
        '      "schemaName": "default",\n'
        '      "key": {\n'
        '        "dataFormat": "raw",\n'
        '        "fields": [\n'
        '          {\n'
        '            "name": "redis_key",\n'
        '            "type": "varchar",\n'
        '            "hidden": true\n'
        '          }\n'
        '        ]\n'
        '      },\n'
        '      "value": {\n'
        '        "dataFormat": "hash",\n'
        '        "fields": [\n' + ",\n".join(fields) + "\n        ]\n      }\n    }"
    )
    with open(os.path.join(out_dir, f"{table}.redis.json"), "w") as f:
        f.write(json_str)

    with open(os.path.join(out_dir, "manifest.txt"), "a") as f:
        f.write(f"{table}|{len(rows)}|{pk}|{cols_def}\n")

    return table, len(rows), pk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample-dir", default=os.path.join(os.path.dirname(__file__), "..", "sample"))
    ap.add_argument("--out-dir", default="/tmp/eds-poc-gen")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    manifest_path = os.path.join(args.out_dir, "manifest.txt")
    if os.path.exists(manifest_path):
        os.remove(manifest_path)

    csvs = sorted(
        (f for f in os.listdir(args.sample_dir) if f.lower().endswith(".csv")),
        key=lambda f: int(f.split(".", 1)[0]) if f.split(".", 1)[0].isdigit() else 999,
    )
    for fname in csvs:
        table, n, pk = process_file(os.path.join(args.sample_dir, fname), args.out_dir)
        print(f"{table}: {n} rows, pk={pk}")

    print(f"\nGenerated files under {args.out_dir}")


if __name__ == "__main__":
    main()
