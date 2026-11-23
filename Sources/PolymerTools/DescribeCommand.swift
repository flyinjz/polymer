// Self-describing API, modifier, token, and command catalog (`polymer describe`).
import PolymerBase
import PolymerPlatform
import PolymerApp
import PolymerDesign
import PolymerChecks

private struct DescribedSymbol {
    let module: String
    let file: String
    let kind: String
    let signature: String
    let doc: String
}

private let describedModules = [
    "PolymerBase",
    "PolymerPlatform",
    "PolymerText",
    "PolymerRender",
    "PolymerGPU",
    "PolymerUI",
    "PolymerApp",
    "PolymerDesign",
    "PolymerAudio",
]

private let moduleSummaries: [(name: String, summary: String)] = [
    ("PolymerBase", "Geometry, Color, Path, StableID, ByteReader, JSON, zlib, CRC-32/Adler-32, Logger."),
    ("PolymerPlatform", "FileSystem and Process interfaces with Windows, Mac, and Linux backends."),
    ("PolymerText", "OpenType parser, GPOS/GSUB, analytic rasteriser, GlyphCache, line wrapping, TextBuffer/TextEditorState."),
    ("PolymerRender", "Bitmap, RenderImage, PNG codec, CPU Canvas (images, backdrop blur, scroll blit), DisplayList + damage."),
    ("PolymerGPU", "Backend-agnostic GPUDevice/Buffer/Texture/Pipeline/CommandEncoder, GlyphAtlas packer, DisplayList batch compiler."),
    ("PolymerUI", "Retained View/Node tree, Observation state, layout, TextField/TextEditor, LazyVStack/HStack/VGrid/HGrid, DragGesture, focus, contextMenu, Animation, AccessibilityNode."),
    ("PolymerApp", "Unified Command/CommandRegistry, deterministic JSON SettingsStore, WindowConfig/Scene, ScreenRegistry."),
    ("PolymerDesign", "Swappable Theme tokens (pgr/dark/light presets), opt-in DesignLint, themed controls, CustomizeState engine."),
    ("PolymerAudio", "Lock-free SPSC ring buffer, 64-bit float AudioGraph, pure-Swift WAV/AIFF/FLAC codecs, sinc resampler, TPDF dither, biquad EQ, EBU R128/true-peak limiter, crossfade, crossfeed."),
]

/// Runs `polymer describe [section] [--json]`.
@MainActor
func describeCommand(section: String?, asJSON: Bool, root: String) {
    let validSections = ["all", "modules", "api", "modifiers", "tokens", "commands", "screens"]
    let selected = (section ?? "all").lowercased()
    guard validSections.contains(selected) else {
        print("Unknown describe section \"\(selected)\". Use one of: \(validSections.joined(separator: ", ")).")
        Platform.process.exit(2)
    }

    let (types, modifiers) = scanPublicAPI(root: root)
    let themes: [Theme] = [.pgr, .dark, .light]
    let sampleRegistry = buildStandardCommandRegistry()

    if asJSON {
        var obj: [String: JSON] = [:]
        if selected == "all" || selected == "modules" {
            obj["modules"] = .array(moduleSummaries.map { m in
                .object(["name": .string(m.name), "summary": .string(m.summary)])
            })
        }
        if selected == "all" || selected == "api" {
            obj["types"] = .array(types.map(symbolJSON))
        }
        if selected == "all" || selected == "modifiers" {
            obj["modifiers"] = .array(modifiers.map(symbolJSON))
        }
        if selected == "all" || selected == "tokens" {
            obj["themes"] = .array(themes.map { $0.describeTokens() })
            obj["lintRules"] = .array(DesignLintRule.allCases.map { .string($0.rawValue) })
        }
        if selected == "all" || selected == "commands" {
            obj["cliCommands"] = .array(cliCommandDescriptions.map { c in
                .object(["name": .string(c.name), "usage": .string(c.usage), "summary": .string(c.summary)])
            })
            obj["appCommands"] = sampleRegistry.describeJSON()
        }
        if selected == "all" || selected == "screens" {
            obj["screens"] = .array(toolScreenNames.map { .string($0) })
        }
        print(JSON.object(obj).pretty)
        return
    }

    var out: [String] = []
    out.append("Polymer API & Design Reference")
    out.append("==============================")

    if selected == "all" || selected == "modules" {
        out.append("")
        out.append("Modules:")
        for m in moduleSummaries {
            out.append("  \(m.name) — \(m.summary)")
        }
    }

    if selected == "all" || selected == "api" {
        out.append("")
        out.append("Public Types (\(types.count), scanned from Sources/):")
        var currentModule = ""
        for sym in types {
            if sym.module != currentModule {
                currentModule = sym.module
                out.append("  [\(currentModule)]")
            }
            if sym.doc.isEmpty {
                out.append("    \(sym.signature)")
            } else {
                out.append("    \(sym.signature) — \(sym.doc)")
            }
        }
    }

    if selected == "all" || selected == "modifiers" {
        out.append("")
        out.append("View Modifiers (\(modifiers.count), scanned from Sources/):")
        for sym in modifiers {
            if sym.doc.isEmpty {
                out.append("  [\(sym.module)] \(sym.signature)")
            } else {
                out.append("  [\(sym.module)] \(sym.signature) — \(sym.doc)")
            }
        }
    }

    if selected == "all" || selected == "tokens" {
        out.append("")
        out.append("Design Theme Presets (\(themes.map(\.name).joined(separator: ", "))):")
        for t in themes {
            out.append("  Theme.\(t.name) (dark=\(t.isDark), glass=\(t.glass.enabled), radii.small=\(t.radii.small), hairline=\(t.borders.hairlineWidth == 0 ? "1px" : "\(t.borders.hairlineWidth)pt"), accent=\(t.colors.accent))")
        }
        out.append("  Opt-in DesignLint rules: \(DesignLintRule.allCases.map(\.rawValue).joined(separator: ", "))")
        out.append("  Customize addressing: #id (.accessibilityIdentifier) or Node.stablePath via CustomizeState + .customizable(_:)")
        out.append("  Example: MyView().theme(.pgr).customizeState(customize)")
    }

    if selected == "all" || selected == "commands" {
        out.append("")
        out.append("CLI Commands:")
        for c in cliCommandDescriptions {
            out.append("  \(c.usage) — \(c.summary)")
        }
        out.append("")
        out.append("App CommandRegistry Example Schema:")
        for meta in sampleRegistry.describe() {
            let key = meta.shortcut.map { " [\($0)]" } ?? ""
            out.append("  \(meta.id) (\(meta.category)): \(meta.title)\(key)")
        }
    }

    if selected == "all" || selected == "screens" {
        out.append("")
        out.append("Sample Screens: \(toolScreenNames.joined(separator: ", "))")
    }

    print(out.joined(separator: "\n"))
}

