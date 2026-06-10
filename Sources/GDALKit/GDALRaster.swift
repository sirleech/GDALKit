//
//  GDALRaster.swift
//
//  Wraps a single georeferenced raster for display.
//
//  Strategy: on load, reproject (warp) the source GeoTIFF to EPSG:3857
//  (Web Mercator) ONCE, writing a tiled + overviewed temporary GeoTIFF. After
//  that, serving an on-screen region is a cheap, axis-aligned windowed RasterIO
//  read — no per-tile coordinate transforms, and correct for any source CRS that
//  PROJ understands (GDA2020 MGA, GDA94, UTM, …).
//
//  This type is deliberately **MapKit-free**: geometry is expressed in Web
//  Mercator metres (`MercatorBounds`). The consuming app maps those to MapKit
//  (MKMapRect/MKMapPoint) — keeping all UI/MapKit code out of the package.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CGDAL

/// An axis-aligned rectangle in EPSG:3857 (Web Mercator) metres.
public struct MercatorBounds: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
}

public final class GDALRaster {

    /// Half the world width in EPSG:3857 metres (the ±extent of Web Mercator).
    public static let mercatorMax = 20_037_508.342_789_244

    /// Web-Mercator footprint of the warped raster (metres).
    public let bounds: MercatorBounds

    // MARK: Private
    private let warpedPath: String
    /// Whether `deinit` deletes `warpedPath`. True for a temp warp (we made it); false for
    /// a persistent cache the app owns (`cacheTo:` / `open(warped:)`).
    private let ownsWarpedFile: Bool
    private var gt = [Double](repeating: 0, count: 6)         // geotransform of the warped raster
    private var rasterW = 0
    private var rasterH = 0
    private var bandCount = 0
    private let pool: DatasetPool

    // MARK: - Loading (run off the main thread; the warp is heavy)

