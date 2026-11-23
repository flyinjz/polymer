// Opt-in design lint rules for auditing view trees against house style guidelines
// (such as the pgr aesthetic). Never forced on all apps; callers select which rules to run.
import PolymerBase
import PolymerRender
import PolymerUI

/// A single actionable lint violation reported by `DesignLint.audit`.
public struct DesignLintViolation: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rule: String
    public let elementPath: String
    public let message: String
    public let fix: String

    public init(rule: String, elementPath: String, message: String, fix: String) {
        self.rule = rule
        self.elementPath = elementPath
        self.message = message
        self.fix = fix
    }

    public var description: String {
        "[\(rule)] \(elementPath): \(message) Fix: \(fix)"
    }

    public func toJSON() -> JSON {
        .object([
            "rule": .string(rule),
            "elementPath": .string(elementPath),
            "message": .string(message),
            "fix": .string(fix),
        ])
    }
}

/// Opt-in lint rules that apps may enable individually or via presets like `DesignLint.pgrRules`.
public enum DesignLintRule: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Flags UI copy of 4+ letters written entirely in ALL CAPS.
    case noAllCaps = "no-all-caps"
    /// Flags gimmicky `"//"` prefixes in UI labels.
    case noDoubleSlashPrefix = "no-double-slash-prefix"
    /// Enforces 0pt sharp corners in `Theme.radii` and no `RoundedRectangle` elements.
    case pgrSharpCorners = "pgr-sharp-corners"
    /// Flags overlapping or nested `BackdropBlur` veils that produce murky stacked glass.
    case noStackedGlass = "no-stacked-glass"
    /// Verifies every drawn colour in the `DisplayList` matches an active `Theme` palette token.
    case tokenColorsOnly = "token-colors-only"
}

/// Opt-in design-system auditor operating headlessly on a `ViewTree` and `Theme`.
public enum DesignLint {
    /// Complete opt-in rule set for the house pgr preset.
    public static let pgrRules: Set<DesignLintRule> = [
        .noAllCaps,
        .noDoubleSlashPrefix,
        .pgrSharpCorners,
        .noStackedGlass,
        .tokenColorsOnly,
    ]

    /// Copy-only rule subset applicable across any visual aesthetic.
    public static let copyRules: Set<DesignLintRule> = [
        .noAllCaps,
        .noDoubleSlashPrefix,
    ]

    /// Default short technical acronyms exempted from `.noAllCaps`.
    public static let defaultAllowedAcronyms: Set<String> = [
        "FLAC", "ALAC", "AIFF", "MP3", "PCM", "DSD", "HDMI", "USB",
        "WASAPI", "ASIO", "MIDI", "HTTP", "HTTPS", "JSON", "RGBA", "SRGB", "UUID",
    ]

