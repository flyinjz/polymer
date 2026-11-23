// Bitmaps and PNG, our own codec.
import PolymerBase
import Synchronization

/// Sampling mode when drawing an image at a size other than its own pixels.
public enum ImageFilter: Hashable, Sendable {
    case nearest
    case bilinear
}

/// An immutable image ready for display lists and views. Equality and hashing
/// are O(1) by identity token so display-list diffing never scans pixels.
public final class RenderImage: Hashable, Sendable {
    private static let nextToken = Atomic<UInt64>(1)
    private let token: UInt64
    public let bitmap: Bitmap

    public var width: Int { bitmap.width }
    public var height: Int { bitmap.height }
    public var size: Size { Size(width: Double(bitmap.width), height: Double(bitmap.height)) }

    public init(_ bitmap: Bitmap) {
        self.token = Self.nextToken.add(1, ordering: .relaxed).oldValue
        self.bitmap = bitmap
    }

    public static func png(_ data: [UInt8]) throws(ImageError) -> RenderImage {
        RenderImage(try PNG.decode(data))
    }

    public static func == (a: RenderImage, b: RenderImage) -> Bool { a.token == b.token }
    public func hash(into h: inout Hasher) { h.combine(token) }
}

/// 8-bit RGBA, sRGB-encoded, straight alpha, rows top to bottom.
public struct Bitmap: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = width; self.height = height
        var p = [UInt8](repeating: 0, count: width * height * 4)
        if fill != (0, 0, 0, 0) {
            for i in stride(from: 0, to: p.count, by: 4) { p[i] = fill.0; p[i + 1] = fill.1; p[i + 2] = fill.2; p[i + 3] = fill.3 }
        }
        pixels = p
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "Bitmap needs width * height * 4 bytes")
        self.width = width; self.height = height; self.pixels = pixels
    }

    @inlinable public subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// Luma of each pixel as 0...1 sRGB-encoded grey (for grey images: the grey value).
    public var grey: [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for k in 0..<out.count {
            let i = k * 4
            out[k] = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
        }
        return out
    }
}

public struct ImageError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { "image: \(message)" }
}

