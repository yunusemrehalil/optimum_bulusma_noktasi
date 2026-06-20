-- Variant B, step 1: prepare the routable graph for the shortest-path queries.
-- osm2pgrouting has already built `ways` (the noded edge graph) and `ways_vertices_pgr`
-- (its nodes). Travel time in seconds is stored as cost_s / reverse_cost_s, with one-way
-- streets expressed as a NEGATIVE reverse_cost_s (pgRouting reads a negative cost as "no
-- edge in that direction"), and the straight road length is in length_m. Step 03 has
-- already materialised `main_component_vertices` (the largest connected component = the
-- routable network). This script (a) reports the network's coverage and (b) snaps each
-- person (K) and candidate (H) to a graph vertex for the routing query in step 21.

-- (a) Routability report. The routable network is the largest connected component; the
-- small remainder (isolated stubs, ferry-only islands like Adalar) is out of scope. Read
-- the figures from the existing tables instead of recomputing the components.
SELECT (SELECT count(*) FROM ways_vertices_pgr)         AS total_vertices,
       (SELECT count(*) FROM main_component_vertices)   AS main_component_vertices,
       (SELECT count(*) FROM ways_vertices_pgr)
         - (SELECT count(*) FROM main_component_vertices) AS off_main_vertices;

-- (b) Snap persons and candidates to their nearest graph vertex via the indexed KNN
-- operator <-> (all geometries are EPSG:4326). Persons are restricted to the main
-- component so every start point is routable -- consistent with how step 03 placed them.
-- Candidates are snapped to the nearest vertex overall: a candidate on an isolated island
-- is genuinely unreachable and must be dropped by the routing query (HAVING COUNT = K),
-- not relocated to the mainland. The mappings live in their own tables so persons/
-- candidates stay untouched and the routing query stays simple.
DROP TABLE IF EXISTS person_nodes;
CREATE TABLE person_nodes AS
SELECT p.id AS person_id, n.id AS vid
FROM persons p
CROSS JOIN LATERAL (
    SELECT v.id FROM ways_vertices_pgr v
    WHERE EXISTS (SELECT 1 FROM main_component_vertices m WHERE m.id = v.id)
    ORDER BY v.geom <-> p.geom
    LIMIT 1
) n;
ALTER TABLE person_nodes ADD PRIMARY KEY (person_id);

DROP TABLE IF EXISTS candidate_nodes;
CREATE TABLE candidate_nodes AS
SELECT c.id AS cand_id, n.id AS vid
FROM candidates c
CROSS JOIN LATERAL (
    SELECT v.id FROM ways_vertices_pgr v
    ORDER BY v.geom <-> c.geom
    LIMIT 1
) n;
ALTER TABLE candidate_nodes ADD PRIMARY KEY (cand_id);

-- Verify every person and candidate received exactly one snap vertex.
SELECT (SELECT count(*) FROM persons)         AS persons,
       (SELECT count(*) FROM person_nodes)    AS persons_snapped,
       (SELECT count(*) FROM candidates)      AS candidates,
       (SELECT count(*) FROM candidate_nodes) AS candidates_snapped;

-- Report how far each set of points moved to reach its vertex, in metres (computed in
-- EPSG:32635). Small values confirm the snapping is sound; a large maximum flags a point
-- sitting far from its part of the network.
SELECT 'person' AS kind,
       round(avg(ST_Distance(g_pt, g_vx))::numeric, 1) AS avg_snap_m,
       round(max(ST_Distance(g_pt, g_vx))::numeric, 1) AS max_snap_m
FROM (
    SELECT ST_Transform(p.geom, 32635) AS g_pt, ST_Transform(v.geom, 32635) AS g_vx
    FROM person_nodes pn
    JOIN persons p            ON p.id = pn.person_id
    JOIN ways_vertices_pgr v  ON v.id = pn.vid
) s
UNION ALL
SELECT 'candidate',
       round(avg(ST_Distance(g_pt, g_vx))::numeric, 1),
       round(max(ST_Distance(g_pt, g_vx))::numeric, 1)
FROM (
    SELECT ST_Transform(c.geom, 32635) AS g_pt, ST_Transform(v.geom, 32635) AS g_vx
    FROM candidate_nodes cn
    JOIN candidates c         ON c.id = cn.cand_id
    JOIN ways_vertices_pgr v  ON v.id = cn.vid
) s;