    /// Audits `tree` against `theme` using the selected opt-in `rules`.
    @MainActor
    public static func audit(
        tree: ViewTree,
        theme: Theme,
        rules: Set<DesignLintRule> = DesignLint.pgrRules,
        colorTolerance: Double = 0.02,
        allowedAcronyms: Set<String> = DesignLint.defaultAllowedAcronyms
    ) -> [DesignLintViolation] {
        guard !rules.isEmpty else { return [] }
        var violations: [DesignLintViolation] = []

        let parsed = parseElementTree(tree.elementTree)

        if rules.contains(.noAllCaps) || rules.contains(.noDoubleSlashPrefix) {
            for elem in parsed where elem.role == "Text" {
                guard let label = elem.quotedText else { continue }
                if rules.contains(.noDoubleSlashPrefix) {
                    let trimmed = trimLeadingWhitespace(label)
                    if trimmed.hasPrefix("//") {
                        violations.append(DesignLintViolation(
                            rule: DesignLintRule.noDoubleSlashPrefix.rawValue,
                            elementPath: elem.path,
                            message: "Text label \"\(label)\" starts with a '//' prefix.",
                            fix: "Remove the '//' prefix and write plain descriptive copy."
                        ))
                    }
                }
                if rules.contains(.noAllCaps), isAllCapsViolation(label, allowedAcronyms: allowedAcronyms) {
                    violations.append(DesignLintViolation(
                        rule: DesignLintRule.noAllCaps.rawValue,
                        elementPath: elem.path,
                        message: "Text label \"\(label)\" uses ALL CAPS.",
                        fix: "Use sentence case or title case instead of ALL CAPS copy."
                    ))
                }
            }
        }

        if rules.contains(.pgrSharpCorners) {
            let r = theme.radii
            if r.none > 0 || r.small > 0 || r.medium > 0 || r.large > 0 || r.pill > 0 {
                violations.append(DesignLintViolation(
                    rule: DesignLintRule.pgrSharpCorners.rawValue,
                    elementPath: "Theme.radii",
                    message: "Theme \"\(theme.name)\" has non-zero corner radii (small=\(r.small), medium=\(r.medium), large=\(r.large), pill=\(r.pill)).",
                    fix: "Use Theme.pgr or set ThemeRadii(none: 0, small: 0, medium: 0, large: 0, pill: 0)."
                ))
            }
            for elem in parsed where elem.role == "RoundedRectangle" {
                violations.append(DesignLintViolation(
                    rule: DesignLintRule.pgrSharpCorners.rawValue,
                    elementPath: elem.path,
                    message: "RoundedRectangle found while sharp-corner pgr lint is active.",
                    fix: "Use Rectangle or a Theme-aware container with 0 corner radius."
                ))
            }
        }

        if rules.contains(.noStackedGlass) || rules.contains(.tokenColorsOnly) {
            if tree.displayList == nil {
                _ = tree.render()
            }
            if let list = tree.displayList {
                if rules.contains(.noStackedGlass) {
                    var blurs: [(index: Int, bounds: PixelRect)] = []
                    for (idx, item) in list.items.enumerated() {
                        if case .backdropBlur = item.operation {
                            blurs.append((idx, item.bounds))
                        }
                    }
                    var flagged = Set<Int>()
                    for i in 0..<blurs.count {
                        for j in (i + 1)..<blurs.count {
                            if rectsIntersect(blurs[i].bounds, blurs[j].bounds), !flagged.contains(blurs[j].index) {
                                flagged.insert(blurs[j].index)
                                violations.append(DesignLintViolation(
                                    rule: DesignLintRule.noStackedGlass.rawValue,
                                    elementPath: "DisplayList/BackdropBlur[\(blurs[j].index)]",
                                    message: "Stacked BackdropBlur regions overlap at (\(blurs[j].bounds.x), \(blurs[j].bounds.y), \(blurs[j].bounds.width)x\(blurs[j].bounds.height)).",
                                    fix: "Avoid nesting or overlapping BackdropBlur surfaces; apply glass to a single container layer."
                                ))
                            }
                        }
                    }
                }

                if rules.contains(.tokenColorsOnly) {
                    let palette = theme.paletteColors
                    var seenOffPalette = Set<String>()
                    for (idx, item) in list.items.enumerated() {
                        let color: Color?
                        switch item.operation {
                        case .rect(_, let c): color = c
                        case .path(_, let c): color = c
                        case .glyphs(let g): color = g.color
                        case .image, .backdropBlur: color = nil
                        }
                        guard let c = color, c.opacity >= 0.001 else { continue }
                        if !matchesPalette(c, palette: palette, tolerance: colorTolerance) {
                            let desc = c.description
                            if seenOffPalette.insert(desc).inserted {
                                violations.append(DesignLintViolation(
                                    rule: DesignLintRule.tokenColorsOnly.rawValue,
                                    elementPath: "DisplayList/Item[\(idx)]",
                                    message: "Drawn colour \(desc) is not in Theme \"\(theme.name)\" palette tokens.",
                                    fix: "Replace \(desc) with a semantic colour from @Environment(\\.theme).colors."
                                ))
                            }
                        }
                    }
                }
            }
        }

        return violations
    }

