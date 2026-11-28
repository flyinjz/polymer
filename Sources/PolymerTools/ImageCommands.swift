import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI
import PolymerChecks
import PolymerDesign

/// A number with `places` digits after the point, rounded, no Foundation.
func fixed(_ value: Double, places: Int = 2) -> String {
    guard value.isFinite else { return value > 0 ? "inf" : value < 0 ? "-inf" : "nan" }
    var factor = 1
    for _ in 0..<places { factor *= 10 }
    let n = Int((value * Double(factor)).rounded())
    if places == 0 { return String(n) }
    let whole = n / factor, frac = abs(n % factor)
    var digits = String(frac)
    while digits.count < places { digits = "0" + digits }
    return (n < 0 && whole == 0 ? "-" : "") + String(whole) + "." + digits
}

// MARK: diff

/// How two images of the same size differ.
struct ImageDifference {
    let width: Int, height: Int
    /// Pixels whose largest channel difference is above the threshold.
    let changed: Int
    /// Mean of the channel differences of every pixel's four channels, 0...255.
    let meanDelta: Double
    /// The largest single-channel difference, 0...255.
    let maxDelta: Int

    var pixels: Int { width * height }
    var changedFraction: Double { pixels == 0 ? 0 : Double(changed) / Double(pixels) }
    var isIdentical: Bool { changed == 0 && maxDelta == 0 }
}

/// Two images the command cannot compare.
struct ImageDifferenceError: Error, CustomStringConvertible {
    let description: String
}

/// Per-pixel differences of two images; `b`'s size must equal `a`'s.
func imageDifference(_ a: Bitmap, _ b: Bitmap, pixelThreshold: Int = 0) throws -> ImageDifference {
    guard a.width == b.width, a.height == b.height else {
        throw ImageDifferenceError(description: "the images are different sizes: \(a.width)x\(a.height) and \(b.width)x\(b.height). Crop or scale one first; the diff compares pixels one for one.")
    }
    var changed = 0, maxDelta = 0, sum = 0
    var k = 0
    while k < a.pixels.count {
        var pixelMax = 0
        for c in 0..<4 {
            let d = abs(Int(a.pixels[k + c]) - Int(b.pixels[k + c]))
            sum += d
            if d > pixelMax { pixelMax = d }
        }
        if pixelMax > maxDelta { maxDelta = pixelMax }
        if pixelMax > pixelThreshold { changed += 1 }
        k += 4
    }
    let channels = a.pixels.count == 0 ? 1 : a.pixels.count
    return ImageDifference(width: a.width, height: a.height, changed: changed,
                           meanDelta: Double(sum) / Double(channels), maxDelta: maxDelta)
}

/// `a` dimmed to a backdrop, with the pixels that differ in magenta (a small
/// change) or red (32 or more), so the shape of the change reads at a glance.
func differenceImage(_ a: Bitmap, _ b: Bitmap, pixelThreshold: Int = 0) -> Bitmap {
    var out = Bitmap(width: a.width, height: a.height)
    var k = 0
    while k < out.pixels.count {
        var pixelMax = 0
        for c in 0..<3 {
            let d = abs(Int(a.pixels[k + c]) - Int(b.pixels[k + c]))
            if d > pixelMax { pixelMax = d }
        }
        if pixelMax > pixelThreshold {
            out.pixels[k] = 255
            out.pixels[k + 1] = 0
            out.pixels[k + 2] = pixelMax >= 32 ? 0 : 255
        } else {
            for c in 0..<3 { out.pixels[k + c] = UInt8(Double(a.pixels[k + c]) * 0.3) }
        }
        out.pixels[k + 3] = 255
        k += 4
    }
    return out
}

