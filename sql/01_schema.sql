-- Defines the three core tables used throughout the project: the İstanbul province
-- boundary, the candidate target points (H), and the person start points (K).
-- Geometry is stored in EPSG:4326, OpenStreetMap's native coordinate system;
-- metric distances are produced later by transforming to EPSG:32635 (UTM zone 35N).

-- Drop any existing tables first so the schema rebuilds cleanly on a re-run. CASCADE
-- clears anything that later depends on them (foreign keys, views); the derived helper
-- tables in steps 03/20 manage their own re-creation with DROP ... IF EXISTS.
DROP TABLE IF EXISTS persons CASCADE;
DROP TABLE IF EXISTS candidates CASCADE;
DROP TABLE IF EXISTS istanbul_boundary CASCADE;

-- The province polygon bounds the study area: it clips incoming OSM data and
-- constrains where the random person points are placed.
CREATE TABLE istanbul_boundary (
    id   serial PRIMARY KEY,
    name text,
    geom geometry(MultiPolygon, 4326)
);

-- The candidate meeting targets, each restaurant or park reduced to a single point.
CREATE TABLE candidates (
    id       serial PRIMARY KEY,
    osm_id   bigint,                  -- originating OpenStreetMap feature id
    name     text,
    category text,                    -- 'restaurant' or 'park'
    geom     geometry(Point, 4326)
);

-- The person start points, populated in step 03.
CREATE TABLE persons (
    id   serial PRIMARY KEY,
    geom geometry(Point, 4326)
);

-- GiST indexes accelerate the geometry comparisons used for clipping and for
-- nearest-neighbour lookups in later steps.
CREATE INDEX idx_boundary_geom   ON istanbul_boundary USING gist (geom);
CREATE INDEX idx_candidates_geom ON candidates        USING gist (geom);
CREATE INDEX idx_persons_geom    ON persons           USING gist (geom);
