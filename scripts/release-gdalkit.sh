#!/usr/bin/env bash
# =============================================================================
# release-gdalkit.sh
#
# Package the built XCFramework and publish it as a GitHub Release asset, then
# point Package.swift's CGDAL binaryTarget at it (url + checksum).
#
# Run this AFTER ./build-gdal-ios.sh has produced build/output/GDALKit.xcframework
# (with the CGDAL module.modulemap in its Headers).
#
# Steps:
#   1. zip  build/output/GDALKit.xcframework  ->  GDALKit.xcframework.zip
#   2. swift package compute-checksum
#   3. create (or update --clobber) the release  gdalkit-<GDAL_VERSION>
#   4. rewrite Package.swift's CGDAL url + checksum to match
#
# Prereqs: a built xcframework, the GitHub CLI (`gh auth login`) with push access,
# and a Swift toolchain. The version + tag are read from build-gdal-ios.sh so the
# release always matches the binary you built.
#
# USAGE:  ./release-gdalkit.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/build/output"
XCF="$OUT/GDALKit.xcframework"
ASSET="GDALKit.xcframework.zip"
PKG="$ROOT/Package.swift"

# ---- preconditions ----------------------------------------------------------
command -v gh    >/dev/null 2>&1 || { echo "error: GitHub CLI 'gh' not found (brew install gh; gh auth login)."; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "error: 'swift' toolchain not found."; exit 1; }
[ -d "$XCF" ] || { echo "error: $XCF missing — run ./build-gdal-ios.sh first."; exit 1; }
[ -f "$XCF/ios-arm64/Headers/module.modulemap" ] || \
  { echo "error: CGDAL module.modulemap not found in the xcframework Headers — rebuild with the current build-gdal-ios.sh."; exit 1; }

# Version + tag come from the build script so the release matches the binary.
GDAL_VERSION="$(grep -m1 '^GDAL_VERSION=' "$SCRIPT_DIR/build-gdal-ios.sh" | cut -d'"' -f2)"
PROJ_VERSION="$(grep -m1 '^PROJ_VERSION=' "$SCRIPT_DIR/build-gdal-ios.sh" | cut -d'"' -f2)"
[ -n "$GDAL_VERSION" ] || { echo "error: could not read GDAL_VERSION from build-gdal-ios.sh"; exit 1; }
TAG="gdalkit-${GDAL_VERSION}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo 'sirleech/GDALKit')"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

echo "repo=${REPO}  tag=${TAG}  (GDAL ${GDAL_VERSION} / PROJ ${PROJ_VERSION})"

# ---- 1. zip -----------------------------------------------------------------
echo "==> zipping ${ASSET}"
( cd "$OUT" && rm -f "$ASSET" && zip -ryq "$ASSET" GDALKit.xcframework )

# ---- 2. checksum (must run from a package directory) ------------------------
CHECKSUM="$(cd "$ROOT" && swift package compute-checksum "build/output/${ASSET}")"
echo "==> sha256 ${CHECKSUM}"

# ---- 3. publish -------------------------------------------------------------
NOTES="Prebuilt static GDALKit.xcframework (iOS device arm64 + simulator arm64).
GDAL ${GDAL_VERSION}, PROJ ${PROJ_VERSION} (internal libtiff/geotiff/jpeg/png/zlib).
Carries the CGDAL module.modulemap in each slice's Headers.

checksum (sha256): ${CHECKSUM}"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> release ${TAG} exists — updating asset + notes"
  gh release upload "$TAG" "$OUT/$ASSET" --repo "$REPO" --clobber
  gh release edit   "$TAG" --repo "$REPO" --notes "$NOTES"
else
  echo "==> creating release ${TAG}"
  gh release create "$TAG" "$OUT/$ASSET" --repo "$REPO" \
    --title "GDALKit (GDAL ${GDAL_VERSION} / PROJ ${PROJ_VERSION})" --notes "$NOTES"
fi

# ---- 4. point Package.swift's CGDAL binaryTarget at the release -------------
if [ -f "$PKG" ]; then
  sed -i '' \
    -e "s#url: \"https://github.com/.*/releases/download/.*/GDALKit.xcframework.zip\"#url: \"${URL}\"#" \
    -e "s#checksum: \"[0-9a-f]*\"#checksum: \"${CHECKSUM}\"#" \
    "$PKG"
  echo "==> updated Package.swift CGDAL → ${URL}"
fi

cat <<EOF

DONE.  Release: https://github.com/${REPO}/releases/tag/${TAG}

Next:
  git add Package.swift && git commit -m "Release ${TAG}"
  git tag <semver> && git push origin main --tags      # bump the SwiftPM tag, e.g. 0.1.2
EOF
