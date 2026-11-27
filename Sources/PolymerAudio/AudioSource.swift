// Decoded audio as one interface: every decoder (WAV, FLAC, MP3) is an
// `AudioSource` that reads interleaved Float frames in [-1, 1] and seeks to
// an exact frame. `Audio.open` picks the decoder from the bytes, never from
// the file name.
import PolymerBase
import PolymerPlatform

public struct AudioError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A decoder positioned in a stream. A source is used by one thread at a time
/// (the engine's feeder); it is Sendable so it can be handed to that thread.
public protocol AudioSource: AnyObject, Sendable {
    /// The source's own rate and channel count.
    var format: AudioFormat { get }
    /// Total frames, when the stream says (gapless length for MP3 with a LAME header).
    var frameCount: Int? { get }
    /// The next frame `read` returns.
    var position: Int { get }
    /// Bits per sample of the original (16, 24, ...); 0 for lossy streams.
    var bitsPerSample: Int { get }
    /// Tags and cover art.
    var metadata: AudioMetadata { get }
    /// Reads up to `frames` interleaved frames into `buffer` (room for
    /// `frames * format.channels` samples). Returns the frames read; 0 at the end.
    func read(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int
    /// Moves so the next `read` starts at `frame` (clamped to the stream).
    func seek(toFrame frame: Int) throws(AudioError)
}

extension AudioSource {
    /// Length in seconds, when known.
    public var duration: Double? { frameCount.map { Double($0) / Double(format.sampleRate) } }

    /// Reads everything from the current position (for checks and tools, not playback).
    public func readAll(chunk: Int = 4096) -> [Float] {
        var out: [Float] = []
        if let n = frameCount { out.reserveCapacity(max(0, n - position) * format.channels) }
        var scratch = [Float](repeating: 0, count: chunk * format.channels)
        while true {
            let n = scratch.withUnsafeMutableBufferPointer { read(into: $0.baseAddress!, frames: chunk) }
            if n == 0 { break }
            out.append(contentsOf: scratch[0..<(n * format.channels)])
        }
        return out
    }
}

/// A picture embedded in a file (ID3 APIC, FLAC PICTURE, MP4 covr).
public struct CoverArt: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case jpeg, png, other }
    /// Found from the bytes themselves (the declared MIME type is often wrong).
    public var kind: Kind
    public var mimeType: String
    /// ID3/FLAC picture type: 3 is the front cover, 0 "other".
    public var pictureType: Int
    public var description: String
    /// The encoded image, ready for `JPEG.decode` or `PNG.decode`.
    public var bytes: [UInt8]

    public init(mimeType: String, pictureType: Int, description: String, bytes: [UInt8]) {
        self.mimeType = mimeType; self.pictureType = pictureType; self.description = description; self.bytes = bytes
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { kind = .jpeg }
        else if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { kind = .png }
        else { kind = .other }
    }
}

/// Tags in one shape for every format. Field names follow common usage
/// (Vorbis comments, ID3 frames); `extra` keeps everything else by its own key.
public struct AudioMetadata: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    /// The year or full date as written ("1997", "1997-05-21").
    public var date: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var comment: String?
    /// ReplayGain values in dB, when tagged.
    public var trackGain: Double?
    public var albumGain: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?
    /// Other fields, upper-cased key to value (Vorbis names; ID3 frame IDs or TXXX descriptions).
    public var extra: [String: String] = [:]
    public var pictures: [CoverArt] = []

    public init() {}

    /// The front cover, else the first picture.
    public var frontCover: CoverArt? { pictures.first { $0.pictureType == 3 } ?? pictures.first }

    /// True when nothing at all is tagged.
    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil && composer == nil
            && genre == nil && date == nil && trackNumber == nil && trackTotal == nil
            && discNumber == nil && discTotal == nil && comment == nil && extra.isEmpty && pictures.isEmpty
            && trackGain == nil && albumGain == nil && trackPeak == nil && albumPeak == nil
    }

    /// Sets a field from a Vorbis-comment style key (also used for mapped ID3 frames).
    public mutating func set(_ key: String, _ value: String) {
        let k = key.uppercased()
        func number(_ s: String) -> (Int?, Int?) {
            let parts = s.split(separator: "/", maxSplits: 1).map { $0.trimmingSpaces }
            return (parts.first.flatMap { Int($0) }, parts.count > 1 ? Int(parts[1]) : nil)
        }
        func gain(_ s: String) -> Double? {
            var t = s.trimmingSpaces
            if t.lowercased().hasSuffix("db") { t = String(t.dropLast(2)).trimmingSpaces }
            return Double(t)
        }
        switch k {
        case "TITLE": title = value
        case "ARTIST": artist = artist.map { $0 + "; " + value } ?? value
        case "ALBUM": album = value
        case "ALBUMARTIST", "ALBUM ARTIST": albumArtist = value
        case "COMPOSER": composer = value
        case "GENRE": genre = value
        case "DATE", "YEAR": if date == nil || k == "DATE" { date = value }
        case "TRACKNUMBER":
            let (n, t) = number(value); trackNumber = n; if let t { trackTotal = t }
        case "TRACKTOTAL", "TOTALTRACKS": trackTotal = Int(value.trimmingSpaces)
        case "DISCNUMBER":
            let (n, t) = number(value); discNumber = n; if let t { discTotal = t }
        case "DISCTOTAL", "TOTALDISCS": discTotal = Int(value.trimmingSpaces)
        case "COMMENT", "DESCRIPTION": comment = value
        case "REPLAYGAIN_TRACK_GAIN": trackGain = gain(value)
        case "REPLAYGAIN_ALBUM_GAIN": albumGain = gain(value)
        case "REPLAYGAIN_TRACK_PEAK": trackPeak = Double(value.trimmingSpaces)
        case "REPLAYGAIN_ALBUM_PEAK": albumPeak = Double(value.trimmingSpaces)
        default: extra[k] = value
        }
    }
}

