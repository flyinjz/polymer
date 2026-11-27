// Tags: ID3v2 (2.2, 2.3, 2.4, with unsynchronisation and compressed
// frames), ID3v1, Vorbis comments and FLAC/Vorbis pictures, all into one
// `AudioMetadata`.
import PolymerBase

public enum ID3v2 {
    /// Bytes taken by the tag at the start of `b` (header, body, footer); 0 when there is none.
    public static func totalSize(_ b: [UInt8]) -> Int {
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, b[3] < 0xFF, b[4] < 0xFF else { return 0 }
        let size = synchsafe(b, 6)
        return min(b.count, 10 + size + (b[5] & 0x10 != 0 ? 10 : 0))
    }

    static func synchsafe(_ b: [UInt8], _ at: Int) -> Int {
        Int(b.u8(at: at) & 0x7F) << 21 | Int(b.u8(at: at + 1) & 0x7F) << 14 | Int(b.u8(at: at + 2) & 0x7F) << 7 | Int(b.u8(at: at + 3) & 0x7F)
    }

    /// Removes the 0x00 that unsynchronisation puts after every 0xFF.
    static func resynchronise(_ b: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var previous: UInt8 = 0
        for x in b {
            if !(previous == 0xFF && x == 0) { out.append(x) }
            previous = x
        }
        return out
    }

    /// Reads the tag at the start of `bytes` into `m`.
    public static func read(_ bytes: [UInt8], into m: inout AudioMetadata) {
        let total = totalSize(bytes)
        guard total > 10 else { return }
        let version = Int(bytes[3])
        let flags = bytes[5]
        guard version >= 2 && version <= 4 else { return }
        var body = Array(bytes[10..<min(total, bytes.count)])
        if bytes[5] & 0x10 != 0, body.count >= 10 { body.removeLast(10) }
        if flags & 0x80 != 0 && version < 4 { body = resynchronise(body[...]) }
        var at = 0
        if flags & 0x40 != 0 && version >= 3 {
            at = version == 3 ? Int(body.u32(at: 0)) + 4 : synchsafe(body, 0)
        }
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        while at + headerLength <= body.count {
            if body[at] == 0 { break }   // padding
            let id = String(decoding: body[at..<at + idLength], as: UTF8.self)
            guard id.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else { break }
            var size: Int
            var formatFlags: UInt8 = 0
            switch version {
            case 2: size = Int(body.u24(at: at + 3))
            case 3: size = Int(body.u32(at: at + 4)); formatFlags = body[at + 9]
            default:
                size = synchsafe(body, at + 4)
                formatFlags = body[at + 9]
                // Some writers put plain sizes in 2.4 tags: prefer the reading that lands on a frame.
                let plain = Int(body.u32(at: at + 4))
                if plain != size && !landsOnFrame(body, at + 10 + size) && landsOnFrame(body, at + 10 + plain) { size = plain }
            }
            let start = at + headerLength
            let end = min(start + size, body.count)
            if start > end { break }
            var data = Array(body[start..<end])
            at = end
            // Frame format flags.
            if version == 3 {
                if formatFlags & 0x40 != 0 { continue }   // encrypted
                if formatFlags & 0x20 != 0, !data.isEmpty { data.removeFirst() }   // group
                if formatFlags & 0x80 != 0 {
                    guard data.count > 4, let d = try? Zlib.decompress(Array(data[4...])) else { continue }
                    data = d
                }
            } else if version == 4 {
                if formatFlags & 0x04 != 0 { continue }
                if formatFlags & 0x40 != 0, !data.isEmpty { data.removeFirst() }
                if formatFlags & 0x01 != 0, data.count >= 4 { data.removeFirst(4) }
                if formatFlags & 0x02 != 0 || flags & 0x80 != 0 { data = resynchronise(data[...]) }
                if formatFlags & 0x08 != 0 {
                    guard let d = try? Zlib.decompress(data) else { continue }
                    data = d
                }
            }
            frame(id, data, into: &m)
        }
    }

    static func landsOnFrame(_ b: [UInt8], _ at: Int) -> Bool {
        if at == b.count { return true }
        guard at + 4 <= b.count else { return false }
        if b[at] == 0 { return true }
        for i in 0..<4 { let c = b[at + i]; if !((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)) { return false } }
        return true
    }

