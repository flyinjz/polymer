// Generic pure-Swift audio container metadata and tag parser:
// FLAC (STREAMINFO, VORBIS_COMMENT, PICTURE), ID3v2.3 & ID3v2.4 + MPEG Layer III,
// MP4/M4A (mdhd, stsd/alac, ilst), WAV (fmt, data, LIST/INFO), and AIFF (COMM, NAME/AUTH/ANNO).
// Standard library + PolymerBase only — bounds-checked throughout.
import PolymerBase

/// Recognized audio container / bitstream format.
public enum AudioContainerFormat: String, CaseIterable, Equatable, Hashable, Sendable {
    case flac
    case alac
    case wav
    case aiff
    case mp3
    case mp4
    case unknown
}

/// Container-agnostic audio metadata extracted from file headers and embedded tags.
public struct AudioMetadata: Equatable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var year: Int?
    public var genre: String?
    public var comment: String?
    public var durationSeconds: Double?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var format: AudioContainerFormat
    public var replayGainTrackDB: Double?
    public var replayGainAlbumDB: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumPeak: Double?
    public var artwork: [UInt8]?
    public var artworkMIME: String?
    public var extraTags: [String: String]

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        comment: String? = nil,
        durationSeconds: Double? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        channels: Int? = nil,
        format: AudioContainerFormat = .unknown,
        replayGainTrackDB: Double? = nil,
        replayGainAlbumDB: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumPeak: Double? = nil,
        artwork: [UInt8]? = nil,
        artworkMIME: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.year = year
        self.genre = genre
        self.comment = comment
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.format = format
        self.replayGainTrackDB = replayGainTrackDB
        self.replayGainAlbumDB = replayGainAlbumDB
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.artwork = artwork
        self.artworkMIME = artworkMIME
        self.extraTags = extraTags
    }

    /// Deterministic JSON representation (keys sorted on serialization by `JSON`).
    public func toJSON() -> JSON {
        var obj: [String: JSON] = ["format": .string(format.rawValue)]
        if let title { obj["title"] = .string(title) }
        if let artist { obj["artist"] = .string(artist) }
        if let album { obj["album"] = .string(album) }
        if let albumArtist { obj["albumArtist"] = .string(albumArtist) }
        if let trackNumber { obj["trackNumber"] = .number(Double(trackNumber)) }
        if let trackTotal { obj["trackTotal"] = .number(Double(trackTotal)) }
        if let discNumber { obj["discNumber"] = .number(Double(discNumber)) }
        if let discTotal { obj["discTotal"] = .number(Double(discTotal)) }
        if let year { obj["year"] = .number(Double(year)) }
        if let genre { obj["genre"] = .string(genre) }
        if let comment { obj["comment"] = .string(comment) }
        if let durationSeconds { obj["durationSeconds"] = .number(durationSeconds) }
        if let sampleRate { obj["sampleRate"] = .number(Double(sampleRate)) }
        if let bitDepth { obj["bitDepth"] = .number(Double(bitDepth)) }
        if let channels { obj["channels"] = .number(Double(channels)) }
        if let replayGainTrackDB { obj["replayGainTrackDB"] = .number(replayGainTrackDB) }
        if let replayGainAlbumDB { obj["replayGainAlbumDB"] = .number(replayGainAlbumDB) }
        if let replayGainTrackPeak { obj["replayGainTrackPeak"] = .number(replayGainTrackPeak) }
        if let replayGainAlbumPeak { obj["replayGainAlbumPeak"] = .number(replayGainAlbumPeak) }
        if let artworkMIME { obj["artworkMIME"] = .string(artworkMIME) }
        if let artwork { obj["artworkByteCount"] = .number(Double(artwork.count)) }
        if !extraTags.isEmpty {
            var extras: [String: JSON] = [:]
            for (k, v) in extraTags {
                extras[k] = .string(v)
            }
            obj["extraTags"] = .object(extras)
        }
        return .object(obj)
    }

    /// Reconstructs textual and numeric metadata fields from a JSON object produced by `toJSON()`.
    public init?(json: JSON) {
        guard case .object(let obj) = json else { return nil }
        let fmt = obj["format"]?.string.flatMap(AudioContainerFormat.init(rawValue:)) ?? .unknown
        var extras: [String: String] = [:]
        if let extraObj = obj["extraTags"]?.object {
            for (k, v) in extraObj {
                if let s = v.string { extras[k] = s }
            }
        }
        self.init(
            title: obj["title"]?.string,
            artist: obj["artist"]?.string,
            album: obj["album"]?.string,
            albumArtist: obj["albumArtist"]?.string,
            trackNumber: obj["trackNumber"]?.int,
            trackTotal: obj["trackTotal"]?.int,
            discNumber: obj["discNumber"]?.int,
            discTotal: obj["discTotal"]?.int,
            year: obj["year"]?.int,
            genre: obj["genre"]?.string,
            comment: obj["comment"]?.string,
            durationSeconds: obj["durationSeconds"]?.double,
            sampleRate: obj["sampleRate"]?.int,
            bitDepth: obj["bitDepth"]?.int,
            channels: obj["channels"]?.int,
            format: fmt,
            replayGainTrackDB: obj["replayGainTrackDB"]?.double,
            replayGainAlbumDB: obj["replayGainAlbumDB"]?.double,
            replayGainTrackPeak: obj["replayGainTrackPeak"]?.double,
            replayGainAlbumPeak: obj["replayGainAlbumPeak"]?.double,
            artwork: nil,
            artworkMIME: obj["artworkMIME"]?.string,
            extraTags: extras
        )
    }
}

// MARK: - Private Binary & String Helpers

private extension Array where Element == UInt8 {
    @inline(__always) func metaFourCC(at i: Int) -> String {
        guard i >= 0, i + 4 <= count else { return "" }
        return String(decoding: self[i..<(i + 4)], as: UTF8.self)
    }

    @inline(__always) func metaU64BE(at i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= count else { return 0 }
        return (UInt64(u32(at: i)) << 32) | UInt64(u32(at: i + 4))
    }

    @inline(__always) mutating func appendMetaU16LE(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }

    @inline(__always) mutating func appendMetaU32LE(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 24))
    }

    @inline(__always) mutating func appendMetaU24BE(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    @inline(__always) mutating func appendMetaSynchsafe32(_ v: Int) {
        let u = UInt32(Swift.max(0, v))
        append(UInt8((u >> 21) & 0x7F))
        append(UInt8((u >> 14) & 0x7F))
        append(UInt8((u >> 7) & 0x7F))
        append(UInt8(u & 0x7F))
    }

    @inline(__always) mutating func appendMetaASCII(_ s: String) {
        append(contentsOf: s.utf8)
    }
}

