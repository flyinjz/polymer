// The `polymer` command.
import PolymerBase
import PolymerPlatform
import PolymerChecks
import PolymerRender
import PolymerUI
#if os(Windows)
import PolymerPlatformWindows
Platform.install(files: WindowsFileSystem(), process: WindowsProcess())
Platform.installDesktop(windowRunner: WindowsWindowRunner(), clipboard: WindowsClipboard(), audioOutput: HeadlessAudioOutputBackend())
#elseif os(macOS)
import PolymerPlatformMac
Platform.install(files: MacFileSystem(), process: MacProcess())
Platform.installDesktop(windowRunner: MacWindowRunner(), clipboard: MacClipboard(), audioOutput: HeadlessAudioOutputBackend())
#elseif os(Linux)
import PolymerPlatformLinux
Platform.install(files: LinuxFileSystem(), process: LinuxProcess())
Platform.installDesktop(windowRunner: LinuxWindowRunner(), clipboard: LinuxClipboard(), audioOutput: HeadlessAudioOutputBackend())
#endif

let usage = """
    polymer <command> [options]

    Commands:
      check [filter] [--list] [--verbose]    Run the headless checks (all, or names containing filter).
      render <screen> <out.png> [--scale N] [--click "text"] [--click-id "id"] [--right-click "text"] [--right-click-id "id"] [--scroll N] [--key K] [--hover "text"] [--press "text"]...
                                             Render a screen to a PNG, headless.
      preview <screen> [--scale N] [...]     Open a screen in a live interactive window (Windows/macOS).
      tree <screen> [--a11y] [--click "text"] [--click-id "id"] [--right-click "text"] [--right-click-id "id"] [--scroll N] [--key K] [--hover "text"] [--press "text"]...
                                             Print a screen's element tree (or accessibility tree with --a11y).
      describe [section] [--json]            Self-describing API, modifier, token, and command reference.
      zoom <in> <out> x y w h factor         Crop a PNG and enlarge it, for inspecting pixels.
      help                                   Show this text.

    Screens: \(toolScreenNames.joined(separator: ", ")).
    --click presses the button or tap handler under the text that reads exactly "text";
    --click-id presses the element with .accessibilityIdentifier("id");
    --right-click secondary-clicks the element under "text" (opening its .contextMenu if any);
    --right-click-id secondary-clicks the element with .accessibilityIdentifier("id");
    --scroll moves the scroll view in the middle of the screen down by N points (up when negative).
    --key presses a key: "tab", "shift+tab", "space", "return", "down", "cmd+a", "x".
    --hover moves the pointer over the text; --press holds the pointer down on it (to see pressed looks).
    Steps are applied in the order given, before the screen is rendered or printed.

    Run from the repository root (the folder with Package.swift).
    """

Logger.sink = { level, category, message in
    Platform.process.writeStandardError("[\(level.name)] \(category): \(message)\n")
}

// Arguments: options that take a value are listed here; everything else starting with "--" is a flag.
let valueOptions: Set<String> = [
    "--scale", "--click", "--click-id", "--right-click", "--right-click-id",
    "--scroll", "--key", "--hover", "--press",
]
var positionals: [String] = []
var flags: Set<String> = []
var values: [String: [String]] = [:]
/// The input steps (--click, --scroll, --key, --hover, --press) in the order given.
var steps: [(option: String, value: String)] = []
do {
    let args = Array(Platform.process.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        if valueOptions.contains(a) {
            guard i + 1 < args.count else {
                print("\(a) needs a value.\n")
                print(usage)
                Platform.process.exit(2)
            }
            values[a, default: []].append(args[i + 1])
            if a != "--scale" { steps.append((a, args[i + 1])) }
            i += 2
        } else if a.hasPrefix("--") {
            flags.insert(a); i += 1
        } else {
            positionals.append(a); i += 1
        }
    }
}
let root = "."

@MainActor func positional(_ k: Int) -> String? { k < positionals.count ? positionals[k] : nil }

@MainActor func scaleOption() -> Double {
    guard let s = values["--scale"]?.last else { return 1 }
    guard let v = Double(s), v > 0 else {
        print("--scale needs a positive number, got \"\(s)\".")
        Platform.process.exit(2)
    }
    return v
}

switch positional(0) {
case "check":
    if flags.contains("--list") {
        for c in Checks.all { print(c.name) }
        break
    }
    guard Platform.files.exists(Path.join(root, "Package.swift")) else {
        print("Run `polymer check` from the repository root (the folder with Package.swift).")
        Platform.process.exit(2)
    }
    let failed = Checks.run(filter: positional(1), root: root, verbose: flags.contains("--verbose"))
    Platform.process.exit(failed == 0 ? 0 : 1)
case "zoom":
    do { try zoomCommand(Array(positionals.dropFirst())) } catch { print(error); Platform.process.exit(1) }
case "render":
    do {
        guard let screen = positional(1), let out = positional(2) else {
            print("usage: polymer render <screen> <out.png> [--scale N] [--click \"text\"]...")
            Platform.process.exit(2)
        }
        let tree = try screenTree(screen, scale: scaleOption(), steps: steps)
        try Platform.files.write(PNG.encode(tree.render()), to: out)
    } catch { print(error); Platform.process.exit(1) }
case "preview":
    do {
        guard let screen = positional(1) else {
            print("usage: polymer preview <screen> [--scale N]")
            Platform.process.exit(2)
        }
        try previewCommand(screen: screen, scale: scaleOption(), steps: steps)
    } catch { print(error); Platform.process.exit(1) }
case "tree":
    do {
        guard let screen = positional(1) else {
            print("usage: polymer tree <screen> [--a11y] [--click \"text\"]...")
            Platform.process.exit(2)
        }
        let tree = try screenTree(screen, scale: 1, steps: steps)
        if flags.contains("--a11y") {
            print(tree.accessibilityTree().describeTree(), terminator: "")
        } else {
            print(tree.elementTree, terminator: "")
        }
    } catch { print(error); Platform.process.exit(1) }
case "describe":
    describeCommand(section: positional(1), asJSON: flags.contains("--json"), root: root)
case "help", nil:
    print(usage)
case let other?:
    print("Unknown command \"\(other)\".\n")
    print(usage)
    Platform.process.exit(2)
}
