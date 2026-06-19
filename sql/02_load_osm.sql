-- Populates the analysis tables from the QuickOSM staging tables. In OpenStreetMap
-- a restaurant or park may be mapped as a node (point) or as a way/relation
-- (polygon), so both geometry types are combined here and every feature is reduced
-- to one representative interior point. Only features inside the province polygon
-- are retained.

-- Store the province boundary as a MultiPolygon; it is the reference geometry for
-- the clipping step below.
INSERT INTO istanbul_boundary (name, geom)
SELECT name, ST_Multi(geom)::geometry(MultiPolygon, 4326)
FROM stg_boundary_mp;

-- Union the restaurant and park staging tables across both geometry types, reduce
-- each feature to a representative interior point with ST_PointOnSurface, and keep
-- only the points that fall within the İstanbul boundary.
WITH features AS (
    SELECT osm_id, name, 'restaurant' AS category, geom FROM stg_restaurants_pt
    UNION ALL SELECT osm_id, name, 'restaurant', geom FROM stg_restaurants_mp
    UNION ALL SELECT osm_id, name, 'park',       geom FROM stg_parks_pt
    UNION ALL SELECT osm_id, name, 'park',       geom FROM stg_parks_mp
),
points AS (
    SELECT osm_id, name, category, ST_PointOnSurface(geom) AS geom FROM features
)
INSERT INTO candidates (osm_id, name, category, geom)
SELECT osm_id::bigint, name, category, geom
FROM points
WHERE ST_Within(geom, (SELECT geom FROM istanbul_boundary LIMIT 1));

-- Confirm the load by reporting the boundary and per-category candidate counts.
SELECT count(*) AS boundary_rows FROM istanbul_boundary;
SELECT category, count(*) AS n FROM candidates GROUP BY category ORDER BY category;
