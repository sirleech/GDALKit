# geospatial-ios-swift-kit

GDAL + PROJ + SQLite for iOS as a **Swift package**: a prebuilt static
`GDALKit.xcframework` (C module `CGDAL`), a thin MapKit-free Swift wrapper
(`GDALKit`), and the PROJ/GDAL runtime data bundled via `Bundle.module`.
Extracted from GeoMapViewer; consumed by GeoMapViewer/WaypointGo as a package.

## Layout

```
Package.swift                       binaryTarget CGDAL + wrapper target GDALKit + tests
scripts/build-gdal-ios.sh           builds the xcframework, writes the CGDAL modulemap,
                                    syncs share/ into the package resources
Sources/GDALKit/
  GDALEnvironment.swift             bootstrap(): proj.db via Bundle.module + GDALAllRegister
  GDALRaster.swift                  warp-to-3857 + windowed reads + DatasetPool (MapKit-free)
  CoordinateProjector.swift         EPSG<->EPSG transform over PROJ (OGR OCT)
  Resources/share/                  proj.db + gdal data — COMMITTED (consumers can't build GDAL)
Tests/GDALKitTests/                 smoke test: a real 4326<->3857 transform resolves
docs/index.html                     minimal API reference
build/output/                       gitignored: GDALKit.xcframework + share + build trees
```

## Two modules, no bridging header

- **`CGDAL`** = raw GDAL/PROJ/SQLite C API. A bridging header cannot cross a
  package boundary, so the build script writes a `module.modulemap` into each
  xcframework slice's `Headers/` (module `CGDAL`, listing gdal.h, cpl_*.h,
  gdal_utils.h, gdalwarper.h, ogr_srs_api.h). Package Swift files `import CGDAL`.
- **`GDALKit`** = the Swift wrapper apps `import`. It owns `-lc++`
  (`linkerSettings`, propagates to consumers) and ships `proj.db` as a resource.

If `import CGDAL` ever fails to resolve from the binaryTarget's modulemap, the
fallback is a separate C shim target (`Sources/CGDAL/include/module.modulemap` +
an umbrella header that `#include`s the framework headers, with the xcframework as
a dependency). We currently use the in-framework modulemap.

## MapKit-free rule

A file belongs in this package only if it imports **only** Foundation /
CoreGraphics / ImageIO + the GDAL C API. `GDALRaster` therefore speaks Web
Mercator metres (`MercatorBounds`), **not** `MKMapRect`/`MKMapPoint`. The original
GeoMapViewer `GDALRaster` imported MapKit (for boundingMapRect and the linear
MKMapPoint↔3857 mapping from issues #14/#16); that MapKit glue stays in the app.
Anything importing SwiftUI/UIKit/MapKit/CoreLocation does not come here.

## Building & publishing the xcframework

```bash
cd scripts && ./build-gdal-ios.sh            # prebuilt release asset, else source build
./build-gdal-ios.sh --force                  # always source build (~10–20 min)
```

Publish a prebuilt so consumers skip the build (Phase B — not done yet):

```bash
cd build/output && zip -ry GDALKit.xcframework.zip GDALKit.xcframework && cd -
swift package compute-checksum build/output/GDALKit.xcframework.zip
gh release create gdalkit-<GDAL_VERSION> build/output/GDALKit.xcframework.zip \
    --repo sirleech/geospatial-ios-swift-kit --title "GDALKit (GDAL <ver>)"
# then switch Package.swift CGDAL to url:+checksum: (a commented stub is in place)
```

Versioning: the package version tracks GDAL via a `gdalkit-<GDAL_VERSION>` tag.

> **Known wrinkle (fix during the release step):** the script's *prebuilt-fetch*
> path downloads `GDALKit-prebuilt.tgz` (xcframework **+** share, the old
> GeoMapViewer scheme), while the SwiftPM url-binaryTarget needs a `.zip` of just
> the xcframework. Reconcile these when wiring up the first release.

## Build gotchas (do not regress — these are why the build works on iOS)

1. **`-DHAVE_DL_ITERATE_PHDR=OFF`** is required for GDAL ≥ 3.12 on iOS. The iOS
   SDK exposes `dl_iterate_phdr`, so CMake's probe sets the macro and
   `apps/gdalgetgdalpath.cpp` includes Linux's `<link.h>` instead of the
   `<mach-o/dyld.h>` branch, breaking `appslib` (which contains `GDALWarp`).
   Re-check on version bumps.
2. **`CMAKE_FIND_ROOT_PATH_MODE_*=BOTH`** — the iOS toolchain restricts `find_*()`
   to the SDK sysroot; these let `find_package(PROJ)` / `FindSQLite3` see our
   per-slice install prefix. Removing them breaks the GDAL configure step.
3. **Full Xcode, not just Command Line Tools.** The script uses `xcrun --sdk
   iphoneos` + `xcodebuild`. If `xcode-select -p` points at CommandLineTools,
   `sudo xcode-select -s /Applications/Xcode.app` or prefix with
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
4. **Internal libtiff/geotiff/jpeg/png/zlib.** `GDAL_USE_*_INTERNAL=ON` +
   `GDAL_USE_EXTERNAL_LIBS=OFF`. Only SQLite and PROJ are cross-compiled
   separately; SQLite must build **before** PROJ (PROJ needs it), PROJ before GDAL.
5. **Static merge → `-lc++` only.** `libtool` merges libgdal/libproj/libsqlite3
   into one static lib; GDAL is C++ so consumers need `-lc++` (set here via
   `linkerSettings`). No `-lsqlite3 / -lz / -liconv`.
6. **proj.db is mandatory** and must be reachable at runtime. `bootstrap()` points
   PROJ at it via `OSRSetPROJSearchPaths` + `CPLSetConfigOption("PROJ_DATA"/…)`,
   resolved from **`Bundle.module`** (NOT `Bundle.main`). Without it,
   GDA2020/UTM/3857 transforms fail silently.
7. **Simulator slice is arm64-only.** Consumers set
   `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`; build on Apple Silicon.
8. **GDAL datasets are not thread-safe** — `GDALRaster.DatasetPool` hands out one
   handle per concurrent read. Don't share a handle across threads.
9. **Band layout after `-dstalpha`:** warp appends an alpha band → 1=gray,
   2=gray+alpha, 3=RGB, 4=RGBA. A single gray band maps to R=G=B; band 2 is
   **alpha, not green** (reading band 2 as green is what made 1-channel TIFFs green).
10. **SQLite amalgamation URL** encodes version + year — verify on sqlite.org when
    bumping. **Datum accuracy** ~1–2 m without NTv2 grids (fine for hiking).

## Verifying (next step — not yet done)

iOS-only xcframework can't be `swift build`-ed on the macOS host. Verify by
building the package for the simulator and running the smoke test:

```bash
xcodebuild -scheme GDALKit -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme GDALKit -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

## Memory

`bootstrap()` caps `GDAL_CACHEMAX` at 128 MB so a warp-on-load can't balloon RAM
and trip iOS jetsam (default is 5% of physical RAM).
