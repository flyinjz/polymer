// Platform interfaces. Shared code talks to the OS only through these;
// each OS implements them in its backend (PolymerPlatformWindows, ...Mac)
// and the app entry point installs one with `Platform.install`.
import PolymerBase

public struct FileError: Error, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
    public var description: String { "\(path): \(message)" }
}

/// Files and folders. Paths use '/' on every OS; backends convert.
public protocol FileSystem: Sendable {
    func read(_ path: String) throws(FileError) -> [UInt8]
    func write(_ bytes: [UInt8], to path: String) throws(FileError)
    func exists(_ path: String) -> Bool
    /// Creates the folder and any missing parents.
    func createDirectory(_ path: String) throws(FileError)
    /// Names of the entries in a folder, sorted, without "." and "..".
    func list(_ path: String) throws(FileError) -> [String]
}

/// The running process.
public protocol Process: Sendable {
    var arguments: [String] { get }
    func environment(_ name: String) -> String?
    func writeStandardError(_ text: String)
    func exit(_ code: Int32) -> Never
}

public enum Platform {
    nonisolated(unsafe) private static var _files: (any FileSystem)?
    nonisolated(unsafe) private static var _process: (any Process)?

    /// Called once by the entry point, before anything else.
    public static func install(files: any FileSystem, process: any Process) {
        _files = files
        _process = process
    }

    public static var files: any FileSystem {
        guard let f = _files else {
            fatalError("Platform not installed: call Platform.install(...) from the entry point with the backend for this OS")
        }
        return f
    }
    public static var process: any Process {
        guard let p = _process else {
            fatalError("Platform not installed: call Platform.install(...) from the entry point with the backend for this OS")
        }
        return p
    }
}

extension FileSystem {
    public func readText(_ path: String) throws(FileError) -> String {
        String(decoding: try read(path), as: UTF8.self)
    }
    public func write(_ text: String, to path: String) throws(FileError) {
        try write(Array(text.utf8), to: path)
    }
}

/// Path helpers ('/' separators).
public enum Path {
    public static func join(_ parts: String...) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if out.isEmpty || out.hasSuffix("/") { out += p } else { out += "/" + p }
        }
        return out
    }
    public static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }
    public static func fileName(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: i)...])
    }
    public static func stem(_ path: String) -> String {
        let n = fileName(path)
        guard let i = n.lastIndex(of: ".") else { return n }
        return String(n[..<i])
    }
}
