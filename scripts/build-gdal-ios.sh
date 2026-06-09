#!/usr/bin/env bash
# =============================================================================
# build-gdal-ios.sh
#
# Builds GDAL + PROJ + SQLite as a single STATIC XCFramework for:
#   - iOS device          (arm64,  PLATFORM=OS64)
#   - iOS simulator        (arm64, PLATFORM=SIMULATORARM64)
#
# libtiff / libgeotiff / libjpeg / libpng / zlib are taken from GDAL's *internal*
# (vendored) copies, so the only external deps we cross-compile are SQLite
# (required by PROJ) and PROJ itself.
#
# REQUIREMENTS (run on macOS):
#   - Xcode + Command Line Tools
#   - cmake            (brew install cmake)
#   - git, curl, unzip
#
# USAGE:
#   chmod +x build-gdal-ios.sh
#   ./build-gdal-ios.sh
#
# OUTPUT:
#   build/output/GDALKit.xcframework   -> Swift package binaryTarget "CGDAL"
#                                         (a module.modulemap is written into each
#                                         slice's Headers so it imports as `CGDAL`)
#   build/output/share/                -> proj.db + gdal data. Also copied into
#                                         Sources/GDALKit/Resources/share, which ships
#                                         it to consumers via Bundle.module.
#
# NOTES:
#   * Versions below are current stable as of 2026-06. They can be bumped freely;
#     the CMake flags are stable across GDAL 3.5+ and PROJ 9.x. A known-good newer
#     combo is GDAL 3.13.1 + PROJ 9.8.1.
#   * ALWAYS verify the SQLite amalgamation filename/URL on
#     https://www.sqlite.org/download.html (it encodes the version + year).
#   * First run downloads sources and takes ~10-20 min.
# =============================================================================
set -euo pipefail

# ---- versions ---------------------------------------------------------------
GDAL_VERSION="3.12.4"
PROJ_VERSION="9.6.2"
SQLITE_YEAR="2025"
SQLITE_AMALG="sqlite-amalgamation-3500400"     # 3.50.4  <-- VERIFY on sqlite.org
IOS_CMAKE_REF="master"
DEPLOYMENT_TARGET="15.0"

# ---- prebuilt artifact ------------------------------------------------------
# A known-good GDALKit.xcframework + share/ is published as a GitHub Release
# asset so a fresh checkout needn't run the full (~10-20 min) source build, and
# is resilient to upstream source-URL rot. The tag is version-matched, so bumping
# GDAL_VERSION naturally falls back to a source build until a new asset exists.
# Skip the prebuilt and force a source build with:  ./build-gdal-ios.sh --force
PREBUILT_REPO="sirleech/geospatial-ios-swift-kit"
PREBUILT_TAG="gdalkit-${GDAL_VERSION}"
PREBUILT_URL="https://github.com/${PREBUILT_REPO}/releases/download/${PREBUILT_TAG}/GDALKit-prebuilt.tgz"
FORCE_BUILD=0
[ "${1:-}" = "--force" ] && FORCE_BUILD=1

# ---- paths ------------------------------------------------------------------
# The script lives in scripts/; build artifacts go in the repo root's build/.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$ROOT/build"
SRC="$WORK/src"
OUT="$WORK/output"
TOOLCHAIN="$WORK/ios-cmake/ios.toolchain.cmake"
NCPU="$(sysctl -n hw.ncpu)"
mkdir -p "$SRC" "$OUT"

# ---- try the prebuilt artifact first ----------------------------------------
if [ "$FORCE_BUILD" = 0 ] && [ ! -d "$OUT/GDALKit.xcframework" ]; then
  echo "Looking for a prebuilt GDALKit (tag $PREBUILT_TAG)…"
  got=0
  # The repo is private, so the release asset needs auth: prefer the GitHub CLI
  # (`gh auth login`), which handles it. Fall back to plain curl if the repo is
  # public/anonymous. Either path → extract and skip the source build.
  if command -v gh >/dev/null 2>&1 && \
     gh release download "$PREBUILT_TAG" --repo "$PREBUILT_REPO" \
        --pattern 'GDALKit-prebuilt.tgz' --dir "$OUT" --clobber 2>/dev/null; then
    got=1
  elif curl -fL --retry 2 -o "$OUT/GDALKit-prebuilt.tgz" "$PREBUILT_URL"; then
    got=1
  fi
  if [ "$got" = 1 ]; then
    tar xf "$OUT/GDALKit-prebuilt.tgz" -C "$OUT" && rm -f "$OUT/GDALKit-prebuilt.tgz"
    if [ -d "$OUT/GDALKit.xcframework" ] && [ -f "$OUT/share/proj/proj.db" ]; then
      echo "Using prebuilt GDALKit.xcframework + share/  (skip source build)."
      echo "  -> $OUT   (run with --force to rebuild from source)"
      exit 0
    fi
    echo "Prebuilt archive looked incomplete; falling back to a source build."
  else
    echo "No prebuilt for '$PREBUILT_TAG' (missing, or not authenticated); building from source."
  fi
