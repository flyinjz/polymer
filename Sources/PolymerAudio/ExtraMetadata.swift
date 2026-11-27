// Tags for the containers the older parsers did not read: MP4/M4A (the
// iTunes `ilst` boxes, including freeform ReplayGain) and AIFF (NAME/AUTH/
// ANNO and an embedded ID3 chunk). `MP4Metadata.tagsBox` writes the same
// boxes back, so an ALAC file made here carries its tags.
import PolymerBase

public enum MP4Metadata {
    struct Atom {
        var type: String
        var payloadStart: Int
        var end: Int
    }

    static func fourCC(_ b: [UInt8], _ at: Int) -> String {
        guard at >= 0, at + 4 <= b.count else { return "" }
        return String([
            Character(UnicodeScalar(b[at])),
            Character(UnicodeScalar(b[at + 1])),
            Character(UnicodeScalar(b[at + 2])),
            Character(UnicodeScalar(b[at + 3]))
        ])
    }

    static func atoms(_ b: [UInt8], _ range: Range<Int>) -> [Atom] {
        var out: [Atom] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let size32 = b.u32(at: pos)
            var header = 8
            var end = range.upperBound
            if size32 == 1 {
                guard pos + 16 <= range.upperBound else { break }
                let size64 = UInt64(b.u32(at: pos + 8)) << 32 | UInt64(b.u32(at: pos + 12))
                guard size64 >= 16, size64 <= UInt64(range.upperBound - pos) else { break }
                header = 16
                end = pos + Int(size64)
            } else if size32 != 0 {
                guard size32 >= 8 else { break }
                end = min(range.upperBound, pos + Int(size32))
            }
            out.append(Atom(type: fourCC(b, pos + 4), payloadStart: pos + header, end: end))
            if end <= pos { break }
            pos = end
        }
        return out
    }

    /// Reads the tags of an MP4/M4A file (empty when it has none).
    public static func read(_ b: [UInt8]) -> AudioMetadata {
        var meta = AudioMetadata()
        guard let moov = atoms(b, 0..<b.count).first(where: { $0.type == "moov" }) else { return meta }
        for box in atoms(b, moov.payloadStart..<moov.end) {
            switch box.type {
            case "udta": readUdta(b, box.payloadStart..<box.end, into: &meta)
            case "meta": readMeta(b, box.payloadStart..<box.end, into: &meta)
            default: break
            }
        }
        return meta
    }

    private static func readUdta(_ b: [UInt8], _ range: Range<Int>, into meta: inout AudioMetadata) {
        for box in atoms(b, range) where box.type == "meta" {
            readMeta(b, box.payloadStart..<box.end, into: &meta)
        }
    }

    private static func readMeta(_ b: [UInt8], _ range: Range<Int>, into meta: inout AudioMetadata) {
        guard range.count >= 8 else { return }
        // `meta` is a FullBox: version and flags come before its children.
        let start = (range.lowerBound + 4)..<range.upperBound
        for box in atoms(b, start) where box.type == "ilst" {
            readIlst(b, box.payloadStart..<box.end, into: &meta)
        }
    }

    private static func trim(_ s: String) -> String {
        var t = s
        while let f = t.first, f == "\0" || f == " " || f == "\n" || f == "\r" { t.removeFirst() }
        while let l = t.last, l == "\0" || l == " " || l == "\n" || l == "\r" { t.removeLast() }
        return t
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func readIlst(_ b: [UInt8], _ range: Range<Int>, into meta: inout AudioMetadata) {
        for item in atoms(b, range) {
            let subs = atoms(b, item.payloadStart..<item.end)

            // Freeform `----`: mean + name + data.
            if item.type == "----" {
                var name = "", value = ""
                for sub in subs {
                    if sub.type == "name", sub.payloadStart + 4 <= sub.end {
                        name = trim(String(decoding: b[(sub.payloadStart + 4)..<sub.end], as: UTF8.self))
                    } else if sub.type == "data", sub.payloadStart + 8 <= sub.end {
                        value = trim(String(decoding: b[(sub.payloadStart + 8)..<sub.end], as: UTF8.self))
                    }
                }
                if !name.isEmpty { meta.set(name, value) }
                continue
            }

            guard let data = subs.first(where: { $0.type == "data" }), data.payloadStart + 8 <= data.end else { continue }
            let dataType = b.u32(at: data.payloadStart)
            let valueStart = data.payloadStart + 8
            let valueRange = valueStart..<data.end

            func text() -> String {
                if dataType == 2 { return trim(utf16(b[valueRange])) }
                return trim(String(decoding: b[valueRange], as: UTF8.self))
            }

            switch item.type {
            case "\u{A9}nam": meta.title = text()
            case "\u{A9}ART": meta.artist = text()
            case "\u{A9}alb": meta.album = text()
            case "aART": meta.albumArtist = text()
            case "\u{A9}day": meta.date = text()
            case "\u{A9}gen": meta.genre = text()
            case "\u{A9}cmt": meta.comment = text()
            case "\u{A9}wrt": meta.composer = text()
            case "trkn":
                if valueRange.count >= 6 {
                    let number = Int(b.u16(at: valueStart + 2))
                    if number > 0 { meta.trackNumber = number }
                    let total = Int(b.u16(at: valueStart + 4))
                    if total > 0 { meta.trackTotal = total }
                }
            case "disk":
                if valueRange.count >= 6 {
                    let number = Int(b.u16(at: valueStart + 2))
                    if number > 0 { meta.discNumber = number }
                    let total = Int(b.u16(at: valueStart + 4))
                    if total > 0 { meta.discTotal = total }
                }
            case "covr":
                let art = Array(b[valueRange])
                guard !art.isEmpty else { break }
                let mime = dataType == 13 ? "image/jpeg" : dataType == 14 ? "image/png" : "application/octet-stream"
                meta.pictures.append(CoverArt(mimeType: mime, pictureType: 3, description: "", bytes: art))
            default: break
            }
        }
    }

    // MARK: Writing

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8 + payload.count)
        out.append(u32: UInt32(8 + payload.count))
        for scalar in type.unicodeScalars {
            out.append(UInt8(truncatingIfNeeded: scalar.value))
        }
        out.append(contentsOf: payload)
        return out
    }

    private static func dataBox(type: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = []
        payload.append(u32: type)
        payload.append(u32: 0) // locale
        payload.append(contentsOf: bytes)
        return box("data", payload)
    }

    private static func textItem(_ type: String, _ value: String?) -> [UInt8]? {
        guard let value, !value.isEmpty else { return nil }
        return box(type, dataBox(type: 1, Array(value.utf8)))
    }

    private static func pairItem(_ type: String, _ number: Int?, _ total: Int?) -> [UInt8]? {
        guard number != nil || total != nil else { return nil }
        var payload: [UInt8] = [UInt8](repeating: 0, count: 6)
        payload[2] = UInt8(truncatingIfNeeded: (number ?? 0) >> 8)
        payload[3] = UInt8(truncatingIfNeeded: number ?? 0)
        payload[4] = UInt8(truncatingIfNeeded: (total ?? 0) >> 8)
        payload[5] = UInt8(truncatingIfNeeded: total ?? 0)
        return box(type, dataBox(type: 0, payload))
    }

    private static func freeform(_ name: String, _ value: String) -> [UInt8] {
        var payload: [UInt8] = []
        payload.append(contentsOf: box("mean", [UInt8](repeating: 0, count: 4) + Array("com.apple.iTunes".utf8)))
        payload.append(contentsOf: box("name", [UInt8](repeating: 0, count: 4) + Array(name.utf8)))
        payload.append(contentsOf: dataBox(type: 1, Array(value.utf8)))
        return box("----", payload)
    }

    private static func gainText(_ db: Double) -> String {
        let rounded = (db * 100).rounded() / 100
        let sign = rounded > 0 ? "+" : ""
        let whole = Int(rounded)
        let fraction = Int((abs(rounded - Double(whole)) * 100).rounded())
        return "\(sign)\(whole).\(fraction < 10 ? "0" : "")\(fraction) dB"
    }

    /// An `udta` box holding `meta`/`ilst` with the fields that are set.
    public static func tagsBox(_ meta: AudioMetadata) -> [UInt8] {
        var items: [UInt8] = []
        func add(_ item: [UInt8]?) { if let item { items.append(contentsOf: item) } }
        add(textItem("\u{A9}nam", meta.title))
        add(textItem("\u{A9}ART", meta.artist))
        add(textItem("\u{A9}alb", meta.album))
        add(textItem("aART", meta.albumArtist))
        add(textItem("\u{A9}wrt", meta.composer))
        add(textItem("\u{A9}day", meta.date))
        add(textItem("\u{A9}gen", meta.genre))
        add(textItem("\u{A9}cmt", meta.comment))
        add(pairItem("trkn", meta.trackNumber, meta.trackTotal))
        add(pairItem("disk", meta.discNumber, meta.discTotal))
        for picture in meta.pictures {
            let type: UInt32 = picture.kind == .jpeg ? 13 : picture.kind == .png ? 14 : 0
            items.append(contentsOf: box("covr", dataBox(type: type, picture.bytes)))
        }
        if let gain = meta.trackGain { items.append(contentsOf: freeform("REPLAYGAIN_TRACK_GAIN", gainText(gain))) }
        if let gain = meta.albumGain { items.append(contentsOf: freeform("REPLAYGAIN_ALBUM_GAIN", gainText(gain))) }
        if let peak = meta.trackPeak { items.append(contentsOf: freeform("REPLAYGAIN_TRACK_PEAK", "\(peak)")) }
        if let peak = meta.albumPeak { items.append(contentsOf: freeform("REPLAYGAIN_ALBUM_PEAK", "\(peak)")) }
        guard !items.isEmpty else { return [] }

        var hdlrPayload: [UInt8] = [0, 0, 0, 0] // version + flags
        hdlrPayload.append(u32: 0)              // pre_defined
        hdlrPayload.append(contentsOf: Array("mdir".utf8))
        hdlrPayload.append(contentsOf: Array("appl".utf8))
        hdlrPayload.append(contentsOf: [UInt8](repeating: 0, count: 8))
        hdlrPayload.append(0)
        let hdlr = box("hdlr", hdlrPayload)

        var metaPayload: [UInt8] = [0, 0, 0, 0] // FullBox version + flags
        metaPayload.append(contentsOf: hdlr)
        metaPayload.append(contentsOf: box("ilst", items))
        return box("udta", box("meta", metaPayload))
    }
}
