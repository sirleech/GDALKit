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
    private var gt = [Double](repeating: 0, count: 6)         // geotransform of the warped raster
    private var rasterW = 0
    private var rasterH = 0
    private var bandCount = 0
    private let pool: DatasetPool

    // MARK: - Loading (run off the main thread; the warp is heavy)

    /// Loads and warps a georeferenced raster to Web Mercator on a background
    /// queue. Returns nil if the source can't be opened/warped. Call
    /// `GDALEnvironment.bootstrap()` once before the first load.
    public static func load(from sourceURL: URL) async -> GDALRaster? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: GDALRaster(sourceURL: sourceURL))
            }
        }
    }

    private init?(sourceURL: URL) {
        // 1. Copy the picked file into our sandbox while we hold security-scoped access.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let tmp = FileManager.default.temporaryDirectory
        let srcCopy = tmp.appendingPathComponent("src-\(UUID().uuidString).tif")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: srcCopy)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: srcCopy) }

        // 2. Warp source -> EPSG:3857 tiled GeoTIFF (+ alpha band for clean transparent edges).
        let dst = tmp.appendingPathComponent("warp-\(UUID().uuidString).tif")
        guard GDALRaster.warpToWebMercator(src: srcCopy.path, dst: dst.path) else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
        warpedPath = dst.path

        // 3. Build overviews so zoomed-out reads are fast and smooth.
        GDALRaster.buildOverviews(path: dst.path)

        // 4. Read geo metadata from the warped raster.
        guard let ds = GDALOpen(dst.path, GA_ReadOnly) else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
        GDALGetGeoTransform(ds, &gt)
        rasterW = Int(GDALGetRasterXSize(ds))
        rasterH = Int(GDALGetRasterYSize(ds))
        bandCount = Int(GDALGetRasterCount(ds))
        GDALClose(ds)

        guard rasterW > 0, rasterH > 0, gt[1] != 0, gt[5] != 0, bandCount >= 1 else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }

        // 5. Footprint in Web-Mercator metres (gt[5] is negative → north is gt[3]).
        bounds = MercatorBounds(
            minX: gt[0],
            minY: gt[3] + Double(rasterH) * gt[5],
            maxX: gt[0] + Double(rasterW) * gt[1],
            maxY: gt[3])

        // 6. Pool of read handles for parallel windowed reads (GDAL datasets are
        //    NOT thread-safe). More handles fill a freshly-zoomed screen faster.
        let n = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        pool = DatasetPool(path: dst.path, size: n)
    }

    deinit {
        pool.closeAll()
        try? FileManager.default.removeItem(atPath: warpedPath)
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

    private static func warpToWebMercator(src: String, dst: String) -> Bool {
        guard let srcDS = GDALOpen(src, GA_ReadOnly) else { return false }
        defer { GDALClose(srcDS) }

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

        var srcArr: [GDALDatasetH?] = [srcDS]
        var usageErr: Int32 = 0
        let out = srcArr.withUnsafeMutableBufferPointer { buf in
            GDALWarp(dst, nil, 1, buf.baseAddress, opts, &usageErr)
        }
        guard let outDS = out else { return false }
        GDALClose(outDS)
        return true
    }

    private static func buildOverviews(path: String) {
        guard let ds = GDALOpen(path, GA_Update) else { return }
        defer { GDALClose(ds) }
        var levels: [Int32] = [2, 4, 8, 16, 32]
        _ = GDALBuildOverviews(ds, "AVERAGE", Int32(levels.count), &levels, 0, nil, nil, nil)
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
