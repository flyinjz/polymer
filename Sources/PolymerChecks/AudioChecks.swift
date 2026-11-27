// Checks for PolymerAudio: decoders, tags, the resampler and the engine.
// Every input is generated here in memory; files in Tests/Fixtures/Audio
// (made with ffmpeg, lame and flac, see `audioFixtureRecipes`) add real
// encoder output when present and are skipped when not.
import PolymerBase
import PolymerPlatform
import PolymerAudio

/// Deterministic noise in [-0.5, 0.5).
func audioNoise(frames: Int, channels: Int, seed: UInt32) -> [Float] {
    var s = seed | 1
    return (0..<(frames * channels)).map { _ in
        s = s &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: s) >> 8) / Float(1 << 24)
    }
}

/// The largest difference between `got` from frame `at` and `want` from frame `from`, over `count` frames.
func audioError(_ got: [Float], at: Int, _ want: [Float], from: Int, count: Int, channels: Int) -> Float {
    var worst: Float = 0
    for i in 0..<(count * channels) {
        let g = got.indices.contains(at * channels + i) ? got[at * channels + i] : .infinity
        let w = want.indices.contains(from * channels + i) ? want[from * channels + i] : 0
        worst = max(worst, abs(g - w))
    }
    return worst
}

/// Where `want[from..<from+count]` best lines up in `got`, searching frames `range`.
func audioAlign(_ got: [Float], _ want: [Float], from: Int, count: Int, channels: Int, range: ClosedRange<Int>) -> (frame: Int, error: Float) {
    var best = (range.lowerBound, Float.infinity)
    for o in range where o >= 0 {
        let e = audioError(got, at: o, want, from: from, count: count, channels: channels)
        if e < best.1 { best = (o, e) }
    }
    return best
}

func wavSource(_ samples: [Float], _ format: AudioFormat) throws -> WAVSource {
    try WAVSource(WAV.encode(samples, format: format, encoding: .float32))
}

/// Shell commands that make the optional fixtures (run from the repository root).
let audioFixtureRecipes: [(file: String, make: String)] = [
    ("sweep-mpeg1-joint-cbr.mp3", "ffmpeg -f lavfi -i \"aevalsrc=sin(2*PI*(220+880*t)*t)|sin(2*PI*(330+660*t)*t):d=4:s=44100\" -c:a libmp3lame -b:a 192k -joint_stereo 1"),
    ("sweep-mpeg1-vbr.mp3", "ffmpeg -f lavfi -i \"aevalsrc=sin(2*PI*(220+880*t)*t)|0.5*sin(2*PI*(110+440*t)*t):d=4:s=48000\" -c:a libmp3lame -q:a 2"),
    ("clicks-mpeg1-mono.mp3", "ffmpeg -f lavfi -i \"aevalsrc='if(lt(mod(t,0.25),0.004),random(0)-0.5,0)':d=3:s=44100\" -c:a libmp3lame -b:a 128k"),
    ("sweep-lsf-22050.mp3", "ffmpeg -f lavfi -i \"aevalsrc=sin(2*PI*(200+600*t)*t)|sin(2*PI*(300+500*t)*t):d=3:s=22050\" -c:a libmp3lame -b:a 64k"),
    ("sweep-mpeg25-8000.mp3", "ffmpeg -f lavfi -i \"aevalsrc=sin(2*PI*(200+300*t)*t):d=3:s=8000\" -c:a libmp3lame -b:a 16k"),
    ("sweep-24bit.flac", "ffmpeg -f lavfi -i \"aevalsrc=0.9*sin(2*PI*(100+2000*t)*t)|0.9*sin(2*PI*(150+1500*t)*t):d=3:s=96000\" -c:a flac -sample_fmt s32 -bits_per_raw_sample 24"),
]

