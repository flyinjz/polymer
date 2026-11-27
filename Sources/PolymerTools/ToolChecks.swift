// Checks for the `polymer` command itself, run by `polymer check` after the
// framework's checks (Checks.all) and printed the same way. They live here
// because the code they check lives here.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI
import PolymerChecks

struct ToolCheck {
    let name: String
    /// Returns what went wrong; empty when the check passed.
    let run: @MainActor (_ root: String) throws -> [String]
}

@MainActor
enum ToolChecks {
    static var all: [ToolCheck] {
        [
            ToolCheck(name: "tools.arguments", run: arguments),
            ToolCheck(name: "tools.activity", run: activity),
            ToolCheck(name: "tools.element-tree-json", run: elementTree),
            ToolCheck(name: "tools.describe", run: describe),
            ToolCheck(name: "tools.controls", run: controls),
            ToolCheck(name: "tools.status", run: status),
            ToolCheck(name: "tools.diff", run: diff),
            ToolCheck(name: "tools.bench", run: bench),
        ]
    }

    /// Runs the checks; returns how many failed.
    static func run(_ checks: [ToolCheck], root: String) -> Int {
        var failed = 0
        let clock = ContinuousClock()
        for c in checks {
            let start = clock.now
            var failures: [String]
            do { failures = try c.run(root) } catch { failures = ["threw: \(error)"] }
            let ms = (clock.now - start).milliseconds
            if failures.isEmpty {
                print("pass  \(c.name)  (\(ms) ms)")
            } else {
                failed += 1
                print("FAIL  \(c.name)  (\(ms) ms)")
                for f in failures.prefix(20) { print("      \(f)") }
            }
        }
        print(failed == 0 ? "\(checks.count) tool checks passed." : "\(failed) of \(checks.count) tool checks failed.")
        return failed
    }

