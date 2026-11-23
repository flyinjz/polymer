// Skyline bin-packed single-channel (r8Unorm) glyph texture atlas.
// Rasterizes glyphs via PolymerText with subpixel positioning and stem darkening,
// maintains 1px padding to prevent bilinear bleed, tracks dirty regions, and
// uploads into GPUTexture pages when attached to a GPUDevice.
import PolymerBase
import PolymerText

/// Cache key identifying a rasterized glyph variant in `GlyphAtlas`.
public struct GlyphAtlasKey: Hashable, Sendable {
    public var fontID: UInt64
    public var glyphID: GlyphID
    /// Pixel size quantized to quarter-pixel steps (`Int((pixelSize * 4).rounded())`).
    public var quantizedPPEM: Int
    /// Fractional horizontal subpixel bucket (`0..<subpixelBuckets`).
    public var subpixelXBucket: Int
    /// Fractional vertical subpixel bucket (`0..<subpixelBuckets`).
    public var subpixelYBucket: Int
    /// Quantized linear luminance bucket (`0...16`) for stem darkening.
    public var luminanceBucket: Int
    public var stemDarkening: Bool

    public init(
        fontID: UInt64,
        glyphID: GlyphID,
        quantizedPPEM: Int,
        subpixelXBucket: Int,
        subpixelYBucket: Int = 0,
        luminanceBucket: Int,
        stemDarkening: Bool = true
    ) {
        self.fontID = fontID
        self.glyphID = glyphID
        self.quantizedPPEM = quantizedPPEM
        self.subpixelXBucket = subpixelXBucket
        self.subpixelYBucket = subpixelYBucket
        self.luminanceBucket = luminanceBucket
        self.stemDarkening = stemDarkening
    }

    @inline(__always)
    public static func fontID(for font: FontFace) -> UInt64 {
        UInt64(UInt(bitPattern: ObjectIdentifier(font)))
    }
}

/// Location and metrics of a packed glyph inside a `GlyphAtlas` page.
public struct AtlasRegion: Equatable, Sendable {
    public var pageIndex: Int
    /// Exact glyph coverage rectangle inside the atlas page (excluding padding).
    public var pixelRect: PixelRect
    /// Normalized texture coordinates (`0...1`).
    public var u0: Float
    public var v0: Float
    public var u1: Float
    public var v1: Float
    /// Pixel offset from the quantized baseline-left integer origin to the mask's top-left corner.
    public var bearingX: Int
    public var bearingY: Int

    public init(
        pageIndex: Int,
        pixelRect: PixelRect,
        u0: Float,
        v0: Float,
        u1: Float,
        v1: Float,
        bearingX: Int,
        bearingY: Int
    ) {
        self.pageIndex = pageIndex
        self.pixelRect = pixelRect
        self.u0 = u0
        self.v0 = v0
        self.u1 = u1
        self.v1 = v1
        self.bearingX = bearingX
        self.bearingY = bearingY
    }

    public static let empty = AtlasRegion(
        pageIndex: 0,
        pixelRect: PixelRect(x: 0, y: 0, width: 0, height: 0),
        u0: 0, v0: 0, u1: 0, v1: 0,
        bearingX: 0, bearingY: 0
    )

    @inlinable
    public var isEmpty: Bool { pixelRect.isEmpty }
}

/// One single-channel (`r8Unorm`) texture atlas page using skyline bottom-left bin packing.
public final class GlyphAtlasPage {
    private struct SkylineNode {
        var x: Int
        var y: Int
        var width: Int
    }

    public let pageIndex: Int
    public let width: Int
    public let height: Int
    public let padding: Int

    /// CPU-side single-channel coverage bytes (`width * height`).
    public private(set) var pixels: [UInt8]
    /// Unuploaded dirty rectangles since the last `uploadDirtyRegions()`.
    public private(set) var dirtyRects: [PixelRect] = []
    /// Attached GPU texture, if any.
    public private(set) var texture: (any GPUTexture)?

    private var skyline: [SkylineNode]
    public private(set) var packedCount: Int = 0
    public private(set) var usedArea: Int = 0

