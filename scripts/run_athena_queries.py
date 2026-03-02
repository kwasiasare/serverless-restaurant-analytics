#!/usr/bin/env python3
"""
run_athena_queries.py
---------------------
Submits the 4 Athena SQL queries against the live clickstream table and
prints formatted results.  Uses boto3 so SQL files are read as strings —
no bash variable interpolation, no special-character mangling.

Usage:
    python3 scripts/run_athena_queries.py [--profile PROFILE] [--region REGION]
"""

import argparse
import os
import sys
import time
import boto3
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WORKGROUP   = "restaurant-analytics-workgroup"
DATABASE    = "restaurant_analytics_db"
OUTPUT_LOC  = "s3://restaurant-analytics-athena-results-629344231707/query-results/"
QUERY_DIR   = Path(__file__).parent.parent / "athena" / "queries"

QUERIES = [
    ("popular_items",    "popular_items.sql",    "Top 20 Items by Interaction (7 days)"),
    ("hourly_trends",    "hourly_trends.sql",    "Hourly Event Heatmap (7 days)"),
    ("category_analysis","category_analysis.sql","Category Analysis (30 days)"),
    ("device_breakdown", "device_breakdown.sql", "Device Breakdown (7 days)"),
]

POLL_INTERVAL = 2   # seconds between status checks
MAX_WAIT      = 120 # seconds before giving up


def load_sql(filename: str, database: str) -> str:
    """Read SQL file, substitute YOUR_DATABASE, and sanitize for Athena."""
    path = QUERY_DIR / filename
    sql  = path.read_text()
    sql  = sql.replace("YOUR_DATABASE", database)

    # Athena's API pre-validator treats ANY semicolon as a statement separator
    # — even those inside -- comments or trailing inline comments like:
    #   ORDER BY col DESC;  -- sort descending
    # None of our queries use semicolons inside string literals, so stripping
    # every semicolon is safe and the cleanest fix.
    sql = sql.replace(";", "")

    return sql


def start_query(athena, sql: str, database: str) -> str:
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": database},
        ResultConfiguration={"OutputLocation": OUTPUT_LOC},
        WorkGroup=WORKGROUP,
    )
    return resp["QueryExecutionId"]


def wait_for_query(athena, qid: str, label: str) -> str:
    """Poll until terminal state; return final state string."""
    elapsed = 0
    while elapsed < MAX_WAIT:
        resp  = athena.get_query_execution(QueryExecutionId=qid)
        state = resp["QueryExecution"]["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return state
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
        print(f"  [{label}] {state} … ({elapsed}s)", end="\r", flush=True)
    return "TIMEOUT"


def fetch_results(athena, qid: str, max_rows: int = 30):
    """Return (column_names, rows) from a succeeded query."""
    pages   = athena.get_paginator("get_query_results").paginate(QueryExecutionId=qid)
    columns = None
    rows    = []
    for page in pages:
        result_rows = page["ResultSet"]["Rows"]
        if columns is None:
            columns = [c["VarCharValue"] for c in result_rows[0]["Data"]]
            result_rows = result_rows[1:]
        for row in result_rows:
            rows.append([c.get("VarCharValue", "") for c in row["Data"]])
            if len(rows) >= max_rows:
                return columns, rows
    return columns, rows


def print_table(columns, rows, title: str):
    """Pretty-print query results."""
    print(f"\n{'='*70}")
    print(f"  {title}")
    print(f"{'='*70}")
    if not rows:
        print("  (no rows returned)")
        return
    # Calculate column widths
    widths = [len(c) for c in columns]
    for row in rows:
        for i, val in enumerate(row):
            widths[i] = max(widths[i], len(val))
    fmt = "  " + "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*columns))
    print("  " + "  ".join("-" * w for w in widths))
    for row in rows:
        print(fmt.format(*row))
    print(f"\n  ({len(rows)} rows shown)")


def main():
    parser = argparse.ArgumentParser(description="Run Athena analytics queries")
    parser.add_argument("--profile", default="iam-cli", help="AWS profile")
    parser.add_argument("--region",  default="us-east-1")
    parser.add_argument("--database", default=DATABASE)
    parser.add_argument("--queries", nargs="*",
                        help="Subset of query names to run (default: all)")
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    athena  = session.client("athena")

    targets = args.queries or [q[0] for q in QUERIES]
    selected = [q for q in QUERIES if q[0] in targets]

    print(f"\nRunning {len(selected)} Athena quer{'y' if len(selected)==1 else 'ies'} "
          f"against {args.database} …\n")

    results = {}

    # Submit all queries in parallel
    for name, filename, title in selected:
        sql = load_sql(filename, args.database)
        try:
            qid = start_query(athena, sql, args.database)
            results[name] = {"qid": qid, "title": title, "filename": filename, "error": None}
            print(f"  Submitted [{name}]  QID={qid}")
        except Exception as exc:
            results[name] = {"qid": None, "title": title, "filename": filename, "error": str(exc)}
            print(f"  FAILED    [{name}]  {exc}")

    print()

    # Wait for each and collect results
    for name, filename, title in selected:
        info = results[name]
        if info["error"] or info["qid"] is None:
            print(f"\n  SKIPPED [{name}] — submission failed: {info['error']}")
            continue
        qid = info["qid"]
        print(f"  Waiting  [{name}] …")
        state = wait_for_query(athena, qid, name)
        print(f"  {'✓' if state=='SUCCEEDED' else '✗'} [{name}] → {state}          ")

        if state == "SUCCEEDED":
            cols, rows = fetch_results(athena, qid)
            print_table(cols, rows, title)
        else:
            resp   = athena.get_query_execution(QueryExecutionId=qid)
            reason = resp["QueryExecution"]["Status"].get("StateChangeReason", "unknown")
            print(f"\n  ERROR [{name}]: {reason}")

    print("\nDone.\n")


if __name__ == "__main__":
    main()