/// `polymer diff <a.png> <b.png> [--out diff.png] [--threshold N]`: how two
/// PNGs differ, and where, as a picture. Exits 1 when the mean difference is
/// above the threshold (0 by default: any difference).
func diffCommand(_ a: [String], out: String?, threshold: Double, json: Bool) throws {
    guard a.count == 2 else {
        print("usage: polymer diff <a.png> <b.png> [--out diff.png] [--threshold N]. `polymer help` lists the commands.")
        Platform.process.exit(2)
    }
    guard threshold >= 0, threshold <= 255 else {
        print("--threshold takes a channel difference from 0 to 255, got \(fixed(threshold)).")
        Platform.process.exit(2)
    }
    let first = try PNG.decode(try Platform.files.read(a[0]))
    let second = try PNG.decode(try Platform.files.read(a[1]))
    let d = try imageDifference(first, second, pixelThreshold: Int(threshold.rounded()))
    var written: String?
    if let out {
        try Platform.files.write(PNG.encode(differenceImage(first, second, pixelThreshold: Int(threshold.rounded()))), to: out)
        written = out
    }
    let above = d.meanDelta > threshold
    if json {
        var o: [String: JSON] = [
            "a": .string(a[0]), "b": .string(a[1]), "width": .number(Double(d.width)), "height": .number(Double(d.height)),
            "pixels": .number(Double(d.pixels)), "changed": .number(Double(d.changed)),
            "changedFraction": .number(d.changedFraction), "percentChanged": .number(d.changedFraction * 100),
            "meanDelta": .number(d.meanDelta), "maxDelta": .number(Double(d.maxDelta)),
            "threshold": .number(threshold), "identical": .bool(d.isIdentical), "aboveThreshold": .bool(above),
        ]
        o["diff"] = written.map { JSON.string($0) } ?? .null
        print(JSON.object(o).pretty, terminator: "")
    } else if d.isIdentical {
        print("\(a[0]) and \(a[1]) are identical: \(d.width)x\(d.height), \(d.pixels) pixels, no difference.")
        if let written { print("wrote \(written) (nothing to show).") }
    } else {
        print("\(a[0]) and \(a[1]): \(d.width)x\(d.height), \(d.pixels) pixels.")
        print("\(d.changed) pixels differ (\(fixed(d.changedFraction * 100))%), mean channel delta \(fixed(d.meanDelta)), max \(d.maxDelta).")
        if let written { print("wrote \(written): the pixels that differ in magenta (a small change) or red (32 or more) over the dimmed first image.") }
        if above {
            print("the mean channel delta \(fixed(d.meanDelta)) is above the threshold of \(fixed(threshold)).")
        }
    }
    Platform.process.exit(above ? 1 : 0)
}

// MARK: customize

/// `--customize <file.json>`: the customizations a screen draws with, read
/// from a file `CustomizeModel.json` wrote.
@MainActor
func customizeOption(_ path: String?) throws -> CustomizeModel? {
    guard let path else { return nil }
    let text: String
    do { text = try Platform.files.readText(path) } catch {
        throw ImageDifferenceError(description: "--customize \(path): cannot read the file. Pass a JSON file such as {\"version\": 1, \"elements\": {\"toolbar/play\": {\"hidden\": true}}}.")
    }
    do {
        let json = try JSON.parse(text)
        do { return try CustomizeModel(json: json) } catch { throw ImageDifferenceError(description: "--customize \(path): \(error)") }
    } catch let e as JSON.ParseError {
        throw ImageDifferenceError(description: "--customize \(path): \(e)")
    } catch let e as ImageDifferenceError {
        throw e
    } catch {
        throw ImageDifferenceError(description: "--customize \(path): \(error)")
    }
}

/// `polymer zoom <in.png> <out.png> x y width height factor`: crop and enlarge (nearest neighbour), for inspecting pixels.
func zoomCommand(_ a: [String]) throws {
    guard a.count == 7, let x = Int(a[2]), let y = Int(a[3]), let w = Int(a[4]), let h = Int(a[5]), let f = Int(a[6]) else {
        print("usage: polymer zoom <in.png> <out.png> x y width height factor")
        Platform.process.exit(2)
    }
    let src = try PNG.decode(try Platform.files.read(a[0]))
    var out = Bitmap(width: w * f, height: h * f)
    for oy in 0..<h * f {
        for ox in 0..<w * f {
            let sx = min(src.width - 1, x + ox / f), sy = min(src.height - 1, y + oy / f)
            let s = (sy * src.width + sx) * 4, o = (oy * w * f + ox) * 4
            for c in 0..<4 { out.pixels[o + c] = src.pixels[s + c] }
        }
    }
    try Platform.files.write(PNG.encode(out), to: a[1])
}

/// Every screen the command knows: the sample screens, then the command's own.
@MainActor var screenNames: [String] { sampleScreenNames + toolScreenNames + demoScreenNames }

/// A screen by name as a live tree, or nil when there is none. `customize`
/// gives the design showcase screen the customizations to draw with; the
/// other sample screens take none.
@MainActor
func namedScreen(_ name: String, scale: Double, customize: CustomizeModel? = nil) throws -> ViewTree? {
    if name == "components", let customize {
        var e = EnvironmentValues()
        e.displayScale = scale
        return ViewTree(try sampleComponents(root: ".", customize: customize), environment: e)
    }
    if let t = try demoScreenTree(name, root: ".", scale: scale, initialWidth: 1280, initialHeight: 820, customize: customize) { return t }
    if let t = try toolScreenTree(name, root: ".", scale: scale) { return t }
    return try sampleTree(name, root: ".", scale: scale)
}

