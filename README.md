# Optimum Buluşma Noktası — İstanbul

Determining the optimal meeting target `H*` among **H** candidate points (restaurants,
parks) for **K** people in İstanbul, computed entirely in SQL, using two distance models:

- **Variant A (Euclidean):** straight-line distance via PostGIS.
- **Variant B (Road network):** shortest-path distance via pgRouting over OSM roads.

Objectives: **min-sum** (minimize total travel, primary) and **min-max** (minimize the
worst individual travel, secondary).

## Environment

| Component | Version |
|-----------|---------|
| PostgreSQL | 16.10 |
| PostGIS | 3.6.2 |
| pgRouting | 4.0.1 |
| osm2pgrouting | 3.0.0 (bundled in PostgreSQL 16 bin) |
| QGIS (with GDAL/ogr2ogr) | 4.0.3 |
| Python | 3.12 (matplotlib, pandas, psycopg2) |

## Database connection

Default parameters used by all scripts:

```
host=localhost port=5432 user=postgres dbname=istanbul_gis
```

To run scripts without entering the password each time, create
`%APPDATA%\postgresql\pgpass.conf` with a single line:

```
localhost:5432:*:postgres:<password>
```

## Run order

The `sql/` files can be run with any client: the IntelliJ Database console (used in
this project) or the `psql` CLI shown below. Run from the project root; PostgreSQL
binaries are in `C:\Program Files\PostgreSQL\16\bin`.

```bash
# Step 0 - database and extensions
createdb -U postgres istanbul_gis
psql -U postgres -d istanbul_gis -f sql/00_setup_extensions.sql

# Step 1 - schema
psql -U postgres -d istanbul_gis -f sql/01_schema.sql

# Step 2 - acquire point/boundary OSM data via QuickOSM (see "Data acquisition"),
#          then clip boundary + restaurants/parks into the schema tables
psql -U postgres -d istanbul_gis -f sql/02_load_osm.sql

# Step 3 - build the routable road graph. Roads need raw OSM XML, so the saved query
#          is sent to the Overpass API, then imported with osm2pgrouting. This MUST run
#          before step 4: person placement depends on the road vertices.
curl.exe -s --data-urlencode "data@scripts/overpass_roads.overpassql" \
         "https://overpass.kumi.systems/api/interpreter" -o data/raw/istanbul_roads.osm
"C:\Program Files\PostgreSQL\16\bin\osm2pgrouting.exe" \
    --f data/raw/istanbul_roads.osm \
    --conf "C:\Program Files\PostgreSQL\16\bin\mapconfig_for_cars.xml" \
    --dbname istanbul_gis --username postgres --host localhost --port 5432 \
    --password <password> --clean

# Step 4 - generate K random persons near the road network (K, seed set in the script)
psql -U postgres -d istanbul_gis -f sql/03_generate_persons.sql

# Step 5 - Variant A: Euclidean optimum
psql -U postgres -d istanbul_gis -f sql/10_euclidean_optimum.sql

# Step 6 - Variant A: Euclidean validation (small hand-checkable fixture)
psql -U postgres -d istanbul_gis -f sql/11_euclidean_validate.sql

# Step 7 - Variant B: network optimum (20 builds the routing/snapping helpers first)
psql -U postgres -d istanbul_gis -f sql/20_build_routing.sql      # connectivity + snapping helpers
psql -U postgres -d istanbul_gis -f sql/21_network_optimum.sql

# Step 8 - Variant B: network validation (small hand-checkable fixture)
psql -U postgres -d istanbul_gis -f sql/22_network_validate.sql

# Step 9 - benchmark
python scripts/benchmark.py

# Step 10 - plots
python scripts/plot_performance.py

# Step 11 - QGIS maps. First precompute the map layers (optima H* + routes), then build
#           the project and export the map PNG with the QGIS-bundled Python.
psql -U postgres -d istanbul_gis -f sql/30_routes_for_qgis.sql
"C:\Program Files\QGIS 4.0.3\bin\python-qgis.bat" qgis/build_project.py
#           -> writes qgis/project.qgz and outputs/qgis_optimum_map.png
#           (open qgis/project.qgz in the QGIS GUI to explore / re-style interactively)

# Step 12 - report: compile report/rapor.md (Turkish)
```

Note the dependency: `osm2pgrouting` (Step 3) runs **before** persons (Step 4),
because `03_generate_persons.sql` places people on the routable network — within 250 m
of a vertex in the graph's largest connected component. The İstanbul province polygon is
mostly sea, forest and rural land, and ferry-only areas (e.g. Adalar) form separate
components, so sampling uniformly would otherwise strand people far from any road or on
an unroutable island; constraining to the main component keeps start points realistic
and guarantees every person is reachable by road.

## Data acquisition

**Points and boundary (Step 2)** are fetched in QGIS with the **QuickOSM** plugin
(Quick query form, `In` = İstanbul) and imported into PostGIS staging tables with
**DB Manager** (SRID 4326, geometry column `geom`). OSM features occur as points
(nodes) and polygons (ways/relations), so each query is imported per geometry type:

| QuickOSM query | Staging tables |
|----------------|----------------|
| `amenity` = `restaurant` | `stg_restaurants_pt`, `stg_restaurants_mp` |
| `leisure` = `park` | `stg_parks_pt`, `stg_parks_mp` |
| `admin_level` = `4` | `stg_boundary_mp` |

