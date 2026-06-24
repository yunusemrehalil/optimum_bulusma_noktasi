# Optimum Buluşma Noktası — İstanbul

İstanbul'da **K** kişi için, bilinen **H** aday nokta (restoranlar, parklar) arasından en
uygun tek buluşma hedefini `H*` tamamen SQL içinde, iki mesafe modeliyle belirler:

- **Varyant A (Öklid):** PostGIS ile düz çizgi (kuş uçuşu) mesafesi.
- **Varyant B (Yol ağı):** pgRouting ile OSM yolları üzerinde en kısa yol mesafesi.

Amaç fonksiyonları: **min-sum** (toplam yolculuğu en aza indir, birincil) ve **min-max**
(en uzaktaki bireyin yolculuğunu en aza indir, ikincil).

> **Tüm yöntem, sonuç ve analiz** için bkz. [`report/rapor.pdf`](report/rapor.pdf).

## Ortam

| Bileşen | Sürüm |
|---------|-------|
| PostgreSQL | 16.10 |
| PostGIS | 3.6.2 |
| pgRouting | 4.0.1 |
| osm2pgrouting | 3.0.0 (PostgreSQL 16 bin içinde gelir) |
| QGIS (GDAL/ogr2ogr ile) | 4.0.3 |
| Python | 3.12 (matplotlib, pandas, psycopg2) |

## Veritabanı bağlantısı

Tüm betiklerin kullandığı varsayılan parametreler:

```
host=localhost port=5432 user=postgres dbname=istanbul_gis
```

Her seferinde parola girmemek için `%APPDATA%\postgresql\pgpass.conf` dosyasını tek satırla
oluşturun: `localhost:5432:*:postgres:<parola>`.

## Veri edinimi

**Noktalar ve sınır**, QGIS'te **QuickOSM** eklentisiyle (`In` = İstanbul) çekilir ve
**DB Manager** ile PostGIS hazırlık (staging) tablolarına aktarılır (SRID 4326, `geom`
sütunu); her sorgu geometri türüne göre ayrı içe aktarılır:

| QuickOSM sorgusu | Hazırlık tabloları |
|------------------|--------------------|
| `amenity` = `restaurant` | `stg_restaurants_pt`, `stg_restaurants_mp` |
| `leisure` = `park` | `stg_parks_pt`, `stg_parks_mp` |
| `admin_level` = `4` | `stg_boundary_mp` |

**Yollar** için ham OSM XML gerekir (QuickOSM bunu üretemez); bu yüzden kayıtlı sorgu
`scripts/overpass_roads.overpassql`, Overpass API'ye gönderilip `osm2pgrouting` ile içe
aktarılır (aşağıda 3. adım).

## Çalıştırma sırası

Proje kök dizininden çalıştırın. `sql/` dosyaları herhangi bir istemciyle çalışır (IntelliJ
Database konsolu ya da aşağıdaki `psql` CLI); PostgreSQL ikili dosyaları
`C:\Program Files\PostgreSQL\16\bin` içindedir.

```bash
# 0 - veritabanı ve eklentiler
createdb -U postgres istanbul_gis
psql -U postgres -d istanbul_gis -f sql/00_setup_extensions.sql

# 1 - şema
psql -U postgres -d istanbul_gis -f sql/01_schema.sql

# 2 - OSM nokta/sınır yükleme (QuickOSM ile edinimden sonra, yukarıya bakın)
psql -U postgres -d istanbul_gis -f sql/02_load_osm.sql

# 3 - yönlü yol ağını kur (4. adımdan ÖNCE çalışmalı)
curl.exe -s --data-urlencode "data@scripts/overpass_roads.overpassql" \
         "https://overpass.kumi.systems/api/interpreter" -o data/raw/istanbul_roads.osm
"C:\Program Files\PostgreSQL\16\bin\osm2pgrouting.exe" \
    --f data/raw/istanbul_roads.osm \
    --conf "C:\Program Files\PostgreSQL\16\bin\mapconfig_for_cars.xml" \
    --dbname istanbul_gis --username postgres --host localhost --port 5432 \
    --password <parola> --clean

# 4 - yol ağına yakın K rastgele kişi üret (K ve seed betik içinde ayarlı)
psql -U postgres -d istanbul_gis -f sql/03_generate_persons.sql

# 5-6 - Varyant A: Öklid optimumu + doğrulama
psql -U postgres -d istanbul_gis -f sql/10_euclidean_optimum.sql
psql -U postgres -d istanbul_gis -f sql/11_euclidean_validate.sql

# 7-8 - Varyant B: ağ optimumu (20 önce yönlendirme/snap yardımcılarını kurar) + doğrulama
psql -U postgres -d istanbul_gis -f sql/20_build_routing.sql
psql -U postgres -d istanbul_gis -f sql/21_network_optimum.sql
psql -U postgres -d istanbul_gis -f sql/22_network_validate.sql

# 9-10 - başarım ölçümü + grafikler
python scripts/benchmark.py
python scripts/plot_performance.py

# 11 - QGIS haritaları (önce katmanları önhesapla, sonra projeyi kur + PNG dışa aktar)
psql -U postgres -d istanbul_gis -f sql/30_routes_for_qgis.sql
"C:\Program Files\QGIS 4.0.3\bin\python-qgis.bat" qgis/build_project.py
```

**Bağımlılık:** 3. adım (`osm2pgrouting`), 4. adımdan önce çalışmalıdır; çünkü
`03_generate_persons.sql` kişileri yol ağına yerleştirir — ağın birbirine bağlı en büyük
parçasındaki bir düğüme 250 m'den yakın — böylece her kişi yolla erişilebilir olur.

## Depo yapısı

| Yol | İçerik |
|-----|--------|
| `sql/` | Tüm hesaplama: şema, OSM yükleme, optimumlar, doğrulama, QGIS katmanları |
| `scripts/` | Başarım ölçümü ve grafik (Python), Overpass yol sorgusu |
| `qgis/` | Başsız (headless) PyQGIS harita oluşturucu ve `.qgz` projesi |
| `outputs/` | Başarım CSV'leri, ölçekleme grafikleri, dışa aktarılan harita PNG'si |
| `report/` | `rapor.pdf` / `rapor.md` — tam rapor |