extension Substring {
    var trimmingSpaces: String { String(self).trimmingSpaces }
}
extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" || f == "\0" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\0" { s = s.dropLast() }
        return String(s)
    }
}

public enum Audio {
    /// The container in `bytes`, from its first bytes.
    public enum Container: Sendable, Equatable { case wav, flac, mp3, aiff, alac, unknown }

    public static func container(of bytes: [UInt8]) -> Container {
        func tag(_ at: Int, _ s: String) -> Bool {
            let u = Array(s.utf8)
            guard at + u.count <= bytes.count else { return false }
            for i in 0..<u.count where bytes[at + i] != u[i] { return false }
            return true
        }
        if (tag(0, "RIFF") || tag(0, "RF64")) && tag(8, "WAVE") { return .wav }
        if tag(0, "FORM") && (tag(8, "AIFF") || tag(8, "AIFC")) { return .aiff }
        if tag(4, "ftyp") { return .alac }
        var start = 0
        if tag(0, "ID3") { start = ID3v2.totalSize(bytes) }
        if tag(start, "fLaC") { return .flac }
        if MP3.findFrame(bytes, from: start, limit: 64 * 1024) != nil { return .mp3 }
        return .unknown
    }

    /// A decoder for the bytes of a whole file.
    public static func open(_ bytes: [UInt8]) throws(AudioError) -> any AudioSource {
        switch container(of: bytes) {
        case .wav: return try WAVSource(bytes)
        case .flac: return try FLACSource(bytes)
        case .mp3: return try MP3Source(bytes)
        case .aiff: return try AIFFSource(bytes)
        case .alac: return try ALACSource(bytes)
        case .unknown:
            throw AudioError("not a WAV, FLAC, MP3, AIFF or ALAC stream (first bytes \(bytes.prefix(4).map { String($0, radix: 16) }.joined(separator: " "))); AAC and Vorbis are not decoded yet")
        }
    }

    /// Reads and opens a file through `Platform.files`.
    public static func open(path: String) throws(AudioError) -> any AudioSource {
        let bytes: [UInt8]
        do { bytes = try Platform.files.read(path) } catch { throw AudioError("\(path): \(error.message)") }
        do { return try open(bytes) } catch { throw AudioError("\(path): \(error.message)") }
    }

    /// Tags and pictures only, without setting up a decoder.
    public static func metadata(_ bytes: [UInt8]) -> AudioMetadata {
        switch container(of: bytes) {
        case .flac: return (try? FLACSource.readMetadata(bytes)) ?? AudioMetadata()
        case .mp3:
            var m = AudioMetadata()
            if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { ID3v2.read(bytes, into: &m) }
            else { ID3v1.read(bytes, into: &m) }
            return m
        case .wav: return WAVSource.readMetadata(bytes)
        case .aiff: return AIFFSource.readMetadata(bytes)
        case .alac: return MP4Metadata.read(bytes)
        case .unknown: return AudioMetadata()
        }
    }
}