@MainActor let audioChecks: [Check] = [
    Check("audio.md5") { c in
        c.expectEqual(AudioFixtures.md5Hex([]), "d41d8cd98f00b204e9800998ecf8427e", "MD5 of nothing")
        c.expectEqual(AudioFixtures.md5Hex(Array("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72", "MD5 of abc")
        c.expectEqual(AudioFixtures.md5Hex(Array("The quick brown fox jumps over the lazy dog".utf8)),
                      "9e107d9d372bb6826bd81d3542a419d6", "MD5 over one block boundary")
        c.expectEqual(AudioFixtures.md5Hex([UInt8](repeating: 0x61, count: 1000)), "cabe45dcc9ae5b66ba86600cca6b8ba8", "MD5 of 1000 a")
    },

    Check("audio.wav.roundtrip") { c in
        let format = AudioFormat(sampleRate: 44100, channels: 2)
        let samples = audioNoise(frames: 3000, channels: 2, seed: 7).map { $0 * 1.8 }
        let encodings: [(WAV.Encoding, Double)] = [(.int16, 1.0 / 32767), (.int24, 1.0 / 8_388_607), (.float32, 0.0)]
        for (encoding, step) in encodings {
            let bytes = WAV.encode(samples, format: format, encoding: encoding)
            c.expectEqual(Audio.container(of: bytes), .wav, "\(encoding) container")
            do {
                let s = try WAVSource(bytes)
                c.expectEqual(s.format, format, "\(encoding) format")
                c.expectEqual(s.frameCount, 3000, "\(encoding) frames")
                let back = s.readAll(chunk: 700)
                c.expectEqual(back.count, samples.count, "\(encoding) samples read")
                let worst = zip(back, samples).map { Double(abs($0 - $1)) }.max() ?? 0
                c.expect(worst <= step * 0.51 + 1e-9, "\(encoding): round trip off by \(worst), more than half a step")
                try s.seek(toFrame: 2500)
                var tail = [Float](repeating: 0, count: 1000)
                let n = tail.withUnsafeMutableBufferPointer { s.read(into: $0.baseAddress!, frames: 500) }
                c.expectEqual(n, 500, "\(encoding) frames after seek")
                c.expect(abs(tail[0] - back[5000]) < 1e-7, "\(encoding): seek to 2500 does not land on frame 2500")
            } catch { c.fail("\(encoding): \(error)") }
        }
    },

    Check("audio.resampler") { c in
        for (from, to) in [(44100, 48000), (48000, 44100), (44100, 96000), (48000, 47999)] {
            let r = Resampler(from: from, to: to, channels: 1)
            let n = from
            let f = 1000.0
            let input = (0..<n).map { Float(0.5 * Math.sin(2 * Double.pi * f * Double($0) / Double(from))) }
            var out: [Float] = []
            var buffer = [Float](repeating: 0, count: 4096)
            var at = 0
            while at < n {
                let chunk = min(997, n - at)
                let (used, made) = input.withUnsafeBufferPointer { i in
                    buffer.withUnsafeMutableBufferPointer { o in r.process(i.baseAddress! + at, frames: chunk, into: o.baseAddress!, capacity: 4096) }
                }
                out += buffer[0..<made]
                at += used
                if used == 0 && made == 0 { c.fail("\(from) to \(to): the resampler stopped taking input"); break }
            }
            while true {
                let made = buffer.withUnsafeMutableBufferPointer { r.finish(into: $0.baseAddress!, capacity: 4096) }
                if made == 0 { break }
                out += buffer[0..<made]
            }
            let expected = (n * to + from - 1) / from
            c.expectEqual(out.count, expected, "\(from) to \(to): output length (ceil(n * out / in))")
            var signal = 0.0, noise = 0.0
            for i in 200..<(out.count - 200) {
                let ideal = 0.5 * Math.sin(2 * Double.pi * f * Double(i) / Double(to))
                signal += ideal * ideal
                noise += (Double(out[i]) - ideal) * (Double(out[i]) - ideal)
            }
            let snr = 10 * Math.log(signal / max(noise, 1e-30)) / Math.log(10)
            c.note("resampler \(from) to \(to): 1 kHz SNR \(snr) dB")
            // Ratios with more than 1024 phases interpolate between filter phases.
            let needed = to == 47999 ? 60.0 : 80.0
            c.expect(snr > needed, "\(from) to \(to): 1 kHz sine SNR is \(snr) dB, expected over \(needed) (check the filter table and phase stepping)")

            let dc = Resampler(from: from, to: to, channels: 2)
            let ones = [Float](repeating: 0.25, count: 2 * 4000)
            var o = [Float](repeating: 0, count: 2 * 8000)
            let made = ones.withUnsafeBufferPointer { i in o.withUnsafeMutableBufferPointer { dc.process(i.baseAddress!, frames: 4000, into: $0.baseAddress!, capacity: 8000).produced } }
            if made > 1000 {
                let mid = o[2 * (made / 2)]
                c.expectClose(Double(mid), 0.25, tolerance: 1e-5, "\(from) to \(to): DC gain")
            } else { c.fail("\(from) to \(to): only \(made) frames out of 4000 in") }
        }
    },

    Check("audio.flac.decode") { c in
        for (channels, bps, rate) in [(2, 16, 44100), (1, 24, 96000), (2, 8, 8000)] {
            let frames = 5000
            let peak = Double((1 << (bps - 1)) - 1)
            var ints: [Int32] = []
            let noise = audioNoise(frames: frames, channels: channels, seed: UInt32(bps))
            for i in 0..<frames {
                for ch in 0..<channels {
                    // A sine, some noise, and a silent stretch (constant subframes).
                    let v = i >= 2048 && i < 3072 ? 0 : 0.6 * Math.sin(Double(i) * 0.05 * Double(ch + 1)) + 0.3 * Double(noise[i * channels + ch])
                    ints.append(Int32((v * peak).rounded()))
                }
            }
            let cover = CoverArt(mimeType: "image/png", pictureType: 3, description: "Front", bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
            let bytes = AudioFixtures.flac(samples: ints, channels: channels, sampleRate: rate, bitsPerSample: bps,
                                           blockSize: 1024, comments: ["TITLE=Test tone", "ARTIST=Polymer", "TRACKNUMBER=3/12"], picture: cover)
            let name = "\(channels) ch \(bps) bit"
            c.expectEqual(Audio.container(of: bytes), .flac, "\(name) container")
            do {
                let s = try FLACSource(bytes)
                c.expectEqual(s.format, AudioFormat(sampleRate: rate, channels: channels), "\(name) format")
                c.expectEqual(s.bitsPerSample, bps, "\(name) bits")
                c.expectEqual(s.frameCount, frames, "\(name) frames")
                c.expectEqual(s.metadata.title, "Test tone", "\(name) title")
                c.expectEqual(s.metadata.artist, "Polymer", "\(name) artist")
                c.expectEqual(s.metadata.trackNumber, 3, "\(name) track number")
                c.expectEqual(s.metadata.trackTotal, 12, "\(name) track total")
                c.expectEqual(s.metadata.frontCover?.bytes, cover.bytes, "\(name) cover bytes")
                c.expectEqual(s.metadata.frontCover?.kind, .png, "\(name) cover kind")
                let scale = 1 / Float(1 << (bps - 1))
                let want = ints.map { Float($0) * scale }
                let got = s.readAll(chunk: 333)
                c.expectEqual(got.count, want.count, "\(name) samples")
                c.expectEqual(audioError(got, at: 0, want, from: 0, count: frames, channels: channels), 0, "\(name): decoded samples differ from the input")
                c.expectEqual(s.damagedFrames, 0, "\(name) damaged frames")
                let v = s.verify()
                c.expectEqual(v.frames, frames, "\(name) verify frames")
                c.expectEqual(v.md5Matches, true, "\(name) STREAMINFO MD5")
                for target in [0, 1023, 1024, 2500, 4999, 4096] {
                    try s.seek(toFrame: target)
                    c.expectEqual(s.position, target, "\(name) position after seek")
                    var buf = [Float](repeating: 0, count: 64 * channels)
                    let n = buf.withUnsafeMutableBufferPointer { s.read(into: $0.baseAddress!, frames: 64) }
                    c.expectEqual(n, min(64, frames - target), "\(name) frames after seek to \(target)")
                    c.expectEqual(audioError(buf, at: 0, want, from: target, count: n, channels: channels), 0, "\(name): seek to \(target) lands elsewhere")
                }
                var damaged = bytes
                damaged[damaged.count - 400] ^= 0x5A
                let d = try FLACSource(damaged)
                let dv = d.verify()
                c.expect(dv.damaged >= 1 && dv.md5Matches != true, "\(name): a flipped byte was not reported (damaged \(dv.damaged), md5 \(String(describing: dv.md5Matches)))")
                c.expectEqual(d.readAll().count, want.count, "\(name): a damaged file keeps its length")
            } catch { c.fail("\(name): \(error)") }
        }
    },

    Check("audio.tags.id3v2") { c in
        let cover = CoverArt(mimeType: "image/jpeg", pictureType: 3, description: "Cover", bytes: [0xFF, 0xD8, 0xFF, 0xE0, 9, 8, 7, 0xFF, 0xD9])
        let tag = AudioFixtures.id3v2(title: "Señor ♫", artist: "Ärzte", album: "Album", track: "4/9", picture: cover)
        c.expectEqual(ID3v2.totalSize(tag), tag.count, "tag size")
        var m = AudioMetadata()
        ID3v2.read(tag, into: &m)
        c.expectEqual(m.title, "Señor ♫", "UTF-16 title")
        c.expectEqual(m.artist, "Ärzte", "Latin-1 artist")
        c.expectEqual(m.album, "Album", "album")
        c.expectEqual(m.trackNumber, 4, "track number")
        c.expectEqual(m.trackTotal, 9, "track total")
        c.expectEqual(m.pictures.count, 1, "pictures")
        c.expectEqual(m.frontCover?.bytes, cover.bytes, "APIC bytes")
        c.expectEqual(m.frontCover?.kind, .jpeg, "APIC kind")
        c.expectEqual(m.frontCover?.description, "Cover", "APIC description")

        // The same tag in front of an MP3 stream, with an ID3v1 tag at the end that must not win.
        var v1 = Array("TAG".utf8) + [UInt8](repeating: 0, count: 125)
        for (i, b) in "Other".utf8.enumerated() { v1[3 + i] = b }
        let file = tag + AudioFixtures.mp3Silence(frames: 8) + v1
        c.expectEqual(Audio.container(of: file), .mp3, "tagged MP3 container")
        do {
            let s = try MP3Source(file)
            c.expectEqual(s.metadata.title, "Señor ♫", "MP3 title from ID3v2")
            c.expectEqual(s.metadata.frontCover?.bytes, cover.bytes, "MP3 cover")
            c.expectEqual(s.mpegFrames, 8, "frames between the tags")
        } catch { c.fail("tagged MP3: \(error)") }
        let alone = AudioFixtures.mp3Silence(frames: 3) + v1
        do {
            let s = try MP3Source(alone)
            c.expectEqual(s.metadata.title, "Other", "ID3v1 title when there is no ID3v2")
            c.expectEqual(s.mpegFrames, 3, "frames before an ID3v1 tag")
        } catch { c.fail("ID3v1 MP3: \(error)") }
    },

    Check("audio.mp3.tables") { c in
        for p in MP3Diagnostics.huffmanProblems() { c.fail("Huffman table: \(p)") }
        for p in MP3Diagnostics.huffmanRoundTripFailures() { c.fail("Huffman round trip: \(p)") }
        for p in MP3Diagnostics.bandProblems() { c.fail("scalefactor bands: \(p)") }
        for p in MP3Diagnostics.windowProblems() { c.fail("synthesis window: \(p)") }
        for t in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 24, 32] {
            let unused = MP3Diagnostics.unusedCodes(table: t)
            if !unused.isEmpty { c.note("Huffman table \(t) leaves \(unused.count) codes unused: \(unused.prefix(6).joined(separator: ", "))") }
        }
    },

    Check("audio.mp3.filterbank") { c in
        let fb = MP3Diagnostics.filterbankRoundTrip()
        c.note("polyphase analysis and synthesis: SNR \(fb.snr) dB, delay \(fb.delay), gain \(fb.gain)")
        c.expect(fb.snr > 60, "polyphase round trip SNR is \(fb.snr) dB, expected over 60 (check the window D and the matrixing)")
        c.expectClose(fb.gain, 1, tolerance: 0.01, "polyphase round trip gain")
        let e = MP3Diagnostics.imdctRoundTripError()
        c.note("IMDCT with overlap-add over mixed block types: largest error \(e)")
        c.expect(e < 1e-4, "IMDCT round trip error \(e), expected under 1e-4 (check the windows and the short block placement)")
    },

    Check("audio.mp3.gapless") { c in
        let delay = 576, padding = 1000
        let bytes = AudioFixtures.mp3Silence(frames: 20, delay: delay, padding: padding)
        c.expectEqual(MP3.findFrame(bytes, from: 0, limit: 4096), 0, "first frame")
        do {
            let s = try MP3Source(bytes)
            c.expectEqual(s.format, AudioFormat(sampleRate: 44100, channels: 2), "format")
            c.expectEqual(s.encoderDelay, delay, "encoder delay from the LAME tag")
            c.expectEqual(s.encoderPadding, padding, "encoder padding from the LAME tag")
            c.expectEqual(s.mpegFrames, 20, "audio frames (the Info frame is not audio)")
            c.expectEqual(s.frameCount, 20 * 1152 - delay - padding, "gapless length")
            c.expectClose(Double(s.bitrate), 128000, tolerance: 1000, "bitrate")
            let all = s.readAll(chunk: 1000)
            c.expectEqual(all.count, (20 * 1152 - delay - padding) * 2, "samples read")
            c.expect(all.allSatisfy { $0 == 0 }, "silent frames decode to something other than silence")
            try s.seek(toFrame: 10000)
            var buf = [Float](repeating: 1, count: 200)
            let n = buf.withUnsafeMutableBufferPointer { s.read(into: $0.baseAddress!, frames: 100) }
            c.expectEqual(n, 100, "frames after seek")
            c.expectEqual(s.position, 10100, "position after seek and read")
            c.expect(buf.allSatisfy { $0 == 0 }, "silence after a seek is not silent")
            try s.seek(toFrame: 1 << 30)
            c.expectEqual(s.readAll().count, 0, "nothing past the end")
        } catch { c.fail("Info frame stream: \(error)") }
        do {
            let s = try MP3Source(AudioFixtures.mp3Silence(frames: 5))
            c.expectEqual(s.frameCount, 5 * 1152, "length without a LAME tag")
            c.expectEqual(s.readAll().count, 5 * 1152 * 2, "samples without a LAME tag")
        } catch { c.fail("plain stream: \(error)") }
        do {
            _ = try MP3Source(Array("not an mp3 at all".utf8) + [UInt8](repeating: 0, count: 2000))
            c.fail("garbage opened as MP3")
        } catch { c.expect(!"\(error)".isEmpty, "the error says nothing") }
    },

    Check("audio.mp3.decode") { c in
        let bytes = AudioFixtures.mp3SingleLine(frames: 4)
        do {
            let s = try MP3Source(bytes)
            c.expectEqual(s.format.channels, 1, "mono")
            let all = s.readAll()
            c.expectEqual(all.count, 4 * 1152, "samples")
            c.expect(all.allSatisfy { $0.isFinite }, "output is not finite")
            let peak = all.map { abs($0) }.max() ?? 0
            let energy = all.reduce(0) { $0 + Double($1) * Double($1) }
            c.note("one spectral line of 1.0: peak \(peak), energy \(energy)")
            c.expect(peak > 1e-4 && peak < 2, "one spectral line of 1.0 gives a peak of \(peak); expected a small nonzero signal")
            // Decoding again after a seek to 0 gives the same samples.
            try s.seek(toFrame: 0)
            let again = s.readAll()
            c.expectEqual(again, all, "decode after seeking to the start")
        } catch { c.fail("single-line stream: \(error)") }
    },

    Check("audio.engine.gapless") { c in
        let format = AudioFormat(sampleRate: 48000, channels: 2)
        let a = audioNoise(frames: 12000, channels: 2, seed: 1), b = audioNoise(frames: 9000, channels: 2, seed: 2)
        let engine = AudioEngine(format: format)
        let out = OfflineAudioOutput(format: format, periodFrames: 480)
        try engine.start(on: out)
        let first = try wavSource(a, format), second = try wavSource(b, format)
        engine.play(first, token: 1)
        engine.enqueue(second, token: 2)
        out.pump(frames: 4800)
        let joined = a + b
        let (start, err) = audioAlign(out.captured, joined, from: 1000, count: 256, channels: 2, range: 1000...2000)
        let lead = start - 1000
        c.expectEqual(lead, 0, "frames before the first track starts")
        c.expect(err < 1e-6, "the first track is not played as decoded (error \(err))")
        if let p = engine.position {
            c.expectEqual(p.token, 1, "token while the first track plays")
            c.expectClose(p.seconds, Double(out.captured.count / 2 - lead) / 48000, tolerance: 0.0005, "clock in the first track")
        } else { c.fail("no position while playing") }
        out.pump(frames: 9600)
        if let p = engine.position {
            c.expectEqual(p.token, 2, "token after the boundary")
            c.expectClose(p.seconds, Double(out.captured.count / 2 - lead - 12000) / 48000, tolerance: 0.0005, "clock in the second track")
        } else { c.fail("no position in the second track") }
        out.pump(frames: 14400)
        let ramp = 512
        let e = audioError(out.captured, at: lead + ramp, joined, from: ramp, count: 21000 - ramp, channels: 2)
        c.expect(e < 1e-6, "the two tracks are not joined sample for sample (largest error \(e))")
        let tail = out.captured[((lead + 21000) * 2)...]
        c.expect(tail.allSatisfy { $0 == 0 }, "sound after the end of the queue")
        c.expectEqual(engine.underruns, 0, "underruns with an unlimited feeder")
        engine.stop()
    },

    Check("audio.engine.controls") { c in
        let format = AudioFormat(sampleRate: 48000, channels: 2)
        let a = audioNoise(frames: 96000, channels: 2, seed: 3)
        let engine = AudioEngine(format: format)
        let out = OfflineAudioOutput(format: format, periodFrames: 480)
        try engine.start(on: out)
        let track = try wavSource(a, format)
        engine.play(track, token: 7)
        out.pump(frames: 4800)
        let lead = audioAlign(out.captured, a, from: 1000, count: 256, channels: 2, range: 1000...2000).frame - 1000

        // Volume: after the ramp the output is the input scaled.
        engine.volume = 0.5
        out.pump(frames: 4800)
        let n = out.captured.count / 2
        let half = a.map { $0 * 0.5 }
        let ev = audioError(out.captured, at: n - 2400, half, from: n - 2400 - lead, count: 2400, channels: 2)
        c.expect(ev < 1e-6, "volume 0.5 is not applied exactly after its ramp (error \(ev))")
        engine.volume = 1

        // Pause: silence, and the clock holds.
        out.pump(frames: 960)
        engine.pause()
        out.pump(frames: 1920)
        let held = engine.position?.seconds ?? -1
        let before = out.captured.count
        out.pump(frames: 4800)
        c.expect(out.captured[before...].allSatisfy { $0 == 0 }, "sound while paused")
        c.expectClose(engine.position?.seconds ?? -2, held, tolerance: 1e-9, "clock while paused")
        engine.resume()
        out.pump(frames: 4800)
        c.expect((engine.position?.seconds ?? 0) > held + 0.09, "the clock does not move after resume")

        // Seek: what is heard afterwards is the track from the new time.
        engine.seek(toSeconds: 1.25)
        out.pump(frames: 9600)
        if let p = engine.position {
            c.expectEqual(p.token, 7, "token after seek")
            let heard = Int((p.seconds * 48000).rounded())
            c.expect(heard > 60000 && heard <= 60000 + 9600,"after seeking to 1.25 s and playing 0.2 s the clock says \(p.seconds) s")
            let end = out.captured.count / 2
            let m = audioAlign(out.captured, a, from: heard - 1024, count: 256, channels: 2, range: (end - 1024 - 8)...(end - 1024 + 8))
            c.expect(m.error < 1e-6, "the audio after a seek is not the track at the clock's time (best error \(m.error) at \(m.frame - (end - 1024)) frames off)")
        } else { c.fail("no position after seek") }

        // A starved feeder underruns; the count says so.
        let starved = audioNoise(frames: 96000, channels: 2, seed: 4)
        let slow = try wavSource(starved, format)
        engine.play(slow, token: 8)
        out.pump(frames: 960)
        out.pump(frames: 48000, refillsPerPeriod: 0)
        c.expect(engine.underruns > 0, "no underrun counted when the feeder never ran for a second")
        engine.stop()
        out.pump(frames: 1920)
        c.expect(engine.position == nil, "a position after stop")
    },

    Check("audio.engine.resample") { c in
        // A 44.1 kHz track into a 48 kHz engine: the clock runs in source time
        // and the length comes out exact.
        let format = AudioFormat(sampleRate: 48000, channels: 2)
        let src = AudioFormat(sampleRate: 44100, channels: 1)
        let tone = (0..<44100).map { Float(0.5 * Math.sin(2 * Double.pi * 440 * Double($0) / 44100)) }
        let engine = AudioEngine(format: format)
        let out = OfflineAudioOutput(format: format, periodFrames: 480)
        try engine.start(on: out)
        let resampled = try wavSource(tone, src)
        engine.play(resampled, token: 1)
        out.pump(frames: 24000)
        c.expectClose(engine.position?.seconds ?? 0, 0.5, tolerance: 0.011, "clock half way through a resampled track")
        out.pump(frames: 48000)
        let frames = out.captured.count / 2
        var last = 0
        for i in 0..<frames where out.captured[2 * i] != 0 { last = i }
        c.expect(abs(last - 48000) < 64, "a one second 44.1 kHz track ends at frame \(last) of the 48 kHz output, expected about 48000")
        var mismatch: Float = 0
        for i in 0..<frames { mismatch = max(mismatch, abs(out.captured[2 * i] - out.captured[2 * i + 1])) }
        c.expectEqual(mismatch, 0, "mono is not copied to both channels")
    },

    Check("audio.fixtures") { c in
        let dir = c.root + "/Tests/Fixtures/Audio/"
        var missing: [String] = []
        for (file, make) in audioFixtureRecipes {
            let source: any AudioSource
            do { source = try Audio.open(path: dir + file) } catch {
                missing.append(file)
                c.note("skipped \(file) (\(error)); make it with: \(make) Tests/Fixtures/Audio/\(file)")
                continue
            }
            let pcm = source.readAll()
            c.expect(pcm.allSatisfy { $0.isFinite && abs($0) <= 4 }, "\(file): output not finite or far beyond full scale")
            if let n = source.frameCount { c.expectEqual(pcm.count, n * source.format.channels, "\(file): samples against the stated length") }
            // A reference decode (ffmpeg -i X -c:a pcm_f32le X.ref.wav) must match closely.
            guard let ref = try? Audio.open(path: dir + file + ".ref.wav") else {
                c.note("\(file): no reference; make one with: ffmpeg -i Tests/Fixtures/Audio/\(file) -c:a pcm_f32le Tests/Fixtures/Audio/\(file).ref.wav")
                continue
            }
            let want = ref.readAll()
            let ch = source.format.channels
            let count = min(pcm.count, want.count) / ch
            var signal = 0.0, noise = 0.0
            for i in 0..<(count * ch) { signal += Double(want[i]) * Double(want[i]); noise += Double(pcm[i] - want[i]) * Double(pcm[i] - want[i]) }
            let snr = 10 * Math.log(signal / max(noise, 1e-30)) / Math.log(10)
            c.note("\(file): \(snr) dB against the reference, \(pcm.count / ch) frames against \(want.count / ch)")
            c.expect(snr > 60, "\(file): only \(snr) dB against the reference decode")
            c.expectEqual(pcm.count, want.count, "\(file): length against the reference")
        }
        if !missing.isEmpty { c.note("\(missing.count) audio fixtures missing; the checks above ran on generated streams only") }
    },
]
