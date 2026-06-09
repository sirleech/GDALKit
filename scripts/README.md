# GDALKit build & release scripts

Two scripts own the GDAL/PROJ/SQLite XCFramework lifecycle:

| script | what it does |
|--------|--------------|
| `build-gdal-ios.sh`  | Build (or fetch a prebuilt) `GDALKit.xcframework` + `share/`, write the `CGDAL` modulemap, and sync `share/` into the package resources. |
| `release-gdalkit.sh` | Zip + checksum the built framework, publish it as a GitHub Release asset, and point `Package.swift`'s `CGDAL` target at it. |

> Run on **macOS, Apple Silicon**. The simulator slice is arm64-only.

---

## Prerequisites

**To build** (`build-gdal-ios.sh`):
- **Full Xcode** (not just the Command Line Tools) with the iOS SDKs. If
  `xcode-select -p` points at `/Library/Developer/CommandLineTools`, either
  `sudo xcode-select -s /Applications/Xcode.app` or prefix commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `cmake` — `brew install cmake`
- `git`, `curl`, `unzip` (preinstalled on macOS)
- Network access (first run downloads GDAL, PROJ, and the SQLite amalgamation)

**To release** (`release-gdalkit.sh`), additionally:
- **GitHub CLI** authenticated with push access — `brew install gh && gh auth login`
- A **Swift toolchain** (ships with Xcode) for `swift package compute-checksum`

---

## 1. Build from scratch (with logging)

```bash
cd scripts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./build-gdal-ios.sh --force 2>&1 | tee /tmp/gdalkit-build.log
```

- `--force` skips the prebuilt fast path and builds from source (~10 min the
  first run; it downloads sources). Without `--force` the script first tries to
  download the prebuilt release asset and only builds from source if that's
  missing.
- `tee` keeps a full log at `/tmp/gdalkit-build.log` for debugging.

The build does, per slice (`OS64` device, then `SIMULATORARM64`):
**SQLite** → **PROJ** (uses that SQLite; the host `sqlite3` generates `proj.db`)
→ **GDAL** (optional drivers off; internal libtiff/geotiff/jpeg/png/zlib) →
merge the three static libs → write the `CGDAL` modulemap → assemble the
XCFramework → copy runtime data.

---

## 2. Expected output

On success the script ends with this summary:

```text
DONE.
  XCFramework : …/build/output/GDALKit.xcframework   (binaryTarget CGDAL; modulemap in Headers)
  Runtime data: …/build/output/share  ->  Sources/GDALKit/Resources/share  (Bundle.module)

This is a Swift package — consumers add the package and:
    import GDALKit     // GDALEnvironment, GDALRaster, CoordinateProjector
    import CGDAL       // raw GDAL/PROJ C API, if needed
-lc++ is applied via Package.swift linkerSettings; no bridging header needed.

To publish this build as a GitHub release:  ./release-gdalkit.sh   (see scripts/README.md)
```

…and produces:

```
build/output/GDALKit.xcframework        # binaryTarget "CGDAL"
  ├── ios-arm64/…/Headers/module.modulemap          (module CGDAL)
  └── ios-arm64-simulator/…/Headers/module.modulemap
build/output/share/                     # proj/proj.db + gdal/…
Sources/GDALKit/Resources/share/        # synced copy, committed (Bundle.module)
```

Quick checks:

```bash
ls build/output/GDALKit.xcframework                       # Info.plist + 2 slices
ls build/output/GDALKit.xcframework/ios-arm64/Headers/module.modulemap   # exists
ls build/output/share/proj/proj.db                        # exists (~9 MB)
```

`build/` is git-ignored (~100 MB+ framework + ~1 GB of source/build trees); only
`Sources/GDALKit/Resources/share` is committed.

---

## 3. Release the artifact to GitHub

```bash
cd scripts
./release-gdalkit.sh
```

It:
1. zips `build/output/GDALKit.xcframework` → `GDALKit.xcframework.zip`,
2. computes the SwiftPM checksum,
3. creates the release `gdalkit-<GDAL_VERSION>` (or updates its asset with
   `--clobber` if it already exists), and
4. rewrites `Package.swift`'s `CGDAL` `binaryTarget` `url` + `checksum`.

The tag/version are read from `build-gdal-ios.sh`, so the release always matches
the binary you built. Then commit and bump the SwiftPM semver tag:

```bash
git add Package.swift && git commit -m "Release gdalkit-<GDAL_VERSION>"
git tag 0.1.2 && git push origin main --tags
```

> Binary tag vs SwiftPM tag: the xcframework asset is hosted under
> `gdalkit-<GDAL_VERSION>` (e.g. `gdalkit-3.12.4`); consumers depend on the semver
> tags (`0.1.x`). Bump the semver tag whenever `Package.swift` changes.

### Manual fallback

If you'd rather do it by hand:

```bash
cd build/output && zip -ry GDALKit.xcframework.zip GDALKit.xcframework && cd -
swift package compute-checksum build/output/GDALKit.xcframework.zip
gh release create gdalkit-<ver> build/output/GDALKit.xcframework.zip \
  --repo sirleech/GDALKit --title "GDALKit (GDAL <ver>)" --notes "…"
# then set Package.swift's CGDAL url + checksum to match
```

---

## Bumping GDAL / PROJ

Edit the versions at the top of `build-gdal-ios.sh` (and verify the SQLite
amalgamation URL on <https://www.sqlite.org/download.html>), then
`./build-gdal-ios.sh --force` and `./release-gdalkit.sh`. The CMake flags are
stable across GDAL 3.5+ / PROJ 9.x. See the repo `CLAUDE.md` for the build gotchas
(e.g. `-DHAVE_DL_ITERATE_PHDR=OFF`, `CMAKE_FIND_ROOT_PATH_MODE_*=BOTH`).
