//
//  GDALEnvironment.swift
//
//  One-time process setup for GDAL + PROJ. Registers GDAL drivers and points
//  PROJ/GDAL at the runtime data (proj.db + gdal data) that ships inside this
//  package as a resource (`Bundle.module`).
//
//  Call `GDALEnvironment.bootstrap()` once at app launch, before any other
//  GDALKit call. It is idempotent and thread-safe.
//

import Foundation
import CGDAL

public enum GDALEnvironment {

    private static var didBootstrap = false
    private static let lock = NSLock()

    /// Registers GDAL drivers and points PROJ/GDAL at the bundled data.
    ///
    /// `proj.db` is **mandatory** for reprojection — without it, datum/CRS
    /// transforms (GDA2020/MGA, UTM, …) fail silently. The data is resolved from
    /// `Bundle.module` (the package resource bundle), *not* `Bundle.main`, so it
    /// works the same whether GDALKit is linked into an app, a test bundle, or
    /// another package.
    public static func bootstrap() {
        lock.lock(); defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        if let share = shareDirectory() {
            let projDir = share.appendingPathComponent("proj").path
            let gdalDir = share.appendingPathComponent("gdal").path

            CPLSetConfigOption("PROJ_DATA", projDir)     // PROJ 9.x
            CPLSetConfigOption("PROJ_LIB", projDir)      // older PROJ var name (belt & suspenders)
            CPLSetConfigOption("GDAL_DATA", gdalDir)

            projDir.withCString { p in
                var paths: [UnsafePointer<CChar>?] = [p, nil]   // null-terminated
                OSRSetPROJSearchPaths(&paths)
            }
        }

        // Cap GDAL's block cache so a warp-on-load (esp. large rasters) can't
        // balloon RAM and trip iOS jetsam. Default is 5% of physical RAM, which on
        // a big device is hundreds of MB on top of the warp's own buffers. 128 MB
        // is plenty for windowed tile reads.
        CPLSetConfigOption("GDAL_CACHEMAX", "128MB")

        GDALAllRegister()
    }

    /// Locates the bundled `share/` directory (containing `proj/proj.db` and
    /// `gdal/…`) inside the package resource bundle.
    public static func shareDirectory() -> URL? {
        // `.copy("Resources/share")` preserves the `share` folder verbatim in the
        // bundle root, so `<bundle>/share/proj/proj.db` is the layout PROJ expects.
        if let url = Bundle.module.url(forResource: "share", withExtension: nil) {
            return url
        }
        return Bundle.module.resourceURL?.appendingPathComponent("share")
    }
}
