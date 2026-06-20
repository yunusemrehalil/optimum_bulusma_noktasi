# Optimum Buluşma Noktası — İstanbul

Determining the optimal meeting target `H*` among **H** candidate points (restaurants,
parks) for **K** people in İstanbul, computed entirely in SQL, using two distance models:

- **Variant A (Euclidean):** straight-line distance via PostGIS.
- **Variant B (Road network):** shortest-path distance via pgRouting over OSM roads.

Objectives: **min-sum** (minimize total travel, primary) and **min-max** (minimize the
worst individual travel, secondary).

See `PLAN.md` for the full design.

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

# Step 5 - Variant A: Euclidean optimum and validation
psql -U postgres -d istanbul_gis -f sql/10_euclidean_optimum.sql
psql -U postgres -d istanbul_gis -f sql/11_euclidean_validate.sql

# Step 6 - Variant B: connectivity check + snapping, network optimum, validation
psql -U postgres -d istanbul_gis -f sql/20_build_routing.sql      # connectivity + snapping helpers
psql -U postgres -d istanbul_gis -f sql/21_network_optimum.sql
psql -U postgres -d istanbul_gis -f sql/22_network_validate.sql

# Step 7 - benchmark and plots
python scripts/benchmark.py
python scripts/plot_performance.py

# Step 8 - open qgis/project.qgz in QGIS for map output
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
| 8 | Network validation | pending |
| 9 | Benchmark | pending |
| 10 | Plots | pending |
| 11 | QGIS maps | pending |
| 12 | Report | pending |