fi
[ "$FORCE_BUILD" = 1 ] && echo "--force given: building from source."

# slice name == ios-cmake PLATFORM value
SLICES=("OS64" "SIMULATORARM64")

# ---- fetch sources ----------------------------------------------------------
[ -f "$TOOLCHAIN" ] || git clone --depth 1 -b "$IOS_CMAKE_REF" \
    https://github.com/leetal/ios-cmake.git "$WORK/ios-cmake"

cd "$SRC"
fetch() { local url="$1" file="${1##*/}"; [ -f "$file" ] || curl -fL -o "$file" "$url"; }
fetch "https://download.osgeo.org/gdal/${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz"
fetch "https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz"
fetch "https://www.sqlite.org/${SQLITE_YEAR}/${SQLITE_AMALG}.zip"

rm -rf "gdal-${GDAL_VERSION}" "proj-${PROJ_VERSION}" "${SQLITE_AMALG}"
tar xf "gdal-${GDAL_VERSION}.tar.gz"
tar xf "proj-${PROJ_VERSION}.tar.gz"
unzip -q "${SQLITE_AMALG}.zip"

# The iOS toolchain restricts find_*() to the SDK sysroot by default; these make
# find_package(PROJ) / FindSQLite3 also look inside our per-slice install prefix.
FIND_ROOT_FLAGS=(
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
)

# -----------------------------------------------------------------------------
build_slice() {
  local PLATFORM="$1"
  local PREFIX="$WORK/$PLATFORM/prefix"
  mkdir -p "$PREFIX/lib" "$PREFIX/include"

  # Pick SDK + min-version flag for the raw clang SQLite compile.
  local SDK MINFLAG
  if [ "$PLATFORM" = "OS64" ]; then
    SDK="iphoneos";        MINFLAG="-mios-version-min=$DEPLOYMENT_TARGET"
  else
    SDK="iphonesimulator"; MINFLAG="-mios-simulator-version-min=$DEPLOYMENT_TARGET"
  fi
  local SYSROOT CLANG
  SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  CLANG="$(xcrun --sdk "$SDK" --find clang)"

  echo "=== [$PLATFORM] SQLite ====================================================="
  "$CLANG" -arch arm64 -isysroot "$SYSROOT" $MINFLAG -O2 \
      -DSQLITE_ENABLE_RTREE=1 -DSQLITE_ENABLE_COLUMN_METADATA=1 \
      -c "$SRC/${SQLITE_AMALG}/sqlite3.c" -o "$WORK/$PLATFORM/sqlite3.o"
  xcrun --sdk "$SDK" ar rcs "$PREFIX/lib/libsqlite3.a" "$WORK/$PLATFORM/sqlite3.o"
  cp "$SRC/${SQLITE_AMALG}/sqlite3.h" "$PREFIX/include/"

  echo "=== [$PLATFORM] PROJ ======================================================="
  cmake -S "$SRC/proj-${PROJ_VERSION}" -B "$WORK/$PLATFORM/proj" -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$PLATFORM" \
      -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DENABLE_BITCODE=OFF \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_PREFIX_PATH="$PREFIX" "${FIND_ROOT_FLAGS[@]}" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
      -DENABLE_TIFF=OFF -DENABLE_CURL=OFF \
      -DEXE_SQLITE3="$(command -v sqlite3)" \
      -DSQLite3_INCLUDE_DIR="$PREFIX/include" \
      -DSQLite3_LIBRARY="$PREFIX/lib/libsqlite3.a"
  cmake --build "$WORK/$PLATFORM/proj" --target install -j"$NCPU"

  # HAVE_DL_ITERATE_PHDR: GDAL 3.12's apps/gdalgetgdalpath.cpp does
  #   #if HAVE_DL_ITERATE_PHDR -> #include <link.h>   (Linux-only header)
  #   #elif __APPLE__          -> #include <mach-o/dyld.h>
  # check_function_exists() finds dl_iterate_phdr in the iOS SDK and sets the
  # macro, so the unreachable Apple branch never runs and <link.h> is missing.
  # Pre-seeding the cache var OFF skips the test and forces the Apple branch.
  echo "=== [$PLATFORM] GDAL ======================================================="
  cmake -S "$SRC/gdal-${GDAL_VERSION}" -B "$WORK/$PLATFORM/gdal" -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$PLATFORM" \
      -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DENABLE_BITCODE=OFF \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_PREFIX_PATH="$PREFIX" "${FIND_ROOT_FLAGS[@]}" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
      -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_JAVA_BINDINGS=OFF -DBUILD_CSHARP_BINDINGS=OFF \
      -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
      -DGDAL_USE_EXTERNAL_LIBS=OFF \
      -DGDAL_USE_TIFF_INTERNAL=ON -DGDAL_USE_GEOTIFF_INTERNAL=ON \
      -DGDAL_USE_JPEG_INTERNAL=ON -DGDAL_USE_PNG_INTERNAL=ON \
      -DGDAL_USE_ZLIB_INTERNAL=ON -DGDAL_USE_JSONC_INTERNAL=ON \
      -DGDAL_USE_LERC_INTERNAL=ON -DGDAL_USE_ICONV=OFF \
      -DHAVE_DL_ITERATE_PHDR=OFF \
      -DPROJ_INCLUDE_DIR="$PREFIX/include" -DPROJ_LIBRARY="$PREFIX/lib/libproj.a"
  cmake --build "$WORK/$PLATFORM/gdal" --target install -j"$NCPU"

  echo "=== [$PLATFORM] merge static libs ========================================="
  mkdir -p "$WORK/$PLATFORM/merged"
  libtool -static -o "$WORK/$PLATFORM/merged/libGDALKit.a" \
      "$PREFIX/lib/libgdal.a" "$PREFIX/lib/libproj.a" "$PREFIX/lib/libsqlite3.a"
}

