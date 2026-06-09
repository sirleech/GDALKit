// swift-tools-version: 5.9
import PackageDescription

// GDALKit
//
// A prebuilt GDAL + PROJ + SQLite static `GDALKit.xcframework` plus a thin,
// MapKit-free Swift wrapper (`GDALKit`) and the PROJ/GDAL runtime data
// (proj.db + gdal data) bundled as a package resource.
//
//   import GDALKit   // Swift wrapper: GDALEnvironment, GDALRaster, CoordinateProjector
//   import CGDAL     // raw GDAL/PROJ C API (exposed by the xcframework's modulemap)
//
// The xcframework is produced by `scripts/build-gdal-ios.sh` and is NOT committed
// (it lives under build/output, which is gitignored, and is published as a
// version-matched GitHub Release asset). During Phase A we point `CGDAL` at the
// LOCAL path so the package can be built/verified before any release exists;
// Phase B swaps it for a `url:` + `checksum:` remote binary target.

let package = Package(
    name: "GDALKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "GDALKit", targets: ["GDALKit"]),
    ],
    targets: [
        // --- C API (the prebuilt static xcframework) ----------------------------
        // Local-path binary target for development (Phase A). The xcframework must
        // exist at this path — run `scripts/build-gdal-ios.sh` (or drop in a
        // prebuilt) before resolving the package.
        .binaryTarget(name: "CGDAL", path: "build/output/GDALKit.xcframework"),
        // Phase B — published release asset (uncomment + fill in the checksum,
        // remove the local-path line above):
        // .binaryTarget(
        //     name: "CGDAL",
        //     url: "https://github.com/sirleech/GDALKit/releases/download/gdalkit-<v>/GDALKit.xcframework.zip",
        //     checksum: "<swift package compute-checksum GDALKit.xcframework.zip>"
        // ),

        // --- Swift wrapper (what apps import) -----------------------------------
        .target(
            name: "GDALKit",
            dependencies: ["CGDAL"],
            resources: [.copy("Resources/share")],   // proj.db + gdal data → Bundle.module
            linkerSettings: [
                .linkedLibrary("c++"),               // GDAL is C++; propagates to consumers
            ]
        ),

        // --- Smoke test ---------------------------------------------------------
        .testTarget(
            name: "GDALKitTests",
            dependencies: ["GDALKit", "CGDAL"],   // CGDAL: query driver availability in tests
            resources: [.copy("Fixtures")]         // RGB.byte.tif → test Bundle.module
        ),
    ]
)
