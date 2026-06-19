-- Variant A: Euclidean (straight-line) optimum meeting target. The candidate set is
-- discrete, so the optimum is found by brute force: for every candidate target (H)
-- the straight-line distances to all person points (K) are aggregated, and the
-- candidate minimizing the total distance is the primary optimum (min-sum). The
-- candidate minimizing the worst-case distance is the secondary, fairness-oriented
-- optimum (min-max). Distances are measured in meters by transforming the WGS84
-- geometries to EPSG:32635 (UTM zone 35N).

-- Pre-transform the points to the metric CRS once; MATERIALIZED caches the result so
-- the cross join operates on projected geometries instead of re-projecting per pair.
WITH persons_utm AS MATERIALIZED (
    SELECT id, ST_Transform(geom, 32635) AS geom FROM persons
),
candidates_utm AS MATERIALIZED (
    SELECT id, name, category, ST_Transform(geom, 32635) AS geom FROM candidates
),
-- Evaluate the straight-line distance for every person-candidate pair exactly once.
pairs AS (
    SELECT c.id, c.name, c.category, ST_Distance(p.geom, c.geom) AS distance_m
    FROM candidates_utm c
    CROSS JOIN persons_utm p
),
-- Reduce each candidate's distances to the two objective values: total and worst-case.
scored AS (
    SELECT id, name, category,
           sum(distance_m) AS total_distance_m,
           max(distance_m) AS max_distance_m
    FROM pairs
    GROUP BY id, name, category
)
-- Rank by both objectives and return the strongest candidates: rank_minsum = 1 is the
-- min-sum optimum, rank_minmax = 1 is the min-max optimum. Distances shown in km.
SELECT id, name, category,
       round((total_distance_m / 1000.0)::numeric, 2) AS total_distance_km,
       round((max_distance_m   / 1000.0)::numeric, 2) AS max_distance_km,
       rank() OVER (ORDER BY total_distance_m) AS rank_minsum,
       rank() OVER (ORDER BY max_distance_m)   AS rank_minmax
FROM scored
ORDER BY total_distance_m
LIMIT 10;
