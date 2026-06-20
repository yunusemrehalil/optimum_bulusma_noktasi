"""Step 11 (QGIS): build the QGIS project and export the optimum-meeting-point map.

Headless PyQGIS script. It connects to the istanbul_gis PostGIS database, loads the
analysis layers and the precomputed visualization layers from sql/30_routes_for_qgis.sql,
styles them to mirror reference.png (people = blue dots, candidates = faint grey, chosen
H* = red star, Variant B road route = green, Variant A straight route = blue dashed),
adds an OpenStreetMap basemap, saves qgis/project.qgz, and exports a print-layout PNG
(title, legend, scale bar, north arrow, OSM attribution) to outputs/.

Run with the QGIS-bundled Python so PyQGIS is on the path:

    & "C:\\Program Files\\QGIS 4.0.3\\bin\\python-qgis.bat" qgis\\build_project.py

Re-runnable; overwrites qgis/project.qgz and the PNG. The SQL helper (sql/30) must have
been run first.
"""

import os
import sys

# Headless rendering: no display needed for the layout export. Qt6 in this QGIS build
# ships no fonts, so point its font database at the Windows fonts (otherwise labels render
# as empty boxes).
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QPA_FONTDIR", r"C:\Windows\Fonts")

from qgis.core import (
    QgsApplication, QgsProject, QgsVectorLayer, QgsRasterLayer, QgsDataSourceUri,
    QgsCoordinateReferenceSystem, QgsCoordinateTransform, QgsRectangle,
    QgsMarkerSymbol, QgsLineSymbol, QgsFillSymbol, QgsSingleSymbolRenderer,
    QgsPalLayerSettings, QgsTextFormat, QgsTextBufferSettings, QgsVectorLayerSimpleLabeling,
    QgsPrintLayout, QgsLayoutItemMap, QgsLayoutItemLegend, QgsLayoutItemScaleBar,
    QgsLayoutItemPicture, QgsLayoutItemLabel, QgsLayoutItemPage, QgsLayoutSize,
    QgsLayoutPoint, QgsLayoutExporter, QgsLayoutItem,
)
from qgis.PyQt.QtCore import QRectF
from qgis.PyQt.QtGui import QFont, QColor

# --------------------------------------------------------------------------- #
# Paths and DB connection
# --------------------------------------------------------------------------- #
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
QGZ = os.path.join(HERE, "project.qgz")
PNG = os.path.join(ROOT, "outputs", "qgis_optimum_map.png")
os.makedirs(os.path.join(ROOT, "outputs"), exist_ok=True)

DB = dict(
    host=os.environ.get("PGHOST", "localhost"),
    port=os.environ.get("PGPORT", "5432"),
    db=os.environ.get("PGDATABASE", "istanbul_gis"),
    user=os.environ.get("PGUSER", "postgres"),
    pwd=os.environ.get("PGPASSWORD", "admin"),
)

# Millimetre unit enum (the symbol moved namespace across QGIS versions).
try:
    MM = QgsLayoutItem.LayoutMillimeters  # type: ignore[attr-defined]
except AttributeError:
    from qgis.core import QgsUnitTypes
    MM = QgsUnitTypes.LayoutMillimeters


def pg_layer(table, geom_col, key, title, where=""):
    """Build a PostGIS QgsVectorLayer for one table."""
    uri = QgsDataSourceUri()
    uri.setConnection(DB["host"], DB["port"], DB["db"], DB["user"], DB["pwd"])
    uri.setDataSource("public", table, geom_col, where, key)
    layer = QgsVectorLayer(uri.uri(False), title, "postgres")
    if not layer.isValid():
        sys.exit(f"FAILED to load layer '{table}'. Did you run sql/30_routes_for_qgis.sql?")
    return layer


def marker(props):
    return QgsSingleSymbolRenderer(QgsMarkerSymbol.createSimple(props))


def line(props):
    return QgsSingleSymbolRenderer(QgsLineSymbol.createSimple(props))


def fill(props):
    return QgsSingleSymbolRenderer(QgsFillSymbol.createSimple(props))


def label_optimum(layer):
    """Label each H* star with 'variant objective = value unit'."""
    s = QgsPalLayerSettings()
    s.fieldName = "concat(variant, ' ', objective, ' = ', value, ' ', unit)"
    s.isExpression = True
    s.placement = QgsPalLayerSettings.AroundPoint
    fmt = QgsTextFormat()
    fmt.setFont(QFont("Arial", 9, QFont.Weight.Bold))
    fmt.setSize(9)
    buf = QgsTextBufferSettings()
    buf.setEnabled(True)
    buf.setSize(1.0)
    buf.setColor(QColor("white"))
    fmt.setBuffer(buf)
    s.setFormat(fmt)
    layer.setLabeling(QgsVectorLayerSimpleLabeling(s))
    layer.setLabelsEnabled(True)


def combined_extent_3857(layers, project_crs):
    """Union of layer extents transformed into the project CRS, with an 8% margin."""
    ext = QgsRectangle()
    ext.setMinimal()
    for lyr in layers:
        tr = QgsCoordinateTransform(lyr.crs(), project_crs, QgsProject.instance())
        ext.combineExtentWith(tr.transformBoundingBox(lyr.extent()))
    ext.scale(1.08)
    return ext


def add_picture_northarrow(layout):
    """Add a north arrow if a suitable SVG ships with this QGIS install."""
    base = os.path.join(QgsApplication.pkgDataPath(), "svg", "arrows")
    for name in ("NorthArrow_02.svg", "NorthArrow_04.svg", "NorthArrow_01.svg"):
        svg = os.path.join(base, name)
        if os.path.exists(svg):
            pic = QgsLayoutItemPicture(layout)
            pic.setPicturePath(svg)
            layout.addLayoutItem(pic)
            pic.attemptResize(QgsLayoutSize(14, 14, MM))
            pic.attemptMove(QgsLayoutPoint(275, 8, MM))
            return True
    print("  (no north-arrow SVG found; skipping)")
    return False


