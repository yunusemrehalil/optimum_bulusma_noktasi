-- Variant B, step 1: prepare the routable graph for the shortest-path queries.
-- osm2pgrouting has already built `ways` (the noded edge graph) and
-- `ways_vertices_pgr` (its nodes) directly from the OSM road network. Travel time in
-- seconds is stored as cost_s / reverse_cost_s, with one-way streets expressed as a
-- NEGATIVE reverse_cost_s (pgRouting reads a negative cost as "no edge in that
-- direction"), and the straight road length is in length_m. This script does not
-- rebuild that graph; it only (a) checks the network is sound and (b) snaps each
-- person (K) and candidate (H) to its nearest graph vertex, so the routing query in
-- step 21 can run start -> end between vertex ids.

-- (a) Connectivity check.
-- A routable network should be dominated by one large connected component; small
-- islands (digitising gaps, isolated service stubs) are normal, but a point snapped
-- onto one may be unreachable from the rest. pgRouting 4.0 removed pgr_analyzeGraph,
-- so pgr_connectedComponents is used instead; length_m is passed as cost in both
-- directions to get an undirected, purely physical view of connectivity.
SELECT count(*)                  AS total_vertices,
       count(DISTINCT component) AS components,
       max(component_size)       AS largest_component
FROM (
    SELECT component,
           count(*) OVER (PARTITION BY component) AS component_size
    FROM pgr_connectedComponents(
        'SELECT id, source, target, length_m AS cost, length_m AS reverse_cost FROM ways'
    )
) c;

-- (b) Snap persons and candidates to their nearest graph vertex.
-- Points and vertices are all in EPSG:4326; the KNN operator <-> uses the spatial
-- index osm2pgrouting already built on ways_vertices_pgr. At the road network's
-- vertex density the nearest vertex by degree is the nearest by metre, so no metric
-- transform is needed for the lookup itself. The mappings live in their own tables
-- so persons/candidates stay untouched and the routing query stays simple.
DROP TABLE IF EXISTS person_nodes;
CREATE TABLE person_nodes AS
SELECT p.id AS person_id, n.id AS vid
FROM persons p
CROSS JOIN LATERAL (
    SELECT v.id FROM ways_vertices_pgr v
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

-- Report how far each set of points moved to reach its vertex, in metres (computed
-- in EPSG:32635). Small values confirm the snapping is sound; a large maximum flags
-- a point sitting far from any road.
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
