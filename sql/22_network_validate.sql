-- Validation of the Variant B logic on a small, hand-checkable road graph. It mirrors
-- the reference figure (two persons K1, K2; three targets H1, H2, H3) as a routable
-- network: every person reaches the candidates through a central hub (node 3), with costs
-- chosen so the near-hub target H2 is the clear optimum. A fourth candidate H4 sits behind
-- a one-way edge that points away from it (40 -> 3 only), so no person can reach it -- it
-- must be dropped by HAVING, exercising the reachability filter. Costs are travel seconds;
-- the one-way edge uses a negative reverse_cost (pgRouting reads negative as "no edge"),
-- exactly as osm2pgrouting encodes real one-way streets. The query is otherwise identical
-- to the production query in 21_network_optimum.sql.
--
-- Hand-computed costs (seconds); persons K1 = node 1, K2 = node 2, hub = node 3:
--   H2 (node 20): K1 100+50 = 150, K2 150  -> total 300, max 150   <- optimum, both objectives
--   H1 (node 10): K1 100+150 = 250, K2 250 -> total 500, max 250
--   H3 (node 30): K1 250, K2 250           -> total 500, max 250
--   H4 (node 40): unreachable (one-way 40 -> 3) -> dropped by HAVING, must not appear
-- H2 must therefore rank 1 on both min-sum and min-max.

WITH person_nodes (person_id, vid) AS (
    VALUES (1, 1), (2, 2)                                  -- K1 -> node 1, K2 -> node 2
),
cand_nodes (cand_id, name, vid) AS (
    VALUES (1, 'H1', 10), (2, 'H2', 20), (3, 'H3', 30), (4, 'H4', 40)
),
-- K×H cost matrix over the inline graph, exactly as step 21 does over the real `ways`.
matrix AS (
    SELECT start_vid, end_vid, agg_cost AS cost_s
    FROM pgr_dijkstraCost(
        'SELECT * FROM (VALUES
            (1, 1,  3, 100, 100),
            (2, 2,  3, 100, 100),
            (3, 3, 20,  50,  50),
            (4, 3, 10, 150, 150),
            (5, 3, 30, 150, 150),
            (6, 40, 3,  80,  -1)
         ) AS e(id, source, target, cost, reverse_cost)',
        (SELECT array_agg(vid) FROM person_nodes),
        (SELECT array_agg(vid) FROM cand_nodes),
        directed := true
    )
),
-- Map matrix vertices back to persons and candidates, exactly as in step 21.
pairs AS (
    SELECT cn.cand_id, cn.name, pn.person_id, m.cost_s
    FROM matrix m
    JOIN person_nodes pn ON pn.vid = m.start_vid
    JOIN cand_nodes   cn ON cn.vid = m.end_vid
),
-- Aggregate per candidate, dropping any the persons cannot all reach (H4).
scored AS (
    SELECT cand_id, name,
           sum(cost_s) AS total_cost_s,
           max(cost_s) AS max_cost_s
    FROM pairs
    GROUP BY cand_id, name
    HAVING count(DISTINCT person_id) = (SELECT count(*) FROM person_nodes)
)
-- Rank exactly as the production query does; compare against the expected values in the
-- header. H2 must be rank 1 on both objectives and H4 must be absent.
SELECT cand_id, name,
       round(total_cost_s) AS total_cost_s,
       round(max_cost_s)   AS max_cost_s,
       rank() OVER (ORDER BY total_cost_s) AS rank_minsum,
       rank() OVER (ORDER BY max_cost_s)   AS rank_minmax
FROM scored
ORDER BY total_cost_s;
