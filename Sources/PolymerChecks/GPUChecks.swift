// The GPU renderer against the CPU reference: the same display lists drawn
// both ways must match within a stated tolerance, on the system GPU and on
// the software one (WARP), and a GPU frame that redraws only the damage must
// equal a whole GPU draw.
import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender
import PolymerGPU
import PolymerUI

/// How far a GPU image may be from the CPU reference, in 8-bit steps.
/// Targets hold half floats (11 significant bits) and masks 8-bit coverage;
/// measured on an RTX 5070 and on WARP (2026-11-14): max 1, mean 0.035, no
/// value more than 2 off. The bounds leave a little room for other GPUs.
enum GPUTolerance {
    /// Mean absolute difference over all channel values.
    static let mean = 0.1
    /// Share of channel values more than 2 steps off.
    static let outliers = 0.001
    /// Largest difference anywhere.
    static let max = 4
}

struct ImageDifference: CustomStringConvertible {
    var max = 0
    var mean = 0.0
    /// Channel values more than 2 steps off.
    var outliers = 0
    var count = 0
    var description: String {
        "max \(max), mean \(Double(Int(mean * 1000)) / 1000), \(outliers) of \(count) values off by more than 2"
    }
    var outlierShare: Double { count == 0 ? 0 : Double(outliers) / Double(count) }

    init(_ a: Bitmap, _ b: Bitmap) {
        guard a.width == b.width, a.height == b.height else { max = 255; mean = 255; return }
        var sum = 0
        for i in 0..<a.pixels.count {
            let d = abs(Int(a.pixels[i]) - Int(b.pixels[i]))
            sum += d
            if d > max { max = d }
            if d > 2 { outliers += 1 }
        }
        count = a.pixels.count
        mean = Double(sum) / Double(Swift.max(1, count))
    }

    /// CPU, GPU and their difference times 8, side by side.
    static func strip(_ cpu: Bitmap, _ gpu: Bitmap) -> Bitmap {
        let w = cpu.width, h = cpu.height
        var out = Bitmap(width: w * 3, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                for c in 0..<4 {
                    out.pixels[(y * w * 3 + x) * 4 + c] = cpu.pixels[i + c]
                    out.pixels[(y * w * 3 + w + x) * 4 + c] = gpu.pixels[i + c]
                    out.pixels[(y * w * 3 + 2 * w + x) * 4 + c] = c == 3 ? 255
                        : UInt8(Swift.min(255, abs(Int(cpu.pixels[i + c]) - Int(gpu.pixels[i + c])) * 8))
                }
            }
        }
        return out
    }
}

/// Everything the display list can hold: fractional rects, a path, text,
/// an image, layers (opacity, mask, blur), a material, single and merged
/// glass with dispersion, and a backdrop inside a layer.
@MainActor
func gpuTestScene(root: String, shift: Double = 0) throws -> DisplayList {
    let face = try TextReference.font(root: root, "Inter-Regular.otf")
    var l = DisplayList(width: 480, height: 320, scale: 2)
    for i in 0..<24 {
        let k = Double(i % 8) / 8
        l.fill(Rect(x: Double(i) * 10.3 + shift, y: 0, width: 5.15, height: 160), Color(red: 0.2 + 0.6 * k, green: 0.35, blue: 0.8 - 0.5 * k))
    }
    let title = TextLayout.line("Polymer GPU 0123", font: face, pixelSize: 14)
    l.drawGlyphs(title, font: face, size: 14, at: Point(x: 8.3, y: 20.6), color: .white)
    let small = TextLayout.line("Small grey text, kerned: AVATAR", font: face, pixelSize: 9)
    l.drawGlyphs(small, font: face, size: 9, at: Point(x: 8, y: 33.25), color: Color(white: 0.1))
    l.fill(RoundedRect(Rect(x: 160.4, y: 6.2, width: 30, height: 30), cornerRadius: 15).path(), Color(red: 1, green: 0.5, blue: 0, opacity: 0.8))
    var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
    for y in 0..<16 {
        for x in 0..<16 {
            let i = (y * 16 + x) * 4, on = (x / 4 + y / 4) % 2 == 0
            pixels[i] = on ? 240 : 20; pixels[i + 1] = UInt8(x * 16); pixels[i + 2] = UInt8(y * 16); pixels[i + 3] = UInt8(255 - x * 8)
        }
    }
    l.draw(RasterImage(Bitmap(width: 16, height: 16, pixels: pixels)), in: Rect(x: 200.3, y: 6, width: 32.5, height: 30))
    l.layer(LayerEffect(opacity: 0.6), area: Rect(x: 10, y: 42, width: 60, height: 40)) { l in
        l.fill(Rect(x: 10, y: 42, width: 40, height: 30), Color(red: 1, green: 1, blue: 1))
        l.fill(Rect(x: 30, y: 52, width: 40, height: 30), Color(red: 0, green: 0.8, blue: 0.4))
    }
    let mask = RoundedRect(Rect(x: 80, y: 42, width: 60, height: 40), cornerRadius: 12)
    l.layer(LayerEffect(opacity: 1, mask: mask, blur: 2), area: mask.rect) { l in
        l.fill(Rect(x: 85, y: 48, width: 50, height: 10), .white)
        l.drawGlyphs(title, font: face, size: 14, at: Point(x: 84, y: 76), color: Color(red: 1, green: 0.9, blue: 0.2))
    }
    l.drawBackdrop(RoundedRect(Rect(x: 150, y: 46, width: 80, height: 34), cornerRadius: 8), .material(blur: 6, tint: Color(white: 0.1, opacity: 0.5)))
    let glass = GlassStyle(refraction: 8, bezel: 10, frost: 1.5, tint: Color(white: 1, opacity: 0.08), rim: 0.6, dispersion: 0.2)
    l.drawBackdrop(RoundedRect(Rect(x: 10, y: 92, width: 100, height: 40), cornerRadius: 20), .glass(glass))
    l.drawBackdrop(.union([RoundedRect(Rect(x: 122, y: 92, width: 48, height: 40), cornerRadius: 20),
                           RoundedRect(Rect(x: 176, y: 97, width: 54, height: 30), cornerRadius: 15)], smoothing: 12),
                   .glass(GlassStyle(refraction: 6, bezel: 8, frost: 0.8, tint: Color(red: 0.3, green: 0.6, blue: 1, opacity: 0.15), rim: 0.5)))
    l.drawGlyphs(title, font: face, size: 14, at: Point(x: 20, y: 117), color: .white)
    l.layer(LayerEffect(opacity: 0.85), area: Rect(x: 0, y: 136, width: 240, height: 24)) { l in
        for i in 0..<12 { l.fill(Rect(x: Double(i) * 20 + shift, y: 136, width: 10, height: 24), Color(white: Double(i) / 12)) }
        l.drawBackdrop(RoundedRect(Rect(x: 60, y: 139, width: 120, height: 18), cornerRadius: 9), .glass(glass))
    }
    return l
}

