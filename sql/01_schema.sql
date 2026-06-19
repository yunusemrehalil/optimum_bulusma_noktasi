-- Create the core tables: İstanbul boundary, candidate targets (H), persons (K).
-- All geometry is stored in EPSG:4326 (OSM native); metric distance is computed
-- later by transforming to EPSG:32635 (UTM 35N).

-- İstanbul province polygon, used to clip OSM data and to place random persons.
CREATE TABLE istanbul_boundary (
    id   serial PRIMARY KEY,
    name text,
    geom geometry(MultiPolygon, 4326)
);

-- Candidate target points H (restaurants, parks).
CREATE TABLE candidates (
    id       serial PRIMARY KEY,
    osm_id   bigint,              -- source OSM id, for traceability
    name     text,
    category text,                -- 'restaurant' or 'park'
    geom     geometry(Point, 4326)
);

-- Person start points K (generated randomly in step 03).
CREATE TABLE persons (
    id   serial PRIMARY KEY,
    geom geometry(Point, 4326)
);

-- Spatial indexes to speed up clipping and nearest-node lookups.
CREATE INDEX idx_boundary_geom   ON istanbul_boundary USING gist (geom);
CREATE INDEX idx_candidates_geom ON candidates        USING gist (geom);
CREATE INDEX idx_persons_geom    ON persons           USING gist (geom);
