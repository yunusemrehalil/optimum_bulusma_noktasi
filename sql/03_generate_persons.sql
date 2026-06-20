-- Populates `persons` with K start points placed at random inside the İstanbul
-- boundary, but constrained to lie near the road network so they represent routable,
-- realistic locations. The province polygon is mostly sea, forest and rural land, so
-- sampling uniformly over its whole area drops most points kilometres from any road
-- (snap distances of 5-19 km were observed). People live next to roads, so a point
-- far from the network is not a meaningful start location.
--
-- Method: oversample many uniform points (seeded for reproducibility), keep only
-- those within 250 m of their nearest graph vertex, and take the first K in
-- generation order. Filtering on the nearest vertex both bounds each person's later
-- snap distance (step 20) and reuses the indexed KNN lookup, so it stays cheap.
--
-- NOTE: this step now depends on `ways_vertices_pgr`, so it must run AFTER the
-- routing graph is built with osm2pgrouting (see README run order). Parameters here:
-- oversample count = 10000, seed = 42, proximity = 250 m, K = 10.

TRUNCATE persons RESTART IDENTITY;

WITH raw AS (
    -- Uniform points over the boundary; path[1] preserves the (random) generation
    -- order so the final K-subset is deterministic and spatially unbiased.
    SELECT (d).path[1] AS ord, (d).geom AS geom
    FROM (
        SELECT ST_Dump(ST_GeneratePoints(geom, 10000, 42)) AS d
        FROM istanbul_boundary
    ) s
),
near AS (
    -- Exact metric distance (EPSG:32635) to the single nearest graph vertex, found
    -- with the indexed KNN operator <->.
    SELECT r.ord, r.geom,
           ST_Distance(ST_Transform(r.geom, 32635), ST_Transform(v.geom, 32635)) AS dist_m
    FROM raw r
    CROSS JOIN LATERAL (
        SELECT w.geom FROM ways_vertices_pgr w
        ORDER BY w.geom <-> r.geom
        LIMIT 1
    ) v
)
INSERT INTO persons (geom)
SELECT geom
FROM near
WHERE dist_m <= 250
ORDER BY ord
LIMIT 10;

-- Confirm K points were produced (if fewer than 10, raise the oversample count) and
-- preview how far they sit from the network.
SELECT count(*) AS person_count FROM persons;

SELECT round(avg(d.dist_m)::numeric, 1) AS avg_dist_m,
       round(max(d.dist_m)::numeric, 1) AS max_dist_m
FROM persons p
CROSS JOIN LATERAL (
    SELECT ST_Distance(ST_Transform(p.geom, 32635), ST_Transform(w.geom, 32635)) AS dist_m
    FROM ways_vertices_pgr w
    ORDER BY w.geom <-> p.geom
    LIMIT 1
) d;