    // MARK: Helpers

    private struct ParsedElement {
        let depth: Int
        let role: String
        let path: String
        let quotedText: String?
    }

    private static func parseElementTree(_ dump: String) -> [ParsedElement] {
        var out: [ParsedElement] = []
        var pathStack: [String] = []
        var siblingCounts: [[String: Int]] = [[:]]

        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            var spaces = 0
            for ch in line {
                if ch == " " { spaces += 1 } else { break }
            }
            let depth = spaces / 2
            let trimmed = String(line.dropFirst(spaces))
            let role = String(trimmed.prefix { $0 != " " })

            while pathStack.count > depth {
                pathStack.removeLast()
            }
            while siblingCounts.count > depth + 1 {
                siblingCounts.removeLast()
            }
            while siblingCounts.count <= depth {
                siblingCounts.append([:])
            }

            let explicitID = extractIdentifier(from: trimmed)
            let step: String
            if let explicitID {
                step = "#\(explicitID)"
            } else {
                let idx = siblingCounts[depth][role, default: 0]
                siblingCounts[depth][role] = idx + 1
                step = "\(role)[\(idx)]"
            }

            let fullPath = (pathStack + [step]).joined(separator: "/")
            pathStack.append(step)

            let quoted = role == "Text" ? extractQuotedText(from: trimmed) : nil
            out.append(ParsedElement(depth: depth, role: role, path: fullPath, quotedText: quoted))
        }
        return out
    }

    private static func extractIdentifier(from line: String) -> String? {
        guard let closeParen = line.firstIndex(of: ")") else { return nil }
        let afterParen = line[line.index(after: closeParen)...]
        var i = afterParen.startIndex
        while i < afterParen.endIndex && afterParen[i] == " " {
            i = afterParen.index(after: i)
        }
        guard i < afterParen.endIndex, afterParen[i] == "#" else { return nil }
        let idStart = afterParen.index(after: i)
        var idEnd = idStart
        while idEnd < afterParen.endIndex && afterParen[idEnd] != " " {
            idEnd = afterParen.index(after: idEnd)
        }
        let id = String(afterParen[idStart..<idEnd])
        // Ignore hex colour literals like "#FFFFFF" emitted by Color/Rectangle/Border details.
        if (id.count == 6 || id.count == 8), id.allSatisfy({ $0.isHexDigit }) { return nil }
        return id.isEmpty ? nil : id
    }

    private static func extractQuotedText(from line: String) -> String? {
        guard let closeParen = line.firstIndex(of: ")") else { return nil }
        let rest = line[line.index(after: closeParen)...]
        guard let firstQuote = rest.firstIndex(of: "\""),
              let lastQuote = rest.lastIndex(of: "\""),
              firstQuote < lastQuote else { return nil }
        return String(rest[rest.index(after: firstQuote)..<lastQuote])
    }

    private static func trimLeadingWhitespace(_ s: String) -> String {
        String(s.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    }

    private static func isAllCapsViolation(_ text: String, allowedAcronyms: Set<String>) -> Bool {
        var letterCount = 0
        for ch in text where ch.isLetter {
            letterCount += 1
            if !ch.isUppercase { return false }
        }
        guard letterCount >= 4 else { return false }
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if !words.isEmpty && words.allSatisfy({ allowedAcronyms.contains($0) }) {
            return false
        }
        return true
    }

    private static func rectsIntersect(_ a: PixelRect, _ b: PixelRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    private static func matchesPalette(_ color: Color, palette: [Color], tolerance: Double) -> Bool {
        for token in palette {
            if abs(color.red - token.red) <= tolerance &&
                abs(color.green - token.green) <= tolerance &&
                abs(color.blue - token.blue) <= tolerance &&
                abs(color.opacity - token.opacity) <= tolerance {
                return true
            }
        }
        return false
    }
}
