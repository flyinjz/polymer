// Windows backend: files and process through the C runtime and Win32,
// with UTF-16 paths so any file name works.
#if os(Windows)
import WinSDK
import ucrt
import PolymerPlatform

public struct WindowsFileSystem: FileSystem {
    public init() {}

    static func wide(_ path: String) -> [UInt16] {
        Array(path.replacing("/", with: "\\").utf16) + [0]
    }

    func lastError(_ path: String, _ what: String) -> FileError {
        let code = GetLastError()
        let reason: String
        switch code {
        case 2: reason = "no such file"
        case 3: reason = "no such folder"
        case 5: reason = "access denied"
        case 32: reason = "file is in use by another program"
        default: reason = "Windows error \(code)"
        }
        return FileError(path: path, message: "\(what): \(reason)")
    }

    public func read(_ path: String) throws(FileError) -> [UInt8] {
        let h = CreateFileW(Self.wide(path), GENERIC_READ, DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                            DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        guard h != INVALID_HANDLE_VALUE else { throw lastError(path, "cannot open") }
        defer { CloseHandle(h) }
        var size = LARGE_INTEGER()
        guard GetFileSizeEx(h, &size) else { throw lastError(path, "cannot read size") }
        let n = Int(size.QuadPart)
        var out = [UInt8](repeating: 0, count: n)
        var done = 0
        while done < n {
            var got: DWORD = 0
            let want = DWORD(min(n - done, 1 << 30))
            let ok = out.withUnsafeMutableBytes { ReadFile(h, $0.baseAddress! + done, want, &got, nil) }
            guard ok, got > 0 else { throw lastError(path, "cannot read") }
            done += Int(got)
        }
        return out
    }

    public func write(_ bytes: [UInt8], to path: String) throws(FileError) {
        let h = CreateFileW(Self.wide(path), DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        guard h != INVALID_HANDLE_VALUE else { throw lastError(path, "cannot create") }
        defer { CloseHandle(h) }
        var done = 0
        while done < bytes.count {
            var put: DWORD = 0
            let want = DWORD(min(bytes.count - done, 1 << 30))
            let ok = bytes.withUnsafeBytes { WriteFile(h, $0.baseAddress! + done, want, &put, nil) }
            guard ok else { throw lastError(path, "cannot write") }
            done += Int(put)
        }
    }

    public func exists(_ path: String) -> Bool {
        GetFileAttributesW(Self.wide(path)) != INVALID_FILE_ATTRIBUTES
    }

    public func createDirectory(_ path: String) throws(FileError) {
        if path.isEmpty || exists(path) { return }
        let parent = Path.parent(path)
        if !parent.isEmpty, !parent.hasSuffix(":") { try createDirectory(parent) }
        if !CreateDirectoryW(Self.wide(path), nil), GetLastError() != DWORD(ERROR_ALREADY_EXISTS) {
            throw lastError(path, "cannot create folder")
        }
    }

    public func list(_ path: String) throws(FileError) -> [String] {
        var data = WIN32_FIND_DATAW()
        let h = FindFirstFileW(Self.wide(path + "/*"), &data)
        guard h != INVALID_HANDLE_VALUE else { throw lastError(path, "cannot list") }
        defer { FindClose(h) }
        var names: [String] = []
        repeat {
            let name = withUnsafeBytes(of: data.cFileName) { raw -> String in
                let u = raw.bindMemory(to: UInt16.self)
                let len = u.firstIndex(of: 0) ?? u.count
                return String(decoding: u[0..<len], as: UTF16.self)
            }
            if name != ".", name != ".." { names.append(name) }
        } while FindNextFileW(h, &data)
        return names.sorted()
    }
}

public struct WindowsProcess: Process {
    public init() {
        // UTF-8 console output.
        SetConsoleOutputCP(UINT(CP_UTF8))
    }

    public var arguments: [String] { CommandLine.arguments }

    public func environment(_ name: String) -> String? {
        let key = Array(name.utf16) + [0]
        let n = GetEnvironmentVariableW(key, nil, 0)
        guard n > 0 else { return nil }
        var buf = [UInt16](repeating: 0, count: Int(n))
        let got = GetEnvironmentVariableW(key, &buf, n)
        return String(decoding: buf[0..<Int(got)], as: UTF16.self)
    }

    public func writeStandardError(_ text: String) {
        fflush(nil)
        let h = GetStdHandle(STD_ERROR_HANDLE)
        let bytes = Array(text.utf8)
        var put: DWORD = 0
        bytes.withUnsafeBytes { _ = WriteFile(h, $0.baseAddress, DWORD($0.count), &put, nil) }
    }

    public func exit(_ code: Int32) -> Never {
        fflush(nil)
        ucrt.exit(code)
    }
}
#endif
