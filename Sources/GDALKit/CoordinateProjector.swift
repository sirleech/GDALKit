//
//  CoordinateProjector.swift
//
//  A thin wrapper over PROJ (via GDAL's OGR Spatial Reference C API) that
//  transforms coordinates between two CRSs identified by EPSG code — e.g.
//  WGS84 (4326) <-> Web Mercator (3857), or a UTM/MGA zone <-> WGS84.
//
//  Requires `GDALEnvironment.bootstrap()` to have run first (so proj.db is found).
//
//  Threading: an OGRCoordinateTransformation is NOT thread-safe — create one per
//  thread, or serialise access. Construction is cheap.
//

import Foundation
import CGDAL

public final class CoordinateProjector {

    private let transform: OGRCoordinateTransformationH

    /// Builds a transform from `fromEPSG` to `toEPSG`. Returns nil if either CRS
    /// can't be constructed (usually means proj.db wasn't found — call
    /// `GDALEnvironment.bootstrap()` first). Axis order is forced to traditional
    /// GIS order, so coordinates are always `(x, y)` = `(longitude/easting,
    /// latitude/northing)` regardless of the authority's declared axis order.
    public init?(fromEPSG: Int32, toEPSG: Int32) {
        guard let src = OSRNewSpatialReference(nil),
              let dst = OSRNewSpatialReference(nil) else { return nil }
        defer {
            OSRDestroySpatialReference(src)
            OSRDestroySpatialReference(dst)
        }
        guard OSRImportFromEPSG(src, fromEPSG) == OGRERR_NONE,
              OSRImportFromEPSG(dst, toEPSG) == OGRERR_NONE else { return nil }
        OSRSetAxisMappingStrategy(src, OAMS_TRADITIONAL_GIS_ORDER)
        OSRSetAxisMappingStrategy(dst, OAMS_TRADITIONAL_GIS_ORDER)
        guard let t = OCTNewCoordinateTransformation(src, dst) else { return nil }
        transform = t
    }

    deinit {
        OCTDestroyCoordinateTransformation(transform)
    }

    /// Projects a single point. `(x, y)` are in the *source* CRS (GIS order:
    /// x = lon/easting, y = lat/northing); the result is in the destination CRS.
    /// Returns nil if PROJ reports the point as untransformable.
    public func project(x: Double, y: Double) -> (x: Double, y: Double)? {
        var px = x, py = y, pz = 0.0
        let ok = OCTTransform(transform, 1, &px, &py, &pz)
        return ok != 0 ? (px, py) : nil
    }

    /// Projects an array of points in place-efficient bulk. Coordinates that fail
    /// to transform are left as PROJ leaves them (typically HUGE_VAL); the bool
    /// reports whether every point transformed successfully.
    @discardableResult
    public func project(xs: inout [Double], ys: inout [Double]) -> Bool {
        precondition(xs.count == ys.count, "xs and ys must have equal length")
        let n = Int32(xs.count)
        guard n > 0 else { return true }
        return xs.withUnsafeMutableBufferPointer { xb in
            ys.withUnsafeMutableBufferPointer { yb in
                OCTTransform(transform, n, xb.baseAddress, yb.baseAddress, nil) != 0
            }
        }
    }
}
