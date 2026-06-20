-- Variant B: road-network optimum meeting target. Same discrete brute-force idea as
-- Variant A, but straight-line distance is replaced by shortest-path travel time over
-- the İstanbul road graph. A single pgr_dijkstraCost computes the K×H matrix of fastest-
-- route costs (seconds) from every person's snap vertex to every candidate's snap vertex;
-- the costs are then aggregated per candidate into the two objectives. One-way streets
-- are honoured by the directed search over cost_s / reverse_cost_s: osm2pgrouting stores a
-- negative reverse_cost_s where reverse travel is forbidden, or a negative cost_s for
-- reversed (oneway=-1) streets, and pgRouting treats either negative value as an absent
-- edge in that direction. Time is reported in minutes to match the reference figure.

-- person_nodes (K) and candidate_nodes (H) were snapped to graph vertices in step 20.
-- Build the whole cost matrix in one call: every person vertex to every candidate vertex.
WITH matrix AS (
    SELECT start_vid, end_vid, agg_cost AS cost_s
    FROM pgr_dijkstraCost(
        'SELECT id, source, target, cost_s AS cost, reverse_cost_s AS reverse_cost FROM ways',
        (SELECT array_agg(DISTINCT vid) FROM person_nodes),
        (SELECT array_agg(DISTINCT vid) FROM candidate_nodes),
        directed := true
    )
),
-- Map matrix vertices back to persons and candidates. Two points may share a snap vertex,
-- so the join expands the matrix to one row per (person, candidate) pair.
pairs AS (
    SELECT cn.cand_id, pn.person_id, m.cost_s
    FROM matrix m
    JOIN person_nodes    pn ON pn.vid = m.start_vid
    JOIN candidate_nodes cn ON cn.vid = m.end_vid
),
-- Aggregate each candidate's costs into the two objectives, keeping only candidates that
-- every person can reach by road: unreachable pairs produce no matrix row, so an island
-- candidate falls short of K persons and is dropped.
scored AS (
    SELECT cand_id,
           sum(cost_s) AS total_cost_s,
           max(cost_s) AS max_cost_s
    FROM pairs
    GROUP BY cand_id
    HAVING count(DISTINCT person_id) = (SELECT count(*) FROM persons)
),
-- Rank every reachable candidate on both objectives.
ranked AS (
    SELECT cand_id, total_cost_s, max_cost_s,
           rank() OVER (ORDER BY total_cost_s) AS rank_minsum,
           rank() OVER (ORDER BY max_cost_s)   AS rank_minmax
    FROM scored
)
-- Surface both optima in one result: the leaders by min-sum (total travel time, the
-- headline objective) and by min-max (the worst individual time, the fairness objective).
-- rank_minsum = 1 is the network min-sum optimum; rank_minmax = 1 is the network min-max
-- optimum. The two are usually different candidates. Times shown in minutes.
SELECT r.cand_id, c.name, c.category,
       round((r.total_cost_s / 60.0)::numeric, 1) AS total_min,
       round((r.max_cost_s   / 60.0)::numeric, 1) AS max_min,
       r.rank_minsum, r.rank_minmax
FROM ranked r
JOIN candidates c ON c.id = r.cand_id
WHERE r.rank_minsum <= 5 OR r.rank_minmax <= 5
ORDER BY r.rank_minsum, r.rank_minmax;