@MainActor let gpuChecks: [Check] = [
    Check("render.gpu") { c in
        guard GPU.isAvailable else {
            c.note("no GPU backend for this OS yet (Metal comes with the Mac session)")
            return
        }
        let dir = Path.join(c.outputDirectory, "gpu")
        try Platform.files.createDirectory(dir)
        let background = Color(white: 0.08)
        let scene = try gpuTestScene(root: c.root)
        var canvas = Canvas(width: scene.width, height: scene.height, scale: scene.scale, background: background)
        canvas.draw(scene)
        let reference = canvas.bitmap

        // The glass sample screen, and a frame of it scrolled.
        let tree = try sampleTree("glass", root: c.root, scale: 2)!
        let screen = tree.render(background: .black)
        let screenList = tree.displayList!

        let clock = ContinuousClock()
        for adapter in [GPUAdapter.hardware, .software] {
            let backend: any GPUBackend
            do { backend = try GPU.makeBackend(adapter) } catch {
                if adapter == .hardware { c.note("no hardware GPU: \(error)"); continue }
                c.fail("\(error)"); continue
            }
            let tag = adapter == .hardware ? "hardware" : "warp"
            let renderer = try GPURenderer(backend: backend)
            func expectClose(_ gpu: Bitmap, _ cpu: Bitmap, _ what: String) {
                let d = ImageDifference(gpu, cpu)
                c.note("\(backend.name), \(what): \(d)")
                c.expect(d.mean <= GPUTolerance.mean && d.outlierShare <= GPUTolerance.outliers && d.max <= GPUTolerance.max,
                         "\(backend.name), \(what): \(d); allowed mean \(GPUTolerance.mean), \(GPUTolerance.outliers * 100)% over 2, max \(GPUTolerance.max). See out/checks/gpu/")
            }

            let target = try renderer.makeTarget(width: scene.width, height: scene.height)
            defer { backend.destroy(target) }
            try renderer.draw(scene, into: target, background: background)
            let image = try renderer.read(target)
            try Platform.files.write(PNG.encode(ImageDifference.strip(reference, image)), to: Path.join(dir, "scene-\(tag).png"))
            expectClose(image, reference, "test scene")

            // Only the damage of a changed frame, drawn over the last one, equals a whole draw.
            let moved = try gpuTestScene(root: c.root, shift: 3)
            let damage = moved.damage(since: scene)
            c.expect(!damage.isEmpty, "the moved scene has damage")
            try renderer.draw(moved, into: target, regions: damage, background: background)
            let partial = try renderer.read(target)
            let whole = try renderer.makeTarget(width: scene.width, height: scene.height)
            defer { backend.destroy(whole) }
            try renderer.draw(moved, into: whole, background: background)
            let wholeImage = try renderer.read(whole)
            let pd = ImageDifference(partial, wholeImage)
            c.expect(pd.max <= 1, "\(backend.name): a partial redraw differs from a whole one: \(pd)")

            let st = try renderer.makeTarget(width: screenList.width, height: screenList.height)
            defer { backend.destroy(st) }
            try renderer.draw(screenList, into: st, background: .black)
            let screenImage = try renderer.read(st)
            try Platform.files.write(PNG.encode(ImageDifference.strip(screen, screenImage)), to: Path.join(dir, "glass-screen-\(tag).png"))
            expectClose(screenImage, screen, "glass screen")

            // Speed: the whole scene, drawn and finished (no readback).
            let runs = adapter == .hardware ? 20 : 3
            let start = clock.now
            for _ in 0..<runs { try renderer.draw(scene, into: target, background: background) }
            let ms = (clock.now - start).seconds * 1000 / Double(runs)
            c.note("\(backend.name): test scene \(Double(Int(ms * 100)) / 100) ms per frame (CPU work, submit and wait)")
        }
        _ = tree
    },
]