    static let textFrames: [String: String] = [
        "TIT2": "TITLE", "TT2": "TITLE", "TPE1": "ARTIST", "TP1": "ARTIST", "TALB": "ALBUM", "TAL": "ALBUM",
        "TPE2": "ALBUMARTIST", "TP2": "ALBUMARTIST", "TCOM": "COMPOSER", "TCM": "COMPOSER",
        "TCON": "GENRE", "TCO": "GENRE", "TYER": "YEAR", "TYE": "YEAR", "TDRC": "DATE",
        "TRCK": "TRACKNUMBER", "TRK": "TRACKNUMBER", "TPOS": "DISCNUMBER", "TPA": "DISCNUMBER",
    ]

    static func frame(_ id: String, _ d: [UInt8], into m: inout AudioMetadata) {
        guard !d.isEmpty else { return }
        let enc = d[0]
        if let key = textFrames[id] {
            var values = splitStrings(Array(d[1...]), encoding: enc)
            if key == "GENRE" { values = values.map(genreName) }
            let joined = values.filter { !$0.isEmpty }.joined(separator: "; ")
            if !joined.isEmpty {
                if key == "ARTIST" { m.artist = joined } else { m.set(key, joined) }
            }
            return
        }
        switch id {
        case "TXXX", "TXX":
            let parts = splitStrings(Array(d[1...]), encoding: enc)
            if parts.count >= 2 { m.set(parts[0], parts[1...].joined(separator: "; ")) }
        case "COMM", "COM":
            guard d.count > 4 else { return }
            let parts = splitStrings(Array(d[4...]), encoding: enc)   // language, then description and text
            if parts.count >= 2, parts[0].isEmpty || m.comment == nil { m.comment = parts[1] }
            else if parts.count == 1 { m.comment = parts[0] }
        case "APIC":
            var at = 1
            let mimeEnd = d[at...].firstIndex(of: 0) ?? d.count
            let mime = String(decoding: d[at..<mimeEnd], as: UTF8.self)
            at = mimeEnd + 1
            guard at < d.count else { return }
            let type = Int(d[at]); at += 1
            let (description, next) = string(d, from: at, encoding: enc)
            guard next <= d.count else { return }
            m.pictures.append(CoverArt(mimeType: mime, pictureType: type, description: description, bytes: Array(d[next...])))
        case "PIC":
            guard d.count > 5 else { return }
            let format = String(decoding: d[1..<4], as: UTF8.self).uppercased()
            let type = Int(d[4])
            let (description, next) = string(d, from: 5, encoding: enc)
            guard next <= d.count else { return }
            let mime = format == "PNG" ? "image/png" : format == "JPG" ? "image/jpeg" : "image/" + format.lowercased()
            m.pictures.append(CoverArt(mimeType: mime, pictureType: type, description: description, bytes: Array(d[next...])))
        default: break
        }
    }

    /// A string ending at its terminator (one zero byte, or two aligned for UTF-16) and where the next field starts.
    static func string(_ d: [UInt8], from: Int, encoding: UInt8) -> (String, Int) {
        if encoding == 1 || encoding == 2 {
            var i = from
            while i + 1 < d.count, !(d[i] == 0 && d[i + 1] == 0) { i += 2 }
            let end = min(i, d.count)
            return (decode(Array(d[from..<end]), encoding: encoding), min(end + 2, d.count))
        }
        let end = d[from...].firstIndex(of: 0) ?? d.count
        return (decode(Array(d[from..<end]), encoding: encoding), min(end + 1, d.count))
    }

    /// All the zero-separated strings in a text field.
    static func splitStrings(_ d: [UInt8], encoding: UInt8) -> [String] {
        var out: [String] = []
        var at = 0
        while at < d.count {
            let (s, next) = string(d, from: at, encoding: encoding)
            out.append(s)
            if next <= at { break }
            at = next
        }
        if out.isEmpty { out.append("") }
        return out
    }

    static func decode(_ b: [UInt8], encoding: UInt8) -> String {
        switch encoding {
        case 0:
            var s = ""
            s.unicodeScalars.append(contentsOf: b.map { Unicode.Scalar($0) })
            return s
        case 1, 2:
            var bigEndian = encoding == 2
            var start = 0
            if b.count >= 2 {
                if b[0] == 0xFF && b[1] == 0xFE { bigEndian = false; start = 2 }
                else if b[0] == 0xFE && b[1] == 0xFF { bigEndian = true; start = 2 }
            }
            var units: [UInt16] = []
            var i = start
            while i + 1 < b.count {
                units.append(bigEndian ? UInt16(b[i]) << 8 | UInt16(b[i + 1]) : UInt16(b[i + 1]) << 8 | UInt16(b[i]))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        default:
            return String(decoding: b, as: UTF8.self)
        }
    }

    /// "(13)", "13" or "(13)Pop" to a name, using the ID3v1 list.
    static func genreName(_ s: String) -> String {
        var t = Substring(s)
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") {
            let number = t[t.index(after: t.startIndex)..<close]
            let rest = t[t.index(after: close)...]
            if !rest.isEmpty { return String(rest) }
            t = number
        }
        if let n = Int(t), n >= 0, n < ID3v1.genres.count { return ID3v1.genres[n] }
        return s
    }
}