def main():
    QgsApplication.setPrefixPath(
        os.environ.get("QGIS_PREFIX_PATH", r"C:\Program Files\QGIS 4.0.3\apps\qgis"), True
    )
    qgs = QgsApplication([], False)
    qgs.initQgis()

    project = QgsProject.instance()
    crs3857 = QgsCoordinateReferenceSystem("EPSG:3857")
    project.setCrs(crs3857)

    # ----- Basemap (OpenStreetMap XYZ tiles) -----
    osm = QgsRasterLayer(
        "type=xyz&url=https://tile.openstreetmap.org/%7Bz%7D/%7Bx%7D/%7By%7D.png&zmax=19&zmin=0",
        "OpenStreetMap", "wms",
    )
    if osm.isValid():
        project.addMapLayer(osm)
    else:
        print("  (OSM basemap layer invalid; continuing without it)")
        osm = None

    # ----- Vector layers -----
    boundary = pg_layer("istanbul_boundary", "geom", "id", "İstanbul boundary")
    candidates = pg_layer("candidates", "geom", "id", "Candidates (H)")
    route_a = pg_layer("qgis_route_euclidean", "geom", "person_id", "Route A (Euclidean)")
    route_b = pg_layer("qgis_route_network", "geom", "person_id", "Route B (road network)")
    persons = pg_layer("persons", "geom", "id", "People (K)")
    optimum = pg_layer("qgis_optimum", "geom", "id", "Optimum H*")

    # ----- Styling (mirrors reference.png) -----
    boundary.setRenderer(fill({"color": "230,230,230,40", "outline_color": "120,120,120",
                               "outline_width": "0.4"}))
    candidates.setRenderer(marker({"name": "circle", "color": "110,110,110,160",
                                   "outline_style": "no", "size": "1.8"}))
    route_a.setRenderer(line({"line_color": "31,119,180", "line_width": "0.4",
                              "line_style": "dash"}))
    route_b.setRenderer(line({"line_color": "44,160,44", "line_width": "0.9"}))
    persons.setRenderer(marker({"name": "circle", "color": "31,119,180",
                                "outline_color": "white", "outline_width": "0.4", "size": "3"}))
    optimum.setRenderer(marker({"name": "star", "color": "227,26,28",
                                "outline_color": "black", "outline_width": "0.4", "size": "7"}))
    label_optimum(optimum)

    # Add in draw order (first added = bottom, above the basemap).
    for lyr in (boundary, candidates, route_a, route_b, persons, optimum):
        project.addMapLayer(lyr)

    # Layer order for the map (top first).
    ordered = [optimum, persons, route_b, route_a, candidates, boundary]
    if osm:
        ordered = ordered + [osm]

    # ----- Print layout -----
    layout = QgsPrintLayout(project)
    layout.initializeDefaults()
    layout.setName("Optimum Buluşma Noktası")
    page = layout.pageCollection().pages()[0]
    page.setPageSize("A4", QgsLayoutItemPage.Landscape)

    map_item = QgsLayoutItemMap(layout)
    map_item.attemptMove(QgsLayoutPoint(6, 18, MM))
    map_item.attemptResize(QgsLayoutSize(230, 186, MM))
    map_item.setCrs(crs3857)
    map_item.setLayers(ordered)
    map_item.setExtent(combined_extent_3857([persons, route_b, optimum], crs3857))
    map_item.setFrameEnabled(True)
    layout.addLayoutItem(map_item)

    title = QgsLayoutItemLabel(layout)
    title.setText("Optimum Buluşma Noktası — İstanbul (min-sum H*)")
    title.setFont(QFont("Arial", 16, QFont.Weight.Bold))
    title.adjustSizeToText()
    layout.addLayoutItem(title)
    title.attemptMove(QgsLayoutPoint(6, 6, MM))

    legend = QgsLayoutItemLegend(layout)
    legend.setTitle("Legend")
    legend.setLinkedMap(map_item)
    legend.setAutoUpdateModel(True)
    layout.addLayoutItem(legend)
    legend.attemptMove(QgsLayoutPoint(240, 18, MM))

    sb = QgsLayoutItemScaleBar(layout)
    sb.setStyle("Single Box")
    sb.setLinkedMap(map_item)
    sb.applyDefaultSize()
    layout.addLayoutItem(sb)
    sb.attemptMove(QgsLayoutPoint(8, 196, MM))

    add_picture_northarrow(layout)

    attr = QgsLayoutItemLabel(layout)
    attr.setText("© OpenStreetMap contributors")
    attr.setFont(QFont("Arial", 7))
    attr.adjustSizeToText()
    layout.addLayoutItem(attr)
    attr.attemptMove(QgsLayoutPoint(240, 200, MM))

    layout.refresh()
    project.layoutManager().addLayout(layout)

    # ----- Save project + export PNG -----
    if not project.write(QGZ):
        sys.exit(f"FAILED to write {QGZ}")
    print(f"  wrote {QGZ}")

    exporter = QgsLayoutExporter(layout)
    settings = QgsLayoutExporter.ImageExportSettings()
    settings.dpi = 200
    res = exporter.exportToImage(PNG, settings)
    if res != QgsLayoutExporter.Success:
        sys.exit(f"FAILED to export PNG (code {res})")
    print(f"  wrote {PNG}")

    qgs.exitQgis()


if __name__ == "__main__":
    main()
