# GDALKit

GDAL + PROJ + SQLite for iOS, packaged as a **Swift package**: a prebuilt static
`GDALKit.xcframework`, a thin **MapKit-free** Swift wrapper, and the PROJ/GDAL
runtime data (`proj.db` + gdal data) bundled as a package resource.

Extracted from [GeoMapViewer](https://github.com/sirleech/GeoMapViewer) so it can
be shared across apps (GeoMapViewer, WaypointGo, …).

## Modules

| `import`   | What it is |
|------------|------------|
| `GDALKit`  | Swift wrapper apps use: `GDALEnvironment`, `GDALRaster`, `CoordinateProjector`. |
| `CGDAL`    | The raw GDAL/PROJ/SQLite C API, exposed from the xcframework via a `module.modulemap`. Import only if you need the C API directly. |

A bridging header can't cross a Swift-package boundary, so `CGDAL` replaces the
old `GDAL-Bridging-Header.h`.

## Usage

```swift
import GDALKit

// Once, at launch — points PROJ at the bundled proj.db (mandatory for transforms).
GDALEnvironment.bootstrap()

// Reproject + warp a GeoTIFF to Web Mercator off the main thread.
if let raster = await GDALRaster.load(from: url) {
    // raster.bounds : MercatorBounds (EPSG:3857 metres) — map this to MapKit in the app.
    let tile = raster.readImage(minX: …, maxX: …, minY: …, maxY: …, outW: 768, outH: 768)
    // tile?.image  : CGImage      tile?.bounds : exact covered MercatorBounds
}

// Transform coordinates between EPSG CRSs.
let p = CoordinateProjector(fromEPSG: 4326, toEPSG: 3857)
let merc = p?.project(x: 151.2093, y: -33.8688)   // (x: lon, y: lat) → metres
```

> The package is intentionally MapKit-free. `GDALRaster` speaks Web-Mercator
> metres (`MercatorBounds`); the consuming app converts to `MKMapRect`/`MKMapPoint`.

## Adding the package

```swift
// Package.swift
.package(url: "https://github.com/sirleech/GDALKit.git", from: "0.1.0")
```

XcodeGen (`project.yml`):

```yaml
packages:
  GDALKit:
    url: https://github.com/sirleech/GDALKit.git
    from: 0.1.0
    # local dev:  path: ../GDALKit
targets:
  YourApp:
    dependencies:
      - package: GDALKit
```

No `-lc++` and no bundled `proj.db` in the app — the package owns both
(`linkerSettings` + `Bundle.module`).

## Building the xcframework

```bash
cd scripts && ./build-gdal-ios.sh            # tries a prebuilt release asset first,
                                             # else a ~10 min source build
./build-gdal-ios.sh --force                  # always build from source
```

Output: `build/output/GDALKit.xcframework` (with the `CGDAL` modulemap in its
Headers) + `build/output/share`, and a synced copy of `share/` into
`Sources/GDALKit/Resources/share`. The ~100 MB xcframework is git-ignored and
published as a release asset; `share/` (~10 MB) **is** committed (consumers can't
run a GDAL build). See [CLAUDE.md](CLAUDE.md).

## Versions

GDAL 3.12.4 · PROJ 9.6.2 · SQLite 3.50.4 (internal libtiff/geotiff/jpeg/png/zlib).
Package version tracks GDAL via a `gdalkit-<GDAL_VERSION>` release tag.

## Docs

A minimal API reference is in [`docs/index.html`](docs/index.html) (also publishable
via GitHub Pages).

## License

The Swift wrapper here is under this repo's license. GDAL, PROJ, SQLite, and the
bundled `proj.db`/gdal data retain their own upstream licenses (see
`Sources/GDALKit/Resources/share/gdal/LICENSE.TXT`).