public enum PNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func decode(_ data: [UInt8]) throws(ImageError) -> Bitmap {
        guard data.count > 8, Array(data[0..<8]) == signature else { throw ImageError("not a PNG file") }
        var pos = 8
        var width = 0, height = 0, depth = 0, colorType = 0, interlace = 0
        var idat: [UInt8] = []
        var palette: [UInt8] = []
        var trns: [UInt8] = []
        while pos + 8 <= data.count {
            let len = Int(data.u32(at: pos))
            let type = String(decoding: data[pos + 4..<pos + 8], as: UTF8.self)
            let body = pos + 8
            guard body + len + 4 <= data.count else { throw ImageError("chunk \(type) runs past the end") }
            switch type {
            case "IHDR":
                width = Int(data.u32(at: body)); height = Int(data.u32(at: body + 4))
                depth = Int(data[body + 8]); colorType = Int(data[body + 9]); interlace = Int(data[body + 12])
            case "PLTE": palette = Array(data[body..<body + len])
            case "tRNS": trns = Array(data[body..<body + len])
            case "IDAT": idat.append(contentsOf: data[body..<body + len])
            case "IEND": pos = data.count; continue
            default: break
            }
            pos = body + len + 4
        }
        guard width > 0, height > 0 else { throw ImageError("missing IHDR") }
        guard interlace == 0 else { throw ImageError("interlaced PNG is not supported; save without interlacing") }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw ImageError("unknown colour type \(colorType)")
        }
        guard depth == 8 || depth == 16 || (depth < 8 && (colorType == 0 || colorType == 3)) else {
            throw ImageError("bit depth \(depth) with colour type \(colorType) is not supported")
        }
        let raw: [UInt8]
        do { raw = try Zlib.decompress(idat) } catch { throw ImageError(error.description) }
        let bitsPerPixel = channels * depth
        let stride = (width * bitsPerPixel + 7) / 8
        let bpp = max(1, bitsPerPixel / 8)
        guard raw.count >= (stride + 1) * height else { throw ImageError("image data too short") }
        var rows = [UInt8](repeating: 0, count: stride * height)
        try unfilter(raw, into: &rows, stride: stride, height: height, bpp: bpp)

        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = y * stride
            for x in 0..<width {
                func sample(_ c: Int) -> UInt8 {
                    switch depth {
                    case 16: return rows[row + (x * channels + c) * 2]
                    case 8: return rows[row + x * channels + c]
                    default:
                        let bit = x * depth
                        let v = (rows[row + bit / 8] >> UInt8(8 - depth - bit % 8)) & UInt8((1 << depth) - 1)
                        return colorType == 3 ? v : UInt8(Int(v) * 255 / ((1 << depth) - 1))
                    }
                }
                let o = (y * width + x) * 4
                switch colorType {
                case 0:
                    let g = sample(0); out[o] = g; out[o + 1] = g; out[o + 2] = g
                case 2:
                    out[o] = sample(0); out[o + 1] = sample(1); out[o + 2] = sample(2)
                case 3:
                    let i = Int(sample(0))
                    guard i * 3 + 2 < palette.count else { throw ImageError("palette index out of range") }
                    out[o] = palette[i * 3]; out[o + 1] = palette[i * 3 + 1]; out[o + 2] = palette[i * 3 + 2]
                    out[o + 3] = i < trns.count ? trns[i] : 255
                case 4:
                    let g = sample(0); out[o] = g; out[o + 1] = g; out[o + 2] = g; out[o + 3] = sample(1)
                default:
                    out[o] = sample(0); out[o + 1] = sample(1); out[o + 2] = sample(2); out[o + 3] = sample(3)
                }
            }
        }
        return Bitmap(width: width, height: height, pixels: out)
    }

    static func unfilter(_ raw: [UInt8], into rows: inout [UInt8], stride: Int, height: Int, bpp: Int) throws(ImageError) {
        for y in 0..<height {
            let f = raw[y * (stride + 1)]
            let src = y * (stride + 1) + 1
            let dst = y * stride
            for i in 0..<stride {
                let x = raw[src + i]
                let a = i >= bpp ? Int(rows[dst + i - bpp]) : 0
                let b = y > 0 ? Int(rows[dst - stride + i]) : 0
                let c = (i >= bpp && y > 0) ? Int(rows[dst - stride + i - bpp]) : 0
                let v: Int
                switch f {
                case 0: v = 0
                case 1: v = a
                case 2: v = b
                case 3: v = (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    v = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                default: throw ImageError("unknown row filter \(f)")
                }
                rows[dst + i] = x &+ UInt8(truncatingIfNeeded: v)
            }
        }
    }

    /// Encodes as 8-bit RGBA (or grey when every pixel is opaque grey).
    public static func encode(_ image: Bitmap) -> [UInt8] {
        var isGrey = true
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            let p = image.pixels
            if p[i] != p[i + 1] || p[i] != p[i + 2] || p[i + 3] != 255 { isGrey = false; break }
        }
        let channels = isGrey ? 1 : 4
        let stride = image.width * channels
        var raw: [UInt8] = []
        raw.reserveCapacity((stride + 1) * image.height)
        var prev = [UInt8](repeating: 0, count: stride)
        var cur = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        var trial = [UInt8](repeating: 0, count: stride)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                if isGrey { cur[x] = image.pixels[o] } else { for c in 0..<4 { cur[x * 4 + c] = image.pixels[o + c] } }
            }
            // Pick the filter with the smallest sum of absolute values.
            var bestFilter: UInt8 = 0, bestScore = Int.max
            for f in 0..<5 {
                var score = 0
                for i in 0..<stride {
                    let a = i >= channels ? Int(cur[i - channels]) : 0
                    let b = Int(prev[i])
                    let c = i >= channels ? Int(prev[i - channels]) : 0
                    let pred: Int
                    switch f {
                    case 0: pred = 0
                    case 1: pred = a
                    case 2: pred = b
                    case 3: pred = (a + b) / 2
                    default:
                        let p = a + b - c
                        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                        pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                    }
                    let v = cur[i] &- UInt8(truncatingIfNeeded: pred)
                    trial[i] = v
                    score += v < 128 ? Int(v) : 256 - Int(v)
                }
                if score < bestScore { bestScore = score; bestFilter = UInt8(f); swap(&best, &trial) }
            }
            raw.append(bestFilter)
            raw.append(contentsOf: best)
            swap(&prev, &cur)
        }
        var out = signature
        func chunk(_ type: String, _ body: [UInt8]) {
            out.append(u32: UInt32(body.count))
            let t = Array(type.utf8)
            out.append(contentsOf: t)
            out.append(contentsOf: body)
            out.append(u32: Checksum.crc32(body, continuing: Checksum.crc32(t)))
        }
        var ihdr: [UInt8] = []
        ihdr.append(u32: UInt32(image.width)); ihdr.append(u32: UInt32(image.height))
        ihdr.append(contentsOf: [8, isGrey ? 0 : 6, 0, 0, 0])
        chunk("IHDR", ihdr)
        // sRGB, perceptual intent.
        chunk("sRGB", [0])
        chunk("IDAT", Zlib.compress(raw))
        chunk("IEND", [])
        return out
    }
}