    public init(pageIndex: Int, width: Int, height: Int, padding: Int = 1) {
        precondition(width >= 16 && height >= 16 && padding >= 0)
        self.pageIndex = pageIndex
        self.width = width
        self.height = height
        self.padding = padding
        self.pixels = [UInt8](repeating: 0, count: width * height)
        self.skyline = [SkylineNode(x: padding, y: padding, width: max(0, width - padding))]
    }

    /// Resets the skyline and clears all page pixels.
    public func reset() {
        for i in 0..<pixels.count { pixels[i] = 0 }
        skyline = [SkylineNode(x: padding, y: padding, width: max(0, width - padding))]
        packedCount = 0
        usedArea = 0
        dirtyRects = [PixelRect(x: 0, y: 0, width: width, height: height)]
    }

    /// Packs a rectangle of `(glyphWidth, glyphHeight)` with `padding` separation.
    /// Returns the glyph's exact `PixelRect` (excluding padding), or `nil` if the page is full.
    public func allocate(width glyphWidth: Int, height glyphHeight: Int) -> PixelRect? {
        guard glyphWidth > 0 && glyphHeight > 0 else { return nil }
        let allocW = glyphWidth + padding
        let allocH = glyphHeight + padding
        guard allocW <= width - padding, allocH <= height - padding else { return nil }

        var bestIndex = -1
        var bestY = Int.max
        var bestWidth = Int.max

        for i in 0..<skyline.count {
            if let y = fitHeight(at: i, width: allocW, height: allocH) {
                if y < bestY || (y == bestY && skyline[i].width < bestWidth) {
                    bestIndex = i
                    bestY = y
                    bestWidth = skyline[i].width
                }
            }
        }

        guard bestIndex >= 0 else { return nil }
        let bestX = skyline[bestIndex].x

        // Insert new skyline segment covering `[bestX, bestX + allocW)` at `bestY + allocH`.
        let newNode = SkylineNode(x: bestX, y: bestY + allocH, width: allocW)
        skyline.insert(newNode, at: bestIndex)

        let i = bestIndex + 1
        while i < skyline.count {
            let prevRight = skyline[i - 1].x + skyline[i - 1].width
            if skyline[i].x < prevRight {
                let shrink = prevRight - skyline[i].x
                skyline[i].x += shrink
                skyline[i].width -= shrink
                if skyline[i].width <= 0 {
                    skyline.remove(at: i)
                    continue
                }
                break
            } else {
                break
            }
        }

        // Merge adjacent skyline segments at the same height.
        var j = 0
        while j + 1 < skyline.count {
            if skyline[j].y == skyline[j + 1].y {
                skyline[j].width += skyline[j + 1].width
                skyline.remove(at: j + 1)
            } else {
                j += 1
            }
        }

        packedCount += 1
        usedArea += allocW * allocH
        return PixelRect(x: bestX, y: bestY, width: glyphWidth, height: glyphHeight)
    }

    private func fitHeight(at index: Int, width allocW: Int, height allocH: Int) -> Int? {
        let x = skyline[index].x
        if x + allocW > width { return nil }
        var widthLeft = allocW
        var i = index
        var maxY = skyline[index].y
        while widthLeft > 0 {
            if i >= skyline.count { return nil }
            if skyline[i].y > maxY { maxY = skyline[i].y }
            if maxY + allocH > height { return nil }
            widthLeft -= skyline[i].width
            i += 1
        }
        return maxY
    }

    /// Copies floating-point coverage (`0...1`) into `rect` and records a dirty upload region.
    public func writeCoverage(_ coverage: [Float], into rect: PixelRect) {
        guard !rect.isEmpty, coverage.count >= rect.width * rect.height else { return }
        for row in 0..<rect.height {
            let dstRow = (rect.y + row) * width + rect.x
            let srcRow = row * rect.width
            for col in 0..<rect.width {
                let v = coverage[srcRow + col]
                pixels[dstRow + col] = UInt8(min(max(v * 255.0 + 0.5, 0.0), 255.0))
            }
        }
        dirtyRects.append(rect)
    }

