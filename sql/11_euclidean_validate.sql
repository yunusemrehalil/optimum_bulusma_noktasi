-- Validation of the Variant A logic on a small, hand-checkable fixture that mirrors
-- the reference figure: two persons (K1, K2) and three candidate targets (H1, H2, H3)
-- positioned so the middle target H2 is the clear optimum. Coordinates are given
-- directly in EPSG:32635 (meters) so the expected distances follow from the
-- Pythagorean theorem and can be verified by hand; the production query in
-- 10_euclidean_optimum.sql adds only the ST_Transform step on top of this same logic.
--
-- Expected distances (meters):
--   H1: total 14770, max 10770
--   H2: total 12806, max  6403   <- optimum on both objectives
--   H3: total 14770, max 10770
-- H2 must therefore rank 1 on both min-sum and min-max.

WITH persons (id, geom) AS (
    VALUES (1, ST_SetSRID(ST_MakePoint(0,     0), 32635)),
           (2, ST_SetSRID(ST_MakePoint(10000, 0), 32635))
),
candidates (id, name, geom) AS (
    VALUES (1, 'H1', ST_SetSRID(ST_MakePoint(0,     4000), 32635)),
           (2, 'H2', ST_SetSRID(ST_MakePoint(5000,  4000), 32635)),
           (3, 'H3', ST_SetSRID(ST_MakePoint(10000, 4000), 32635))
),
-- Straight-line distance for every person-candidate pair, evaluated once.
pairs AS (
    SELECT c.id, c.name, ST_Distance(p.geom, c.geom) AS distance_m
    FROM candidates c CROSS JOIN persons p
)
-- Aggregate and rank exactly as the production query does; compare against the
-- expected values in the header.
SELECT id, name,
       round(sum(distance_m)) AS total_distance_m,
       round(max(distance_m)) AS max_distance_m,
       rank() OVER (ORDER BY sum(distance_m)) AS rank_minsum,
       rank() OVER (ORDER BY max(distance_m)) AS rank_minmax
FROM pairs
GROUP BY id, name
ORDER BY total_distance_m;
