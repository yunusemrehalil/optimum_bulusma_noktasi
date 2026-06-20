-- Populates `persons` with K start points placed at random inside the İstanbul
-- boundary, constrained to the largest connected component of the road graph so every
-- person is reachable by road. The province polygon is mostly sea, forest and rural
-- land, so sampling uniformly over its whole area strands most points kilometres from
-- any road; and ferry-only areas such as the Princes' Islands (Adalar) form their own
-- graph components. A person on either would be unroutable and would break the network
-- optimum, which requires all K persons to reach a candidate (HAVING COUNT = K).
--
-- Method: oversample uniform points (seeded), then keep only those within 250 m of
-- their nearest vertex IN THE MAIN COMPONENT, and take the first K in generation order.
-- This both bounds each person's later snap distance (step 20) and guarantees they sit
-- on the routable network. Filtering on the nearest vertex reuses the indexed KNN
-- lookup, so it stays cheap.
--
-- NOTE: depends on `ways` / `ways_vertices_pgr`, so it must run AFTER the routing graph
-- is built with osm2pgrouting (see README run order). Parameters here: oversample
-- count = 10000, seed = 42, proximity = 250 m, K = 10.

TRUNCATE persons RESTART IDENTITY;

-- Routable vertex set: the nodes of the largest connected component. pgr_connectedComponents
-- is evaluated once (the CTE is referenced twice but runs a single time); the result is
-- materialised and indexed so the KNN snap below can filter to it cheaply. length_m is
-- the cost in both directions, giving an undirected (physical) view of connectivity.
DROP TABLE IF EXISTS main_component_vertices;
CREATE TABLE main_component_vertices AS
WITH cc AS (
    SELECT node, component
    FROM pgr_connectedComponents(
        'SELECT id, source, target, length_m AS cost, length_m AS reverse_cost FROM ways'
    )
)
SELECT node AS id
FROM cc
WHERE component = (SELECT component FROM cc GROUP BY component ORDER BY count(*) DESC LIMIT 1);
ALTER TABLE main_component_vertices ADD PRIMARY KEY (id);

INSERT INTO persons (geom)
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
    -- Exact metric distance (EPSG:32635) to the single nearest MAIN-COMPONENT vertex.
    -- The indexed KNN operator <-> ranks in EPSG:4326 degree-space, so it fetches the 10
    -- coarse-nearest routable vertices via the GiST index, then the outer ORDER BY re-ranks
    -- those by true metric distance (EPSG:32635) and keeps the genuine nearest. Points whose
    -- nearest routable vertex is far away (e.g. on Adalar) get a large distance and are
    -- dropped by the filter.
    SELECT r.ord, r.geom,
           ST_Distance(ST_Transform(r.geom, 32635), ST_Transform(v.geom, 32635)) AS dist_m
    FROM raw r
    CROSS JOIN LATERAL (
        SELECT k.geom
        FROM (
            SELECT w.geom
            FROM ways_vertices_pgr w
            WHERE EXISTS (SELECT 1 FROM main_component_vertices m WHERE m.id = w.id)
            ORDER BY w.geom <-> r.geom                                    -- index KNN (coarse, 4326)
            LIMIT 10
        ) k
        ORDER BY ST_Transform(k.geom, 32635) <-> ST_Transform(r.geom, 32635)  -- exact metric
        LIMIT 1
    ) v
)
SELECT geom
FROM near
WHERE dist_m <= 250
ORDER BY ord
LIMIT 10;

-- Confirm K points were produced (if fewer than 10, raise the oversample count) and
-- preview how far they sit from the routable network.
SELECT count(*) AS person_count FROM persons;

SELECT round(avg(d.dist_m)::numeric, 1) AS avg_dist_m,
       round(max(d.dist_m)::numeric, 1) AS max_dist_m
FROM persons p
CROSS JOIN LATERAL (
    SELECT ST_Distance(ST_Transform(p.geom, 32635), ST_Transform(k.geom, 32635)) AS dist_m
    FROM (
        SELECT w.geom
        FROM ways_vertices_pgr w
        JOIN main_component_vertices m ON m.id = w.id
        ORDER BY w.geom <-> p.geom                                    -- index KNN (coarse, 4326)
        LIMIT 10
    ) k
    ORDER BY ST_Transform(k.geom, 32635) <-> ST_Transform(p.geom, 32635)  -- exact metric
    LIMIT 1
) d;
