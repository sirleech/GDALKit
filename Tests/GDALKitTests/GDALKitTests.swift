import XCTest
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
}