    /// Loads a georeferenced raster, warping it to Web Mercator on a background queue.
    /// Returns nil if the source can't be opened/warped. Call `GDALEnvironment.bootstrap()`
    /// once before the first load.
    ///
    /// Pass `cacheTo` to warp straight into a persistent file the **caller owns** — it is
    /// not deleted when the raster is released, so the app can reopen it later with
    /// `open(warped:)` and skip the warp entirely. With `cacheTo == nil` the warped file
    /// lives in the temp dir and is deleted on `deinit` (the original behaviour).
    ///
    /// `onProgress` reports the current `WarpPhase` and that phase's own 0…1 fraction,
    /// so the caller can label the step and weight the phases into one bar. It is
    /// invoked **synchronously on the background load thread** and can fire
    /// **frequently**, so throttle and hop to the main actor yourself before driving UI.
    public static func load(from sourceURL: URL,
                            cacheTo: URL? = nil,
                            onProgress: (@Sendable (WarpPhase, Double) -> Void)? = nil) async -> GDALRaster? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: makeByWarping(sourceURL: sourceURL, cacheTo: cacheTo, onProgress: onProgress))
            }
        }
    }

    /// Opens an already-warped EPSG:3857 GeoTIFF (one produced earlier via `cacheTo`)
    /// directly — no copy, render, or warp — for an instant, offline reload. The file is
    /// the caller's and is never deleted by the raster. Returns nil if it isn't a usable
    /// warped raster.
    public static func open(warped url: URL) async -> GDALRaster? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: GDALRaster(openingWarped: url.path, owns: false))
            }
        }
    }

    /// A quick Web-Mercator footprint of a source raster (its geotransform corners
    /// transformed source-CRS → EPSG:3857), **without warping** — for a cheap orientation
    /// outline while the real warp runs. Returns nil if the source has no geotransform/CRS
    /// (e.g. a GeoPDF, whose driver isn't in the iOS build — parse its geo dict instead).
    public static func sourceBounds(of url: URL) async -> MercatorBounds? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: computeSourceBounds(url.path))
            }
        }
    }

    private static func computeSourceBounds(_ path: String) -> MercatorBounds? {
        guard let ds = GDALOpen(path, GA_ReadOnly) else { return nil }
        defer { GDALClose(ds) }

        var g = [Double](repeating: 0, count: 6)
        guard GDALGetGeoTransform(ds, &g) == CE_None else { return nil }
        let w = Double(GDALGetRasterXSize(ds)), h = Double(GDALGetRasterYSize(ds))
        guard let wkt = GDALGetProjectionRef(ds), strlen(wkt) > 0 else { return nil }

        let src = OSRNewSpatialReference(wkt)
        let dst = OSRNewSpatialReference(nil)
        defer { OSRDestroySpatialReference(src); OSRDestroySpatialReference(dst) }
        OSRImportFromEPSG(dst, 3857)
        OSRSetAxisMappingStrategy(src, OAMS_TRADITIONAL_GIS_ORDER)   // x,y order on both sides
        OSRSetAxisMappingStrategy(dst, OAMS_TRADITIONAL_GIS_ORDER)
        guard let ct = OCTNewCoordinateTransformation(src, dst) else { return nil }
        defer { OCTDestroyCoordinateTransformation(ct) }

        // Four pixel corners → source-CRS coords (via the geotransform).
        var xs = [Double](), ys = [Double]()
        for (px, py) in [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)] {
            xs.append(g[0] + px * g[1] + py * g[2])
            ys.append(g[3] + px * g[4] + py * g[5])
        }
        var zs = [Double](repeating: 0, count: 4)
        guard OCTTransform(ct, 4, &xs, &ys, &zs) == 1 else { return nil }

        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else { return nil }
        return MercatorBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Steps 1–3: copy the source into the sandbox, warp it to EPSG:3857, build overviews
    /// — into `cacheTo` (caller-owned) or a temp file (raster-owned) — then open it.
    private static func makeByWarping(sourceURL: URL, cacheTo: URL?,
                                      onProgress: (@Sendable (WarpPhase, Double) -> Void)?) -> GDALRaster? {
        // 1. Copy the picked file into our sandbox while we hold security-scoped access.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let tmp = FileManager.default.temporaryDirectory
        let srcCopy = tmp.appendingPathComponent("src-\(UUID().uuidString).tif")
        do { try FileManager.default.copyItem(at: sourceURL, to: srcCopy) }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: srcCopy) }

        // Report which phase + that phase's own 0…1 to the caller (it weights/labels
        // them). Stays nil — and every progress call a no-op — without `onProgress`.
        let progress = onProgress.map(WarpProgress.init)

        // 2. Warp source -> EPSG:3857 tiled GeoTIFF (+ alpha band for clean transparent edges).
        //    Into the caller's cache path if given, else a temp file we own.
        let dst = cacheTo ?? tmp.appendingPathComponent("warp-\(UUID().uuidString).tif")
        progress?.phase = .reprojecting
        guard warpToWebMercator(src: srcCopy.path, dst: dst.path, progress: progress) else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }

        // 3. Build overviews so zoomed-out reads are fast and smooth.
        progress?.phase = .buildingOverviews
        buildOverviews(path: dst.path, progress: progress)

        // 4–6 in the shared opener. The caller owns `cacheTo`; a temp warp is ours to delete.
        guard let raster = GDALRaster(openingWarped: dst.path, owns: cacheTo == nil) else {
            try? FileManager.default.removeItem(at: dst)   // bad warp output — don't leave garbage
            return nil
        }
        return raster
    }

    /// Steps 4–6: open an EPSG:3857 warped GeoTIFF, read its geo metadata, and stand up the
    /// read-handle pool. `owns` decides whether `deinit` deletes the file (a temp warp) or
    /// leaves it (a persistent cache the app owns).
    private init?(openingWarped path: String, owns: Bool) {
        ownsWarpedFile = owns
        warpedPath = path

        // 4. Read geo metadata from the warped raster.
        guard let ds = GDALOpen(path, GA_ReadOnly) else { return nil }
        GDALGetGeoTransform(ds, &gt)
        rasterW = Int(GDALGetRasterXSize(ds))
        rasterH = Int(GDALGetRasterYSize(ds))
        bandCount = Int(GDALGetRasterCount(ds))
        GDALClose(ds)

        guard rasterW > 0, rasterH > 0, gt[1] != 0, gt[5] != 0, bandCount >= 1 else { return nil }

        // 5. Footprint in Web-Mercator metres (gt[5] is negative → north is gt[3]).
        bounds = MercatorBounds(
            minX: gt[0],
            minY: gt[3] + Double(rasterH) * gt[5],
            maxX: gt[0] + Double(rasterW) * gt[1],
            maxY: gt[3])

        // 6. Pool of read handles for parallel windowed reads (GDAL datasets are NOT
        //    thread-safe). More handles fill a freshly-zoomed screen faster.
        let n = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        pool = DatasetPool(path: path, size: n)
    }

    deinit {
        pool.closeAll()
        if ownsWarpedFile { try? FileManager.default.removeItem(atPath: warpedPath) }
    }

    // MARK: - Reading pixels

    /// Reads an axis-aligned Web-Mercator window of the warped raster into an
    /// `outW`×`outH` RGBA buffer (north-up). The requested window is snapped *out*
    /// to whole source pixels, so the returned buffer covers `[winX, winX+winW]` ×
    /// `[winY, winY+winH]` — a hair wider than asked. Callers MUST draw it at *that*
    /// extent (see `readImage`), not at the originally requested rect; stretching
    /// the snapped buffer onto the exact rect is what misregisters tiles. Returns
    /// nil if the window is fully outside the footprint.
    private func renderWindow(minX: Double, maxX: Double, minY: Double, maxY: Double,
                              outW: Int, outH: Int)
        -> (buf: [UInt8], winX: Int, winY: Int, winW: Int, winH: Int)? {
        // Mercator extent -> source pixel window (axis-aligned; raster is in 3857).
        let px0 = (minX - gt[0]) / gt[1]
        let px1 = (maxX - gt[0]) / gt[1]
        let py0 = (maxY - gt[3]) / gt[5]        // top edge (gt[5] < 0)
        let py1 = (minY - gt[3]) / gt[5]        // bottom edge
        let winX = Int(floor(min(px0, px1)))
        let winY = Int(floor(min(py0, py1)))
        let winW = Int(ceil(max(px0, px1))) - winX
        let winH = Int(ceil(max(py0, py1))) - winY
        guard winW > 0, winH > 0 else { return nil }

        // Intersect the window with the raster bounds.
        let ix0 = max(winX, 0), iy0 = max(winY, 0)
        let ix1 = min(winX + winW, rasterW), iy1 = min(winY + winH, rasterH)
        guard ix1 > ix0, iy1 > iy0 else { return nil }

        // Where the visible part lands inside the output buffer.
        let sx = Double(outW) / Double(winW)
        let sy = Double(outH) / Double(winH)
        let dx0 = Int((Double(ix0 - winX) * sx).rounded())
        let dy0 = Int((Double(iy0 - winY) * sy).rounded())
        var dw = Int((Double(ix1 - winX) * sx).rounded()) - dx0
        var dh = Int((Double(iy1 - winY) * sy).rounded()) - dy0
        dw = min(dw, outW - dx0)
        dh = min(dh, outH - dy0)
        guard dw > 0, dh > 0 else { return nil }

        // Band selection. After warping with -dstalpha the layouts are:
        //   1 band  → gray (opaque)      2 bands → gray + alpha
        //   3 bands → RGB  (opaque)      4 bands → RGBA
        // Map a single gray band to R=G=B so grayscale rasters render neutral
        // rather than tinted. (Reading band 2 — the *alpha* band — into green is
        // what made 1-channel TIFFs look green.) Repeated band indices are fine.
        var bandList: [Int32]
        let useAlphaBand: Bool
        switch bandCount {
        case 1:  bandList = [1, 1, 1];    useAlphaBand = false   // gray, opaque
        case 2:  bandList = [1, 1, 1, 2]; useAlphaBand = true    // gray + alpha
        case 3:  bandList = [1, 2, 3];    useAlphaBand = false   // RGB, opaque
        default: bandList = [1, 2, 3, 4]; useAlphaBand = true    // RGBA
        }

        var buf = [UInt8](repeating: 0, count: outW * outH * 4)   // transparent by default

        guard let ds = pool.acquire() else { return nil }
        defer { pool.release(ds) }

        let status: CPLErr = buf.withUnsafeMutableBytes { raw -> CPLErr in
            let base = raw.baseAddress!.advanced(by: (dy0 * outW + dx0) * 4)
            var extra = GDALRasterIOExtraArg()
            extra.nVersion = Int32(RASTERIO_EXTRA_ARG_CURRENT_VERSION)
            extra.eResampleAlg = GRIORA_Bilinear
            return bandList.withUnsafeMutableBufferPointer { bands in
                GDALDatasetRasterIOEx(
                    ds, GF_Read,
                    Int32(ix0), Int32(iy0), Int32(ix1 - ix0), Int32(iy1 - iy0),
                    base, Int32(dw), Int32(dh), GDT_Byte,
                    Int32(bands.count), bands.baseAddress,
                    /* nPixelSpace */ 4,
                    /* nLineSpace  */ Int64(outW * 4),
                    /* nBandSpace  */ 1,
                    &extra)
            }
        }
        guard status == CE_None else { return nil }

        // For < 4 band sources the alpha byte was left at 0; set it opaque where we read.
        if !useAlphaBand {
            for row in 0..<dh {
                let rowBase = ((dy0 + row) * outW + dx0) * 4
                for col in 0..<dw { buf[rowBase + col * 4 + 3] = 255 }
            }
        }
        return (buf, winX, winY, winW, winH)
    }

    /// Mercator bounds of a standard web tile (z,x,y).
    private static func tileMercatorBounds(x: Int, y: Int, z: Int)
        -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let span = (2 * mercatorMax) / Double(1 << z)
        let minX = -mercatorMax + Double(x) * span
        let maxY = mercatorMax - Double(y) * span
        return (minX, minX + span, maxY - span, maxY)
    }

    /// Renders one 256×256 Web-Mercator tile to PNG (standard XYZ tile scheme).
    public func readTilePNG(x: Int, y: Int, z: Int) -> Data? {
        let b = GDALRaster.tileMercatorBounds(x: x, y: y, z: z)
        guard var r = renderWindow(minX: b.minX, maxX: b.maxX, minY: b.minY, maxY: b.maxY,
                                   outW: 256, outH: 256) else { return nil }
        return GDALRaster.pngData(rgba: &r.buf, width: 256, height: 256)
    }

    /// Renders an arbitrary Web-Mercator window (metres) to a CGImage, returning
    /// the **exact Mercator extent the image covers** — the requested window
    /// snapped out to whole source pixels. The caller must place the image at this
    /// extent (not the requested one) so content lands at its true position.
    /// Returns nil if the window is fully outside the footprint.
    public func readImage(minX: Double, maxX: Double, minY: Double, maxY: Double,
                          outW: Int, outH: Int) -> (image: CGImage, bounds: MercatorBounds)? {
        guard var r = renderWindow(minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                                   outW: outW, outH: outH) else { return nil }
        guard let img = GDALRaster.cgImage(rgba: &r.buf, width: outW, height: outH) else { return nil }
        let covered = MercatorBounds(
            minX: gt[0] + Double(r.winX) * gt[1],
            minY: gt[3] + Double(r.winY + r.winH) * gt[5],   // south; gt[5] < 0
            maxX: gt[0] + Double(r.winX + r.winW) * gt[1],
            maxY: gt[3] + Double(r.winY) * gt[5])            // north
        return (img, covered)
    }

    // MARK: - GDAL helpers

    private static func warpToWebMercator(src: String, dst: String, progress: WarpProgress?) -> Bool {
        guard let srcDS = GDALOpen(src, GA_ReadOnly) else { return false }
        defer { GDALClose(srcDS) }

        // Paletted (colour-table) sources — e.g. USGS DRG topos — must be expanded to
        // RGB before warping, or the warp/read sees palette *indices*, not colour, and
        // the map renders black (#19). Expand on the fly through an in-memory VRT (no
        // large temp file). Only paletted sources are touched — RGB/gray sources (incl.
        // GeoPDFs, already rendered to RGB) warp exactly as before; falls back to the
        // original if expansion fails.
        var warpSrc: GDALDatasetH? = srcDS
        var expanded: GDALDatasetH? = nil
        var expandedVRTPath: String? = nil
        if hasColorTable(srcDS) {
            var targv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            for a in ["-of", "VRT", "-expand", "rgb"] { targv = CSLAddString(targv, a) }
            defer { CSLDestroy(targv) }
            if let topts = GDALTranslateOptionsNew(targv, nil) {
                defer { GDALTranslateOptionsFree(topts) }
                let vrtPath = "/vsimem/gdalkit-expand-\(UUID().uuidString).vrt"
                if let e = GDALTranslate(vrtPath, srcDS, topts, nil) {
                    expanded = e; warpSrc = e; expandedVRTPath = vrtPath
                }
            }
        }
        defer {
            if let e = expanded { GDALClose(e) }
            if let p = expandedVRTPath { VSIUnlink(p) }
        }

        let argv = [
            "-of", "GTiff",
            "-t_srs", "EPSG:3857",
            "-r", "bilinear",
            "-dstalpha",                 // transparent outside the warped footprint
            "-co", "TILED=YES",
            "-co", "BLOCKXSIZE=256",
            "-co", "BLOCKYSIZE=256",
            "-co", "COMPRESS=DEFLATE",
            "-co", "BIGTIFF=IF_SAFER",
        ]
        var cargv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        for a in argv { cargv = CSLAddString(cargv, a) }
        defer { CSLDestroy(cargv) }

        guard let opts = GDALWarpAppOptionsNew(cargv, nil) else { return false }
        defer { GDALWarpAppOptionsFree(opts) }

        // GDAL calls the trampoline on this (background) thread as the warp proceeds;
        // passUnretained is safe because `progress` outlives this synchronous call.
        if let progress {
            GDALWarpAppOptionsSetProgress(opts, gdalProgressTrampoline,
                                          Unmanaged.passUnretained(progress).toOpaque())
        }

        var srcArr: [GDALDatasetH?] = [warpSrc]
        var usageErr: Int32 = 0
        let out = srcArr.withUnsafeMutableBufferPointer { buf in
            GDALWarp(dst, nil, 1, buf.baseAddress, opts, &usageErr)
        }
        guard let outDS = out else { return false }
        GDALClose(outDS)
        return true
    }

    /// Whether the source's first band is paletted (has a colour table) — i.e. its
    /// bytes are palette indices, not colour, and must be expanded before warping.
    private static func hasColorTable(_ ds: GDALDatasetH) -> Bool {
        guard GDALGetRasterCount(ds) >= 1, let band = GDALGetRasterBand(ds, 1) else { return false }
        return GDALGetRasterColorTable(band) != nil
            || GDALGetRasterColorInterpretation(band) == GCI_PaletteIndex
    }

    private static func buildOverviews(path: String, progress: WarpProgress?) {
        guard let ds = GDALOpen(path, GA_Update) else { return }
        defer { GDALClose(ds) }
        var levels: [Int32] = [2, 4, 8, 16, 32]
        let arg = progress.map { Unmanaged.passUnretained($0).toOpaque() }
        _ = GDALBuildOverviews(ds, "AVERAGE", Int32(levels.count), &levels, 0, nil,
                               arg == nil ? nil : gdalProgressTrampoline, arg)
    }

    /// Builds a premultiplied RGBA CGImage from a north-up buffer.
    private static func cgImage(rgba buf: inout [UInt8], width: Int, height: Int) -> CGImage? {
        // CoreGraphics expects premultiplied alpha.
        var i = 0
        while i < buf.count {
            let a = Int(buf[i + 3])
            if a == 0 {
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0
            } else if a != 255 {
                buf[i]     = UInt8(Int(buf[i])     * a / 255)
                buf[i + 1] = UInt8(Int(buf[i + 1]) * a / 255)
                buf[i + 2] = UInt8(Int(buf[i + 2]) * a / 255)
            }
            i += 4
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: cs, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func pngData(rgba buf: inout [UInt8], width: Int, height: Int) -> Data? {
        guard let img = cgImage(rgba: &buf, width: width, height: height) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Dataset pool

    /// A small pool of GDAL dataset handles opened on the same warped file, so
    /// several windows can be read in parallel. A semaphore caps concurrency to the
    /// number of handles; a lock guards check-in / check-out.
    private final class DatasetPool {
        private let path: String
        private var handles: [GDALDatasetH?]
        private let sem: DispatchSemaphore
        private let lock = NSLock()

        init(path: String, size: Int) {
            self.path = path
            self.sem = DispatchSemaphore(value: size)
            self.handles = (0..<size).map { _ in GDALOpen(path, GA_ReadOnly) }
        }

        func acquire() -> GDALDatasetH? {
            sem.wait()
            lock.lock(); defer { lock.unlock() }
            if let idx = handles.firstIndex(where: { $0 != nil }) {
                let h = handles[idx]; handles[idx] = nil; return h
            }
            return GDALOpen(path, GA_ReadOnly)   // fallback, shouldn't normally happen
        }

        func release(_ h: GDALDatasetH?) {
            lock.lock()
            if let slot = handles.firstIndex(where: { $0 == nil }) { handles[slot] = h }
            else { handles.append(h) }
            lock.unlock()
            sem.signal()
        }

        func closeAll() {
            lock.lock()
            for h in handles { if let h { GDALClose(h) } }
            handles.removeAll()
            lock.unlock()
        }
    }
}

// MARK: - Progress plumbing

/// The step a load is in, reported to `GDALRaster.load(onProgress:)` so the caller can
/// label it. Both steps report their own 0…1 fraction; the caller weights them.
public enum WarpPhase: Sendable {
    /// Reprojecting the source to Web Mercator (EPSG:3857) — the heavy step.
    case reprojecting
    /// Building zoom overviews (pyramids) on the warped raster — a shorter tail.
    case buildingOverviews
}

/// Boxes the caller's progress closure so a C `GDALProgressFunc` can reach it through a
/// `void *`. `phase` is set before each GDAL step so the per-step 0…1 it reports is
/// tagged with the step it belongs to.
private final class WarpProgress {
    private let report: (WarpPhase, Double) -> Void
    var phase: WarpPhase = .reprojecting

    init(_ report: @escaping (WarpPhase, Double) -> Void) { self.report = report }

    func emit(_ fraction: Double) {
        report(phase, Swift.max(0, Swift.min(1, fraction)))
    }
}

/// C-callable shim GDAL invokes as a warp / overview build proceeds. `pProgressArg`
/// is the `WarpProgress` passed unretained; returning 1 (TRUE) keeps GDAL going.
private let gdalProgressTrampoline: GDALProgressFunc = { complete, _, arg in
    if let arg {
        Unmanaged<WarpProgress>.fromOpaque(arg).takeUnretainedValue().emit(complete)
    }
    return 1
}
