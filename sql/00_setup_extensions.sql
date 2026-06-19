-- Enable required spatial extensions on the istanbul_gis database.

CREATE EXTENSION IF NOT EXISTS postgis;     -- geometry types and distance functions (Variant A, Euclidean)
CREATE EXTENSION IF NOT EXISTS pgrouting;   -- shortest-path routing over the road graph (Variant B)
CREATE EXTENSION IF NOT EXISTS hstore;      -- key/value column type for storing raw OSM tags