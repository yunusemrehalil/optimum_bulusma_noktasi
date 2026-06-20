-- Step 11 (QGIS): build static map layers for visualization. Precomputes the chosen
-- optima H* and the per-person routes to the headline (min-sum) target for each variant,
-- so QGIS reads ready-made geometries (fast on every pan/zoom) instead of recomputing the
-- routing on each render. Geometry is stored in EPSG:4326; QGIS reprojects on the fly to
-- align with an OSM (EPSG:3857) basemap.
--
-- Depends on: candidates, persons, ways, person_nodes, candidate_nodes (steps 02/03/20).
-- Re-runnable: every table is dropped and rebuilt. Produces three layers:
--   qgis_optimum          - the 4 optima (Variant A/B x min-sum/min-max), labelled stars
--   qgis_route_euclidean  - straight person -> Variant A min-sum H* lines
--   qgis_route_network    - road-following person -> Variant B min-sum H* paths

-- Edge graph shared by the routing calls (travel time seconds; one-way = negative reverse).
-- (kept inline per call because pgr functions take the edges query as a text argument)

-- (1) Optimum targets H*: both variants x both objectives -> 4 rows for the labelled stars.
DROP TABLE IF EXISTS qgis_optimum;
CREATE TABLE qgis_optimum AS
WITH euclid AS (
    SELECT c.id AS cand_id,
           sum(ST_Distance(ST_Transform(p.geom, 32635), ST_Transform(c.geom, 32635))) AS total_m,
           max(ST_Distance(ST_Transform(p.geom, 32635), ST_Transform(c.geom, 32635))) AS max_m
    FROM candidates c CROSS JOIN persons p
    GROUP BY c.id
),
euclid_ranked AS (
    SELECT cand_id, total_m, max_m,
           rank() OVER (ORDER BY total_m) AS rs,
           rank() OVER (ORDER BY max_m)   AS rm
    FROM euclid
),
net_matrix AS (
    SELECT start_vid, end_vid, agg_cost AS cost_s
    FROM pgr_dijkstraCost(
        'SELECT id, source, target, cost_s AS cost, reverse_cost_s AS reverse_cost FROM ways',
        (SELECT array_agg(DISTINCT vid) FROM person_nodes),
        (SELECT array_agg(DISTINCT vid) FROM candidate_nodes),
        directed := true)
),
net_pairs AS (
    SELECT cn.cand_id, pn.person_id, m.cost_s
    FROM net_matrix m
    JOIN person_nodes    pn ON pn.vid = m.start_vid
    JOIN candidate_nodes cn ON cn.vid = m.end_vid
),
net_scored AS (
    SELECT cand_id, sum(cost_s) AS total_s, max(cost_s) AS max_s
    FROM net_pairs
    GROUP BY cand_id
    HAVING count(DISTINCT person_id) = (SELECT count(*) FROM persons)
),
net_ranked AS (
    SELECT cand_id, total_s, max_s,
           rank() OVER (ORDER BY total_s) AS rs,
           rank() OVER (ORDER BY max_s)   AS rm
    FROM net_scored
),
optima AS (
    SELECT 'euclidean' AS variant, 'min-sum' AS objective, c.id AS cand_id, c.name, c.category,
           round((e.total_m / 1000.0)::numeric, 2) AS value, 'km' AS unit,
           c.geom::geometry(Point, 4326) AS geom
    FROM euclid_ranked e JOIN candidates c ON c.id = e.cand_id WHERE e.rs = 1
    UNION ALL
    SELECT 'euclidean', 'min-max', c.id, c.name, c.category,
           round((e.max_m / 1000.0)::numeric, 2), 'km', c.geom::geometry(Point, 4326)
    FROM euclid_ranked e JOIN candidates c ON c.id = e.cand_id WHERE e.rm = 1
    UNION ALL
    SELECT 'network', 'min-sum', c.id, c.name, c.category,
           round((n.total_s / 60.0)::numeric, 1), 'min', c.geom::geometry(Point, 4326)
    FROM net_ranked n JOIN candidates c ON c.id = n.cand_id WHERE n.rs = 1
    UNION ALL
    SELECT 'network', 'min-max', c.id, c.name, c.category,
           round((n.max_s / 60.0)::numeric, 1), 'min', c.geom::geometry(Point, 4326)
    FROM net_ranked n JOIN candidates c ON c.id = n.cand_id WHERE n.rm = 1
)
-- Surrogate integer key: the min-sum winner is the same candidate (9102) for both
-- variants, so cand_id is not unique across the 4 rows -- QGIS needs a unique key column.
SELECT (row_number() OVER (ORDER BY variant, objective))::int AS id, *
FROM optima;

-- (2) Euclidean routes: straight line from each person to the Variant A min-sum H*.
DROP TABLE IF EXISTS qgis_route_euclidean;
CREATE TABLE qgis_route_euclidean AS
WITH hstar AS (
    SELECT geom FROM qgis_optimum WHERE variant = 'euclidean' AND objective = 'min-sum'
)
SELECT p.id AS person_id,
       ST_MakeLine(p.geom, h.geom)::geometry(LineString, 4326) AS geom
FROM persons p CROSS JOIN hstar h;

-- (3) Network routes: the actual fastest road path from each person to the Variant B
-- min-sum H*, recovered edge-by-edge with pgr_dijkstra and reassembled into one line per
-- person. directed := true so the drawn path obeys one-way streets.
DROP TABLE IF EXISTS qgis_route_network;
CREATE TABLE qgis_route_network AS
WITH hstar AS (
    SELECT cn.vid
    FROM qgis_optimum o
    JOIN candidate_nodes cn ON cn.cand_id = o.cand_id
    WHERE o.variant = 'network' AND o.objective = 'min-sum'
),
paths AS (
    SELECT d.start_vid, d.path_seq, d.edge
    FROM pgr_dijkstra(
        'SELECT id, source, target, cost_s AS cost, reverse_cost_s AS reverse_cost FROM ways',
        (SELECT array_agg(vid) FROM person_nodes),
        (SELECT vid FROM hstar),
        directed := true) d
    WHERE d.edge <> -1            -- the terminal row carries edge = -1 (no edge)
)
SELECT pn.person_id,
       ST_Multi(ST_Collect(w.geom ORDER BY pr.path_seq))::geometry(MultiLineString, 4326) AS geom
FROM paths pr
JOIN ways         w  ON w.id  = pr.edge
JOIN person_nodes pn ON pn.vid = pr.start_vid
GROUP BY pn.person_id;

-- Spatial indexes so QGIS renders quickly.
CREATE INDEX idx_qgis_optimum_geom         ON qgis_optimum         USING gist (geom);
CREATE INDEX idx_qgis_route_euclidean_geom ON qgis_route_euclidean USING gist (geom);
CREATE INDEX idx_qgis_route_network_geom   ON qgis_route_network   USING gist (geom);

-- Report what was built.
SELECT variant, objective, cand_id, name, category, value, unit FROM qgis_optimum
ORDER BY variant, objective;
SELECT 'euclidean routes' AS layer, count(*) AS n FROM qgis_route_euclidean
UNION ALL SELECT 'network routes', count(*) FROM qgis_route_network;