    /// Attaches a `r8Unorm` GPU texture created from `device` if not already attached.
    public func attachTexture(from device: any GPUDevice) -> any GPUTexture {
        if let existing = texture { return existing }
        let tex = device.makeTexture(
            width: width,
            height: height,
            format: .r8Unorm,
            usage: [.sampled, .transferDst],
            label: "GlyphAtlasPage[\(pageIndex)]"
        )
        self.texture = tex
        // Ensure existing pixels are queued for initial upload.
        if packedCount > 0 && dirtyRects.isEmpty {
            dirtyRects.append(PixelRect(x: 0, y: 0, width: width, height: height))
        }
        return tex
    }

    /// Uploads all pending dirty rectangles to the attached GPU texture.
    public func uploadDirtyRegions() {
        guard let tex = texture, !dirtyRects.isEmpty else { return }
        // Merge dirty rects into a single bounding rect to minimize GPU transfer calls.
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for r in dirtyRects where !r.isEmpty {
            minX = min(minX, r.x)
            minY = min(minY, r.y)
            maxX = max(maxX, r.x + r.width)
            maxY = max(maxY, r.y + r.height)
        }
        dirtyRects.removeAll(keepingCapacity: true)
        guard minX < maxX, minY < maxY else { return }

        let region = PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        var slice = [UInt8](repeating: 0, count: region.width * region.height)
        for row in 0..<region.height {
            let srcStart = (region.y + row) * width + region.x
            let dstStart = row * region.width
            for col in 0..<region.width {
                slice[dstStart + col] = pixels[srcStart + col]
            }
        }
        slice.withUnsafeBytes { raw in
            tex.upload(bytes: raw, bytesPerRow: region.width, region: region)
        }
    }
}

/// Multi-page skyline glyph texture atlas backed by `PolymerText`.
public final class GlyphAtlas {
    public let pageWidth: Int
    public let pageHeight: Int
    public let padding: Int
    public let maxPages: Int
    public let subpixelBuckets: Int

    public private(set) var pages: [GlyphAtlasPage]
    public private(set) var hits: Int = 0
    public private(set) var misses: Int = 0
    public private(set) var evictions: Int = 0

    /// Underlying outline/mask cache reused across rasterizations.
    public let glyphCache: GlyphCache

    private var entries: [GlyphAtlasKey: AtlasRegion] = [:]
    private var retainedFaces: [UInt64: FontFace] = [:]

    public init(
        pageWidth: Int = 1024,
        pageHeight: Int = 1024,
        padding: Int = 1,
        maxPages: Int = 4,
        subpixelBuckets: Int = 4
    ) {
        self.pageWidth = max(32, pageWidth)
        self.pageHeight = max(32, pageHeight)
        self.padding = max(1, padding)
        self.maxPages = max(1, maxPages)
        self.subpixelBuckets = max(1, subpixelBuckets)
        self.pages = [GlyphAtlasPage(pageIndex: 0, width: self.pageWidth, height: self.pageHeight, padding: self.padding)]
        self.glyphCache = GlyphCache()
    }

    /// Number of cached glyph entries currently resident in the atlas.
    public var entryCount: Int { entries.count }

    /// All non-empty packed regions currently stored in the atlas.
    public var allRegions: [AtlasRegion] {
        entries.values.filter { !$0.isEmpty }
    }

    /// Quantizes a pixel coordinate `pos` into `(integerOrigin, bucket, quantizedFraction)`.
    @inline(__always)
    public func quantizePosition(_ pos: Double) -> (integer: Int, bucket: Int, fraction: Double) {
        let b = subpixelBuckets
        let q = Int((pos * Double(b)).rounded())
        let integer = q >= 0 ? (q / b) : ((q - b + 1) / b)
        let bucket = q - integer * b
        return (integer, bucket, Double(bucket) / Double(b))
    }

