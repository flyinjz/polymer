// `polymer bench`: what a frame costs, measured. It builds a representative
// screen (a library list with a glass bar over it), then times the two stages
// a window runs each frame, over and over, with `ContinuousClock`:
// layout+record (ViewTree.record) and software rasterisation (Canvas.draw of
// the recorded list into a fresh canvas). Nothing here is estimated: every
// number is a real measurement of a real frame, and the same screen on the
// same machine gives the same work each time.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerText
import PolymerUI
import PolymerChecks

/// One stage's times over the frames, in milliseconds.
struct BenchStats: Equatable {
    /// How many frames were measured.
    let samples: Int
    let p50: Double
    let p95: Double
    let max: Double
}

/// Nearest rank: the value at or below which `p` of the samples lie.
func benchPercentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

func benchStats(_ times: [Double]) -> BenchStats {
    let sorted = times.sorted()
    return BenchStats(samples: sorted.count, p50: benchPercentile(sorted, 0.5),
                      p95: benchPercentile(sorted, 0.95), max: sorted.last ?? 0)
}

/// What one bench run measured.
struct BenchResult {
    let frames: Int
    let width: Double, height: Double
    /// Points per pixel the screen was drawn at.
    let scale: Double
    /// Rows in the list.
    let rows: Int
    /// Drawing items in the recorded list, and the pixels it covers.
    let items: Int, pixels: Int
    let layout: BenchStats
    let raster: BenchStats
}

// MARK: The screen

/// One row of the list: a title, a spacer and a length, as a library row is.
struct BenchRow: View {
    let index: Int
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            Text("Track \(index + 1)").font(font)
            Spacer()
            Text("3:\(10 + index % 45)").font(font).foregroundStyle(Color(white: 0.6))
        }
        .padding(horizontal: 12, vertical: 5)
    }
}

/// A screen worth measuring: a header, a list of rows, and a glass bar over
/// them (the shape of a PolymerDesign screen: text, lines, a spacer, glass).
struct BenchShowcase: View {
    let font: Font
    let rows: Int
    let width: Double, height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Library").font(font)
                Spacer()
                Text("20 000 tracks").font(font).foregroundStyle(Color(white: 0.6))
            }
            .padding(horizontal: 12, vertical: 10)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows) { BenchRow(index: $0, font: font) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Play").font(font).padding(horizontal: 12, vertical: 6)
                Text("Next").font(font).padding(horizontal: 12, vertical: 6)
                Spacer()
                Text("\(rows) shown").font(font).foregroundStyle(Color(white: 0.6))
            }
            .padding(horizontal: 12, vertical: 10)
            .glassEffect(.regular, in: Capsule())
            .padding(12)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color(white: 0.063))
    }
}

// MARK: The measurement

/// Times `frames` frames of the showcase: first layout+record, then drawing
/// the recorded list into a fresh canvas. Three frames run first to load the
/// fonts and fill the glyph cache, as a window's first frames do.
@MainActor
func runBench(frames: Int = 20, width: Double = 720, height: Double = 480, scale: Double = 1,
              root: String = ".") throws -> BenchResult {
    let font = Font(try TextReference.font(root: root, "Geist-Regular.otf"), size: 13)
    let rows = max(4, Int((height - 96) / 28))
    var environment = EnvironmentValues()
    environment.displayScale = scale
    let tree = ViewTree(BenchShowcase(font: font, rows: rows, width: width, height: height), environment: environment)
    let size = ProposedViewSize(width: width, height: height)
    let background = Color(white: 0.063)
    let glyphs = GlyphCache()
    let clock = ContinuousClock()
    var layout: [Double] = [], raster: [Double] = []
    var items = 0, pixels = 0
    // Warm-up frames: the first frame builds the tree and rasterises every glyph.
    for frame in 0..<(frames + 3) {
        // A frame that shows changed content lays out again, then records; this is that frame.
        tree.proposedSize = size
        let start = clock.now
        let (list, _) = tree.record(background: background)
        let recorded = clock.now
        var canvas = Canvas(width: list.width, height: list.height, scale: list.scale, background: background)
        canvas.glyphCache = glyphs
        canvas.draw(list)
        let drawn = clock.now
        if frame >= 3 {
            layout.append((recorded - start).seconds * 1000)
            raster.append((drawn - recorded).seconds * 1000)
            items = list.items.count
            pixels = list.width * list.height
        }
    }
    return BenchResult(frames: frames, width: width, height: height, scale: scale, rows: rows,
                       items: items, pixels: pixels, layout: benchStats(layout), raster: benchStats(raster))
}

/// `polymer bench [--frames N] [--width W] [--height H]`: prints what a frame
/// of a representative screen costs, stage by stage.
@MainActor
func benchCommand(frames: Int, width: Double, height: Double, json: Bool) throws {
    guard frames >= 1, frames <= 10_000 else {
        print("--frames takes how many frames to measure, at least 1 and at most 10000; got \(frames).")
        Platform.process.exit(2)
    }
    guard width >= 16, width <= 8192, height >= 16, height <= 8192 else {
        print("--width and --height take the screen's size in points, from 16 to 8192; got \(fixed(width))x\(fixed(height)).")
        Platform.process.exit(2)
    }
    let r = try runBench(frames: frames, width: width, height: height)
    func stage(_ s: BenchStats) -> String {
        "p50 \(fixed(s.p50)) ms  p95 \(fixed(s.p95)) ms  max \(fixed(s.max)) ms"
    }
    if json {
        func stats(_ s: BenchStats) -> JSON {
            .object(["p50": .number(s.p50), "p95": .number(s.p95), "max": .number(s.max), "samples": .number(Double(s.samples))])
        }
        let o: JSON = .object([
            "frames": .number(Double(r.frames)), "width": .number(r.width), "height": .number(r.height),
            "scale": .number(r.scale), "rows": .number(Double(r.rows)), "items": .number(Double(r.items)),
            "pixels": .number(Double(r.pixels)), "layout": stats(r.layout), "raster": stats(r.raster),
        ])
        print(o.pretty, terminator: "")
        return
    }
    print("bench: \(r.frames) frames of \(fixed(r.width))x\(fixed(r.height)) points at scale \(fixed(r.scale)), \(r.rows) rows, \(r.items) items over \(r.pixels) pixels.")
    print("layout+record  \(stage(r.layout))")
    print("raster         \(stage(r.raster))")
}