private func asciiUpper(_ s: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for b in s.utf8 {
        if b >= 0x61 && b <= 0x7A {
            out.append(b - 32)
        } else {
            out.append(b)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func trimASCII(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var lo = 0
    var hi = bytes.count
    @inline(__always) func isTrim(_ b: UInt8) -> Bool {
        b == 0x00 || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }
    while lo < hi && isTrim(bytes[lo]) { lo += 1 }
    while hi > lo && isTrim(bytes[hi - 1]) { hi -= 1 }
    return String(decoding: bytes[lo..<hi], as: UTF8.self)
}

private func parseNumberPair(_ raw: String) -> (Int?, Int?) {
    let trimmed = trimASCII(raw)
    guard !trimmed.isEmpty else { return (nil, nil) }
    if let slash = trimmed.firstIndex(of: "/") {
        let left = trimASCII(String(trimmed[..<slash]))
        let right = trimASCII(String(trimmed[trimmed.index(after: slash)...]))
        return (Int(left), Int(right))
    }
    return (Int(trimmed), nil)
}

private func parseYear(_ raw: String) -> Int? {
    let bytes = Array(raw.utf8)
    var run = 0
    var start = 0
    for i in 0..<bytes.count {
        if bytes[i] >= 0x30 && bytes[i] <= 0x39 {
            if run == 0 { start = i }
            run += 1
            if run == 4 {
                return Int(String(decoding: bytes[start..<(start + 4)], as: UTF8.self))
            }
        } else {
            run = 0
        }
    }
    return nil
}

private func parseReplayGainDB(_ raw: String) -> Double? {
    var s = trimASCII(raw)
    if s.hasPrefix("+") {
        s.removeFirst()
    }
    let upper = asciiUpper(s)
    if upper.hasSuffix("DB") {
        s = trimASCII(String(s.dropLast(2)))
    }
    return Double(s)
}

private func detectImageMIME(_ bytes: [UInt8]) -> String? {
    if bytes.count >= 8,
       bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
        return "image/png"
    }
    if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
        return "image/jpeg"
    }
    if bytes.count >= 4, bytes.metaFourCC(at: 0) == "GIF8" {
        return "image/gif"
    }
    if bytes.count >= 12, bytes.metaFourCC(at: 0) == "RIFF", bytes.metaFourCC(at: 8) == "WEBP" {
        return "image/webp"
    }
    return nil
}

// MARK: - Audio Metadata Parser

/// Pure-Swift audio container metadata parser and synthetic tag builder.
public enum AudioMetadataParser {
    /// Detects the container format from leading magic bytes.
    public static func detectFormat(_ bytes: [UInt8]) -> AudioContainerFormat {
        if bytes.count >= 4, bytes.metaFourCC(at: 0) == "fLaC" {
            return .flac
        }
        if bytes.count >= 12, bytes.metaFourCC(at: 0) == "RIFF", bytes.metaFourCC(at: 8) == "WAVE" {
            return .wav
        }
        if bytes.count >= 12, bytes.metaFourCC(at: 0) == "FORM" {
            let formType = bytes.metaFourCC(at: 8)
            if formType == "AIFF" || formType == "AIFC" {
                return .aiff
            }
        }
        if bytes.count >= 8, bytes.metaFourCC(at: 4) == "ftyp" {
            return .mp4
        }
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return .mp3
        }
        if bytes.count >= 4, MP3FrameHeader.parse(from: bytes, at: 0) != nil {
            return .mp3
        }
        return .unknown
    }

    /// Parses container headers, audio stream parameters, tags, ReplayGain, and artwork from `bytes`.
    public static func parse(_ bytes: [UInt8]) -> AudioMetadata {
        let detected = detectFormat(bytes)
        switch detected {
        case .flac:
            return parseFLAC(bytes)
        case .mp3:
            return parseID3AndMP3(bytes)
        case .mp4, .alac:
            return parseMP4(bytes)
        case .wav:
            return parseWAV(bytes)
        case .aiff:
            return parseAIFF(bytes)
        case .unknown:
            return AudioMetadata(format: .unknown)
        }
    }

    // MARK: FLAC (STREAMINFO + VORBIS_COMMENT + PICTURE)

    private static func parseFLAC(_ bytes: [UInt8]) -> AudioMetadata {
        var meta = AudioMetadata(format: .flac)
        guard bytes.count >= 4, bytes.metaFourCC(at: 0) == "fLaC" else { return meta }

        var pos = 4
        var isLast = false
        var hasFrontCover = false

        while !isLast, pos + 4 <= bytes.count {
            let header = bytes[pos]
            isLast = (header & 0x80) != 0
            let blockType = header & 0x7F
            let blockLen = Int(bytes.u24(at: pos + 1))
            pos += 4
            let blockEnd = min(bytes.count, pos + blockLen)

            switch blockType {
            case 0: // STREAMINFO
                if pos + 18 <= blockEnd {
                    let o = pos + 10
                    let b0 = UInt64(bytes[o])
                    let b1 = UInt64(bytes[o + 1])
                    let b2 = UInt64(bytes[o + 2])
                    let b3 = UInt64(bytes[o + 3])
                    let b4 = UInt64(bytes[o + 4])
                    let b5 = UInt64(bytes[o + 5])
                    let b6 = UInt64(bytes[o + 6])
                    let b7 = UInt64(bytes[o + 7])

                    let sr = Int((b0 << 12) | (b1 << 4) | (b2 >> 4))
                    let ch = Int((b2 >> 1) & 0x07) + 1
                    let bps = Int(((b2 & 0x01) << 4) | (b3 >> 4)) + 1
                    let totalSamples = ((b3 & 0x0F) << 32) | (b4 << 24) | (b5 << 16) | (b6 << 8) | b7

                    if sr > 0 {
                        meta.sampleRate = sr
                        meta.channels = ch
                        meta.bitDepth = bps
                        if totalSamples > 0 {
                            meta.durationSeconds = Double(totalSamples) / Double(sr)
                        }
                    }
                }

            case 4: // VORBIS_COMMENT
                parseVorbisComment(bytes, range: pos..<blockEnd, into: &meta)

            case 6: // PICTURE
                parseFLACPicture(bytes, range: pos..<blockEnd, hasFrontCover: &hasFrontCover, into: &meta)

            default:
                break
            }

            if blockEnd <= pos && blockLen > 0 { break }
            pos = blockEnd
        }

        return meta
    }

    private static func parseVorbisComment(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        var p = range.lowerBound
        guard p + 4 <= range.upperBound else { return }
        let vendorLen = Int(bytes.u32le(at: p))
        p += 4
        guard vendorLen >= 0, p + vendorLen + 4 <= range.upperBound else { return }
        p += vendorLen

        let count = Int(bytes.u32le(at: p))
        p += 4

        for _ in 0..<count {
            guard p + 4 <= range.upperBound else { break }
            let len = Int(bytes.u32le(at: p))
            p += 4
            guard len >= 0, p + len <= range.upperBound else { break }
            let entry = String(decoding: bytes[p..<(p + len)], as: UTF8.self)
            p += len

            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = asciiUpper(trimASCII(String(entry[..<eq])))
            let val = trimASCII(String(entry[entry.index(after: eq)...]))
            guard !key.isEmpty else { continue }

            switch key {
            case "TITLE":
                meta.title = val
            case "ARTIST":
                meta.artist = val
            case "ALBUM":
                meta.album = val
            case "ALBUMARTIST", "ALBUM ARTIST":
                meta.albumArtist = val
            case "TRACKNUMBER":
                let (num, tot) = parseNumberPair(val)
                if let num { meta.trackNumber = num }
                if let tot { meta.trackTotal = tot }
            case "TRACKTOTAL", "TOTALTRACKS":
                if let tot = Int(val) { meta.trackTotal = tot }
            case "DISCNUMBER":
                let (num, tot) = parseNumberPair(val)
                if let num { meta.discNumber = num }
                if let tot { meta.discTotal = tot }
            case "DISCTOTAL", "TOTALDISCS":
                if let tot = Int(val) { meta.discTotal = tot }
            case "DATE", "YEAR":
                if let y = parseYear(val) { meta.year = y }
            case "GENRE":
                meta.genre = val
            case "COMMENT", "DESCRIPTION":
                meta.comment = val
            case "REPLAYGAIN_TRACK_GAIN":
                meta.replayGainTrackDB = parseReplayGainDB(val)
            case "REPLAYGAIN_ALBUM_GAIN":
                meta.replayGainAlbumDB = parseReplayGainDB(val)
            case "REPLAYGAIN_TRACK_PEAK":
                meta.replayGainTrackPeak = Double(val)
            case "REPLAYGAIN_ALBUM_PEAK":
                meta.replayGainAlbumPeak = Double(val)
            default:
                meta.extraTags[key] = val
            }
        }
    }

    private static func parseFLACPicture(
        _ bytes: [UInt8],
        range: Range<Int>,
        hasFrontCover: inout Bool,
        into meta: inout AudioMetadata
    ) {
        var p = range.lowerBound
        guard p + 8 <= range.upperBound else { return }
        let picType = bytes.u32(at: p)
        let mimeLen = Int(bytes.u32(at: p + 4))
        p += 8
        guard mimeLen >= 0, p + mimeLen + 4 <= range.upperBound else { return }
        let mime = String(decoding: bytes[p..<(p + mimeLen)], as: UTF8.self)
        p += mimeLen

        let descLen = Int(bytes.u32(at: p))
        p += 4
        guard descLen >= 0, p + descLen + 20 <= range.upperBound else { return }
        p += descLen + 16 // skip description + width/height/depth/indexedColors

        let dataLen = Int(bytes.u32(at: p))
        p += 4
        guard dataLen >= 0, p + dataLen <= range.upperBound else { return }

        if meta.artwork == nil || (picType == 3 && !hasFrontCover) {
            let art = Array(bytes[p..<(p + dataLen)])
            meta.artwork = art
            meta.artworkMIME = mime.isEmpty ? detectImageMIME(art) : mime
            if picType == 3 { hasFrontCover = true }
        }
    }

    // MARK: ID3v2.3 & ID3v2.4 + MPEG Layer III Frame Info

    private static func synchsafe32(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let b0 = bytes[offset], b1 = bytes[offset + 1], b2 = bytes[offset + 2], b3 = bytes[offset + 3]
        guard (b0 & 0x80) == 0, (b1 & 0x80) == 0, (b2 & 0x80) == 0, (b3 & 0x80) == 0 else { return nil }
        return (Int(b0) << 21) | (Int(b1) << 14) | (Int(b2) << 7) | Int(b3)
    }

    private static func deunsynchronise(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(slice.count)
        var i = slice.startIndex
        while i < slice.endIndex {
            let b = slice[i]
            out.append(b)
            if b == 0xFF, slice.index(after: i) < slice.endIndex, slice[slice.index(after: i)] == 0x00 {
                i = slice.index(i, offsetBy: 2)
            } else {
                i = slice.index(after: i)
            }
        }
        return out
    }

    private static func parseID3AndMP3(_ bytes: [UInt8]) -> AudioMetadata {
        var meta = AudioMetadata(format: .mp3)
        parseID3v2Tag(bytes, into: &meta)
        parseMP3AudioInfo(bytes, into: &meta)
        return meta
    }

    private static func parseID3v2Tag(_ bytes: [UInt8], into meta: inout AudioMetadata) {
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return }
        let major = bytes[3]
        guard major == 3 || major == 4 else { return }
        let flags = bytes[5]
        guard let tagSize = synchsafe32(bytes, at: 6) else { return }

        let tagEnd = min(bytes.count, 10 + tagSize)
        var bodyBytes: [UInt8]
        var pos: Int
        var end: Int

        if major == 3 && (flags & 0x80) != 0 {
            bodyBytes = deunsynchronise(bytes[10..<tagEnd])
            pos = 0
            end = bodyBytes.count
        } else {
            bodyBytes = bytes
            pos = 10
            end = tagEnd
        }

        // Skip optional extended header.
        if (flags & 0x40) != 0, pos + 4 <= end {
            if major == 4, let extSize = synchsafe32(bodyBytes, at: pos), extSize >= 6 {
                pos = min(end, pos + extSize)
            } else if major == 3 {
                let extSize = Int(bodyBytes.u32(at: pos))
                pos = min(end, pos + 4 + extSize)
            }
        }

        var hasFrontCover = false
        while pos + 10 <= end {
            if bodyBytes[pos] == 0 { break }
            let idBytes = bodyBytes[pos..<(pos + 4)]
            let validID = idBytes.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }
            guard validID else { break }
            let frameID = String(decoding: idBytes, as: UTF8.self)

            let frameSize: Int
            if major == 4 {
                if let ss = synchsafe32(bodyBytes, at: pos + 4) {
                    frameSize = ss
                } else {
                    frameSize = Int(bodyBytes.u32(at: pos + 4))
                }
            } else {
                frameSize = Int(bodyBytes.u32(at: pos + 4))
            }
            let frameFlags = bodyBytes.u16(at: pos + 8)
            var frameStart = pos + 10
            let frameEnd = frameStart + frameSize
            guard frameSize > 0, frameEnd <= end else { break }

            // ID3v2.4 data length indicator (4 synchsafe bytes) & per-frame unsynchronisation.
            var frameSliceBytes = bodyBytes
            if major == 4 {
                if (frameFlags & 0x0001) != 0, frameStart + 4 <= frameEnd {
                    frameStart += 4
                }
                if (frameFlags & 0x0002) != 0 {
                    frameSliceBytes = deunsynchronise(bodyBytes[frameStart..<frameEnd])
                    frameStart = 0
                }
            }
            let fEnd = (frameSliceBytes.count == bodyBytes.count && frameStart >= pos + 10) ? frameEnd : frameSliceBytes.count

            switch frameID {
            case "TIT2":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) { meta.title = s }
            case "TPE1":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) { meta.artist = s }
            case "TALB":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) { meta.album = s }
            case "TPE2":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) { meta.albumArtist = s }
            case "TRCK":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) {
                    let (n, t) = parseNumberPair(s)
                    if let n { meta.trackNumber = n }
                    if let t { meta.trackTotal = t }
                }
            case "TPOS":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) {
                    let (n, t) = parseNumberPair(s)
                    if let n { meta.discNumber = n }
                    if let t { meta.discTotal = t }
                }
            case "TYER", "TDRC":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd), let y = parseYear(s) {
                    meta.year = y
                }
            case "TCON":
                if let s = decodeID3TextFrame(frameSliceBytes, range: frameStart..<fEnd) {
                    meta.genre = normalizeID3Genre(s)
                }
            case "COMM":
                parseID3COMM(frameSliceBytes, range: frameStart..<fEnd, into: &meta)
            case "TXXX":
                parseID3TXXX(frameSliceBytes, range: frameStart..<fEnd, into: &meta)
            case "APIC":
                parseID3APIC(frameSliceBytes, range: frameStart..<fEnd, hasFrontCover: &hasFrontCover, into: &meta)
            default:
                break
            }

            pos = frameEnd
        }
    }

    private static func decodeID3TextFrame(_ bytes: [UInt8], range: Range<Int>) -> String? {
        guard range.count >= 1 else { return nil }
        let encoding = bytes[range.lowerBound]
        let payload = (range.lowerBound + 1)..<range.upperBound
        let s = trimASCII(decodeID3String(bytes, range: payload, encoding: encoding))
        return s.isEmpty ? nil : s
    }

    private static func decodeID3String(_ bytes: [UInt8], range: Range<Int>, encoding: UInt8) -> String {
        guard !range.isEmpty else { return "" }
        switch encoding {
        case 0: // ISO-8859-1
            var end = range.upperBound
            while end > range.lowerBound && bytes[end - 1] == 0 { end -= 1 }
            var out = ""
            out.unicodeScalars.reserveCapacity(end - range.lowerBound)
            for i in range.lowerBound..<end {
                out.unicodeScalars.append(Unicode.Scalar(bytes[i]))
            }
            return out

        case 1: // UTF-16 with BOM
            var start = range.lowerBound
            var littleEndian = false
            if range.count >= 2 {
                let b0 = bytes[start], b1 = bytes[start + 1]
                if b0 == 0xFF && b1 == 0xFE {
                    littleEndian = true
                    start += 2
                } else if b0 == 0xFE && b1 == 0xFF {
                    littleEndian = false
                    start += 2
                }
            }
            return decodeUTF16(bytes, range: start..<range.upperBound, littleEndian: littleEndian)

        case 2: // UTF-16BE without BOM
            return decodeUTF16(bytes, range: range, littleEndian: false)

        case 3: // UTF-8
            var end = range.upperBound
            while end > range.lowerBound && bytes[end - 1] == 0 { end -= 1 }
            return String(decoding: bytes[range.lowerBound..<end], as: UTF8.self)

        default:
            var end = range.upperBound
            while end > range.lowerBound && bytes[end - 1] == 0 { end -= 1 }
            return String(decoding: bytes[range.lowerBound..<end], as: UTF8.self)
        }
    }

    private static func decodeUTF16(_ bytes: [UInt8], range: Range<Int>, littleEndian: Bool) -> String {
        let pairCount = range.count / 2
        guard pairCount > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(pairCount)
        for i in 0..<pairCount {
            let p = range.lowerBound + i * 2
            let u = littleEndian ? bytes.u16le(at: p) : bytes.u16(at: p)
            units.append(u)
        }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// Splits an ID3 encoded payload at its first NUL terminator (1 byte for enc 0/3, 2 bytes for enc 1/2).
    private static func splitID3NullTerminated(
        _ bytes: [UInt8],
        range: Range<Int>,
        encoding: UInt8
    ) -> (head: Range<Int>, tail: Range<Int>) {
        if encoding == 1 || encoding == 2 {
            var p = range.lowerBound
            while p + 1 < range.upperBound {
                if bytes[p] == 0 && bytes[p + 1] == 0 {
                    return (range.lowerBound..<p, (p + 2)..<range.upperBound)
                }
                p += 2
            }
            return (range, range.upperBound..<range.upperBound)
        } else {
            var p = range.lowerBound
            while p < range.upperBound {
                if bytes[p] == 0 {
                    return (range.lowerBound..<p, (p + 1)..<range.upperBound)
                }
                p += 1
            }
            return (range, range.upperBound..<range.upperBound)
        }
    }

    private static func parseID3COMM(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        guard range.count >= 4 else { return }
        let encoding = bytes[range.lowerBound]
        let afterLang = (range.lowerBound + 4)..<range.upperBound
        let (_, bodyRange) = splitID3NullTerminated(bytes, range: afterLang, encoding: encoding)
        let text = trimASCII(decodeID3String(bytes, range: bodyRange, encoding: encoding))
        if !text.isEmpty {
            meta.comment = text
        }
    }

    private static func parseID3TXXX(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        guard range.count >= 2 else { return }
        let encoding = bytes[range.lowerBound]
        let payload = (range.lowerBound + 1)..<range.upperBound
        let (descRange, valRange) = splitID3NullTerminated(bytes, range: payload, encoding: encoding)
        let desc = trimASCII(decodeID3String(bytes, range: descRange, encoding: encoding))
        let val = trimASCII(decodeID3String(bytes, range: valRange, encoding: encoding))
        guard !desc.isEmpty else { return }

        let upper = asciiUpper(desc)
        switch upper {
        case "REPLAYGAIN_TRACK_GAIN":
            meta.replayGainTrackDB = parseReplayGainDB(val)
        case "REPLAYGAIN_ALBUM_GAIN":
            meta.replayGainAlbumDB = parseReplayGainDB(val)
        case "REPLAYGAIN_TRACK_PEAK":
            meta.replayGainTrackPeak = Double(val)
        case "REPLAYGAIN_ALBUM_PEAK":
            meta.replayGainAlbumPeak = Double(val)
        case "ALBUMARTIST", "ALBUM ARTIST":
            if meta.albumArtist == nil { meta.albumArtist = val }
        default:
            meta.extraTags[upper] = val
        }
    }

    private static func parseID3APIC(
        _ bytes: [UInt8],
        range: Range<Int>,
        hasFrontCover: inout Bool,
        into meta: inout AudioMetadata
    ) {
        guard range.count >= 4 else { return }
        let encoding = bytes[range.lowerBound]
        let afterEnc = (range.lowerBound + 1)..<range.upperBound
        // MIME type in APIC is always single-byte NUL terminated ASCII/ISO-8859-1.
        let (mimeRange, afterMime) = splitID3NullTerminated(bytes, range: afterEnc, encoding: 0)
        guard !afterMime.isEmpty else { return }
        let mime = trimASCII(String(decoding: bytes[mimeRange], as: UTF8.self))
        let picType = bytes[afterMime.lowerBound]
        let afterType = (afterMime.lowerBound + 1)..<afterMime.upperBound
        let (_, imgRange) = splitID3NullTerminated(bytes, range: afterType, encoding: encoding)
        guard !imgRange.isEmpty else { return }

        if meta.artwork == nil || (picType == 3 && !hasFrontCover) {
            let art = Array(bytes[imgRange])
            meta.artwork = art
            meta.artworkMIME = mime.isEmpty ? detectImageMIME(art) : mime
            if picType == 3 { hasFrontCover = true }
        }
    }

    private static func normalizeID3Genre(_ raw: String) -> String {
        let s = trimASCII(raw)
        if s.hasPrefix("("), let close = s.firstIndex(of: ")") {
            let after = trimASCII(String(s[s.index(after: close)...]))
            if !after.isEmpty { return after }
        }
        return s
    }

    private static func parseMP3AudioInfo(_ bytes: [UInt8], into meta: inout AudioMetadata) {
        let (start, end) = MP3Decoder.locateAudioBounds(in: bytes)
        guard start + 4 <= end else { return }
        var pos = start
        var firstHdr: MP3FrameHeader?
        while pos + 4 <= end {
            if let hdr = MP3FrameHeader.parse(from: bytes, at: pos), pos + hdr.frameSizeBytes <= end {
                firstHdr = hdr
                break
            }
            pos += 1
        }
        guard let hdr = firstHdr else { return }
        meta.sampleRate = hdr.sampleRate
        meta.channels = hdr.channelCount

        // Walk frames to compute exact duration when frames are contiguous; fall back to bitrate estimate.
        var walkPos = pos
        var totalSamples = 0
        var frameCount = 0
        while walkPos + 4 <= end {
            guard let frameHdr = MP3FrameHeader.parse(from: bytes, at: walkPos),
                  walkPos + frameHdr.frameSizeBytes <= end else { break }
            totalSamples += frameHdr.samplesPerFrame
            frameCount += 1
            walkPos += frameHdr.frameSizeBytes
        }
        if frameCount > 0 && hdr.sampleRate > 0 {
            meta.durationSeconds = Double(totalSamples) / Double(hdr.sampleRate)
        } else if hdr.bitrateKbps > 0 {
            meta.durationSeconds = Double(end - pos) * 8.0 / Double(hdr.bitrateKbps * 1000)
        }
    }

    // MARK: MP4 / M4A (mdhd, stsd/alac, moov/udta/meta/ilst)

    private struct MP4Atom {
        var tag: UInt32
        var fourCC: String
        var payloadStart: Int
        var end: Int
    }

    private static func parseMP4Atoms(_ bytes: [UInt8], range: Range<Int>) -> [MP4Atom] {
        var atoms: [MP4Atom] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let size32 = bytes.u32(at: pos)
            let tag = bytes.u32(at: pos + 4)
            let fourCC = bytes.metaFourCC(at: pos + 4)
            let headerSize: Int
            let atomEnd: Int
            if size32 == 0 {
                headerSize = 8
                atomEnd = range.upperBound
            } else if size32 == 1 {
                guard pos + 16 <= range.upperBound else { break }
                let size64 = bytes.metaU64BE(at: pos + 8)
                guard size64 >= 16, size64 <= UInt64(range.upperBound - pos) else { break }
                headerSize = 16
                atomEnd = pos + Int(size64)
            } else {
                guard size32 >= 8 else { break }
                headerSize = 8
                atomEnd = min(range.upperBound, pos + Int(size32))
            }
            atoms.append(MP4Atom(tag: tag, fourCC: fourCC, payloadStart: pos + headerSize, end: atomEnd))
            if atomEnd <= pos { break }
            pos = atomEnd
        }
        return atoms
    }

    private static func parseMP4(_ bytes: [UInt8]) -> AudioMetadata {
        var meta = AudioMetadata(format: .mp4)
        let top = parseMP4Atoms(bytes, range: 0..<bytes.count)
        guard let moov = top.first(where: { $0.fourCC == "moov" }) else { return meta }

        let moovChildren = parseMP4Atoms(bytes, range: moov.payloadStart..<moov.end)

        for box in moovChildren {
            if box.fourCC == "trak" {
                parseMP4Track(bytes, range: box.payloadStart..<box.end, into: &meta)
            } else if box.fourCC == "udta" {
                parseMP4UDTA(bytes, range: box.payloadStart..<box.end, into: &meta)
            } else if box.fourCC == "meta" {
                parseMP4Meta(bytes, range: box.payloadStart..<box.end, into: &meta)
            }
        }
        return meta
    }

    private static func parseMP4Track(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        let trakChildren = parseMP4Atoms(bytes, range: range)
        guard let mdia = trakChildren.first(where: { $0.fourCC == "mdia" }) else { return }
        let mdiaChildren = parseMP4Atoms(bytes, range: mdia.payloadStart..<mdia.end)

        var trackDuration: Double?
        if let mdhd = mdiaChildren.first(where: { $0.fourCC == "mdhd" }) {
            let p = mdhd.payloadStart
            if p + 4 <= mdhd.end {
                let version = bytes[p]
                if version == 0 && p + 20 <= mdhd.end {
                    let timescale = bytes.u32(at: p + 12)
                    let duration = bytes.u32(at: p + 16)
                    if timescale > 0 && duration > 0 {
                        trackDuration = Double(duration) / Double(timescale)
                    }
                } else if version == 1 && p + 32 <= mdhd.end {
                    let timescale = bytes.u32(at: p + 20)
                    let duration = bytes.metaU64BE(at: p + 24)
                    if timescale > 0 && duration > 0 {
                        trackDuration = Double(duration) / Double(timescale)
                    }
                }
            }
        }

        guard let minf = mdiaChildren.first(where: { $0.fourCC == "minf" }) else { return }
        let minfChildren = parseMP4Atoms(bytes, range: minf.payloadStart..<minf.end)
        guard let stbl = minfChildren.first(where: { $0.fourCC == "stbl" }) else { return }
        let stblChildren = parseMP4Atoms(bytes, range: stbl.payloadStart..<stbl.end)
        guard let stsd = stblChildren.first(where: { $0.fourCC == "stsd" }) else { return }
        guard stsd.payloadStart + 8 <= stsd.end else { return }

        let entryCount = Int(bytes.u32(at: stsd.payloadStart + 4))
        var pos = stsd.payloadStart + 8
        for _ in 0..<entryCount {
            guard pos + 8 <= stsd.end else { break }
            let entrySize = Int(bytes.u32(at: pos))
            let entryType = bytes.metaFourCC(at: pos + 4)
            let entryEnd = min(stsd.end, pos + max(8, entrySize))

            if entryType == "alac" || entryType == "mp4a" || entryType == "fLaC" {
                if let trackDuration { meta.durationSeconds = trackDuration }
                if pos + 36 <= entryEnd {
                    meta.channels = Int(bytes.u16(at: pos + 24))
                    meta.bitDepth = Int(bytes.u16(at: pos + 26))
                    let sr16 = Int(bytes.u32(at: pos + 32) >> 16)
                    if sr16 > 0 { meta.sampleRate = sr16 }
                }
                if entryType == "alac" {
                    meta.format = .alac
                    let childStart = pos + 36
                    if childStart < entryEnd {
                        let subBoxes = parseMP4Atoms(bytes, range: childStart..<entryEnd)
                        if let cookieBox = subBoxes.first(where: { $0.fourCC == "alac" }),
                           let cfg = try? ALACConfig(magicCookie: Array(bytes[cookieBox.payloadStart..<cookieBox.end])) {
                            meta.sampleRate = Int(cfg.sampleRate)
                            meta.bitDepth = Int(cfg.bitDepth)
                            meta.channels = Int(cfg.numChannels)
                        }
                    }
                }
                break
            }

            if entryEnd <= pos { break }
            pos = entryEnd
        }
    }

    private static func parseMP4UDTA(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        let children = parseMP4Atoms(bytes, range: range)
        for box in children where box.fourCC == "meta" {
            parseMP4Meta(bytes, range: box.payloadStart..<box.end, into: &meta)
        }
    }

    private static func parseMP4Meta(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        guard range.count >= 8 else { return }
        let firstTag = bytes.metaFourCC(at: range.lowerBound + 4)
        let childrenStart: Int
        if firstTag == "hdlr" || firstTag == "ilst" || firstTag == "keys" {
            childrenStart = range.lowerBound
        } else {
            childrenStart = min(range.upperBound, range.lowerBound + 4)
        }
        let children = parseMP4Atoms(bytes, range: childrenStart..<range.upperBound)
        for box in children where box.fourCC == "ilst" {
            parseMP4ILST(bytes, range: box.payloadStart..<box.end, into: &meta)
        }
    }

    private static func parseMP4ILST(_ bytes: [UInt8], range: Range<Int>, into meta: inout AudioMetadata) {
        let items = parseMP4Atoms(bytes, range: range)
        for item in items {
            let subAtoms = parseMP4Atoms(bytes, range: item.payloadStart..<item.end)

            // Freeform iTunes tag (`----`: mean + name + data).
            if item.tag == 0x2D2D2D2D {
                var nameStr = ""
                var valueStr = ""
                for sub in subAtoms {
                    if sub.fourCC == "name", sub.payloadStart + 4 <= sub.end {
                        nameStr = trimASCII(String(decoding: bytes[(sub.payloadStart + 4)..<sub.end], as: UTF8.self))
                    } else if sub.fourCC == "data", sub.payloadStart + 8 <= sub.end {
                        valueStr = trimASCII(String(decoding: bytes[(sub.payloadStart + 8)..<sub.end], as: UTF8.self))
                    }
                }
                let upper = asciiUpper(nameStr)
                switch upper {
                case "REPLAYGAIN_TRACK_GAIN":
                    meta.replayGainTrackDB = parseReplayGainDB(valueStr)
                case "REPLAYGAIN_ALBUM_GAIN":
                    meta.replayGainAlbumDB = parseReplayGainDB(valueStr)
                case "REPLAYGAIN_TRACK_PEAK":
                    meta.replayGainTrackPeak = Double(valueStr)
                case "REPLAYGAIN_ALBUM_PEAK":
                    meta.replayGainAlbumPeak = Double(valueStr)
                default:
                    if !upper.isEmpty { meta.extraTags[upper] = valueStr }
                }
                continue
            }

            guard let dataBox = subAtoms.first(where: { $0.fourCC == "data" }),
                  dataBox.payloadStart + 8 <= dataBox.end else { continue }
            let dataType = bytes.u32(at: dataBox.payloadStart)
            let valStart = dataBox.payloadStart + 8
            let valRange = valStart..<dataBox.end

            func readText() -> String {
                if dataType == 2 {
                    return trimASCII(decodeUTF16(bytes, range: valRange, littleEndian: false))
                }
                return trimASCII(String(decoding: bytes[valRange], as: UTF8.self))
            }

            switch item.tag {
            case 0xA96E616D: // ©nam
                meta.title = readText()
            case 0xA9415254: // ©ART
                meta.artist = readText()
            case 0xA9616C62: // ©alb
                meta.album = readText()
            case 0x61415254: // aART
                meta.albumArtist = readText()
            case 0xA9646179: // ©day
                if let y = parseYear(readText()) { meta.year = y }
            case 0xA967656E: // ©gen
                meta.genre = readText()
            case 0xA9636D74: // ©cmt
                meta.comment = readText()
            case 0x74726B6E: // trkn
                if valRange.count >= 4 {
                    let num = Int(bytes.u16(at: valStart + 2))
                    if num > 0 { meta.trackNumber = num }
                    if valRange.count >= 6 {
                        let tot = Int(bytes.u16(at: valStart + 4))
                        if tot > 0 { meta.trackTotal = tot }
                    }
                }
            case 0x6469736B: // disk
                if valRange.count >= 4 {
                    let num = Int(bytes.u16(at: valStart + 2))
                    if num > 0 { meta.discNumber = num }
                    if valRange.count >= 6 {
                        let tot = Int(bytes.u16(at: valStart + 4))
                        if tot > 0 { meta.discTotal = tot }
                    }
                }
            case 0x636F7672: // covr
                let art = Array(bytes[valRange])
                if !art.isEmpty {
                    meta.artwork = art
                    if dataType == 13 {
                        meta.artworkMIME = "image/jpeg"
                    } else if dataType == 14 {
                        meta.artworkMIME = "image/png"
                    } else {
                        meta.artworkMIME = detectImageMIME(art)
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: WAV (fmt, data, LIST/INFO)

    private static func parseWAV(_ bytes: [UInt8]) -> AudioMetadata {
        var meta = AudioMetadata(format: .wav)
        guard bytes.count >= 12,
              bytes.metaFourCC(at: 0) == "RIFF",
              bytes.metaFourCC(at: 8) == "WAVE" else { return meta }

        var dataByteSize: Int?
        var pos = 12
        while pos + 8 <= bytes.count {
            let chunkID = bytes.metaFourCC(at: pos)
            let chunkSize = Int(bytes.u32le(at: pos + 4))
            let bodyStart = pos + 8
            let bodyEnd = min(bytes.count, bodyStart + chunkSize)

            if chunkID == "fmt ", bodyStart + 16 <= bodyEnd {
                let channels = Int(bytes.u16le(at: bodyStart + 2))
                let sampleRate = Int(bytes.u32le(at: bodyStart + 4))
                let bitsPerSample = Int(bytes.u16le(at: bodyStart + 14))
                if channels > 0 { meta.channels = channels }
                if sampleRate > 0 { meta.sampleRate = sampleRate }
                if bitsPerSample > 0 { meta.bitDepth = bitsPerSample }
            } else if chunkID == "data" {
                dataByteSize = chunkSize
            } else if chunkID == "LIST", bodyStart + 4 <= bodyEnd, bytes.metaFourCC(at: bodyStart) == "INFO" {
                var subPos = bodyStart + 4
                while subPos + 8 <= bodyEnd {
                    let subID = bytes.metaFourCC(at: subPos)
                    let subSize = Int(bytes.u32le(at: subPos + 4))
                    let subStart = subPos + 8
                    let subEnd = min(bodyEnd, subStart + subSize)
                    let val = trimASCII(String(decoding: bytes[subStart..<subEnd], as: UTF8.self))

                    switch subID {
                    case "INAM": meta.title = val
                    case "IART": meta.artist = val
                    case "IPRD": meta.album = val
                    case "ICRD":
                        if let y = parseYear(val) { meta.year = y }
                    case "IGNR": meta.genre = val
                    case "ITRK":
                        let (n, t) = parseNumberPair(val)
                        if let n { meta.trackNumber = n }
                        if let t { meta.trackTotal = t }
                    case "ICMT": meta.comment = val
                    default:
                        if !subID.isEmpty && !val.isEmpty {
                            meta.extraTags[subID] = val
                        }
                    }

                    let padded = subSize + (subSize & 1)
                    let nextSub = subStart + padded
                    if nextSub <= subPos { break }
                    subPos = nextSub
                }
            } else if chunkID == "id3 " || chunkID == "ID3 " {
                parseID3v2Tag(Array(bytes[bodyStart..<bodyEnd]), into: &meta)
            }

            let padded = chunkSize + (chunkSize & 1)
            let nextPos = bodyStart + padded
            if nextPos <= pos { break }
            pos = nextPos
        }

        if let dataBytes = dataByteSize,
           let sr = meta.sampleRate, sr > 0,
           let ch = meta.channels, ch > 0,
           let bps = meta.bitDepth, bps >= 8 {
            let bytesPerFrame = ch * (bps / 8)
            if bytesPerFrame > 0 {
                meta.durationSeconds = Double(dataBytes / bytesPerFrame) / Double(sr)
            }
        }
        return meta
    }

    // MARK: AIFF (COMM, NAME, AUTH, ANNO)

    private static func parseAIFF(_ bytes: [UInt8]) -> AudioMetadata {
        var meta = AudioMetadata(format: .aiff)
        guard bytes.count >= 12, bytes.metaFourCC(at: 0) == "FORM" else { return meta }
        let formType = bytes.metaFourCC(at: 8)
        guard formType == "AIFF" || formType == "AIFC" else { return meta }

        var pos = 12
        while pos + 8 <= bytes.count {
            let chunkID = bytes.metaFourCC(at: pos)
            let chunkSize = Int(bytes.u32(at: pos + 4))
            let bodyStart = pos + 8
            let bodyEnd = min(bytes.count, bodyStart + chunkSize)

            switch chunkID {
            case "COMM":
                if bodyStart + 18 <= bodyEnd {
                    let ch = Int(bytes.u16(at: bodyStart))
                    let frames = Int(bytes.u32(at: bodyStart + 2))
                    let bps = Int(bytes.u16(at: bodyStart + 6))
                    let sr = AIFFDecoder.decodeExtended80(bytes, at: bodyStart + 8)
                    if ch > 0 { meta.channels = ch }
                    if bps > 0 { meta.bitDepth = bps }
                    if sr > 0 && sr.isFinite {
                        meta.sampleRate = Int(sr.rounded())
                        if frames > 0 {
                            meta.durationSeconds = Double(frames) / sr
                        }
                    }
                }
            case "NAME":
                let s = trimASCII(String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self))
                if !s.isEmpty { meta.title = s }
            case "AUTH":
                let s = trimASCII(String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self))
                if !s.isEmpty { meta.artist = s }
            case "ANNO":
                let s = trimASCII(String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self))
                if !s.isEmpty { meta.comment = s }
            case "ID3 ":
                parseID3v2Tag(Array(bytes[bodyStart..<bodyEnd]), into: &meta)
            default:
                break
            }

            let padded = chunkSize + (chunkSize & 1)
            let nextPos = bodyStart + padded
            if nextPos <= pos { break }
            pos = nextPos
        }

        return meta
    }

    // MARK: - Compact Binary Tag Builders (for Round-Trip Verification)

    /// Builds a valid FLAC metadata header stream containing `STREAMINFO`, optional `VORBIS_COMMENT`,
    /// and optional `PICTURE` blocks.
    public static func makeFLACMetadata(
        sampleRate: Int = 44_100,
        channels: Int = 2,
        bitDepth: Int = 16,
        totalSamples: UInt64 = 44_100,
        vendor: String = "Polymer",
        comments: [(String, String)] = [],
        artwork: [UInt8]? = nil,
        artworkMIME: String = "image/png"
    ) -> [UInt8] {
        var blocks: [(type: UInt8, body: [UInt8])] = []

        // Block 0: STREAMINFO (34 bytes).
        var si: [UInt8] = []
        si.append(u16: 4096)
        si.append(u16: 4096)
        si.appendMetaU24BE(0)
        si.appendMetaU24BE(0)
        let sr = UInt64(max(1, sampleRate)) & 0xFFFFF
        let ch = UInt64(max(1, min(channels, 8)) - 1) & 0x07
        let bps = UInt64(max(4, min(bitDepth, 32)) - 1) & 0x1F
        let tot = totalSamples & 0xF_FFFF_FFFF
        let packed = (sr << 44) | (ch << 41) | (bps << 36) | tot
        for shift in stride(from: 56, through: 0, by: -8) {
            si.append(UInt8((packed >> UInt64(shift)) & 0xFF))
        }
        si.append(contentsOf: repeatElement(0, count: 16))
        blocks.append((0, si))

        // Block 4: VORBIS_COMMENT.
        if !comments.isEmpty {
            var vc: [UInt8] = []
            let vendorBytes = Array(vendor.utf8)
            vc.appendMetaU32LE(UInt32(vendorBytes.count))
            vc.append(contentsOf: vendorBytes)
            vc.appendMetaU32LE(UInt32(comments.count))
            for (k, v) in comments {
                let pair = Array("\(k)=\(v)".utf8)
                vc.appendMetaU32LE(UInt32(pair.count))
                vc.append(contentsOf: pair)
            }
            blocks.append((4, vc))
        }

        // Block 6: PICTURE.
        if let artwork {
            var pic: [UInt8] = []
            pic.append(u32: 3) // front cover
            let mimeBytes = Array(artworkMIME.utf8)
            pic.append(u32: UInt32(mimeBytes.count))
            pic.append(contentsOf: mimeBytes)
            pic.append(u32: 0) // description length
            pic.append(u32: 0); pic.append(u32: 0); pic.append(u32: 0); pic.append(u32: 0)
            pic.append(u32: UInt32(artwork.count))
            pic.append(contentsOf: artwork)
            blocks.append((6, pic))
        }

        var out: [UInt8] = []
        out.appendMetaASCII("fLaC")
        for (idx, blk) in blocks.enumerated() {
            let isLast: UInt8 = (idx == blocks.count - 1) ? 0x80 : 0x00
            out.append(isLast | blk.type)
            out.appendMetaU24BE(UInt32(blk.body.count))
            out.append(contentsOf: blk.body)
        }
        return out
    }

    /// Encodes an ID3v2 text frame body (`0` = ISO-8859-1, `1` = UTF-16LE w/ BOM, `3` = UTF-8).
    public static func makeID3TextBody(_ text: String, encoding: UInt8 = 3) -> [UInt8] {
        var out: [UInt8] = [encoding]
        switch encoding {
        case 0:
            for s in text.unicodeScalars {
                out.append(s.value <= 0xFF ? UInt8(s.value) : 0x3F)
            }
        case 1:
            out.append(0xFF)
            out.append(0xFE)
            for u in text.utf16 {
                out.appendMetaU16LE(u)
            }
        case 2:
            for u in text.utf16 {
                out.append(u16: u)
            }
        default:
            out.append(contentsOf: text.utf8)
        }
        return out
    }

    /// Encodes an ID3v2 `TXXX` user-defined text frame body.
    public static func makeID3TXXXBody(description: String, value: String, encoding: UInt8 = 3) -> [UInt8] {
        var out = makeID3TextBody(description, encoding: encoding)
        if encoding == 1 || encoding == 2 {
            out.append(0); out.append(0)
            let valBody = makeID3TextBody(value, encoding: encoding)
            out.append(contentsOf: valBody.dropFirst())
        } else {
            out.append(0)
            let valBody = makeID3TextBody(value, encoding: encoding)
            out.append(contentsOf: valBody.dropFirst())
        }
        return out
    }

    /// Encodes an ID3v2 `COMM` comment frame body.
    public static func makeID3COMMBody(
        language: String = "eng",
        shortDescription: String = "",
        text: String,
        encoding: UInt8 = 3
    ) -> [UInt8] {
        var out: [UInt8] = [encoding]
        let langBytes = Array(language.utf8)
        for i in 0..<3 {
            out.append(i < langBytes.count ? langBytes[i] : 0x78)
        }
        let descBody = makeID3TextBody(shortDescription, encoding: encoding)
        out.append(contentsOf: descBody.dropFirst())
        if encoding == 1 || encoding == 2 {
            out.append(0); out.append(0)
        } else {
            out.append(0)
        }
        let textBody = makeID3TextBody(text, encoding: encoding)
        out.append(contentsOf: textBody.dropFirst())
        return out
    }

    /// Encodes an ID3v2 `APIC` attached picture frame body.
    public static func makeID3APICBody(
        mime: String = "image/png",
        pictureType: UInt8 = 3,
        description: String = "",
        imageData: [UInt8]
    ) -> [UInt8] {
        var out: [UInt8] = [3] // UTF-8 description
        out.appendMetaASCII(mime)
        out.append(0)
        out.append(pictureType)
        out.append(contentsOf: description.utf8)
        out.append(0)
        out.append(contentsOf: imageData)
        return out
    }

    /// Builds a valid ID3v2.3 container with optional trailing MPEG audio bytes.
    public static func makeID3v23(
        frames: [(id: String, body: [UInt8])],
        trailingAudio: [UInt8] = []
    ) -> [UInt8] {
        var body: [UInt8] = []
        for frame in frames {
            let idBytes = Array(frame.id.utf8)
            guard idBytes.count == 4 else { continue }
            body.append(contentsOf: idBytes)
            body.append(u32: UInt32(frame.body.count))
            body.append(u16: 0)
            body.append(contentsOf: frame.body)
        }
        var out: [UInt8] = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00]
        out.appendMetaSynchsafe32(body.count)
        out.append(contentsOf: body)
        out.append(contentsOf: trailingAudio)
        return out
    }

    /// Builds a valid ID3v2.4 container (synchsafe frame sizes) with optional trailing MPEG audio bytes.
    public static func makeID3v24(
        frames: [(id: String, body: [UInt8])],
        trailingAudio: [UInt8] = []
    ) -> [UInt8] {
        var body: [UInt8] = []
        for frame in frames {
            let idBytes = Array(frame.id.utf8)
            guard idBytes.count == 4 else { continue }
            body.append(contentsOf: idBytes)
            body.appendMetaSynchsafe32(frame.body.count)
            body.append(u16: 0)
            body.append(contentsOf: frame.body)
        }
        var out: [UInt8] = [0x49, 0x44, 0x33, 0x04, 0x00, 0x00]
        out.appendMetaSynchsafe32(body.count)
        out.append(contentsOf: body)
        out.append(contentsOf: trailingAudio)
        return out
    }

    /// Builds a compact valid MP4/M4A metadata container (`ftyp` + `moov` with `mdhd`, `stsd`, and `udta/meta/ilst`).
    public static func makeM4AMetadata(
        sampleRate: Int = 44_100,
        channels: Int = 2,
        bitDepth: Int = 16,
        totalSamples: UInt32 = 44_100,
        isALAC: Bool = true,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        year: String? = nil,
        genre: String? = nil,
        comment: String? = nil,
        artwork: [UInt8]? = nil,
        artworkIsPNG: Bool = true
    ) -> [UInt8] {
        func makeBox(_ tag: UInt32, payload: [UInt8]) -> [UInt8] {
            var b: [UInt8] = []
            b.reserveCapacity(8 + payload.count)
            b.append(u32: UInt32(8 + payload.count))
            b.append(u32: tag)
            b.append(contentsOf: payload)
            return b
        }

        func makeBoxStr(_ fourCC: String, payload: [UInt8]) -> [UInt8] {
            let u = Array(fourCC.utf8)
            let tag = (UInt32(u[0]) << 24) | (UInt32(u[1]) << 16) | (UInt32(u[2]) << 8) | UInt32(u[3])
            return makeBox(tag, payload: payload)
        }

        func makeFullBox(_ fourCC: String, payload: [UInt8]) -> [UInt8] {
            var body: [UInt8] = [0, 0, 0, 0]
            body.append(contentsOf: payload)
            return makeBoxStr(fourCC, payload: body)
        }

        func makeDataBox(type: UInt32, value: [UInt8]) -> [UInt8] {
            var p: [UInt8] = []
            p.append(u32: type)
            p.append(u32: 0)
            p.append(contentsOf: value)
            return makeBoxStr("data", payload: p)
        }

        // ftyp
        var ftypPayload: [UInt8] = []
        ftypPayload.appendMetaASCII("M4A ")
        ftypPayload.append(u32: 0)
        ftypPayload.appendMetaASCII("M4A ")
        ftypPayload.appendMetaASCII("mp42")
        let ftyp = makeBoxStr("ftyp", payload: ftypPayload)

        // mdhd (v0: 20 bytes after version/flags)
        var mdhdPayload = [UInt8](repeating: 0, count: 20)
        let srU32 = UInt32(max(1, sampleRate))
        mdhdPayload[8] = UInt8((srU32 >> 24) & 0xFF)
        mdhdPayload[9] = UInt8((srU32 >> 16) & 0xFF)
        mdhdPayload[10] = UInt8((srU32 >> 8) & 0xFF)
        mdhdPayload[11] = UInt8(srU32 & 0xFF)
        mdhdPayload[12] = UInt8((totalSamples >> 24) & 0xFF)
        mdhdPayload[13] = UInt8((totalSamples >> 16) & 0xFF)
        mdhdPayload[14] = UInt8((totalSamples >> 8) & 0xFF)
        mdhdPayload[15] = UInt8(totalSamples & 0xFF)
        let mdhd = makeFullBox("mdhd", payload: mdhdPayload)

        // stsd
        var sampleEntry: [UInt8] = []
        sampleEntry.append(contentsOf: [0, 0, 0, 0, 0, 0])
        sampleEntry.append(u16: 1)
        sampleEntry.append(u32: 0); sampleEntry.append(u32: 0)
        sampleEntry.append(u16: UInt16(channels))
        sampleEntry.append(u16: UInt16(bitDepth))
        sampleEntry.append(u32: 0)
        sampleEntry.append(u32: UInt32(min(sampleRate, 65535)) << 16)
        if isALAC {
            let cfg = ALACConfig(
                frameLength: 4096,
                bitDepth: UInt8(bitDepth),
                numChannels: UInt8(channels),
                sampleRate: srU32
            )
            sampleEntry.append(contentsOf: makeFullBox("alac", payload: cfg.toBytes()))
        }
        let entryBox = makeBoxStr(isALAC ? "alac" : "mp4a", payload: sampleEntry)
        var stsdPayload: [UInt8] = []
        stsdPayload.append(u32: 1)
        stsdPayload.append(contentsOf: entryBox)
        let stsd = makeFullBox("stsd", payload: stsdPayload)

        let stbl = makeBoxStr("stbl", payload: stsd)
        let minf = makeBoxStr("minf", payload: stbl)
        var mdiaPayload: [UInt8] = []
        mdiaPayload.append(contentsOf: mdhd)
        mdiaPayload.append(contentsOf: minf)
        let mdia = makeBoxStr("mdia", payload: mdiaPayload)
        let trak = makeBoxStr("trak", payload: mdia)

        // ilst
        var ilstPayload: [UInt8] = []
        if let title { ilstPayload.append(contentsOf: makeBox(0xA96E616D, payload: makeDataBox(type: 1, value: Array(title.utf8)))) }
        if let artist { ilstPayload.append(contentsOf: makeBox(0xA9415254, payload: makeDataBox(type: 1, value: Array(artist.utf8)))) }
        if let album { ilstPayload.append(contentsOf: makeBox(0xA9616C62, payload: makeDataBox(type: 1, value: Array(album.utf8)))) }
        if let albumArtist { ilstPayload.append(contentsOf: makeBox(0x61415254, payload: makeDataBox(type: 1, value: Array(albumArtist.utf8)))) }
        if let year { ilstPayload.append(contentsOf: makeBox(0xA9646179, payload: makeDataBox(type: 1, value: Array(year.utf8)))) }
        if let genre { ilstPayload.append(contentsOf: makeBox(0xA967656E, payload: makeDataBox(type: 1, value: Array(genre.utf8)))) }
        if let comment { ilstPayload.append(contentsOf: makeBox(0xA9636D74, payload: makeDataBox(type: 1, value: Array(comment.utf8)))) }
        if trackNumber != nil || trackTotal != nil {
            var trkn: [UInt8] = []
            trkn.append(u16: 0)
            trkn.append(u16: UInt16(trackNumber ?? 0))
            trkn.append(u16: UInt16(trackTotal ?? 0))
            trkn.append(u16: 0)
            ilstPayload.append(contentsOf: makeBox(0x74726B6E, payload: makeDataBox(type: 0, value: trkn)))
        }
        if discNumber != nil || discTotal != nil {
            var disk: [UInt8] = []
            disk.append(u16: 0)
            disk.append(u16: UInt16(discNumber ?? 0))
            disk.append(u16: UInt16(discTotal ?? 0))
            ilstPayload.append(contentsOf: makeBox(0x6469736B, payload: makeDataBox(type: 0, value: disk)))
        }
        if let artwork {
            ilstPayload.append(contentsOf: makeBox(0x636F7672, payload: makeDataBox(type: artworkIsPNG ? 14 : 13, value: artwork)))
        }
        let ilst = makeBoxStr("ilst", payload: ilstPayload)
        let metaBox = makeFullBox("meta", payload: ilst)
        let udta = makeBoxStr("udta", payload: metaBox)

        var moovPayload: [UInt8] = []
        moovPayload.append(contentsOf: trak)
        moovPayload.append(contentsOf: udta)
        let moov = makeBoxStr("moov", payload: moovPayload)

        var out: [UInt8] = []
        out.reserveCapacity(ftyp.count + moov.count)
        out.append(contentsOf: ftyp)
        out.append(contentsOf: moov)
        return out
    }

    /// Builds a compact valid WAV container (`fmt `, `LIST`/`INFO`, and `data` header).
    public static func makeWAVMetadata(
        sampleRate: Int = 44_100,
        channels: Int = 2,
        bitDepth: Int = 16,
        frameCount: Int = 44_100,
        info: [(String, String)] = []
    ) -> [UInt8] {
        let blockAlign = channels * (bitDepth / 8)
        let byteRate = sampleRate * blockAlign
        let dataBytes = frameCount * blockAlign

        var chunks: [UInt8] = []
        // fmt chunk
        chunks.appendMetaASCII("fmt ")
        chunks.appendMetaU32LE(16)
        chunks.appendMetaU16LE(1) // PCM
        chunks.appendMetaU16LE(UInt16(channels))
        chunks.appendMetaU32LE(UInt32(sampleRate))
        chunks.appendMetaU32LE(UInt32(byteRate))
        chunks.appendMetaU16LE(UInt16(blockAlign))
        chunks.appendMetaU16LE(UInt16(bitDepth))

        // LIST/INFO chunk
        if !info.isEmpty {
            var infoBody: [UInt8] = []
            infoBody.appendMetaASCII("INFO")
            for (tag, val) in info {
                guard tag.utf8.count == 4 else { continue }
                var strBytes = Array(val.utf8)
                strBytes.append(0)
                infoBody.appendMetaASCII(tag)
                infoBody.appendMetaU32LE(UInt32(strBytes.count))
                infoBody.append(contentsOf: strBytes)
                if (strBytes.count & 1) != 0 { infoBody.append(0) }
            }
            chunks.appendMetaASCII("LIST")
            chunks.appendMetaU32LE(UInt32(infoBody.count))
            chunks.append(contentsOf: infoBody)
            if (infoBody.count & 1) != 0 { chunks.append(0) }
        }

        // data chunk header (declaring exact byte length for duration calculation without allocating megabytes).
        chunks.appendMetaASCII("data")
        chunks.appendMetaU32LE(UInt32(dataBytes))

        var out: [UInt8] = []
        out.appendMetaASCII("RIFF")
        out.appendMetaU32LE(UInt32(4 + chunks.count))
        out.appendMetaASCII("WAVE")
        out.append(contentsOf: chunks)
        return out
    }

    /// Builds a compact valid AIFF container (`COMM` + optional `NAME`, `AUTH`, `ANNO` chunks).
    public static func makeAIFFMetadata(
        sampleRate: Double = 44_100,
        channels: Int = 2,
        bitDepth: Int = 16,
        frameCount: Int = 44_100,
        name: String? = nil,
        author: String? = nil,
        annotation: String? = nil
    ) -> [UInt8] {
        var chunks: [UInt8] = []
        chunks.appendMetaASCII("COMM")
        chunks.append(u32: 18)
        chunks.append(u16: UInt16(channels))
        chunks.append(u32: UInt32(frameCount))
        chunks.append(u16: UInt16(bitDepth))
        chunks.append(contentsOf: AIFFEncoder.encodeExtended80(sampleRate))

        func appendTextChunk(_ id: String, _ text: String?) {
            guard let text else { return }
            let b = Array(text.utf8)
            chunks.appendMetaASCII(id)
            chunks.append(u32: UInt32(b.count))
            chunks.append(contentsOf: b)
            if (b.count & 1) != 0 { chunks.append(0) }
        }

        appendTextChunk("NAME", name)
        appendTextChunk("AUTH", author)
        appendTextChunk("ANNO", annotation)

        var out: [UInt8] = []
        out.appendMetaASCII("FORM")
        out.append(u32: UInt32(4 + chunks.count))
        out.appendMetaASCII("AIFF")
        out.append(contentsOf: chunks)
        return out
    }
}
