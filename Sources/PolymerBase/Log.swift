// Logging. Messages go to one sink chosen by the app at start-up (the
// `polymer` command uses standard error). Never call on a hot path.

public enum LogLevel: Int, Comparable, Sendable {
    case debug, info, warning, error
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    public var name: String {
        switch self { case .debug: "debug"; case .info: "info"; case .warning: "warning"; case .error: "error" }
    }
}

public struct Logger: Sendable {
    public let category: String
    public init(_ category: String) { self.category = category }

    public typealias Sink = @Sendable (LogLevel, String, String) -> Void

    /// Set once at start-up, before any other thread logs.
    nonisolated(unsafe) public static var sink: Sink = { level, category, message in
        print("[\(level.name)] \(category): \(message)")
    }
    nonisolated(unsafe) public static var minimumLevel: LogLevel = .info

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level >= Logger.minimumLevel else { return }
        Logger.sink(level, category, message())
    }
    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: @autoclosure () -> String) { log(.info, m()) }
    public func warning(_ m: @autoclosure () -> String) { log(.warning, m()) }
    public func error(_ m: @autoclosure () -> String) { log(.error, m()) }
}
