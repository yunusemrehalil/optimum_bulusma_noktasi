-- Populates `persons` with K start points distributed uniformly at random inside
-- the İstanbul boundary. ST_GeneratePoints performs the placement, and passing a
-- fixed seed makes the generated set reproducible across runs. The two parameters
-- are the point count and the seed; here K = 10 and the seed = 42.

INSERT INTO persons (geom)
SELECT (ST_Dump(ST_GeneratePoints(geom, 10, 42))).geom
FROM istanbul_boundary;

-- Confirm the number of generated points.
SELECT count(*) AS person_count FROM persons;