`sql/02_load_osm.sql` merges these, reduces every feature to a representative
interior point (`ST_PointOnSurface`), clips to the boundary (`ST_Within`), and
writes `istanbul_boundary` (1) and `candidates` (5369 restaurants, 4017 parks).

**Roads (Step 3)** need raw OSM XML, which QuickOSM cannot emit — it converts results
to GeoJSON/layers and loses the node topology `osm2pgrouting` requires. The saved
query `scripts/overpass_roads.overpassql` (highway classes motorway…living_street,
with all referenced nodes) is therefore sent straight to the Overpass API to download
`data/raw/istanbul_roads.osm`, which `osm2pgrouting` turns into the `ways` /
`ways_vertices_pgr` routing graph (304,767 edges, 209,818 vertices).

## Methodological notes

- **Snapping and the "last-mile" leg.** Network travel cost is vertex-to-vertex time over
  the road graph; following standard pgRouting practice, the short off-network access leg
  between a person/candidate point and its nearest graph vertex is *not* added to the cost.
  Snap distances are small (person snap max 180 m; candidate snap avg 47 m), so this is
  immaterial for the chosen optima, which all snap tightly. Seven candidate points lie more
  than 1 km from the routable network (max 2075 m); these are off-network outliers and do
  not change the min-sum or min-max winners.
- **The directed reachability filter does real work.** The undirected largest connected
  component holds 9215 candidate snap vertices, but the *directed* network query ranks only
  9205: the `HAVING count(DISTINCT person_id) = K` filter drops 10 candidates that are
  connected in the undirected graph yet unreachable from every person once one-way
  restrictions apply. The filter therefore enforces real-world one-way constraints, not
  merely undirected connectivity.

## Performance (Steps 9–10)

`scripts/benchmark.py` measures how each variant's optimum query scales as the number
of people (K) and candidates (H) grow, over the grid K ∈ {2,10,50,100,500,1000} ×
H ∈ {2,10,50,100,500}. It never modifies the frozen production tables: it samples K
routable person-vertices (from `main_component_vertices`, deterministic `md5(id)` order,
nested samples) and H candidates, and passes them as arrays into queries that mirror
`10`/`21`. Each cell runs one warm-up (discarded) plus five timed executions; timing is
the server-side `Execution Time` from `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. Raw
per-run rows go to `outputs/benchmarks.csv`; `scripts/plot_performance.py` aggregates to
the per-cell **median** and writes `plot_euclidean.png`, `plot_network.png`,
`plot_comparison.png`.

Headline results (median execution time, PostgreSQL 16.10 / PostGIS 3.6.2 /
pgRouting 4.0.1, warm cache):

| | K=2, H=2 | K=10, H=10 | K=100, H=100 | K=1000, H=500 |
|---|---|---|---|---|
| Variant A (Euclidean) | 0.08 ms | 0.19 ms | 6.9 ms | 386 ms |
| Variant B (road network) | 530 ms | 1021 ms | 6424 ms | 64685 ms |

- **Variant A scales ~linearly in K·H** (the `time vs K·H` panel parallels the linear
  reference slope), staying sub-second across the whole grid — it is a pure `O(K·H)`
  in-memory distance enumeration.
- **Variant B is dominated by K, not K·H**: `pgr_dijkstraCost` runs one full one-to-many
  Dijkstra over the 305k-edge graph per person, so cost grows roughly linearly in K
  (~37 s at K=1000) and rises only modestly with H. This is why its `time vs K·H` scatter
  is far shallower than Variant A's — adding candidates is nearly free, adding people is not.
- Variant B is ~10²–10⁴× slower than Variant A for the same (K,H); the realism of road
  travel time is the trade-off for that cost.

## Visualization (Step 11)

`sql/30_routes_for_qgis.sql` precomputes three static map layers so QGIS renders quickly:
`qgis_optimum` (the 4 optima — both variants × min-sum/min-max — as labelled stars),
`qgis_route_euclidean` (straight person→H* lines for Variant A), and `qgis_route_network`
(the actual fastest road paths person→H* for Variant B, recovered edge-by-edge with
`pgr_dijkstra` so they follow real streets and obey one-ways).

`qgis/build_project.py` is a headless PyQGIS script (run with the QGIS-bundled Python) that
loads these layers plus persons/candidates over an OpenStreetMap basemap, styles them to
mirror `reference.png` (people = blue dots, candidates = faint grey, H* = red star, road
route = green, straight route = blue dashed), saves `qgis/project.qgz`, and exports a print
layout — title, legend, scale bar, north arrow, © OSM attribution — to
`outputs/qgis_optimum_map.png`. Open the `.qgz` in the QGIS GUI to explore or re-style.

Both min-sum optima are the same central park (id 9102); the map shows the Variant B road
routes converging on it and, for comparison, the straight-line Variant A routes to the same
point, plus the two (different) min-max optima.

## Progress

| Step | Description | Status |
|------|-------------|--------|
| — | Tooling installed | done |
| 0 | Database and extensions | done |
| 1 | Schema | done |
| 2 | OSM points/boundary load | done |
| 3 | Routable graph (osm2pgrouting) | done |
| 4 | Persons | done |
| 5 | Euclidean optimum | done |
| 6 | Euclidean validation | done |
| 7 | Network optimum | done |
| 8 | Network validation | done |
| 9 | Benchmark | done |
| 10 | Plots | done |
| 11 | QGIS maps | done |
| 12 | Report | done |