/// Reads "x,y" or "x,y,x,y" (spaces allowed): the numbers, or nil when they are not `count` numbers.
func parseNumbers(_ s: String, count: Int) -> [Double]? {
    let parts = s.split(separator: ",", omittingEmptySubsequences: false).map { $0.filter { $0 != " " } }
    guard parts.count == count else { return nil }
    var out: [Double] = []
    for p in parts {
        guard let v = Double(p), v.isFinite else { return nil }
        out.append(v)
    }
    return out
}

/// A screen as a live tree, after the input steps have been applied in order.
@MainActor
func screenTree(_ name: String, scale: Double, steps: [(option: String, value: String)],
                customize: CustomizeModel? = nil) throws -> ViewTree {
    guard let tree = try namedScreen(name, scale: scale, customize: customize) else {
        print("Unknown screen \"\(name)\". Available: \(screenNames.joined(separator: ", ")).")
        Platform.process.exit(2)
    }
    func fail(_ message: String, code: Int32 = 1) -> Never {
        print(message)
        Platform.process.exit(code)
    }
    for step in steps {
        tree.update()
        let v = step.value
        switch step.option {
        case "--click":
            if !tree.click(text: v) {
                fail("--click \"\(v)\": no visible, clickable text reads exactly that. `polymer tree \(name)` lists the texts on the screen; scroll first if it is outside its scroll view.")
            }
        case "--click-at":
            guard let p = parseNumbers(v, count: 2) else { fail("--click-at needs a point in points as x,y (for example 40,12); got \"\(v)\".", code: 2) }
            if !tree.click(at: Point(x: p[0], y: p[1])) {
                fail("--click-at \(v): nothing there takes a click. `polymer tree \(name)` gives every element's frame as (x, y, width x height).")
            }
        case "--hover", "--press":
            guard let p = tree.point(ofText: v) else {
                fail("\(step.option) \"\(v)\": no visible text reads exactly that. `polymer tree \(name)` lists the texts on the screen.")
            }
            if step.option == "--hover" { tree.pointerMoved(to: p) } else { tree.pointerDown(at: p) }
        case "--key":
            guard KeyPress(v) != nil else {
                fail("--key \"\(v)\" is not a key. Use a character or tab, space, return, escape, delete, up, down, left, right, home, end, pageup, pagedown; add shift+, ctrl+, alt+ or cmd+ in front.", code: 2)
            }
            if !tree.key(v) {
                fail("--key \"\(v)\": nothing on the screen handled it. `polymer tree \(name)` shows which element is focused.")
            }
        case "--scroll":
            guard let dy = Double(v) else { fail("--scroll needs a number of points, got \"\(v)\".", code: 2) }
            if !tree.scroll(at: Point(x: tree.size.width / 2, y: tree.size.height / 2), dy: dy) {
                fail("--scroll \(v): nothing under the middle of the screen can scroll that way.")
            }
        case "--drag":
            guard let p = parseNumbers(v, count: 4) else {
                fail("--drag needs a start and an end point in points as x,y,x,y (for example 20,40,120,40); got \"\(v)\".", code: 2)
            }
            // A drag that selects text in a field ends no gesture, so a false result is only a note.
            if !tree.drag(from: Point(x: p[0], y: p[1]), to: Point(x: p[2], y: p[3]), steps: 8) {
                Platform.process.writeStandardError("note: --drag \(v) ended no drag gesture and pressed no button. If that was not meant, `polymer tree \(name)` gives the frames: start inside the view that has the .gesture.\n")
            }
        case "--type":
            guard tree.acceptsTextInput else {
                fail("--type \"\(v)\": no text field has focus. Focus one first: --click-at x,y on the field (its frame is in `polymer tree \(name)`) or --key tab.")
            }
            tree.type(v)
        case "--context-click":
            guard let p = tree.point(ofText: v) else {
                fail("--context-click \"\(v)\": no visible text reads exactly that. `polymer tree \(name)` lists the texts on the screen.")
            }
            if !tree.contextClick(at: p) {
                fail("--context-click \"\(v)\": the view under that text has no context menu. Give it one with .contextMenu { Button(...) }.")
            }
        default:
            fail("Internal: the step \(step.option) has no handler in screenTree (Sources/PolymerTools/ImageCommands.swift).", code: 70)
        }
    }
    tree.update()
    return tree
}