private let cliCommandDescriptions: [(name: String, usage: String, summary: String)] = [
    ("check", "polymer check [filter] [--list] [--verbose]", "Run headless verification checks across all modules."),
    ("render", "polymer render <screen> <out.png> [--scale N] [--click ...] [--click-id ...] [--right-click ...] [--right-click-id ...] [--scroll N] [--key K] [--hover ...] [--press ...]", "Render a screen to a PNG after applying input steps."),
    ("tree", "polymer tree <screen> [--a11y] [--click ...] [--click-id ...] [--right-click ...] [--right-click-id ...] [--scroll N] [--key K] [--hover ...] [--press ...]", "Print a screen's element tree (or accessibility tree with --a11y)."),
    ("describe", "polymer describe [modules|api|modifiers|tokens|commands|screens] [--json]", "Inspect Polymer's public types, View modifiers, theme tokens, and commands."),
    ("zoom", "polymer zoom <in.png> <out.png> x y w h factor", "Crop and nearest-neighbour enlarge a PNG region for pixel inspection."),
]

@MainActor
private func buildStandardCommandRegistry() -> CommandRegistry {
    let registry = CommandRegistry()
    registry.register(Command(id: "app.customize", title: "Toggle Customize Mode", category: "View", shortcut: KeyShortcut("cmd+shift+k")) {})
    registry.register(Command(id: "edit.undo", title: "Undo", category: "Edit", shortcut: KeyShortcut("cmd+z")) {})
    registry.register(Command(id: "edit.redo", title: "Redo", category: "Edit", shortcut: KeyShortcut("cmd+shift+z")) {})
    registry.register(Command(id: "edit.selectAll", title: "Select All", category: "Edit", shortcut: KeyShortcut("cmd+a")) {})
    registry.register(Command(id: "theme.pgr", title: "Use pgr Theme", category: "Appearance") {})
    registry.register(Command(id: "theme.dark", title: "Use Dark Theme", category: "Appearance") {})
    registry.register(Command(id: "theme.light", title: "Use Light Theme", category: "Appearance") {})
    return registry
}

private func symbolJSON(_ s: DescribedSymbol) -> JSON {
    .object([
        "module": .string(s.module),
        "file": .string(s.file),
        "kind": .string(s.kind),
        "signature": .string(s.signature),
        "doc": .string(s.doc),
    ])
}

