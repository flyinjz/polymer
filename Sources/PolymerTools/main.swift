// The `polymer` command.
import PolymerBase
import PolymerPlatform
import PolymerChecks
import PolymerRender
import PolymerUI
import PolymerApp
#if os(Windows)
import WinSDK
import PolymerPlatformWindows
import PolymerGPU
import PolymerGPUD3D12
Platform.install(files: WindowsFileSystem(), process: WindowsProcess())
GPU.install(D3D12Backend.make)
Platform.install(windows: Win32WindowSystem())
Platform.install(clipboard: Win32Clipboard())
/// The local date and time to the minute, for the activity log. (Belongs behind
/// the platform layer, DESIGN D6; here until `Platform` has a wall clock.)
func localTimestamp() -> String {
    var t = SYSTEMTIME()
    GetLocalTime(&t)
    return Activity.timestamp(year: Int(t.wYear), month: Int(t.wMonth), day: Int(t.wDay), hour: Int(t.wHour), minute: Int(t.wMinute))
}
#elseif os(macOS)
import Darwin
import PolymerPlatformMac
Platform.install(files: MacFileSystem(), process: MacProcess())
func localTimestamp() -> String {
    var now = time(nil)
    var parts = tm()
    localtime_r(&now, &parts)
    return Activity.timestamp(year: Int(parts.tm_year) + 1900, month: Int(parts.tm_mon) + 1, day: Int(parts.tm_mday),
                              hour: Int(parts.tm_hour), minute: Int(parts.tm_min))
}
#endif

Logger.sink = { level, category, message in
    Platform.process.writeStandardError("[\(level.name)] \(category): \(message)\n")
}

// Arguments: options that take a value are listed here; everything else starting with "--" is a flag.
let stepOptions: Set<String> = ["--click", "--click-at", "--scroll", "--key", "--hover", "--press", "--drag", "--type", "--context-click"]
let valueOptions: Set<String> = stepOptions.union(["--scale", "--by", "--out", "--threshold", "--frames", "--width", "--height", "--customize"])
var positionals: [String] = []
var flags: Set<String> = []
var values: [String: [String]] = [:]
/// The input steps (`stepOptions`) in the order given.
var steps: [(option: String, value: String)] = []
do {
    let args = Array(Platform.process.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        if valueOptions.contains(a) {
            guard i + 1 < args.count else {
                print("\(a) needs a value. `polymer help steps` shows every option with an example.")
                Platform.process.exit(2)
            }
            values[a, default: []].append(args[i + 1])
            if stepOptions.contains(a) { steps.append((a, args[i + 1])) }
            i += 2
        } else if a.hasPrefix("--") {
            guard Help.knownFlags.contains(a) else {
                print("Unknown option \(a). Options: \(Help.knownFlags.union(valueOptions).sorted().joined(separator: " ")). `polymer help` lists them with what they do.")
                Platform.process.exit(2)
            }
            flags.insert(a); i += 1
        } else {
            positionals.append(a); i += 1
        }
    }
}
let root = "."
let json = flags.contains("--json")

@MainActor func positional(_ k: Int) -> String? { k < positionals.count ? positionals[k] : nil }

@MainActor func scaleOption() -> Double {
    guard let s = values["--scale"]?.last else { return 1 }
    guard let v = Double(s), v > 0 else {
        print("--scale needs a positive number, got \"\(s)\".")
        Platform.process.exit(2)
    }
    return v
}

/// An option's number, or `fallback` when it is absent.
@MainActor func numberOption(_ name: String, _ fallback: Double) -> Double {
    guard let s = values[name]?.last else { return fallback }
    guard let v = Double(s), v.isFinite else {
        print("\(name) needs a number, got \"\(s)\".")
        Platform.process.exit(2)
    }
    return v
}

/// An option's whole number, or `fallback` when it is absent.
@MainActor func integerOption(_ name: String, _ fallback: Int) -> Int {
    guard let s = values[name]?.last else { return fallback }
    guard let v = Int(s) else {
        print("\(name) needs a whole number, got \"\(s)\".")
        Platform.process.exit(2)
    }
    return v
}

/// Stops unless the command runs in the repository root.
@MainActor func requireRoot(_ command: String) {
    guard Platform.files.exists(Path.join(root, "Package.swift")) else {
        print("Run `polymer \(command)` from the repository root (the folder with Package.swift).")
        Platform.process.exit(2)
    }
}

// `polymer <command> --help` is `polymer help <command>`.
if flags.contains("--help") {
    Help.show(topic: positional(0) == "help" ? positional(1) : positional(0), json: json)
    Platform.process.exit(0)
}

