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
| PostgreSQL | 16 |
| PostGIS | 3.x |
| pgRouting | 4.x |
| osm2pgrouting | bundled with PostgreSQL 16 |
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

Execute from the project root. PostgreSQL binaries are in
`C:\Program Files\PostgreSQL\16\bin`.

```bash
# Step 0 - database and extensions
createdb -U postgres istanbul_gis
psql -U postgres -d istanbul_gis -f sql/00_setup_extensions.sql

# Step 1 - schema
psql -U postgres -d istanbul_gis -f sql/01_schema.sql

# Step 2 - load OSM data (boundary, restaurants, parks), clipped to İstanbul
psql -U postgres -d istanbul_gis -f sql/02_load_osm.sql

# Step 3 - generate K random persons
psql -U postgres -d istanbul_gis -v k=10 -f sql/03_generate_persons.sql

# Steps 4-5 - Variant A: Euclidean optimum and validation
psql -U postgres -d istanbul_gis -f sql/10_euclidean_optimum.sql
psql -U postgres -d istanbul_gis -f sql/11_euclidean_validate.sql

# Steps 6-8 - Variant B: routable graph, network optimum, validation
osm2pgrouting --f data/raw/istanbul_roads.osm --conf mapconfig.xml \
              --dbname istanbul_gis --username postgres --clean
psql -U postgres -d istanbul_gis -f sql/21_network_optimum.sql
psql -U postgres -d istanbul_gis -f sql/22_network_validate.sql

# Steps 9-10 - benchmark and plots
python scripts/benchmark.py
python scripts/plot_performance.py

# Step 11 - open qgis/project.qgz in QGIS for map output
```

## Progress

| Step | Description | Status |
|------|-------------|--------|
| 0 | Tooling installed | done |
| 0 | Database and extensions | done |
| 1 | Schema | pending |
| 2 | OSM load | pending |
| 3 | Persons | pending |
| 4 | Euclidean optimum | pending |
| 5 | Euclidean validation | pending |
| 6 | Routable graph | pending |
| 7 | Network optimum | pending |
| 8 | Network validation | pending |
| 9 | Benchmark | pending |
| 10 | Plots | pending |
| 11 | QGIS maps | pending |
| 12 | Report | pending |
