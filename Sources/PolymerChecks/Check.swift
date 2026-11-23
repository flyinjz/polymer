// The check runner behind `polymer check`. Checks are plain functions,
// headless and deterministic; a failure says what was expected and where.
import PolymerBase
import PolymerPlatform

public struct CheckFailure: Error, Sendable {
    public let message: String
    public let location: String
}

/// Passed to each check; collects failures without stopping at the first.
public struct CheckContext {
    public internal(set) var failures: [CheckFailure] = []
    /// Folder for output images and reports (`out/checks`).
    public let outputDirectory: String
    /// Repository root, for fixtures and references.
    public let root: String
    public var notes: [String] = []

    public mutating func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                                file: StaticString = #fileID, line: UInt = #line) {
        if !condition { failures.append(CheckFailure(message: message(), location: "\(file):\(line)")) }
    }

    public mutating func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: @autoclosure () -> String = "",
                                                   file: StaticString = #fileID, line: UInt = #line) {
        if a != b {
            let w = what()
            failures.append(CheckFailure(message: (w.isEmpty ? "" : w + ": ") + "got \(a), expected \(b)",
                                         location: "\(file):\(line)"))
        }
    }

    public mutating func expectClose(_ a: Double, _ b: Double, tolerance: Double, _ what: @autoclosure () -> String = "",
                                     file: StaticString = #fileID, line: UInt = #line) {
        if !(abs(a - b) <= tolerance) {
            let w = what()
            failures.append(CheckFailure(message: (w.isEmpty ? "" : w + ": ") + "got \(a), expected \(b) ± \(tolerance)",
                                         location: "\(file):\(line)"))
        }
    }

    public mutating func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        failures.append(CheckFailure(message: message, location: "\(file):\(line)"))
    }

    /// Recorded in the report (measurements, not failures).
    public mutating func note(_ s: String) { notes.append(s) }
}

@MainActor
public struct Check {
    public let name: String
    public let run: @MainActor (inout CheckContext) throws -> Void
    public init(_ name: String, _ run: @escaping @MainActor (inout CheckContext) throws -> Void) {
        self.name = name; self.run = run
    }
}

@MainActor
public enum Checks {
    /// Every check, grouped by module, in dependency order.
    public static var all: [Check] {
        baseChecks + textChecks + renderChecks + uiChecks + editingAndGridChecks + appAndDesignChecks + audioAndGPUChecks
    }

    /// Runs the checks whose name contains `filter`; returns the number that failed.
    public static func run(filter: String?, root: String, verbose: Bool) -> Int {
        let out = Path.join(root, "out/checks")
        try? Platform.files.createDirectory(out)
        let selected = all.filter { filter == nil || $0.name.contains(filter!) }
        if selected.isEmpty {
            print("No check matches \"\(filter ?? "")\". Run `polymer check --list` to see their names.")
            return 1
        }
        var failed = 0
        let clock = ContinuousClock()
        for check in selected {
            var ctx = CheckContext(outputDirectory: out, root: root)
            let start = clock.now
            do { try check.run(&ctx) } catch { ctx.fail("threw: \(error)") }
            let ms = (clock.now - start).milliseconds
            if ctx.failures.isEmpty {
                print("pass  \(check.name)  (\(ms) ms)")
            } else {
                failed += 1
                print("FAIL  \(check.name)  (\(ms) ms)")
                for f in ctx.failures.prefix(20) { print("      \(f.location): \(f.message)") }
                if ctx.failures.count > 20 { print("      ... \(ctx.failures.count - 20) more") }
            }
            if verbose || !ctx.failures.isEmpty { for n in ctx.notes { print("      \(n)") } }
        }
        print(failed == 0 ? "\(selected.count) checks passed." : "\(failed) of \(selected.count) checks failed.")
        return failed
    }
}

extension Duration {
    public var milliseconds: Int {
        let (s, a) = components
        return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
    }
    public var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1e18
    }
}
