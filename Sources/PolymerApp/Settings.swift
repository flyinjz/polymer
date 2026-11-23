// Deterministic JSON settings persistence built on PolymerBase.JSON and PolymerPlatform.FileSystem.
import Observation
import PolymerBase
import PolymerPlatform
import PolymerUI

public struct SettingsError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "settings: \(message)" }
}

/// Typed key-value settings store with deterministic sorted-key JSON serialization,
/// schema versioning, dirty tracking, and optional file persistence via `Platform.files`.
@MainActor
@Observable
public final class SettingsStore: Equatable {
    /// Backing file path; nil keeps the store purely in memory (ideal for headless tests).
    public let filePath: String?
    /// Schema version written into the persisted JSON envelope.
    public var schemaVersion: Int
    /// True when in-memory state has unsaved modifications.
    public private(set) var isDirty: Bool = false
    /// Monotonic counter incremented on every mutation or reload so observing views update.
    public private(set) var revision: Int = 0

    private var values: [String: JSON] = [:]

    public init(filePath: String? = nil, schemaVersion: Int = 1) {
        self.filePath = filePath
        self.schemaVersion = schemaVersion
    }

    nonisolated public static func == (lhs: SettingsStore, rhs: SettingsStore) -> Bool {
        lhs === rhs
    }

    // MARK: Inspection

    /// All stored keys in deterministic sorted order.
    public var keys: [String] {
        _ = revision
        return values.keys.sorted()
    }

    public var count: Int {
        _ = revision
        return values.count
    }

    public func contains(_ key: String) -> Bool {
        _ = revision
        return values[key] != nil
    }

    // MARK: Raw JSON Access

    public func json(forKey key: String) -> JSON? {
        _ = revision
        return values[key]
    }

    public func set(_ value: JSON, forKey key: String) {
        if values[key] == value { return }
        values[key] = value
        isDirty = true
        revision += 1
    }

    public func remove(_ key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        isDirty = true
        revision += 1
    }

    // MARK: Typed Getters and Setters

    public func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        json(forKey: key)?.bool ?? defaultValue
    }

    public func set(_ value: Bool, forKey key: String) {
        set(.bool(value), forKey: key)
    }

    public func int(forKey key: String, default defaultValue: Int = 0) -> Int {
        json(forKey: key)?.int ?? defaultValue
    }

    public func set(_ value: Int, forKey key: String) {
        set(.number(Double(value)), forKey: key)
    }

    public func double(forKey key: String, default defaultValue: Double = 0) -> Double {
        json(forKey: key)?.double ?? defaultValue
    }

    public func set(_ value: Double, forKey key: String) {
        set(.number(value), forKey: key)
    }

    public func string(forKey key: String, default defaultValue: String = "") -> String {
        json(forKey: key)?.string ?? defaultValue
    }

    public func set(_ value: String, forKey key: String) {
        set(.string(value), forKey: key)
    }

    public func stringArray(forKey key: String, default defaultValue: [String] = []) -> [String] {
        guard let arr = json(forKey: key)?.array else { return defaultValue }
        var out: [String] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            guard let s = item.string else { return defaultValue }
            out.append(s)
        }
        return out
    }

    public func set(_ value: [String], forKey key: String) {
        set(.array(value.map { .string($0) }), forKey: key)
    }

    // MARK: Serialization & Persistence

    /// Deterministic JSON snapshot containing `schemaVersion` and sorted `values`.
    public func snapshotJSON() -> JSON {
        _ = revision
        return .object([
            "schemaVersion": .number(Double(schemaVersion)),
            "values": .object(values),
        ])
    }

    /// Deterministic JSON text (sorted keys on every OS).
    public func serialize(pretty: Bool = true) -> String {
        let doc = snapshotJSON()
        return pretty ? doc.pretty : doc.serialized
    }

    /// Replaces in-memory settings from deterministic JSON text.
    public func deserialize(_ text: String) throws(SettingsError) {
        let parsed: JSON
        do {
            parsed = try JSON.parse(text)
        } catch {
            throw SettingsError("invalid JSON: \(error.description)")
        }
        guard let root = parsed.object else {
            throw SettingsError("expected a top-level JSON object")
        }
        if let ver = root["schemaVersion"]?.int {
            schemaVersion = ver
        } else if root["schemaVersion"] != nil {
            throw SettingsError("schemaVersion must be an integer")
        }
        if let vals = root["values"] {
            guard let map = vals.object else {
                throw SettingsError("values must be a JSON object")
            }
            values = map
        } else {
            // Accept a flat key-value object if no envelope wrapper is present.
            var map = root
            map.removeValue(forKey: "schemaVersion")
            values = map
        }
        isDirty = false
        revision += 1
    }

    /// Loads settings from `filePath` via `Platform.files`. Does nothing if in-memory or file does not yet exist.
    public func load() throws {
        guard let filePath else {
            isDirty = false
            return
        }
        guard Platform.files.exists(filePath) else {
            values.removeAll(keepingCapacity: true)
            isDirty = false
            revision += 1
            return
        }
        let text = try Platform.files.readText(filePath)
        try deserialize(text)
    }

    /// Writes settings deterministically to `filePath` via `Platform.files` (creating parent directories if needed).
    public func save() throws {
        guard let filePath else {
            isDirty = false
            return
        }
        let parent = PolymerPlatform.Path.parent(filePath)
        if !parent.isEmpty {
            try Platform.files.createDirectory(parent)
        }
        try Platform.files.write(serialize(pretty: true), to: filePath)
        isDirty = false
    }

    /// Clears all stored settings.
    public func reset() {
        let hadValues = !values.isEmpty
        values.removeAll(keepingCapacity: true)
        if hadValues {
            isDirty = true
            revision += 1
        }
    }
}

// MARK: Environment Integration

private enum SettingsStoreKey: EnvironmentKey {
    static var defaultValue: SettingsStore? { nil }
}

extension EnvironmentValues {
    public var settingsStore: SettingsStore? {
        get { self[SettingsStoreKey.self] }
        set { self[SettingsStoreKey.self] = newValue }
    }
}

extension View {
    public func settingsStore(_ store: SettingsStore?) -> some View {
        environment(\.settingsStore, store)
    }
}