for s in "${SLICES[@]}"; do build_slice "$s"; done

echo "=== write CGDAL module.modulemap into each slice's headers =================="
# A bridging header can't cross a Swift-package boundary, so the prebuilt binary
# must carry its own modulemap. Placing module.modulemap at the root of each
# slice's Headers dir makes the binaryTarget importable as `import CGDAL`.
write_modulemap() {
  cat > "$1/module.modulemap" <<'MODMAP'
module CGDAL {
    header "cpl_port.h"
    header "cpl_conv.h"
    header "cpl_string.h"
    header "cpl_error.h"
    header "gdal.h"
    header "gdal_utils.h"
    header "gdalwarper.h"
    header "ogr_srs_api.h"
    export *
}
MODMAP
}
write_modulemap "$WORK/OS64/prefix/include"
write_modulemap "$WORK/SIMULATORARM64/prefix/include"

echo "=== assemble XCFramework ====================================================="
rm -rf "$OUT/GDALKit.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/OS64/merged/libGDALKit.a"           -headers "$WORK/OS64/prefix/include" \
  -library "$WORK/SIMULATORARM64/merged/libGDALKit.a" -headers "$WORK/SIMULATORARM64/prefix/include" \
  -output "$OUT/GDALKit.xcframework"

echo "=== collect runtime data (proj.db + gdal data) =============================="
rm -rf "$OUT/share"
mkdir -p "$OUT/share/proj" "$OUT/share/gdal"
cp "$WORK/OS64/prefix/share/proj/proj.db" "$OUT/share/proj/"
cp -R "$WORK/OS64/prefix/share/gdal/." "$OUT/share/gdal/" 2>/dev/null || true

echo "=== copy runtime data into the Swift package resource ======================="
# Consumers can't run a GDAL build, so the package ships proj.db + gdal data as a
# committed resource (Bundle.module). Keep it in sync with each framework build.
RES="$ROOT/Sources/GDALKit/Resources/share"
rm -rf "$RES"; mkdir -p "$RES"
cp -R "$OUT/share/." "$RES/"

echo
echo "DONE."
echo "  XCFramework : $OUT/GDALKit.xcframework   (binaryTarget CGDAL; modulemap in Headers)"
echo "  Runtime data: $OUT/share  ->  Sources/GDALKit/Resources/share  (Bundle.module)"
echo
echo "This is a Swift package — consumers add the package and:"
echo "    import GDALKit     // GDALEnvironment, GDALRaster, CoordinateProjector"
echo "    import CGDAL       // raw GDAL/PROJ C API, if needed"
echo "-lc++ is applied via Package.swift linkerSettings; no bridging header needed."
echo
echo "To publish a prebuilt (so consumers skip the ~20min build):"
echo "    cd build/output && zip -ry GDALKit.xcframework.zip GDALKit.xcframework && cd -"
echo "    swift package compute-checksum build/output/GDALKit.xcframework.zip"
echo "    gh release create $PREBUILT_TAG build/output/GDALKit.xcframework.zip \\"
echo "        --repo $PREBUILT_REPO --title \"GDALKit (GDAL $GDAL_VERSION)\""
echo "    # then point Package.swift's CGDAL binaryTarget at the release url:+checksum:"
