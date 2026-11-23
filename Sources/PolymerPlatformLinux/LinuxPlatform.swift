// Linux backend: files and process through POSIX (Glibc).
#if os(Linux)
import Glibc
import PolymerPlatform

public struct LinuxFileSystem: FileSystem {
    public init() {}

    func failure(_ path: String, _ what: String) -> FileError {
        FileError(path: path, message: "\(what): \(String(cString: strerror(errno)))")
    }

    public func read(_ path: String) throws(FileError) -> [UInt8] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw failure(path, "cannot open") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw failure(path, "cannot read size") }
        let n = Int(st.st_size)
        var out = [UInt8](repeating: 0, count: n)
        var done = 0
        while done < n {
            let got = out.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress! + done, n - done) }
            guard got > 0 else { throw failure(path, "cannot read") }
            done += got
        }
        return out
    }

    public func write(_ bytes: [UInt8], to path: String) throws(FileError) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw failure(path, "cannot create") }
        defer { close(fd) }
        var done = 0
        while done < bytes.count {
            let put = bytes.withUnsafeBytes { Glibc.write(fd, $0.baseAddress! + done, bytes.count - done) }
            guard put > 0 else { throw failure(path, "cannot write") }
            done += put
        }
    }

    public func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    public func createDirectory(_ path: String) throws(FileError) {
        if path.isEmpty || exists(path) { return }
        let parent = Path.parent(path)
        if !parent.isEmpty { try createDirectory(parent) }
        if mkdir(path, 0o755) != 0, errno != EEXIST { throw failure(path, "cannot create folder") }
    }

    public func list(_ path: String) throws(FileError) -> [String] {
        guard let dir = opendir(path) else { throw failure(path, "cannot list") }
        defer { closedir(dir) }
        var names: [String] = []
        while let e = readdir(dir) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }
}

public struct LinuxProcess: Process {
    public init() {}
    public var arguments: [String] { CommandLine.arguments }
    public func environment(_ name: String) -> String? {
        guard let v = getenv(name) else { return nil }
        return String(cString: v)
    }
    public func writeStandardError(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { _ = Glibc.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
    public func exit(_ code: Int32) -> Never {
        fflush(nil)
        Glibc.exit(code)
    }
}
#endif
