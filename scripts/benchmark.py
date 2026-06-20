"""Phase 7 - Performance benchmarking for the Optimum Buluşma Noktası project.

Measures how the two optimum queries scale as the number of people (K) and the
number of candidate targets (H) grow:

  * Variant A (Euclidean): CROSS JOIN persons × candidates, ST_Distance in EPSG:32635.
  * Variant B (road network): pgr_dijkstraCost K×H matrix over the `ways` graph.

Methodology (standard PostgreSQL benchmarking practice):
  * The production tables (persons K=10, candidates) are NEVER modified. Instead the
    K person locations and H candidate locations are sampled and passed into the query
    as id/vertex arrays, so we can sweep K and H freely against the frozen, audited data.
  * Persons are sampled from the routable largest connected component
    (`main_component_vertices`) so every Variant B start point is reachable - mirroring
    how 03_generate_persons.sql constrains real persons. A benchmark "person" is a graph
    vertex (snap distance 0); Variant A uses the same vertices so both variants run on an
    identical person set for a fair comparison.
  * Samples are nested and deterministic (ordered by md5(id)): the K=2 set is a subset of
    K=10, etc., giving smooth, reproducible scaling curves.
  * For each (variant, K, H) cell: one warm-up execution (warms shared_buffers / OS cache,
    result discarded), then --runs timed executions. Timing is the server-side
    "Execution Time" reported by EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), which excludes
    client/network overhead. Planning time and buffer hits/reads are also recorded.
  * Raw per-run rows are written to outputs/benchmarks.csv; plot_performance.py aggregates
    to the median per cell.

Usage:
    python scripts/benchmark.py                 # full PLAN grid
    python scripts/benchmark.py --quick         # tiny grid for a smoke test
    python scripts/benchmark.py --runs 7 --kgrid 2,10,50 --hgrid 2,10,50
"""

from __future__ import annotations

import argparse
import csv
import os
import statistics
import sys
import time

import psycopg2

# --------------------------------------------------------------------------- #
# Connection
# --------------------------------------------------------------------------- #
DB = dict(
    host=os.environ.get("PGHOST", "localhost"),
    port=int(os.environ.get("PGPORT", "5432")),
    user=os.environ.get("PGUSER", "postgres"),
    password=os.environ.get("PGPASSWORD", "admin"),
    dbname=os.environ.get("PGDATABASE", "istanbul_gis"),
)

# --------------------------------------------------------------------------- #
# Default benchmark grid (from PLAN.md Phase 7)
# --------------------------------------------------------------------------- #
K_GRID = [2, 10, 50, 100, 500, 1000]
H_GRID = [2, 10, 50, 100, 500]

# Edge graph used by both pgr_dijkstraCost calls (travel time in seconds; one-way
# streets encoded as negative reverse_cost_s / cost_s).
EDGES_SQL = (
    "SELECT id, source, target, cost_s AS cost, reverse_cost_s AS reverse_cost FROM ways"
)

# --------------------------------------------------------------------------- #
# Timed queries. Both mirror the production scripts (10 / 21) but take the person
# and candidate sets as parameter arrays instead of reading the fixed tables.
# --------------------------------------------------------------------------- #
QUERY_EUCLIDEAN = """
WITH persons_utm AS MATERIALIZED (
    SELECT id, ST_Transform(geom, 32635) AS geom
    FROM ways_vertices_pgr WHERE id = ANY(%(pvids)s)
),
candidates_utm AS MATERIALIZED (
    SELECT id, ST_Transform(geom, 32635) AS geom
    FROM candidates WHERE id = ANY(%(cids)s)
),
pairs AS (
    SELECT c.id, ST_Distance(p.geom, c.geom) AS distance_m
    FROM candidates_utm c CROSS JOIN persons_utm p
),
scored AS (
    SELECT id, sum(distance_m) AS total_distance_m, max(distance_m) AS max_distance_m
    FROM pairs GROUP BY id
),
ranked AS (
    SELECT id, total_distance_m, max_distance_m,
           rank() OVER (ORDER BY total_distance_m) AS rank_minsum,
           rank() OVER (ORDER BY max_distance_m)   AS rank_minmax
    FROM scored
)
SELECT id, total_distance_m, max_distance_m, rank_minsum, rank_minmax
FROM ranked
WHERE rank_minsum <= 5 OR rank_minmax <= 5
ORDER BY rank_minsum, rank_minmax
"""

QUERY_NETWORK = """
WITH matrix AS (
    SELECT start_vid, end_vid, agg_cost AS cost_s
    FROM pgr_dijkstraCost(%(edges)s, %(pvids)s::bigint[], %(cvids)s::bigint[], directed := true)
),
scored AS (
    SELECT end_vid AS cand_vid,
           sum(cost_s) AS total_cost_s, max(cost_s) AS max_cost_s
    FROM matrix
    GROUP BY end_vid
    HAVING count(DISTINCT start_vid) = %(k)s
),
ranked AS (
    SELECT cand_vid, total_cost_s, max_cost_s,
           rank() OVER (ORDER BY total_cost_s) AS rank_minsum,
           rank() OVER (ORDER BY max_cost_s)   AS rank_minmax
    FROM scored
)
SELECT cand_vid, total_cost_s, max_cost_s, rank_minsum, rank_minmax
FROM ranked
WHERE rank_minsum <= 5 OR rank_minmax <= 5
ORDER BY rank_minsum, rank_minmax
"""