switch positional(0) {
case "check":
    let filter = positional(1)
    if flags.contains("--list") {
        for c in Checks.all { print(c.name) }
        for c in ToolChecks.all { print(c.name) }
        break
    }
    requireRoot("check")
    let tools = ToolChecks.all.filter { filter == nil || $0.name.contains(filter!) }
    let others = Checks.all.contains { filter == nil || $0.name.contains(filter!) }
    var failed = 0
    // `Checks.run` reports "no check matches" itself; skip it when only tool checks match.
    if others || tools.isEmpty { failed += Checks.run(filter: filter, root: root, verbose: flags.contains("--verbose")) }
    if !tools.isEmpty { failed += ToolChecks.run(tools, root: root) }
    Platform.process.exit(failed == 0 ? 0 : 1)
case "check-tools":
    // The checks for the command itself, on their own: what `polymer check` adds after the framework's.
    requireRoot("check-tools")
    Platform.process.exit(ToolChecks.run(ToolChecks.all, root: root) == 0 ? 0 : 1)
case "zoom":
    do { try zoomCommand(Array(positionals.dropFirst())) } catch { print(error); Platform.process.exit(1) }
case "diff":
    do {
        try diffCommand(Array(positionals.dropFirst()), out: values["--out"]?.last,
                        threshold: numberOption("--threshold", 0), json: json)
    } catch { print(error); Platform.process.exit(1) }
case "bench":
    do {
        try benchCommand(frames: integerOption("--frames", 20), width: numberOption("--width", 720),
                         height: numberOption("--height", 480), json: json)
    } catch { print(error); Platform.process.exit(1) }
case "render":
    do {
        guard let screen = positional(1), let out = positional(2) else {
            print("usage: polymer render <screen> <out.png> [--scale N] [--customize file.json] [steps]. `polymer help render` explains.")
            Platform.process.exit(2)
        }
        let scale = scaleOption()
        let customize = try customizeOption(values["--customize"]?.last)
        let tree = try screenTree(screen, scale: scale, steps: steps, customize: customize)
        let image = tree.render()
        try Platform.files.write(PNG.encode(image), to: out)
        if let customize { Platform.process.writeStandardError(Describe.customizeNote(customize) + "\n") }
        if json {
            let o: JSON = ["file": .string(out), "screen": .string(screen), "scale": .number(scale),
                           "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                           "customized": .number(Double(customize?.elements.count ?? 0))]
            print(o.pretty, terminator: "")
        }
    } catch { print(error); Platform.process.exit(1) }
case "tree":
    do {
        guard let screen = positional(1) else {
            print("usage: polymer tree <screen> [--a11y] [--json] [steps]. `polymer help tree` explains.")
            Platform.process.exit(2)
        }
        let tree = try screenTree(screen, scale: 1, steps: steps)
        switch (flags.contains("--a11y"), json) {
        case (true, true): print(Describe.json(tree.accessibilityTree).pretty, terminator: "")
        case (true, false): print(tree.accessibilityDescription, terminator: "")
        case (false, true): print(Describe.elementTreeJSON(tree.elementTree).pretty, terminator: "")
        case (false, false): print(tree.elementTree, terminator: "")
        }
    } catch { print(error); Platform.process.exit(1) }
case "describe":
    do {
        guard let screen = positional(1) else {
            print("usage: polymer describe <screen> [--json] [--customize file.json] [steps]. Screens: \(screenNames.joined(separator: ", ")).")
            Platform.process.exit(2)
        }
        let customize = try customizeOption(values["--customize"]?.last)
        let tree = try screenTree(screen, scale: 1, steps: steps, customize: customize)
        let a11y = tree.accessibilityTree
        if let customize { print(Describe.customizeNote(customize)) }
        if json {
            var o = Describe.screenJSON(screen, a11y).object ?? [:]
            if let customize { o["customize"] = .string(Describe.customizeNote(customize)) }
            print(JSON.object(o).pretty, terminator: "")
        } else {
            print(Describe.plain(screen, a11y), terminator: "")
        }
    } catch { print(error); Platform.process.exit(1) }
case "status":
    requireRoot("status")
    statusCommand(root: root, write: flags.contains("--write"), json: json)
case "log":
    requireRoot("log")
    guard positionals.count >= 2 else {
        print("usage: polymer log \"One plain sentence about what you just did.\" [--by \"name\"]. `polymer help log` explains.")
        Platform.process.exit(2)
    }
    let by = values["--by"]?.last ?? Platform.process.environment("POLYMER_AGENT") ?? "agent"
    logCommand(root: root, message: positionals.dropFirst().joined(separator: " "), by: by, time: localTimestamp(), json: json)
case "activity":
    requireRoot("activity")
    let count: Int? = positional(1).map { s in
        guard let n = Int(s), n > 0 else {
            print("polymer activity [N]: N is how many of the latest entries to show, a positive whole number; got \"\(s)\".")
            Platform.process.exit(2)
        }
        return n
    }
    activityCommand(root: root, count: flags.contains("--all") ? nil : (count ?? 20), json: json)
case "demo":
    do { try demoCommand(positional(1) ?? "glass", software: flags.contains("--software")) } catch { print(error); Platform.process.exit(1) }
case "help", nil:
    Help.show(topic: positional(1), json: json)
case let other?:
    print("Unknown command \"\(other)\".\n")
    Help.show(topic: nil, json: false)
    Platform.process.exit(2)
}

/// Opens a sample screen in a window: the owner runs this; checks never do.
@MainActor func demoCommand(_ name: String, software: Bool) throws {
    guard let windows = Platform.windows else {
        print("polymer demo needs a window system; this OS has none yet.")
        Platform.process.exit(1)
    }
    guard let tree = try namedScreen(name, scale: 1) else {
        print("No screen \"\(name)\". Screens: \(screenNames.joined(separator: ", ")).")
        Platform.process.exit(2)
    }
    _ = tree.update()
    let window = try windows.makeWindow(title: "Polymer: \(name)", width: max(320, tree.size.width), height: max(240, tree.size.height))
    let backend = try GPU.makeBackend(software ? .software : .automatic)
    let host = try WindowHost(tree: tree, window: window, backend: backend, background: Color(white: 0.063),
                              clipboard: Platform.clipboard)
    print("\(backend.name), \(window.pixelWidth)x\(window.pixelHeight) pixels at scale \(window.scale). Close the window to quit.")
    window.show()
    windows.run()
    print("\(host.framesPresented) frames presented.")
}
