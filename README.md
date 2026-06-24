# Optimum Buluşma Noktası — İstanbul

Determining the optimal meeting target `H*` among **H** candidate points (restaurants,
parks) for **K** people in İstanbul, computed entirely in SQL, using two distance models:

- **Variant A (Euclidean):** straight-line distance via PostGIS.
- **Variant B (Road network):** shortest-path distance via pgRouting over OSM roads.

Objectives: **min-sum** (minimize total travel, primary) and **min-max** (minimize the
worst individual travel, secondary).

> **Full methodology, results and analysis:** see [`report/rapor.pdf`](report/rapor.pdf) (Turkish).

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

To avoid entering the password each time, create `%APPDATA%\postgresql\pgpass.conf`
with a single line: `localhost:5432:*:postgres:<password>`.

## Data acquisition

**Points and boundary** are fetched in QGIS with the **QuickOSM** plugin (`In` = İstanbul)
and imported into PostGIS staging tables with **DB Manager** (SRID 4326, column `geom`),
one query per geometry type:

| QuickOSM query | Staging tables |
|----------------|----------------|
| `amenity` = `restaurant` | `stg_restaurants_pt`, `stg_restaurants_mp` |
| `leisure` = `park` | `stg_parks_pt`, `stg_parks_mp` |
| `admin_level` = `4` | `stg_boundary_mp` |

**Roads** need raw OSM XML (QuickOSM cannot emit it), so the saved query
`scripts/overpass_roads.overpassql` is sent to the Overpass API and imported with
`osm2pgrouting` (see step 3 below).

## Run order

Run from the project root. The `sql/` files work with any client (the IntelliJ Database
console or the `psql` CLI shown below); PostgreSQL binaries are in
`C:\Program Files\PostgreSQL\16\bin`.

```bash
# 0 - database and extensions
createdb -U postgres istanbul_gis
psql -U postgres -d istanbul_gis -f sql/00_setup_extensions.sql

# 1 - schema
psql -U postgres -d istanbul_gis -f sql/01_schema.sql

# 2 - load OSM points/boundary (after QuickOSM acquisition, see above)
psql -U postgres -d istanbul_gis -f sql/02_load_osm.sql

# 3 - build the routable road graph (MUST run before step 4)
curl.exe -s --data-urlencode "data@scripts/overpass_roads.overpassql" \
         "https://overpass.kumi.systems/api/interpreter" -o data/raw/istanbul_roads.osm
"C:\Program Files\PostgreSQL\16\bin\osm2pgrouting.exe" \
    --f data/raw/istanbul_roads.osm \
    --conf "C:\Program Files\PostgreSQL\16\bin\mapconfig_for_cars.xml" \
    --dbname istanbul_gis --username postgres --host localhost --port 5432 \
    --password <password> --clean

# 4 - generate K random persons near the road network (K, seed set in the script)
psql -U postgres -d istanbul_gis -f sql/03_generate_persons.sql

# 5-6 - Variant A: Euclidean optimum + validation
psql -U postgres -d istanbul_gis -f sql/10_euclidean_optimum.sql
psql -U postgres -d istanbul_gis -f sql/11_euclidean_validate.sql

# 7-8 - Variant B: network optimum (20 builds routing/snapping helpers first) + validation
psql -U postgres -d istanbul_gis -f sql/20_build_routing.sql
psql -U postgres -d istanbul_gis -f sql/21_network_optimum.sql
psql -U postgres -d istanbul_gis -f sql/22_network_validate.sql

# 9-10 - benchmark + plots
python scripts/benchmark.py
python scripts/plot_performance.py

# 11 - QGIS maps (precompute layers, then build project + export PNG)
psql -U postgres -d istanbul_gis -f sql/30_routes_for_qgis.sql
"C:\Program Files\QGIS 4.0.3\bin\python-qgis.bat" qgis/build_project.py
```

**Dependency:** step 3 (`osm2pgrouting`) must run before step 4, because
`03_generate_persons.sql` places people on the routable network — within 250 m of a vertex
in the graph's largest connected component — so every person is reachable by road.

## Repository layout

| Path | Contents |
|------|----------|
| `sql/` | All computation: schema, OSM load, optima, validation, QGIS layers |
| `scripts/` | Benchmark and plotting (Python), Overpass road query |
| `qgis/` | Headless PyQGIS map builder and `.qgz` project |
| `outputs/` | Benchmark CSVs, scaling plots, exported map PNG |
| `report/` | `rapor.pdf` / `rapor.md` — full write-up (Turkish) |