/// Scans `Sources/<Module>/*.swift` using `Platform.files` to extract public types and `extension View` modifiers.
private func scanPublicAPI(root: String) -> (types: [DescribedSymbol], modifiers: [DescribedSymbol]) {
    var types: [DescribedSymbol] = []
    var modifiers: [DescribedSymbol] = []
    let sourcesDir = Path.join(root, "Sources")
    guard Platform.files.exists(sourcesDir) else { return ([], []) }

    for module in describedModules {
        let modDir = Path.join(sourcesDir, module)
        guard Platform.files.exists(modDir), let entries = try? Platform.files.list(modDir) else { continue }
        for entry in entries where entry.hasSuffix(".swift") {
            let filePath = Path.join(modDir, entry)
            guard let source = try? Platform.files.readText(filePath) else { continue }
            parseSwiftFile(source: source, module: module, file: entry, types: &types, modifiers: &modifiers)
        }
    }
    return (types, modifiers)
}

private func parseSwiftFile(
    source: String,
    module: String,
    file: String,
    types: inout [DescribedSymbol],
    modifiers: inout [DescribedSymbol]
) {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var braceDepth = 0
    var viewExtensionDepth: Int? = nil
    var pendingDoc: [String] = []

    for rawLine in lines {
        let trimmed = trimWhitespace(rawLine)

        if trimmed.hasPrefix("///") {
            let text = trimWhitespace(String(trimmed.dropFirst(3)))
            if !text.isEmpty { pendingDoc.append(text) }
            continue
        }

        let isAttribute = trimmed.hasPrefix("@") && !trimmed.contains("{")
        if isAttribute {
            // Keep pending doc comments across attributes like @MainActor or @Observable.
            continue
        }

        if braceDepth == 0 {
            if trimmed.hasPrefix("extension View") && !trimmed.hasPrefix("extension ViewTree") && !trimmed.hasPrefix("extension ViewBuilder") {
                if trimmed.contains("{") {
                    viewExtensionDepth = 1
                }
            } else if let (kind, sig) = extractPublicType(from: trimmed) {
                types.append(DescribedSymbol(
                    module: module,
                    file: file,
                    kind: kind,
                    signature: sig,
                    doc: pendingDoc.first ?? ""
                ))
            }
            pendingDoc.removeAll(keepingCapacity: true)
        } else if let extDepth = viewExtensionDepth, braceDepth == extDepth {
            if let sig = extractPublicModifier(from: trimmed) {
                modifiers.append(DescribedSymbol(
                    module: module,
                    file: file,
                    kind: "modifier",
                    signature: sig,
                    doc: pendingDoc.first ?? ""
                ))
            }
            pendingDoc.removeAll(keepingCapacity: true)
        } else if !trimmed.isEmpty {
            pendingDoc.removeAll(keepingCapacity: true)
        }

        braceDepth += netBraceDelta(trimmed)
        if let extDepth = viewExtensionDepth, braceDepth < extDepth {
            viewExtensionDepth = nil
        }
    }
}

private func extractPublicType(from line: String) -> (String, String)? {
    let stripped = stripLeadingModifiers(line)
    let keywords = ["struct ", "final class ", "class ", "enum ", "protocol ", "typealias "]
    for kw in keywords {
        if stripped.hasPrefix(kw) {
            let sig = cleanSignature(stripped)
            let kind = kw.hasPrefix("final ") ? "class" : trimWhitespace(kw)
            return (kind, sig)
        }
    }
    return nil
}

private func extractPublicModifier(from line: String) -> String? {
    guard line.hasPrefix("public func ") || line.hasPrefix("@MainActor public func ") else { return nil }
    let cleaned = cleanSignature(line)
    return cleaned
}

private func stripLeadingModifiers(_ line: String) -> String {
    guard line.contains("public ") else { return "" }
    var s = line
    let prefixes = ["@MainActor ", "@Observable ", "nonisolated ", "public "]
    var changed = true
    var sawPublic = false
    while changed {
        changed = false
        for p in prefixes {
            if s.hasPrefix(p) {
                if p == "public " { sawPublic = true }
                s = String(s.dropFirst(p.count))
                changed = true
            }
        }
    }
    return sawPublic ? s : ""
}

private func cleanSignature(_ line: String) -> String {
    var s = line
    if let brace = s.firstIndex(of: "{") {
        s = String(s[..<brace])
    }
    return trimWhitespace(s)
}

private func netBraceDelta(_ line: String) -> Int {
    var delta = 0
    var inString = false
    var escaped = false
    var prev: Character = "\0"
    for ch in line {
        if !inString && prev == "/" && ch == "/" {
            break
        }
        if inString {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString = false
            }
        } else {
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                delta += 1
            } else if ch == "}" {
                delta -= 1
            }
        }
        prev = ch
    }
    return delta
}

private func trimWhitespace(_ s: String) -> String {
    var start = s.startIndex
    var end = s.endIndex
    while start < end && (s[start] == " " || s[start] == "\t" || s[start] == "\r") {
        start = s.index(after: start)
    }
    while end > start {
        let prev = s.index(before: end)
        if s[prev] == " " || s[prev] == "\t" || s[prev] == "\r" {
            end = prev
        } else {
            break
        }
    }
    return String(s[start..<end])
}
