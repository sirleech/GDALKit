import XCTest
import CGDAL
@testable import GDALKit

final class GDALKitTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Idempotent — points PROJ at the bundled proj.db and registers drivers.
        GDALEnvironment.bootstrap()
    }

    /// The single most important smoke test: a real CRS transform only resolves if
    /// proj.db was found inside `Bundle.module`. If this passes, the package's
    /// runtime data is wired up correctly.
    func testWebMercatorTransformResolves() throws {
        let projector = try XCTUnwrap(
            CoordinateProjector(fromEPSG: 4326, toEPSG: 3857),
            "Could not build a 4326→3857 transform — proj.db likely not found.")

        // Origin maps to the origin.
        let origin = try XCTUnwrap(projector.project(x: 0, y: 0))
        XCTAssertEqual(origin.x, 0, accuracy: 1e-3)
        XCTAssertEqual(origin.y, 0, accuracy: 1e-3)

        // Sydney (lon, lat) → Web Mercator: positive X, negative Y, right magnitude.
        let sydney = try XCTUnwrap(projector.project(x: 151.2093, y: -33.8688))
        XCTAssertEqual(sydney.x, 16_832_500, accuracy: 5_000)
        XCTAssertEqual(sydney.y, -4_011_500, accuracy: 5_000)
    }

    /// Round-trips 4326 → 3857 → 4326 and expects the original lon/lat back. Proves
    /// both forward and inverse transforms (and thus the full PROJ pipeline) work.
    func testRoundTripPreservesCoordinate() throws {
        let fwd = try XCTUnwrap(CoordinateProjector(fromEPSG: 4326, toEPSG: 3857))
        let inv = try XCTUnwrap(CoordinateProjector(fromEPSG: 3857, toEPSG: 4326))

        let lon = 151.2093, lat = -33.8688
        let merc = try XCTUnwrap(fwd.project(x: lon, y: lat))
        let back = try XCTUnwrap(inv.project(x: merc.x, y: merc.y))
        XCTAssertEqual(back.x, lon, accuracy: 1e-6)
        XCTAssertEqual(back.y, lat, accuracy: 1e-6)
    }

    func testMercatorMaxConstant() {
        // Web Mercator half-world extent, ± in both axes.
        XCTAssertEqual(GDALRaster.mercatorMax, 20_037_508.342_789_244, accuracy: 1e-3)
    }

    // MARK: - Raster load + warp

    /// Loads the bundled UTM-zone-18N GeoTIFF fixture and warps it to EPSG:3857.
    /// This exercises the whole reproject pipeline from a *projected* source CRS —
    /// the case that fails silently without proj.db — fully offline.
    func testLoadAndWarpBundledGeoTIFF() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "RGB.byte", withExtension: "tif", subdirectory: "Fixtures"),
            "RGB.byte.tif fixture is missing from the test bundle.")

        let loaded = await GDALRaster.load(from: url)
        let raster = try XCTUnwrap(
            loaded,
            "GDALRaster.load failed — the UTM→3857 warp probably couldn't find proj.db.")

        // Footprint is a sane, non-empty Web-Mercator box within the world extent.
        let b = raster.bounds
        let M = GDALRaster.mercatorMax
        XCTAssertLessThan(b.minX, b.maxX)
        XCTAssertLessThan(b.minY, b.maxY)
        XCTAssertGreaterThan(b.minX, -M)
        XCTAssertLessThan(b.maxX, M)
        // The fixture sits over the Bahamas (~77°W, 24.5°N): western → X < 0,
        // northern hemisphere → Y > 0 in Web Mercator.
        XCTAssertLessThan(b.maxX, 0)
        XCTAssertGreaterThan(b.minY, 0)

        // A window over the footprint renders a real RGBA image, snapped to the
        // covered extent.
        let tile = try XCTUnwrap(
            raster.readImage(minX: b.minX, maxX: b.maxX, minY: b.minY, maxY: b.maxY,
                             outW: 256, outH: 256),
            "readImage returned nil over the raster's own footprint.")
        XCTAssertEqual(tile.image.width, 256)
        XCTAssertEqual(tile.image.height, 256)
        XCTAssertLessThanOrEqual(tile.bounds.minX, b.minX)   // covered ⊇ requested
        XCTAssertGreaterThanOrEqual(tile.bounds.maxX, b.maxX)
    }

    /// USGS US Topo GeoPDF, loaded by **URL at test time** (not committed — ~33 MB).
    /// Opt-in via `GDALKIT_NET_TESTS=1` so the default run stays offline and fast.
    ///
    /// Note the package boundary: the iOS GDALKit build omits the PDF driver
    /// (optional drivers off, no external libs), so GDALKit itself can't decode a
    /// GeoPDF — that's the consuming app's CoreGraphics importer's job. This test
    /// asserts whichever behaviour matches the build it runs against, and so also
    /// documents that boundary.
    func testRemoteUSGSGeoPDF() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GDALKIT_NET_TESTS"] == "1",
            "Set GDALKIT_NET_TESTS=1 to run the network-backed US Topo GeoPDF test.")

        let url = URL(string: "https://prd-tnm.s3.amazonaws.com/StagedProducts/Maps/USTopo/PDF/TX/TX_7_L_Ranch_20220607_TM_geo.pdf")!
        let (downloaded, _) = try await URLSession.shared.download(from: url)
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("ustopo-\(UUID().uuidString).pdf")
        try FileManager.default.moveItem(at: downloaded, to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let raster = await GDALRaster.load(from: local)
        if GDALGetDriverByName("PDF") != nil {
            // Build includes a PDF driver → GDALKit can warp the GeoPDF directly.
            XCTAssertNotNil(raster, "PDF driver present but the GeoPDF failed to load/warp.")
        } else {
            // No PDF driver (the iOS build) → load returns nil by design.
            XCTAssertNil(raster, "Expected nil: this build has no GDAL PDF driver.")
        }
    }
}