def fetch_pools(cur, max_k, max_h):
    """Fetch the deterministic, nested person-vertex and candidate id/vid pools.

    Persons: vertex ids from the routable main component, ordered by md5(id) so any
    prefix is an unbiased, reproducible sample. Candidates: (id, snap-vertex) pairs from
    the candidate set, same ordering. Returned once and sliced per (K, H) cell.
    """
    cur.execute(
        "SELECT id FROM main_component_vertices ORDER BY md5(id::text) LIMIT %s",
        (max_k,),
    )
    person_vids = [r[0] for r in cur.fetchall()]
    if len(person_vids) < max_k:
        sys.exit(f"Only {len(person_vids)} main-component vertices; need {max_k}.")

    cur.execute(
        """SELECT c.id, cn.vid
           FROM candidates c JOIN candidate_nodes cn ON cn.cand_id = c.id
           ORDER BY md5(c.id::text) LIMIT %s""",
        (max_h,),
    )
    cand_rows = cur.fetchall()
    if len(cand_rows) < max_h:
        sys.exit(f"Only {len(cand_rows)} candidates; need {max_h}.")
    cand_ids = [r[0] for r in cand_rows]
    cand_vids = [r[1] for r in cand_rows]
    return person_vids, cand_ids, cand_vids


def explain_analyze(cur, query, params):
    """Run EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and return the top plan node."""
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query, params)
    plan = cur.fetchone()[0][0]
    return plan


def bench_cell(cur, variant, k, h, pools, runs):
    """Warm up once, then time `runs` executions of one (variant, K, H) cell."""
    person_vids, cand_ids, cand_vids = pools
    pvids = person_vids[:k]
    if variant == "euclidean":
        params = {"pvids": pvids, "cids": cand_ids[:h]}
        query = QUERY_EUCLIDEAN
    else:
        # de-duplicate end vertices (a few candidates share a snap vertex) so the
        # Dijkstra destination array is clean; record the effective count.
        cvids = list(dict.fromkeys(cand_vids[:h]))
        params = {"edges": EDGES_SQL, "pvids": pvids, "cvids": cvids, "k": k}
        query = QUERY_NETWORK

    # Warm-up (also warms the cache); discard.
    explain_analyze(cur, query, params)

    rows = []
    for run_idx in range(1, runs + 1):
        plan = explain_analyze(cur, query, params)
        root = plan["Plan"]  # execution buffers accumulate at the root node
        rows.append(
            dict(
                variant=variant,
                K=k,
                H=h,
                KH=k * h,
                run_idx=run_idx,
                exec_ms=round(plan["Execution Time"], 3),
                plan_ms=round(plan["Planning Time"], 3),
                shared_hit_blks=root.get("Shared Hit Blocks"),
                shared_read_blks=root.get("Shared Read Blocks"),
            )
        )
    return rows


def main():
    ap = argparse.ArgumentParser(description="Benchmark Variant A/B optimum queries.")
    ap.add_argument("--runs", type=int, default=5, help="timed runs per cell (default 5)")
    ap.add_argument("--kgrid", type=str, default=None, help="comma list of K values")
    ap.add_argument("--hgrid", type=str, default=None, help="comma list of H values")
    ap.add_argument("--variants", type=str, default="euclidean,network")
    ap.add_argument("--timeout", type=int, default=600, help="statement_timeout seconds")
    ap.add_argument("--quick", action="store_true", help="tiny smoke-test grid")
    ap.add_argument("--out", type=str, default=None, help="output CSV path")
    args = ap.parse_args()

    if args.quick:
        kgrid, hgrid = [2, 10], [2, 10]
    else:
        kgrid = [int(x) for x in args.kgrid.split(",")] if args.kgrid else K_GRID
        hgrid = [int(x) for x in args.hgrid.split(",")] if args.hgrid else H_GRID
    variants = [v.strip() for v in args.variants.split(",")]

    here = os.path.dirname(os.path.abspath(__file__))
    out_path = args.out or os.path.join(here, "..", "outputs", "benchmarks.csv")
    out_path = os.path.abspath(out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    conn = psycopg2.connect(**DB)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET statement_timeout = %s", (args.timeout * 1000,))

    # Record the exact engine versions for reproducibility (printed, for the report).
    cur.execute("SELECT version()")
    print(cur.fetchone()[0])
    cur.execute("SELECT postgis_full_version()")
    print(cur.fetchone()[0].split("(")[0].strip())

    pools = fetch_pools(cur, max(kgrid), max(hgrid))

    fieldnames = [
        "variant", "K", "H", "KH", "run_idx",
        "exec_ms", "plan_ms", "shared_hit_blks", "shared_read_blks",
    ]
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for variant in variants:
            for k in kgrid:
                for h in hgrid:
                    t0 = time.perf_counter()
                    try:
                        rows = bench_cell(cur, variant, k, h, pools, args.runs)
                    except psycopg2.errors.QueryCanceled:
                        conn.rollback()
                        print(f"  {variant:9s} K={k:<5d} H={h:<5d}  TIMEOUT (> {args.timeout}s)")
                        continue
                    for r in rows:
                        writer.writerow(r)
                    f.flush()
                    med = statistics.median(r["exec_ms"] for r in rows)
                    wall = time.perf_counter() - t0
                    print(
                        f"  {variant:9s} K={k:<5d} H={h:<5d}  "
                        f"median={med:9.2f} ms   (cell wall {wall:5.1f}s, {args.runs} runs)"
                    )

    cur.close()
    conn.close()
    print(f"\nWrote {out_path}")


if __name__ == "__main__":
    main()