public enum ID3v1 {
    /// Reads the 128-byte tag at the end of `b`, filling only fields still empty.
    public static func read(_ b: [UInt8], into m: inout AudioMetadata) {
        guard b.count >= 128 else { return }
        let t = b.count - 128
        guard b[t] == 0x54, b[t + 1] == 0x41, b[t + 2] == 0x47 else { return }
        func field(_ at: Int, _ n: Int) -> String {
            ID3v2.decode(Array(b[(t + at)..<(t + at + n)].prefix { $0 != 0 }), encoding: 0).trimmingSpaces
        }
        if m.title == nil { let v = field(3, 30); if !v.isEmpty { m.title = v } }
        if m.artist == nil { let v = field(33, 30); if !v.isEmpty { m.artist = v } }
        if m.album == nil { let v = field(63, 30); if !v.isEmpty { m.album = v } }
        if m.date == nil { let v = field(93, 4); if !v.isEmpty { m.date = v } }
        if b[t + 125] == 0 && b[t + 126] != 0 {
            if m.trackNumber == nil { m.trackNumber = Int(b[t + 126]) }
            if m.comment == nil { let v = field(97, 28); if !v.isEmpty { m.comment = v } }
        } else if m.comment == nil { let v = field(97, 30); if !v.isEmpty { m.comment = v } }
        let g = Int(b[t + 127])
        if m.genre == nil, g < genres.count { m.genre = genres[g] }
    }

    static let genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}

public enum VorbisComment {
    /// Reads a Vorbis comment block (FLAC VORBIS_COMMENT, Ogg comment header body).
    public static func read(_ b: ArraySlice<UInt8>, into m: inout AudioMetadata) {
        let d = Array(b)
        var at = 0
        let vendor = Int(d.u32le(at: at)); at += 4 + vendor
        let count = Int(d.u32le(at: at)); at += 4
        for _ in 0..<min(count, 100_000) {
            guard at + 4 <= d.count else { break }
            let n = Int(d.u32le(at: at)); at += 4
            guard n >= 0, at + n <= d.count else { break }
            let entry = d[at..<at + n]; at += n
            guard let eq = entry.firstIndex(of: 0x3D) else { continue }
            let key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self).uppercased()
            let value = String(decoding: entry[(eq + 1)...], as: UTF8.self)
            if key == "METADATA_BLOCK_PICTURE" {
                if let raw = base64(value), let p = FLACPicture.parse(raw[...]) { m.pictures.append(p) }
            } else {
                m.set(key, value)
            }
        }
    }

    static func base64(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var acc: UInt32 = 0, bits = 0
        for c in s.utf8 {
            let v: UInt32
            switch c {
            case 0x41...0x5A: v = UInt32(c - 0x41)
            case 0x61...0x7A: v = UInt32(c - 0x61) + 26
            case 0x30...0x39: v = UInt32(c - 0x30) + 52
            case 0x2B: v = 62
            case 0x2F: v = 63
            case 0x3D, 0x0A, 0x0D, 0x20: continue
            default: return nil
            }
            acc = acc << 6 | v; bits += 6
            if bits >= 8 { bits -= 8; out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits))) }
        }
        return out
    }
}

enum FLACPicture {
    /// A FLAC PICTURE block body.
    static func parse(_ s: ArraySlice<UInt8>) -> CoverArt? {
        let d = Array(s)
        var at = 0
        let type = Int(d.u32(at: at)); at += 4
        let mimeLength = Int(d.u32(at: at)); at += 4
        guard at + mimeLength <= d.count else { return nil }
        let mime = String(decoding: d[at..<at + mimeLength], as: UTF8.self); at += mimeLength
        let descLength = Int(d.u32(at: at)); at += 4
        guard at + descLength <= d.count else { return nil }
        let desc = String(decoding: d[at..<at + descLength], as: UTF8.self); at += descLength
        at += 16   // width, height, depth, colours
        let length = Int(d.u32(at: at)); at += 4
        guard at + length <= d.count else { return nil }
        return CoverArt(mimeType: mime, pictureType: type, description: desc, bytes: Array(d[at..<at + length]))
    }
}