    /// Looks up or rasterizes and packs a glyph into the atlas.
    public func glyph(
        font: FontFace,
        glyphID: GlyphID,
        pixelSize: Double,
        fractionalX: Double = 0.0,
        fractionalY: Double = 0.0,
        luminance: Double = 1.0,
        options: TextRenderingOptions = .standard
    ) -> AtlasRegion {
        let fontID = GlyphAtlasKey.fontID(for: font)
        let qPPEM = max(1, Int((pixelSize * 4.0).rounded()))
        let fxNorm = fractionalX - fractionalX.rounded(.down)
        let fyNorm = fractionalY - fractionalY.rounded(.down)
        let bucketX = min(subpixelBuckets - 1, max(0, Int((fxNorm * Double(subpixelBuckets)).rounded(.down))))
        let bucketY = min(subpixelBuckets - 1, max(0, Int((fyNorm * Double(subpixelBuckets)).rounded(.down))))
        let lumBucket = min(16, max(0, Int((min(max(luminance, 0.0), 1.0) * 16.0).rounded())))

        let key = GlyphAtlasKey(
            fontID: fontID,
            glyphID: glyphID,
            quantizedPPEM: qPPEM,
            subpixelXBucket: bucketX,
            subpixelYBucket: bucketY,
            luminanceBucket: lumBucket,
            stemDarkening: options.stemDarkening
        )

        if let cached = entries[key] {
            hits += 1
            return cached
        }

        misses += 1
        retainedFaces[fontID] = font

        let fxQ = Double(bucketX) / Double(subpixelBuckets)
        let fyQ = Double(bucketY) / Double(subpixelBuckets)
        let lumQ = Double(lumBucket) / 16.0
        let ppemQ = Double(qPPEM) * 0.25

        let mask = GlyphRenderer.mask(
            font: font,
            glyph: glyphID,
            pixelSize: ppemQ,
            x: fxQ,
            y: fyQ,
            luminance: lumQ,
            options: options,
            cache: glyphCache
        )

        guard mask.width > 0 && mask.height > 0 && !mask.coverage.isEmpty else {
            entries[key] = .empty
            return .empty
        }

        guard let (pageIndex, rect) = allocateMask(width: mask.width, height: mask.height) else {
            return .empty
        }

        let page = pages[pageIndex]
        page.writeCoverage(mask.coverage, into: rect)

        let invW = 1.0 / Float(page.width)
        let invH = 1.0 / Float(page.height)
        let region = AtlasRegion(
            pageIndex: pageIndex,
            pixelRect: rect,
            u0: Float(rect.x) * invW,
            v0: Float(rect.y) * invH,
            u1: Float(rect.x + rect.width) * invW,
            v1: Float(rect.y + rect.height) * invH,
            bearingX: mask.left,
            bearingY: mask.top
        )
        entries[key] = region
        return region
    }

    private func allocateMask(width: Int, height: Int) -> (pageIndex: Int, rect: PixelRect)? {
        // Try existing pages first (preferring the latest page).
        for idx in stride(from: pages.count - 1, through: 0, by: -1) {
            if let r = pages[idx].allocate(width: width, height: height) {
                return (idx, r)
            }
        }
        // Grow by adding a new page if within maxPages.
        if pages.count < maxPages {
            let newPage = GlyphAtlasPage(pageIndex: pages.count, width: pageWidth, height: pageHeight, padding: padding)
            pages.append(newPage)
            if let r = newPage.allocate(width: width, height: height) {
                return (newPage.pageIndex, r)
            }
            return nil
        }
        // Evict and reset all pages cleanly when full.
        evictions += 1
        reset()
        if let r = pages[0].allocate(width: width, height: height) {
            return (0, r)
        }
        return nil
    }

    /// Attaches textures to all atlas pages and uploads all dirty glyph regions.
    public func flush(to device: any GPUDevice) {
        for page in pages {
            _ = page.attachTexture(from: device)
            page.uploadDirtyRegions()
        }
    }

    /// Clears all cached glyphs and resets all pages.
    public func reset() {
        entries.removeAll(keepingCapacity: true)
        retainedFaces.removeAll(keepingCapacity: true)
        for page in pages {
            page.reset()
        }
    }
}