    /// Collects failures: `expect(cond, "what should have held")`.
    private struct Failures {
        var list: [String] = []
        mutating func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { list.append(message()) } }
        mutating func expectClose(_ a: Double, _ b: Double, tolerance: Double, _ message: @autoclosure () -> String) {
            if !(abs(a - b) <= tolerance) { list.append("\(message()): got \(a), expected \(b) ± \(tolerance)") }
        }
    }

    // MARK: The checks

    static func arguments(_ root: String) -> [String] {
        var f = Failures()
        f.expect(parseNumbers("40,12", count: 2) == [40, 12], "\"40,12\" should read as 40 and 12")
        f.expect(parseNumbers(" 3, 4.5 ,6,7", count: 4) == [3, 4.5, 6, 7], "spaces around numbers should be allowed")
        f.expect(parseNumbers("-2,0", count: 2) == [-2, 0], "negative numbers should be allowed")
        f.expect(parseNumbers("1,2", count: 4) == nil, "two numbers are not four")
        f.expect(parseNumbers("1,,2", count: 3) == nil, "an empty part is not a number")
        f.expect(parseNumbers("a,b", count: 2) == nil, "letters are not numbers")
        f.expect(parseNumbers("inf,1", count: 2) == nil, "infinity is not a point")
        f.expect(KeyPress("shift+tab") != nil && KeyPress("nokey") == nil, "--key validation should accept shift+tab and reject nokey")
        return f.list
    }

    static func activity(_ root: String) -> [String] {
        var f = Failures()
        let t = Activity.timestamp(year: 2026, month: 3, day: 4, hour: 5, minute: 6)
        f.expect(t == "2026-03-04 05:06", "timestamp should be zero-padded, got \"\(t)\"")
        let e = Activity.Entry(time: t, by: "ui agent", message: "Added a menu: Copy, Rename, and Delete.")
        let line = Activity.line(e)
        f.expect(line == "- 2026-03-04 05:06, ui agent: Added a menu: Copy, Rename, and Delete.", "line format changed: \(line)")
        f.expect(Activity.parse(line) == e, "a written line should read back as the same entry")
        let anonymous = Activity.Entry(time: t, by: "", message: "Fixed it.")
        f.expect(Activity.parse(Activity.line(anonymous)) == anonymous, "a line with no name should read back")
        f.expect(Activity.parse("- not a date, x: y") == nil, "a line without a date is not an entry")
        f.expect(Activity.parse("# Activity") == nil, "the heading is not an entry")
        let text = Activity.header + line + "\r\n- broken line\n" + Activity.line(anonymous) + "\n"
        let (entries, bad) = Activity.entries(text)
        f.expect(entries == [e, anonymous] && bad == 1, "the file should give two entries and one unreadable line, got \(entries.count) and \(bad)")
        f.expect(Activity.problem(message: "Did a thing.", by: "agent") == nil, "a plain sentence should be accepted")
        f.expect(Activity.problem(message: "", by: "agent") != nil, "an empty message should be refused")
        f.expect(Activity.problem(message: "Two\nlines", by: "agent") != nil, "a line break should be refused")
        f.expect(Activity.problem(message: "Two\r\nlines", by: "agent") != nil, "a Windows line break should be refused")
        f.expect(Activity.problem(message: String(repeating: "a", count: Activity.maximumLength + 1), by: "agent") != nil,
                 "a message over the limit should be refused")
        f.expect(Activity.problem(message: "Ok.", by: "a: b") != nil, "a name with a colon should be refused")
        f.expect(Activity.trimmed("  Did it. \n") == "Did it.", "messages should be trimmed")
        return f.list
    }

    static func elementTree(_ root: String) -> [String] {
        var f = Failures()
        // As ViewTree.elementTree prints it: a detail is written raw, so a text's line break
        // starts the next line at column 0 and the closing quote ends that line.
        let text = "VStack (0, 0, 240x100.5)\n  Text (16, 16, 50x17) \"Track 1 (picked)\nsecond line of the text\"\n"
            + "  Button (16, 40, 30x20) focused\n    Text (18, 42, 26x16) \"Add\"\r\nText (0, 110, 10x10) \"Two\n\nlines\" leaving\n"
        guard let top = Describe.elementTreeJSON(text).array else { return ["the element tree should give a list"] }
        f.expect(top.count == 2, "two top-level elements expected, got \(top.count)")
        let v = top.first
        f.expect(v?["role"]?.string == "VStack", "first role should be VStack")
        f.expect(v?["frame"]?["height"]?.double == 100.5, "fractional frames should be kept")
        let kids = v?["children"]?.array ?? []
        f.expect(kids.count == 2, "VStack should have two children, got \(kids.count)")
        f.expect(kids.first?["detail"]?.string == "\"Track 1 (picked)\nsecond line of the text\"",
                 "parentheses in text and continuation lines should stay in the detail, got \(kids.first?["detail"]?.string ?? "nil")")
        f.expect(kids.last?["focused"]?.bool == true && kids.last?["detail"]?.string == "", "\"focused\" should become a flag")
        f.expect(kids.last?["children"]?.array?.count == 1, "the button's text should be its child")
        f.expect(top.last?["leaving"]?.bool == true && top.last?["detail"]?.string == "\"Two\n\nlines\"",
                 "\"leaving\" after a text with a blank line in it should become a flag and keep the blank line, got \(top.last?["detail"]?.string ?? "nil")")
        return f.list
    }

    static func describe(_ root: String) throws -> [String] {
        var f = Failures()
        guard let tree = try sampleTree("counter", root: root) else { return ["the counter sample is missing"] }
        let a11y = tree.accessibilityTree
        let text = Describe.plain("counter", a11y)
        f.expect(text.hasPrefix("Screen \"counter\", "), "the description should start with the screen and its size:\n\(text)")
        f.expect(text.contains("\"Counter\"") && text.contains("\"Add\""), "the description should name the title and the Add button:\n\(text)")
        f.expect(text.contains("In all: "), "the description should give the totals:\n\(text)")
        let j = Describe.screenJSON("counter", a11y)
        f.expect((j["counts"]?["button"]?.int ?? 0) >= 2, "the counter has two buttons (Add and Step)")
        f.expect(j["elements"]?.array?.isEmpty == false, "the JSON should list the elements")
        _ = tree.click(text: "Add")
        f.expect(Describe.plain("counter", tree.accessibilityTree).contains("Count 1"), "after a click the description should show the new count")
        return f.list
    }

    /// The controls screen: typing, a context menu, a drag and a sheet, through the same calls the steps make.
    static func controls(_ root: String) throws -> [String] {
        var f = Failures()
        guard let tree = try toolScreenTree("controls", root: root, scale: 1) else { return ["the controls screen is missing"] }
        tree.update()
        func find(_ e: AccessibilityElement, _ role: AccessibilityRole) -> AccessibilityElement? {
            if e.role == role { return e }
            for c in e.children { if let x = find(c, role) { return x } }
            return nil
        }
        if let field = find(tree.accessibilityTree, .textField) {
            tree.click(at: Point(x: field.frame.midX, y: field.frame.midY))
            f.expect(tree.acceptsTextInput, "clicking the text field should focus it")
            tree.type("Ada")
            f.expect(tree.point(ofText: "Hello, Ada") != nil, "typing should reach the field's binding")
        } else {
            f.expect(false, "the controls screen should have a text field in its accessibility tree")
        }
        if let p = tree.point(ofText: "Options") {
            f.expect(tree.contextClick(at: p), "right-clicking Options should open its context menu")
            f.expect(tree.click(text: "Rename"), "the context menu should have Rename")
            f.expect(tree.point(ofText: "Chose Rename") != nil, "choosing Rename should run its action")
        } else {
            f.expect(false, "the controls screen should show Options")
        }
        if let p = tree.point(ofText: "Dragged 0 points") {
            // The handle is the 24-point square left of the text, at the screen's 16-point padding.
            let start = Point(x: 28, y: p.y)
            f.expect(tree.drag(from: start, to: Point(x: 88, y: p.y), steps: 8), "dragging the handle should end a drag gesture")
            f.expect(tree.point(ofText: "Dragged 60 points") != nil, "the drag should report 60 points")
        } else {
            f.expect(false, "the controls screen should show the drag total")
        }
        f.expect(tree.click(text: "Show sheet"), "Show sheet should be clickable")
        f.expect(find(tree.accessibilityTree, .dialog) != nil, "the sheet should be open")
        f.expect(tree.click(text: "Done"), "the sheet should have Done")
        tree.update()
        f.expect(find(tree.accessibilityTree, .dialog) == nil, "Done should close the sheet")
        return f.list
    }

    static func status(_ root: String) throws -> [String] {
        let source = Path.join(root, Status.source), page = Path.join(root, Status.page)
        guard Platform.files.exists(source) else { return ["\(Status.source) is missing"] }
        let j = try JSON.parse(try Platform.files.readText(source))
        let p = Status.problems(j)
        guard p.isEmpty else { return p.map { "\(Status.source): \($0)" } }
        guard Platform.files.exists(page) else { return ["\(Status.page) is missing: run `polymer status --write`"] }
        // "\r\n" is one Character, so it is mapped, not filtered out by "\r".
        let written = try String(Platform.files.readText(page).map { (c: Character) -> Character in c == "\r\n" || c == "\r" ? "\n" : c })
        guard written == Status.render(j) else {
            return ["\(Status.page) differs from \(Status.source): run `polymer status --write` (edit status.json, never STATUS.md)"]
        }
        return []
    }

    /// `polymer diff`: the arithmetic, the threshold, the picture, and a PNG round trip.
    static func diff(_ root: String) throws -> [String] {
        var f = Failures()
        let a = Bitmap(width: 8, height: 4, fill: (40, 40, 40, 255))
        let same = try imageDifference(a, a)
        f.expect(same.isIdentical && same.changed == 0 && same.meanDelta == 0 && same.maxDelta == 0,
                 "an image against itself should be identical, got \(same.changed) changed and mean \(fixed(same.meanDelta))")
        f.expect(same.pixels == 32 && same.changedFraction == 0, "8x4 should be 32 pixels with no change")
        var b = a
        let k = (2 * 8 + 3) * 4          // pixel (3, 2), red channel
        b.pixels[k] = 240
        let one = try imageDifference(a, b)
        f.expect(one.changed == 1, "one changed channel should change one pixel, got \(one.changed)")
        f.expect(one.maxDelta == 200, "the largest single-channel difference should be 200, got \(one.maxDelta)")
        f.expectClose(one.meanDelta, 200.0 / 128, tolerance: 1e-12, "mean over all four channels of every pixel")
        f.expectClose(one.changedFraction, 1.0 / 32, tolerance: 1e-12, "one of 32 pixels")
        let coarse = try imageDifference(a, b, pixelThreshold: 255)
        f.expect(coarse.changed == 0 && coarse.maxDelta == 200,
                 "a threshold of 255 should count no pixel as changed, got \(coarse.changed)")
        let fine = try imageDifference(a, b, pixelThreshold: 199)
        f.expect(fine.changed == 1, "a threshold of 199 should still count the 200 change")
        do {
            _ = try imageDifference(a, Bitmap(width: 4, height: 4, fill: (0, 0, 0, 255)))
            f.expect(false, "images of different sizes should be refused")
        } catch {
            f.expect(String(describing: error).contains("different sizes"), "the size error should say so, got \(error)")
        }
        let picture = differenceImage(a, b)
        f.expect(picture.width == 8 && picture.height == 4, "the diff picture should be the image's size")
        f.expect(picture[3, 2] == (255, 0, 0, 255), "a change of 200 should be red, got \(picture[3, 2])")
        f.expect(picture[0, 0] == (12, 12, 12, 255), "an unchanged pixel should be the first image at 30%, got \(picture[0, 0])")
        var small = a
        small.pixels[k] = 52                 // 12 more than 40: below 32, so magenta
        f.expect(differenceImage(a, small)[3, 2] == (255, 0, 255, 255), "a small change should be magenta")
        // A PNG keeps its pixels, so a saved and read-back image compares equal.
        let round = try PNG.decode(PNG.encode(b))
        let again = try imageDifference(b, round)
        f.expect(again.isIdentical, "a PNG should read back pixel for pixel, got \(again.changed) changed")
        return f.list
    }

    /// `polymer bench`: real frames, timed and summarised.
    static func bench(_ root: String) throws -> [String] {
        var f = Failures()
        f.expect(benchPercentile([1, 2, 3, 4, 5], 0.5) == 3, "the middle of five samples is the third")
        f.expect(benchPercentile([1, 2, 3, 4, 5], 0.95) == 5, "95% of five samples is the fifth")
        f.expect(benchPercentile([7], 0.95) == 7 && benchPercentile([], 0.5) == 0, "one sample, and none")
        let r = try runBench(frames: 3, width: 240, height: 160, root: root)
        f.expect(r.layout.samples == 3 && r.raster.samples == 3, "three frames should give three samples each, got \(r.layout.samples) and \(r.raster.samples)")
        f.expect(r.pixels == 240 * 160 && r.items > 0, "the frame should cover 240x160 pixels with items in it, got \(r.pixels) and \(r.items)")
        f.expect(r.rows >= 4, "the screen should have rows in it, got \(r.rows)")
        for (name, s) in [("layout", r.layout), ("raster", r.raster)] {
            f.expect(s.p50 >= 0 && s.p50 <= s.p95 && s.p95 <= s.max, "\(name): p50 <= p95 <= max should hold, got \(s.p50), \(s.p95), \(s.max)")
            f.expect(s.max.isFinite && s.max > 0, "\(name): a stage should take measurable time, got \(s.max) ms")
        }
        f.expect(r.raster.p50 > 0, "rasterising 240x160 pixels should take time")
        return f.list
    }
}
