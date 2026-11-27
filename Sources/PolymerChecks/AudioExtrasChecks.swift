// Checks for the audio containers and DSP ported after the first audio pass:
// AIFF/AIFC (8/16/24-bit PCM, "sowt", "fl32", the 80-bit rate and the text/ID3
// chunks), ALAC in an M4A container, and the 64-bit DSP primitives (biquads and
// the parametric EQ, BS.1770 loudness, true peak and the limiter, crossfade,
// headphone crossfeed and TPDF dither).
// Every file is built in memory here, so the checks are deterministic and need
// no fixtures.
import PolymerBase
import PolymerPlatform
import PolymerAudio

// MARK: - Deterministic inputs

/// Signed integer samples spread over the full `bits`-wide range, with the
/// extremes (minimum, maximum) in the first two slots.
func audioExtrasInts(frames: Int, channels: Int, bits: Int, seed: UInt32) -> [Int32] {
    let top: Int32 = bits >= 24 ? 8_388_607 : (bits >= 16 ? 32_767 : 127)
    var s = seed | 1
    var out = [Int32](repeating: 0, count: frames * channels)
    for i in out.indices {
        s = s &* 1_664_525 &+ 1_013_904_223
        let v = Int32(bitPattern: s) >> (32 - bits)
        out[i] = i == 0 ? -top - 1 : (i == 1 ? top : max(-top - 1, min(top, v)))
    }
    return out
}

/// A sine at `hz`, interleaved over `channels` identical channels.
func audioExtrasSine(amplitude: Double, hz: Double, frames: Int, channels: Int, sampleRate: Double) -> [Double] {
    var out = [Double](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        let v = amplitude * Math.sin(2.0 * Double.pi * hz * Double(f) / sampleRate)
        for c in 0..<channels { out[f * channels + c] = v }
    }
    return out
}

func audioExtrasWorst(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return .infinity }
    var worst: Float = 0
    for i in a.indices { worst = max(worst, abs(a[i] - b[i])) }
    return worst
}

func audioExtrasWorstDouble(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count else { return .infinity }
    var worst = 0.0
    for i in a.indices { worst = max(worst, abs(a[i] - b[i])) }
    return worst
}

/// RMS of interleaved samples, channel 0 only.
func audioExtrasRMS(_ samples: [Double], channels: Int, from: Int, to: Int) -> Double {
    var sum = 0.0
    var n = 0
    for f in from..<to { sum += samples[f * channels] * samples[f * channels]; n += 1 }
    return n > 0 ? (sum / Double(n)).squareRoot() : 0
}

// MARK: - AIFF byte builders (the encoder only writes big-endian PCM)

func audioExtrasAIFF(_ form: String, channels: Int, bits: Int, rate: Double,
                     compression: String? = nil, payload: [UInt8],
                     text: [(String, String)] = [],
                     extraChunks: [(String, [UInt8])] = []) -> [UInt8] {
    let unit = (bits + 7) / 8
    let frames = unit * channels > 0 ? payload.count / (unit * channels) : 0
    var chunks: [UInt8] = []
    func chunk(_ id: String, _ body: [UInt8]) {
        chunks.append(contentsOf: Array(id.utf8))
        chunks.append(u32: UInt32(body.count))
        chunks.append(contentsOf: body)
        if body.count & 1 != 0 { chunks.append(0) }
    }
    var comm: [UInt8] = []
    comm.append(u16: UInt16(channels))
    comm.append(u32: UInt32(frames))
    comm.append(u16: UInt16(bits))
    comm.append(contentsOf: AIFFEncoder.encodeExtended80(rate))
    if let compression { comm.append(contentsOf: Array(compression.utf8)) }
    chunk("COMM", comm)
    for (id, value) in text { chunk(id, Array(value.utf8)) }
    for (id, body) in extraChunks { chunk(id, body) }
    var ssnd: [UInt8] = []
    ssnd.append(u32: 0)   // offset
    ssnd.append(u32: 0)   // block size
    ssnd.append(contentsOf: payload)
    chunk("SSND", ssnd)

    var out = Array("FORM".utf8)
    out.append(u32: UInt32(4 + chunks.count))
    out.append(contentsOf: Array(form.utf8))
    out.append(contentsOf: chunks)
    return out
}

func audioExtrasPCM8(_ ints: [Int32]) -> [UInt8] {
    ints.map { UInt8(truncatingIfNeeded: $0) }
}

func audioExtrasPCM16(_ ints: [Int32], littleEndian: Bool = false) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(ints.count * 2)
    for v in ints {
        let u = UInt16(truncatingIfNeeded: v)
        if littleEndian {
            out.append(UInt8(truncatingIfNeeded: u))
            out.append(UInt8(truncatingIfNeeded: u >> 8))
        } else {
            out.append(UInt8(truncatingIfNeeded: u >> 8))
            out.append(UInt8(truncatingIfNeeded: u))
        }
    }
    return out
}

func audioExtrasPCM24(_ ints: [Int32]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(ints.count * 3)
    for v in ints {
        let u = UInt32(bitPattern: v)
        out.append(UInt8(truncatingIfNeeded: u >> 16))
        out.append(UInt8(truncatingIfNeeded: u >> 8))
        out.append(UInt8(truncatingIfNeeded: u))
    }
    return out
}

func audioExtrasFloat32BE(_ samples: [Float]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(samples.count * 4)
    for f in samples { out.append(u32: f.bitPattern) }
    return out
}

/// A minimal ID3v2.3 tag with UTF-8 text frames.
func audioExtrasID3(_ frames: [(String, String)]) -> [UInt8] {
    var body: [UInt8] = []
    for (id, value) in frames {
        let data: [UInt8] = [3] + Array(value.utf8)   // encoding 3 = UTF-8
        body.append(contentsOf: Array(id.utf8))
        body.append(u32: UInt32(data.count))
        body.append(u16: 0)
        body.append(contentsOf: data)
    }
    let n = body.count
    var out = Array("ID3".utf8)
    out.append(contentsOf: [3, 0, 0])
    out.append(contentsOf: [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F),
                            UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
    out.append(contentsOf: body)
    return out
}

// MARK: - DSP buffer helper

/// Runs a node over interleaved doubles and returns its output.
func audioExtrasRun(_ node: AudioNode, input: [Double], channels: Int, sampleRate: Double) -> [Double] {
    let frames = input.count / channels
    var src = input
    var dst = [Double](repeating: 0, count: input.count)
    src.withUnsafeMutableBufferPointer { s in
        dst.withUnsafeMutableBufferPointer { d in
            let inView = AudioBufferView(samples: s, channelCount: channels, frameCapacity: frames)
            let outView = AudioBufferView(samples: d, channelCount: channels, frameCapacity: frames)
            node.process(input: inView, output: outView, frameCount: frames, sampleRate: sampleRate)
        }
    }
    return dst
}

@MainActor let audioExtrasChecks: [Check] = [
    // MARK: AIFF

    Check("audio.aiff.extended80") { c in
        let rates: [Double] = [8000, 11025, 22050, 32000, 44100, 48000, 96000, 192000, 44100.5, 1.0e-6, 1.0e6]
        for rate in rates {
            let bytes = AIFFEncoder.encodeExtended80(rate)
            c.expectEqual(bytes.count, 10, "\(rate): ten bytes")
            let back = AIFFDecoder.decodeExtended80(bytes, at: 0)
            let relative = abs(back - rate) / max(abs(rate), 1e-300)
            c.expect(relative < 1e-12, "\(rate) came back as \(back) (relative error \(relative))")
            let padded = [UInt8](repeating: 0xAA, count: 3) + bytes
            c.expectEqual(AIFFDecoder.decodeExtended80(padded, at: 3), back, "\(rate): decode at an offset")
        }
        c.expectEqual(AIFFEncoder.encodeExtended80(0), [UInt8](repeating: 0, count: 10), "zero is ten zero bytes")
        c.expectEqual(AIFFDecoder.decodeExtended80([UInt8](repeating: 0, count: 10), at: 0), 0.0, "all zero decodes as 0")
        c.expectEqual(AIFFDecoder.decodeExtended80([], at: 0), 0.0, "missing bytes decode as 0")
        c.expectEqual(AIFFDecoder.decodeExtended80([0, 0, 0], at: 0), 0.0, "short input decodes as 0")
    },

    Check("audio.aiff.pcm16.roundtrip") { c in
        let channels = 2, rate = 44100, frames = 3000
        let ints = audioExtrasInts(frames: frames, channels: channels, bits: 16, seed: 11)
        var meta = AudioMetadata()
        meta.title = "Sixteen"
        meta.artist = "Polymer"
        meta.comment = "PCM 16 bit"
        meta.extra["COPYRIGHT"] = "2026 Polymer"
        let bytes = AIFFEncoder.encodePCM16(intSamples: ints.map { Int16(truncatingIfNeeded: $0) },
                                            sampleRate: rate, channels: channels, metadata: meta)
        c.expectEqual(Audio.container(of: bytes), .aiff, "container")
        c.expectEqual(bytes.count & 1, 0, "FORM is padded to an even length")
        do {
            let decoded = try AIFFDecoder.decode(bytes)
            c.expectEqual(decoded.format, DecodedAudioFormat(sampleRate: rate, channelCount: channels, bitDepth: 16), "format")
            c.expectEqual(decoded.frames, frames, "frames")
            c.expectEqual(decoded.rawIntSamples ?? [], ints, "16-bit integers are bit exact")
            c.expectEqual(decoded.samples.count, ints.count, "sample count")
            let worst = zip(decoded.samples, ints).map { abs($0 - Double($1) / 32768.0) }.max() ?? 1
            c.expectEqual(worst, 0.0, "normalized samples are the integers over 32768")

            let source = try AIFFSource(bytes)
            c.expectEqual(source.format, AudioFormat(sampleRate: rate, channels: channels), "source format")
            c.expectEqual(source.bitsPerSample, 16, "source bit depth")
            c.expectEqual(source.frameCount, frames, "source frames")
            c.expectEqual(source.metadata, meta, "source metadata")
            c.expectEqual(AIFFSource.readMetadata(bytes), meta, "static metadata read")
            c.expectEqual(Audio.metadata(bytes), meta, "Audio.metadata picks the AIFF reader")

            let all = source.readAll(chunk: 777)
            c.expectEqual(all.count, ints.count, "chunked read returns every sample")
            var worstFloat: Float = 0
            for i in ints.indices { worstFloat = max(worstFloat, abs(all[i] - Float(Double(ints[i]) / 32768.0))) }
            c.expectEqual(worstFloat, 0, "source samples match the decoder")

            try source.seek(toFrame: 1234)
            c.expectEqual(source.position, 1234, "position after seek")
            var buffer = [Float](repeating: 0, count: 40)
            let read = buffer.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, frames: 20) }
            c.expectEqual(read, 20, "frames read after seek")
            c.expectEqual(audioExtrasWorst(buffer, Array(all[(1234 * channels)..<(1254 * channels)])), 0,
                          "seek lands on frame 1234")
            try source.seek(toFrame: 99_999)
            c.expectEqual(source.position, frames, "seek past the end clamps to the end")
            c.expectEqual(source.readAll(), [], "nothing left after the end")
            try source.seek(toFrame: -5)
            c.expectEqual(source.position, 0, "seek before the start clamps to zero")
        } catch { c.fail("\(error)") }
    },

    Check("audio.aiff.pcm24.roundtrip") { c in
        // Mono with an odd sample count, so the SSND chunk needs a pad byte.
        let channels = 1, rate = 96000, frames = 999
        let ints = audioExtrasInts(frames: frames, channels: channels, bits: 24, seed: 23)
        let bytes = AIFFEncoder.encodePCM24(intSamples: ints, sampleRate: rate, channels: channels)
        c.expectEqual(bytes.count & 1, 0, "odd 24-bit payload is padded")
        do {
            let decoded = try AIFFDecoder.decode(bytes)
            c.expectEqual(decoded.format, DecodedAudioFormat(sampleRate: rate, channelCount: 1, bitDepth: 24), "format")
            c.expectEqual(decoded.frames, frames, "frames")
            c.expectEqual(decoded.rawIntSamples ?? [], ints, "24-bit integers are bit exact")
            let worst = zip(decoded.samples, ints).map { abs($0 - Double($1) / 8_388_608.0) }.max() ?? 1
            c.expectEqual(worst, 0.0, "normalized samples")

            let source = try AIFFSource(bytes)
            c.expectEqual(source.bitsPerSample, 24, "source bit depth")
            c.expectEqual(source.frameCount, frames, "source frames")
            let all = source.readAll(chunk: 64)
            c.expectEqual(all.count, frames, "all frames")
            var worstFloat: Float = 0
            for i in ints.indices { worstFloat = max(worstFloat, abs(all[i] - Float(Double(ints[i]) / 8_388_608.0))) }
            c.expectEqual(worstFloat, 0, "24-bit source samples")

            // The float overload quantizes with the same rounding the encoder uses.
            let floats = ints.map { Float(Double($0) / 8_388_608.0) }
            let fromFloats = AIFFEncoder.encodePCM24(floats, sampleRate: rate, channels: channels)
            c.expectEqual(try AIFFDecoder.decode(fromFloats).rawIntSamples ?? [], ints, "float overload is exact for 24-bit values")
        } catch { c.fail("\(error)") }
    },

    Check("audio.aiff.encodings") { c in
        do {
            // 8-bit signed PCM, the format AIFF uses for telephony-grade audio.
            let int8 = audioExtrasInts(frames: 400, channels: 2, bits: 8, seed: 5)
            let eight = audioExtrasAIFF("AIFF", channels: 2, bits: 8, rate: 22050, payload: audioExtrasPCM8(int8))
            let d8 = try AIFFDecoder.decode(eight)
            c.expectEqual(d8.format, DecodedAudioFormat(sampleRate: 22050, channelCount: 2, bitDepth: 8), "8-bit format")
            c.expectEqual(d8.rawIntSamples ?? [], int8, "8-bit integers are bit exact")
            c.expectEqual(zip(d8.samples, int8).map { abs($0 - Double($1) / 128.0) }.max() ?? 1, 0.0, "8-bit scale is 1/128")
            let s8 = try AIFFSource(eight)
            c.expectEqual(s8.bitsPerSample, 8, "8-bit source depth")
            c.expectEqual(audioExtrasWorst(s8.readAll(chunk: 99), int8.map { Float($0) / 128 }), 0, "8-bit source samples")

            // "sowt": little-endian 16-bit samples in an AIFC file.
            let ints = audioExtrasInts(frames: 500, channels: 1, bits: 16, seed: 17)
            let sowt = audioExtrasAIFF("AIFC", channels: 1, bits: 16, rate: 48000, compression: "sowt",
                                       payload: audioExtrasPCM16(ints, littleEndian: true))
            c.expectEqual(Audio.container(of: sowt), .aiff, "AIFC container")
            let ds = try AIFFDecoder.decode(sowt)
            c.expectEqual(ds.rawIntSamples ?? [], ints, "sowt integers are bit exact")
            c.expectEqual(audioExtrasWorst(try AIFFSource(sowt).readAll(), ints.map { Float($0) / 32768 }), 0,
                          "sowt source samples match the big-endian path")

            // "fl32": 32-bit big-endian IEEE floats, one of them not a round
            // binary fraction, so a byte-order slip shows up.
            let floats: [Float] = [0.0, 1.0, -1.0, 0.5, -0.25, 0.999_999, 1.0 / 3.0, -1.0e-30, 3.0e-38]
            let fl32 = audioExtrasAIFF("AIFC", channels: 1, bits: 32, rate: 44100, compression: "fl32",
                                       payload: audioExtrasFloat32BE(floats))
            let df = try AIFFDecoder.decode(fl32)
            c.expectEqual(df.format.bitDepth, 32, "fl32 bit depth")
            c.expectEqual(df.rawIntSamples, nil, "float streams have no integer samples")
            c.expectEqual(df.samples, floats.map(Double.init), "fl32 samples are bit exact")
            let sf = try AIFFSource(fl32)
            c.expectEqual(sf.readAll(), floats, "fl32 source samples are bit exact")
            c.expectEqual(sf.bitsPerSample, 32, "fl32 source depth")

            // Errors, not silent garbage.
            let ima = audioExtrasAIFF("AIFC", channels: 1, bits: 16, rate: 44100, compression: "ima4",
                                      payload: [0, 0, 0, 0])
            do { _ = try AIFFDecoder.decode(ima); c.fail("AIFC 'ima4' decoded, expected unsupportedFormat") } catch {}
            do { _ = try AIFFDecoder.decode(Array("FORM".utf8)); c.fail("a 4-byte FORM decoded") } catch {}
            do {
                _ = try AIFFDecoder.decode(Array("FORM".utf8) + [0, 0, 0, 8] + Array("AIFF".utf8))
                c.fail("a FORM with no chunks decoded")
            } catch {}
            c.expect((try? AIFFSource(Array("not a sound file".utf8))) == nil, "AIFFSource rejects a non-AIFF stream")
        } catch { c.fail("\(error)") }
    },

    Check("audio.aiff.metadata") { c in
        var meta = AudioMetadata()
        meta.title = "Café 日本語"
        meta.artist = "Ångström"
        meta.comment = "ANNO text"
        meta.extra["COPYRIGHT"] = "(c) 2026 Polymer"
        let ints = audioExtrasInts(frames: 32, channels: 1, bits: 16, seed: 3)
        let bytes = AIFFEncoder.encodePCM16(intSamples: ints.map { Int16(truncatingIfNeeded: $0) },
                                            sampleRate: 44100, channels: 1, metadata: meta)
        c.expectEqual(AIFFSource.readMetadata(bytes), meta, "NAME/AUTH/ANNO/(c) round trip")
        c.expectEqual(Audio.metadata(bytes), meta, "Audio.metadata keeps the AIFF tags")

        // An ID3 chunk is read after the text chunks, so it wins the field.
        let tagged = audioExtrasAIFF("AIFF", channels: 1, bits: 16, rate: 44100,
                                     payload: audioExtrasPCM16(ints),
                                     text: [("NAME", "From NAME"), ("AUTH", "Text Author")],
                                     extraChunks: [("ID3 ", audioExtrasID3([("TIT2", "From ID3"), ("TPE1", "ID3 Artist"),
                                                                           ("TALB", "ID3 Album")]))])
        let d = try AIFFDecoder.decode(tagged)
        c.expectEqual(d.frames, 32, "tagged file still decodes")
        let id3 = AIFFSource.readMetadata(tagged)
        c.expectEqual(id3.title ?? "", "From ID3", "ID3 title overrides NAME")
        c.expectEqual(id3.artist ?? "", "ID3 Artist", "ID3 artist overrides AUTH")
        c.expectEqual(id3.album ?? "", "ID3 Album", "ID3 album")
        c.expectEqual(try AIFFSource(tagged).frameCount, 32, "source frames with an ID3 chunk present")

        // A file without tags reports nothing rather than invented values.
        let bare = AIFFEncoder.encodePCM16(intSamples: ints.map { Int16(truncatingIfNeeded: $0) },
                                           sampleRate: 44100, channels: 1)
        c.expectEqual(AIFFSource.readMetadata(bare), AudioMetadata(), "untagged AIFF has empty metadata")
        c.expect(AIFFSource.readMetadata(bare).isEmpty, "untagged AIFF reports isEmpty")
    },

    // MARK: ALAC

    Check("audio.alac.roundtrip") { c in
        for (channels, bits) in [(1, 16), (2, 16), (1, 24), (2, 24)] {
            for compressed in [true, false] {
                let label = "\(channels)ch/\(bits)bit/\(compressed ? "compressed" : "verbatim")"
                // 4600 frames crosses the 4096-frame packet boundary.
                let frames = 4600
                let ints = audioExtrasInts(frames: frames, channels: channels, bits: bits, seed: UInt32(channels * 100 + bits))
                do {
                    let bytes = try ALACEncoder.encodeM4A(intSamples: ints, sampleRate: 44100,
                                                          channelCount: channels, bitDepth: bits,
                                                          compressed: compressed)
                    c.expectEqual(Audio.container(of: bytes), .alac, "\(label): container")
                    let d = try ALACDecoder.decodeM4A(bytes)
                    c.expectEqual(d.format, DecodedAudioFormat(sampleRate: 44100, channelCount: channels, bitDepth: bits),
                                  "\(label): format")
                    c.expectEqual(d.frames, frames, "\(label): frames")
                    c.expectEqual(d.rawIntSamples ?? [], ints, "\(label): lossless, bit exact")
                    let scale = Double(Int64(1) << (bits - 1))
                    let worst = zip(d.samples, ints).map { abs($0 - Double($1) / scale) }.max() ?? 1
                    c.expectEqual(worst, 0.0, "\(label): normalized samples")
                    if channels == 1 {
                        c.expectEqual(d.samples.count, frames, "\(label): one sample per frame")
                    }
                } catch { c.fail("\(label): \(error)") }
            }
        }

        // A single packet straight through encodePacket/decodePacket.
        let config = ALACConfig(frameLength: 4096, compatibleVersion: 0, bitDepth: 16, pb: 40, mb: 10, kb: 14,
                                numChannels: 2, maxRun: 255, maxFrameBytes: 0, avgBitRate: 0, sampleRate: 48000)
        for compressed in [true, false] {
            let ints = audioExtrasInts(frames: 4096, channels: 2, bits: 16, seed: 31)
            do {
                let packet = try ALACEncoder.encodePacket(intSamples: ints, config: config, compressed: compressed)
                c.expect(packet.count >= 4, "packet has a bitstream")
                let back = try ALACDecoder.decodePacket(packet, config: config)
                c.expectEqual(back, ints, "packet round trip (compressed: \(compressed))")
            } catch { c.fail("packet (compressed: \(compressed)): \(error)") }
        }

        // The magic cookie survives a byte round trip and rejects short input.
        c.expectEqual(try ALACConfig(magicCookie: config.toBytes(), offset: 0), config, "config toBytes round trip")
        do { _ = try ALACConfig(magicCookie: Array(config.toBytes()) + [0xFF, 0xFF]); } catch { c.fail("cookie with trailing bytes: \(error)") }
        do { _ = try ALACConfig(magicCookie: [0, 1, 2]); c.fail("a 3-byte magic cookie parsed") } catch {}

        // The float overload quantizes exactly as the encoder's rounding says.
        let values: [Double] = [0.0, 0.25, -0.25, 0.5, -1.0, 1.0, 0.999_9, -0.999_9, 1.5, -1.5]
        let expected = values.map { v -> Int32 in
            let q = (min(max(v, -1.0), 1.0) * 32768.0).rounded()
            return Int32(min(max(q, -32768.0), 32767.0))
        }
        do {
            let bytes = try ALACEncoder.encodeM4A(samples: values, sampleRate: 44100, channelCount: 1, bitDepth: 16)
            let d = try ALACDecoder.decodeM4A(bytes)
            c.expectEqual(d.rawIntSamples ?? [], expected, "float overload clamps and rounds like the encoder")
            c.expectEqual(d.frames, values.count, "float overload frames")
        } catch { c.fail("float overload: \(error)") }
    },

    Check("audio.alac.source") { c in
        let channels = 2, rate = 48000, bits = 24, frames = 6000
        let ints = audioExtrasInts(frames: frames, channels: channels, bits: bits, seed: 41)
        var meta = AudioMetadata()
        meta.title = "ALAC Source"
        meta.artist = "Polymer"
        meta.album = "Extras"
        meta.trackNumber = 7
        meta.trackTotal = 9
        let bytes: [UInt8]
        do {
            bytes = try ALACEncoder.encodeM4A(intSamples: ints, sampleRate: Double(rate), channelCount: channels,
                                              bitDepth: bits, tags: meta)
        } catch { c.fail("encode: \(error)"); return }

        c.expectEqual(Audio.container(of: bytes), .alac, "container")
        do {
            let source = try ALACSource(bytes)
            c.expectEqual(source.format, AudioFormat(sampleRate: rate, channels: channels), "source format")
            c.expectEqual(source.bitsPerSample, 24, "source bit depth")
            c.expectEqual(source.frameCount, frames, "source frames")
            c.expectEqual(source.duration ?? -1, Double(frames) / Double(rate), "duration")
            c.expectEqual(source.metadata.title ?? "", "ALAC Source", "embedded title")
            c.expectEqual(source.metadata.album ?? "", "Extras", "embedded album")
            c.expectEqual(source.metadata.trackNumber, 7, "embedded track number")
            c.expectEqual(ALACSource.readMetadata(bytes), source.metadata, "static metadata read")

            let all = source.readAll(chunk: 1000)
            c.expectEqual(all.count, ints.count, "chunked read covers every sample")
            let expected = ints.map { Float(Double($0) / 8_388_608.0) }
            c.expectEqual(audioExtrasWorst(all, expected), 0, "source samples are the decoded integers")

            try source.seek(toFrame: 4500)
            c.expectEqual(source.position, 4500, "position after seek")
            let tail = source.readAll(chunk: 333)
            c.expectEqual(tail.count, (frames - 4500) * channels, "frames after seek")
            c.expectEqual(audioExtrasWorst(tail, Array(expected[(4500 * channels)...])), 0, "seek lands on frame 4500")

            try source.seek(toFrame: 0)
            c.expectEqual(audioExtrasWorst(source.readAll(), expected), 0, "seek back to the start")
            try source.seek(toFrame: frames * 2)
            c.expectEqual(source.readAll(), [], "seek past the end leaves nothing")

            let opened = try Audio.open(bytes)
            c.expect(opened is ALACSource, "Audio.open returns an ALACSource")
            c.expectEqual(opened.frameCount, frames, "Audio.open frame count")
            c.expectEqual(opened.format, source.format, "Audio.open format")
            c.expectEqual(Audio.metadata(bytes), source.metadata, "Audio.metadata reads the MP4 tags")
        } catch { c.fail("\(error)") }
    },

    Check("audio.alac.metadata") { c in
        var meta = AudioMetadata()
        meta.title = "Round Trip"
        meta.artist = "Artist"
        meta.album = "Album"
        meta.albumArtist = "Album Artist"
        meta.composer = "Composer"
        meta.genre = "Jazz"
        meta.date = "2026-11-26"
        meta.comment = "comment"
        meta.trackNumber = 3
        meta.trackTotal = 12
        meta.discNumber = 1
        meta.discTotal = 2
        meta.trackGain = -7.25
        meta.albumGain = -6.5
        meta.trackPeak = 0.987_65
        meta.albumPeak = 0.9
        meta.pictures = [CoverArt(mimeType: "image/jpeg", pictureType: 3, description: "",
                                  bytes: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A])]

        let tags = MP4Metadata.tagsBox(meta)
        c.expect(!tags.isEmpty, "a tagged file writes an udta box")
        c.expectEqual(Array(tags[4..<8]), Array("udta".utf8), "tagsBox starts with udta")
        // A moov wrapper is all `read` needs.
        var file: [UInt8] = []
        file.append(u32: UInt32(8 + tags.count))
        file.append(contentsOf: Array("moov".utf8))
        file.append(contentsOf: tags)
        c.expectEqual(MP4Metadata.read(file), meta, "every MP4 tag field round trips")

        let read = MP4Metadata.read(file)
        c.expectEqual(read.frontCover?.kind, .jpeg, "cover art kind from its bytes")
        c.expectEqual(read.frontCover?.mimeType ?? "", "image/jpeg", "cover art mime type")
        c.expectEqual(read.frontCover?.bytes ?? [], meta.pictures[0].bytes, "cover art bytes")
        c.expectEqual(read.trackGain ?? 0, -7.25, "ReplayGain track value survives the dB text")
        c.expectEqual(read.albumPeak ?? 0, 0.9, "ReplayGain album peak")

        c.expectEqual(MP4Metadata.tagsBox(AudioMetadata()), [], "empty metadata writes no box")
        c.expectEqual(MP4Metadata.read(Array("not an mp4".utf8)), AudioMetadata(), "a non-MP4 stream reads as untagged")
        // Only the front-cover subscription matters; every field set means no extras leak.
        c.expectEqual(read.trackNumber, 3, "track number")
        c.expectEqual(read.discTotal, 2, "disc total")
        c.expectEqual(read.date ?? "", "2026-11-26", "date")
    },

    // MARK: DSP

    Check("audio.dsp.biquad") { c in
        let rate = 48000.0
        c.expectEqual(BiquadCoefficients.identity.magnitudeResponse(at: 1000, sampleRate: rate), 1.0, "identity passes everything")

        let lowPass = BiquadCoefficients.design(.lowPass(frequency: 1000, q: 0.707_106_78), sampleRate: rate)
        c.expectClose(lowPass.magnitudeResponse(at: 100, sampleRate: rate), 1.0, tolerance: 0.01, "low pass passes 100 Hz")
        c.expectClose(lowPass.magnitudeResponse(at: 1000, sampleRate: rate), 0.707_106_78, tolerance: 0.01, "low pass is -3 dB at its corner")
        c.expect(lowPass.magnitudeResponse(at: 20_000, sampleRate: rate) < 0.001, "low pass stops 20 kHz")

        let highPass = BiquadCoefficients.design(.highPass(frequency: 1000, q: 0.707_106_78), sampleRate: rate)
        c.expectClose(highPass.magnitudeResponse(at: 1000, sampleRate: rate), 0.707_106_78, tolerance: 0.01, "high pass is -3 dB at its corner")
        c.expect(highPass.magnitudeResponse(at: 100, sampleRate: rate) < 0.02, "high pass stops 100 Hz (one decade down)")
        c.expectClose(highPass.magnitudeResponse(at: 20_000, sampleRate: rate), 1.0, tolerance: 0.001, "high pass passes 20 kHz")

        let peaking = BiquadCoefficients.design(.peaking(frequency: 1000, q: 1.0, gainDB: 6.0), sampleRate: rate)
        let plusSix = AudioMath.dbToLinear(6.0)
        c.expectClose(peaking.magnitudeResponse(at: 1000, sampleRate: rate), plusSix, tolerance: 0.01, "peaking band boosts by 6 dB")
        c.expectClose(peaking.magnitudeResponse(at: 40, sampleRate: rate), 1.0, tolerance: 0.01, "peaking band leaves 40 Hz alone")
        c.expectClose(peaking.magnitudeResponse(at: 18_000, sampleRate: rate), 1.0, tolerance: 0.01, "peaking band leaves 18 kHz alone")

        let lowShelf = BiquadCoefficients.design(.lowShelf(frequency: 200, slope: 1.0, gainDB: -6.0), sampleRate: rate)
        c.expectClose(lowShelf.magnitudeResponse(at: 20, sampleRate: rate), AudioMath.dbToLinear(-6.0), tolerance: 0.02, "low shelf cuts the bottom")
        c.expectClose(lowShelf.magnitudeResponse(at: 10_000, sampleRate: rate), 1.0, tolerance: 0.01, "low shelf leaves the top")
        let highShelf = BiquadCoefficients.design(.highShelf(frequency: 4000, slope: 1.0, gainDB: 6.0), sampleRate: rate)
        c.expectClose(highShelf.magnitudeResponse(at: 20_000, sampleRate: rate), plusSix, tolerance: 0.02, "high shelf boosts the top")
        c.expectClose(highShelf.magnitudeResponse(at: 100, sampleRate: rate), 1.0, tolerance: 0.01, "high shelf leaves the bottom")

        // A low pass has unity DC gain: the impulse response sums to 1.
        var state = BiquadState()
        let dcCoeffs = BiquadCoefficients.design(.lowPass(frequency: 2000, q: 0.707_106_78), sampleRate: rate)
        var sum = 0.0
        for i in 0..<4000 { sum += state.process(i == 0 ? 1.0 : 0.0, dcCoeffs) }
        c.expectClose(sum, 1.0, tolerance: 1e-9, "low-pass impulse response sums to one")

        // The node and the bare state produce the same samples.
        let tone = (0..<512).map { 0.3 * Math.sin(2.0 * Double.pi * 440.0 * Double($0) / rate) }
        let node = BiquadFilter(type: .peaking(frequency: 900, q: 0.9, gainDB: -4.0), sampleRate: rate, channelCount: 1)
        let viaNode = audioExtrasRun(node, input: tone, channels: 1, sampleRate: rate)
        var reference = BiquadState()
        let viaState = tone.map { reference.process($0, node.coefficients) }
        c.expectEqual(audioExtrasWorstDouble(viaNode, viaState), 0.0, "BiquadFilter matches BiquadState")

        // Two +6 dB bands in series give +12 dB at 1 kHz and nothing elsewhere.
        let eq = ParametricEQ(sampleRate: rate, channelCount: 2)
        eq.addBand(.peaking(frequency: 1000, q: 1.0, gainDB: 6.0))
        eq.addBand(.peaking(frequency: 1000, q: 1.0, gainDB: 6.0))
        c.expectEqual(eq.bands.count, 2, "two bands")
        eq.prepare(sampleRate: rate, channelCount: 2, maxFrames: 9600)
        guard let firstBand = eq.bands.first else { c.fail("no bands"); return }
        let expectedGain = firstBand.coefficients.magnitudeResponse(at: 1000, sampleRate: rate)
        var stereo = [Double](repeating: 0, count: 9600 * 2)
        for f in 0..<9600 {
            stereo[f * 2] = 0.25 * Math.sin(2.0 * Double.pi * 1000.0 * Double(f) / rate)
            stereo[f * 2 + 1] = 0.0
        }
        let filtered = audioExtrasRun(eq, input: stereo, channels: 2, sampleRate: rate)
        let inRMS = 0.25 / 2.0.squareRoot()
        let outRMS = audioExtrasRMS(filtered, channels: 2, from: 4800, to: 9600)
        c.expectClose(outRMS / inRMS, expectedGain * expectedGain, tolerance: expectedGain * expectedGain * 0.02,
                      "two +6 dB bands measure +12 dB at 1 kHz")
        var rightWorst = 0.0
        for f in 0..<9600 { rightWorst = max(rightWorst, abs(filtered[f * 2 + 1])) }
        c.expectEqual(rightWorst, 0.0, "the EQ keeps channels separate")

        for band in eq.bands { band.isBypassed = true }
        let bypassed = audioExtrasRun(eq, input: stereo, channels: 2, sampleRate: rate)
        c.expectEqual(audioExtrasWorstDouble(bypassed, stereo), 0.0, "bypassed bands are a pass-through")
        eq.removeAllBands()
        c.expectEqual(eq.bands.count, 0, "removeAllBands empties the cascade")
    },

    Check("audio.dsp.loudness") { c in
        let rate = 48_000.0
        func measure(_ samples: [Double], channels: Int) -> LoudnessMeter {
            let meter = LoudnessMeter(sampleRate: rate, channelCount: channels)
            meter.process(samples)
            return meter
        }
        // BS.1770: a 1 kHz sine at -20 dBFS reads about -20 LUFS.
        let stereo = audioExtrasSine(amplitude: 0.1, hz: 1000, frames: 72_000, channels: 2, sampleRate: rate)
        let loud = measure(stereo, channels: 2)
        c.expectClose(loud.integratedLUFS, -20.0, tolerance: 0.75, "stereo -20 dBFS 1 kHz reads -20 LUFS")
        c.expectClose(loud.momentaryLUFS, -20.0, tolerance: 0.75, "momentary loudness agrees")
        c.expectClose(loud.replayGainDB(), 2.0, tolerance: 0.75, "ReplayGain to -18 LUFS is +2 dB")
        c.expectClose(loud.replayGainDB(targetLUFS: -23.0), -3.0, tolerance: 0.75, "ReplayGain to -23 LUFS is -3 dB")

        // 6 dB less signal reads 6 LU lower; one channel reads 3 LU lower than two.
        let quiet = measure(audioExtrasSine(amplitude: 0.05, hz: 1000, frames: 72_000, channels: 2, sampleRate: rate), channels: 2)
        c.expectClose(loud.integratedLUFS - quiet.integratedLUFS, 6.0206, tolerance: 0.05, "6 dB in, 6 LU out")
        let mono = measure(audioExtrasSine(amplitude: 0.1, hz: 1000, frames: 72_000, channels: 1, sampleRate: rate), channels: 1)
        c.expectClose(loud.integratedLUFS - mono.integratedLUFS, 3.0103, tolerance: 0.1, "a second channel adds 3 LU")

        // Silence and inputs shorter than one block are gated out.
        let silent = measure([Double](repeating: 0, count: 48_000 * 2), channels: 2)
        c.expectEqual(silent.integratedLUFS, -200.0, "silence is -200 LUFS")
        c.expectEqual(silent.momentaryLUFS, -200.0, "silence has no momentary value")
        c.expectEqual(silent.replayGainDB(), 0.0, "silence asks for no gain")
        let short = measure(audioExtrasSine(amplitude: 0.5, hz: 440, frames: 4000, channels: 2, sampleRate: rate), channels: 2)
        c.expectEqual(short.integratedLUFS, -200.0, "less than a 400 ms block is gated out")

        // Reset forgets the history.
        let meter = LoudnessMeter(sampleRate: rate, channelCount: 2)
        meter.process(audioExtrasSine(amplitude: 0.5, hz: 1000, frames: 48_000 * 2, channels: 2, sampleRate: rate))
        c.expect(meter.integratedLUFS > -10.0, "a loud tone integrates high")
        meter.reset()
        c.expectEqual(meter.integratedLUFS, -200.0, "reset clears the integrated loudness")
    },

    Check("audio.dsp.truepeak") { c in
        let rate = 48_000.0
        // A quarter-rate sine at 45 degrees puts every sample at 0.6364 while
        // the waveform reaches 0.9 between them.
        let fs = rate / 4.0
        let interleaved = (0..<4800).map { 0.9 * Math.sin(2.0 * Double.pi * fs * Double($0) / rate + Double.pi / 4) }
        var samplePeak = 0.0
        for v in interleaved { samplePeak = max(samplePeak, abs(v)) }
        c.expectClose(samplePeak, 0.9 / 2.0.squareRoot(), tolerance: 0.001, "samples sit at 0.6364")
        let measured = TruePeakLimiter.measureTruePeak(interleaved, channels: 1)
        c.expect(measured > samplePeak * 1.3, "true peak finds the 0.9 between samples (measured \(measured))")
        c.expectClose(measured, 0.9, tolerance: 0.02, "true peak measures 0.9")
        c.expectEqual(TruePeakLimiter.measureTruePeak([], channels: 2), 0.0, "no samples, no peak")

        // The limiter holds a hot signal at the ceiling.
        let ceilingDB = -1.0
        let limiter = TruePeakLimiter(ceilingDB: ceilingDB, lookaheadMs: 5, releaseMs: 50,
                                      sampleRate: rate, channelCount: 2)
        let ceiling = limiter.ceilingLinear
        c.expectClose(ceiling, AudioMath.dbToLinear(ceilingDB), tolerance: 1e-12, "ceiling is -1 dBFS")
        let hot = audioExtrasSine(amplitude: 1.6, hz: 997, frames: 9600, channels: 2, sampleRate: rate)
        let limited = audioExtrasRun(limiter, input: hot, channels: 2, sampleRate: rate)
        c.expectEqual(limited.count, hot.count, "limiter keeps the frame count")
        var outPeak = 0.0, tailPeak = 0.0
        for i in limited.indices {
            outPeak = max(outPeak, abs(limited[i]))
            if i >= 2000 { tailPeak = max(tailPeak, abs(limited[i])) }
        }
        c.expect(outPeak <= ceiling + 1e-9, "no sample exceeds the ceiling (peak \(outPeak), ceiling \(ceiling))")
        c.expect(tailPeak > ceiling * 0.5, "the limiter attenuates, it does not mute (peak \(tailPeak))")
        let outTruePeak = TruePeakLimiter.measureTruePeak(limited, channels: 2)
        c.expect(outTruePeak <= ceiling * 1.02, "the true peak stays at the ceiling (peak \(outTruePeak))")

        limiter.ceilingDB = -6.0
        c.expectClose(limiter.ceilingLinear, AudioMath.dbToLinear(-6.0), tolerance: 1e-12, "ceiling follows ceilingDB")
        limiter.reset()
        c.expectEqual(audioExtrasRun(limiter, input: [Double](repeating: 0, count: 64), channels: 2, sampleRate: rate),
                      [Double](repeating: 0, count: 64), "a reset limiter passes silence")
    },

    Check("audio.dsp.crossfade") { c in
        for t in [0.0, 0.125, 0.25, 0.5, 0.75, 0.875, 1.0] {
            let equalPower = Crossfader.gains(position: t, curve: .equalPower)
            c.expectClose(equalPower.gainA * equalPower.gainA + equalPower.gainB * equalPower.gainB, 1.0,
                          tolerance: 1e-12, "equal power at \(t)")
            let linear = Crossfader.gains(position: t, curve: .linear)
            c.expectClose(linear.gainA + linear.gainB, 1.0, tolerance: 1e-12, "linear sum at \(t)")
            c.expectClose(linear.gainA, 1.0 - t, tolerance: 1e-12, "linear gain A at \(t)")
        }
        let start = Crossfader.gains(position: 0)
        c.expectEqual(start.gainA, 1.0, "position 0 is all A")
        c.expectEqual(start.gainB, 0.0, "position 0 has no B")
        let end = Crossfader.gains(position: 1)
        c.expectClose(end.gainA, 0.0, tolerance: 1e-12, "position 1 has no A")
        c.expectEqual(end.gainB, 1.0, "position 1 is all B")
        c.expectEqual(Crossfader.gains(position: -3).gainA, 1.0, "positions below 0 clamp")
        c.expectClose(Crossfader.gains(position: 3).gainB, 1.0, tolerance: 1e-12, "positions above 1 clamp")
        c.expectClose(Crossfader.gains(position: 0.5).gainA, 0.5.squareRoot(), tolerance: 1e-12, "equal power midpoint")

        let frames = 480
        var a = [Double](repeating: 1.0, count: frames)
        var b = [Double](repeating: 0.0, count: frames)
        var out = [Double](repeating: 0, count: frames)
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                out.withUnsafeMutableBufferPointer { op in
                    Crossfader.mix(a: AudioBufferView(samples: ap, channelCount: 1, frameCapacity: frames),
                                   b: AudioBufferView(samples: bp, channelCount: 1, frameCapacity: frames),
                                   output: AudioBufferView(samples: op, channelCount: 1, frameCapacity: frames),
                                   frameCount: frames, startPosition: 0, endPosition: 1)
                }
            }
        }
        c.expectEqual(out[0], 1.0, "the fade starts on A")
        c.expectClose(out[frames / 2], 0.5.squareRoot(), tolerance: 0.01, "the fade is half way at the middle")
        c.expectClose(out[frames - 1], 0.0, tolerance: 1e-3, "the fade ends on B")
        var monotonic = true
        for i in 1..<frames where out[i] > out[i - 1] + 1e-12 { monotonic = false }
        c.expect(monotonic, "the crossfade gain only falls")

        // Crossfeed: a complementary pair, so identical channels stay identical.
        let crossfeed = HeadphoneCrossfeed(preset: .standard, sampleRate: 48_000)
        let monoSignal = (0..<2000).flatMap { f -> [Double] in
            let v = 0.5 * Math.sin(2.0 * Double.pi * 300.0 * Double(f) / 48_000.0)
            return [v, v]
        }
        let feed = audioExtrasRun(crossfeed, input: monoSignal, channels: 2, sampleRate: 48_000)
        c.expectEqual(audioExtrasWorstDouble(feed, monoSignal), 0.0, "crossfeed preserves mono exactly")

        crossfeed.reset()
        var step = [Double](repeating: 0, count: 20_000 * 2)
        for f in 100..<20_000 { step[f * 2] = 1.0 }
        let steered = audioExtrasRun(crossfeed, input: step, channels: 2, sampleRate: 48_000)
        let ratio = AudioMath.dbToLinear(-HeadphoneCrossfeed.Preset.standard.feedDB)
        let expectedMix = ratio / (1.0 + ratio)
        let last = 19_990 * 2
        c.expectClose(steered[last], 1.0 - expectedMix, tolerance: 1e-4, "left keeps 1 - k of the signal")
        c.expectClose(steered[last + 1], expectedMix, tolerance: 1e-4, "right hears k of the left channel")
        c.expect(steered[last + 1] > 0.0, "some signal crosses over")
    },

    Check("audio.dsp.dither") { c in
        let a = TPDFDither(targetBitDepth: 16, seed: 12_345)
        let first = (0..<64).map { _ in a.nextUniform() }
        let b = TPDFDither(targetBitDepth: 16, seed: 12_345)
        c.expectEqual((0..<64).map { _ in b.nextUniform() }, first, "the same seed gives the same noise")
        let other = TPDFDither(targetBitDepth: 16, seed: 999)
        c.expect((0..<64).map { _ in other.nextUniform() } != first, "a different seed gives different noise")

        let noise = TPDFDither(targetBitDepth: 16, seed: 7)
        var sum = 0.0, sumSq = 0.0
        let count = 40_000
        var inRange = true
        for _ in 0..<count {
            let u = noise.nextUniform()
            if u < 0.0 || u >= 1.0 { inRange = false }
            let t = noise.nextTriangular()
            if t <= -1.0 || t >= 1.0 { inRange = false }
            sum += t
            sumSq += t * t
        }
        c.expect(inRange, "uniform in [0, 1) and triangular in (-1, 1)")
        let mean = sum / Double(count)
        let variance = sumSq / Double(count) - mean * mean
        c.expectClose(mean, 0.0, tolerance: 0.02, "TPDF noise has zero mean")
        c.expectClose(variance, 1.0 / 6.0, tolerance: 0.01, "TPDF noise has variance 1/6")

        // Quantization: one LSB of error at most, and hard clamping at the ends.
        let quantizer = TPDFDither(targetBitDepth: 16, seed: 21)
        var worst = 0.0
        for i in 0..<4000 {
            let value = -0.75 + 1.5 * Double(i) / 3999.0
            let q = quantizer.quantizeToInt16(value)
            worst = max(worst, abs(Double(q) - value * 32768.0))
        }
        c.expect(worst <= 1.5 + 1e-9, "16-bit quantization error stays within 1.5 LSB, the TPDF bound (worst \(worst))")
        let clamps = TPDFDither(targetBitDepth: 16, seed: 22)
        c.expectEqual(clamps.quantizeToInt16(1.0), 32767, "full scale clamps up")
        c.expectEqual(clamps.quantizeToInt16(2.0), 32767, "over full scale clamps up")
        c.expectEqual(clamps.quantizeToInt16(-1.0), -32_768, "minus full scale clamps down")
        c.expectEqual(clamps.quantizeToInt16(-2.0), -32_768, "below full scale clamps down")

        let q24 = TPDFDither(targetBitDepth: 24, seed: 23)
        var worst24 = 0.0
        for i in 0..<2000 {
            let value = -0.5 + Double(i) / 2000.0
            let q = q24.quantizeToInt24(value)
            worst24 = max(worst24, abs(Double(q) - value * 8_388_608.0))
        }
        c.expect(worst24 <= 1.5 + 1e-9, "24-bit quantization error stays within 1.5 LSB, the TPDF bound (worst \(worst24))")
        c.expectEqual(q24.quantizeToInt24(-1.0), -8_388_608, "24-bit minus full scale clamps")
        c.expectEqual(q24.quantizeToInt24(1.0), 8_388_607, "24-bit full scale clamps")

        // Noise shaping is deterministic too, and lands on the same grid.
        let shapedA = TPDFDither(targetBitDepth: 16, noiseShaping: true, seed: 31)
        let shapedB = TPDFDither(targetBitDepth: 16, noiseShaping: true, seed: 31)
        var sameShaped = true
        for i in 0..<512 {
            let v = 0.1 + Double(i) * 1e-5
            let x = shapedA.ditherSample(v)
            let y = shapedB.ditherSample(v)
            if x != y { sameShaped = false }
            if abs(x * 32768.0 - (v * 32768.0).rounded()) > 4.0 { sameShaped = false }
        }
        c.expect(sameShaped, "the shaped dither is deterministic and within a few LSB")
    },
]
