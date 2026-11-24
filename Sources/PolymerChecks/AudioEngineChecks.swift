// Headless deterministic checks for ALAC, MP3, and real-time gapless playback.
import PolymerBase
import PolymerAudio

@MainActor public let audioEngineChecks: [Check] = [
    Check("audio.alac") { c in
        let sr = 48_000.0
        let frames = 2048

        // Generate deterministic multi-tone stereo & mono 16-bit and 24-bit integer signals,
        // including an embedded silent zero-run to exercise ALAC's adaptive zero-run coding.
        var stereo16Ints = [Int32](repeating: 0, count: frames * 2)
        var stereo24Ints = [Int32](repeating: 0, count: frames * 2)
        var mono24Ints = [Int32](repeating: 0, count: frames)

        for i in 0..<frames {
            let inSilence = (i >= 700 && i < 820)
            let t = Double(i) / sr
            let l = inSilence ? 0.0 : (0.62 * Math.sin(2.0 * Double.pi * 440.0 * t) + 0.21 * Math.cos(2.0 * Double.pi * 1320.0 * t))
            let r = inSilence ? 0.0 : (0.58 * Math.sin(2.0 * Double.pi * 440.0 * t + 0.25) - 0.17 * Math.sin(2.0 * Double.pi * 880.0 * t))
            stereo16Ints[i * 2] = Int32((l * 32767.0).rounded())
            stereo16Ints[i * 2 + 1] = Int32((r * 32767.0).rounded())
            stereo24Ints[i * 2] = Int32((l * 8_388_607.0).rounded())
            stereo24Ints[i * 2 + 1] = Int32((r * 8_388_607.0).rounded())
            mono24Ints[i] = Int32((l * 8_388_607.0).rounded())
        }

        let stereo16Doubles = stereo16Ints.map { Double($0) / 32768.0 }
        let stereo24Doubles = stereo24Ints.map { Double($0) / 8_388_608.0 }
        let mono24Doubles = mono24Ints.map { Double($0) / 8_388_608.0 }

        // 1. ALACConfig magic cookie round-trip.
        let cfg = ALACConfig(frameLength: 4096, bitDepth: 24, numChannels: 2, sampleRate: 96_000)
        let parsedCfg = try ALACConfig(magicCookie: cfg.toBytes())
        c.expectEqual(parsedCfg, cfg, "ALACConfig 24-byte magic cookie round-trip")

        // 2. 16-bit stereo compressed M4A (adaptive Rice + dynamic FIR LPC + stereo decorrelation).
        let m4aStereo16Comp = try ALACEncoder.encodeM4A(
            samples: stereo16Doubles,
            sampleRate: sr,
            channelCount: 2,
            bitDepth: 16,
            compressed: true
        )
        let decStereo16 = try ALACDecoder.decodeM4A(m4aStereo16Comp)
        c.expectEqual(decStereo16.format, AudioFormat(sampleRate: sr, channelCount: 2, bitDepth: 16), "ALAC 16-bit stereo format")
        c.expectEqual(decStereo16.frames, frames, "ALAC 16-bit stereo frame count")
        c.expectEqual(decStereo16.rawIntSamples, stereo16Ints, "ALAC 16-bit stereo compressed exact integer match")
        let null16 = AudioMetrics.nullDifferenceDB(a: decStereo16.samples, b: stereo16Doubles)
        c.expect(null16 < -140.0, "ALAC 16-bit stereo compressed null (\(null16) dB) < -140 dB")
        c.expect(m4aStereo16Comp.count < frames * 2 * 2, "ALAC 16-bit stereo compresses smaller than raw PCM")

        // 3. 24-bit mono verbatim M4A.
        let m4aMono24Verb = try ALACEncoder.encodeM4A(
            samples: mono24Doubles,
            sampleRate: 96_000.0,
            channelCount: 1,
            bitDepth: 24,
            compressed: false
        )
        let decMono24Verb = try ALACDecoder.decodeM4A(m4aMono24Verb)
        c.expectEqual(decMono24Verb.format, AudioFormat(sampleRate: 96_000.0, channelCount: 1, bitDepth: 24), "ALAC 24-bit mono verbatim format")
        c.expectEqual(decMono24Verb.rawIntSamples, mono24Ints, "ALAC 24-bit mono verbatim exact integer match")
        let nullMonoVerb = AudioMetrics.nullDifferenceDB(a: decMono24Verb.samples, b: mono24Doubles)
        c.expect(nullMonoVerb < -140.0, "ALAC 24-bit mono verbatim null (\(nullMonoVerb) dB) < -140 dB")

        // 4. 24-bit mono compressed M4A (extraBits LSB shifting + dynamic LPC + Rice).
        let m4aMono24Comp = try ALACEncoder.encodeM4A(
            samples: mono24Doubles,
            sampleRate: 96_000.0,
            channelCount: 1,
            bitDepth: 24,
            compressed: true
        )
        let decMono24Comp = try ALACDecoder.decodeM4A(m4aMono24Comp)
        c.expectEqual(decMono24Comp.rawIntSamples, mono24Ints, "ALAC 24-bit mono compressed exact integer match")
        let nullMonoComp = AudioMetrics.nullDifferenceDB(a: decMono24Comp.samples, b: mono24Doubles)
        c.expect(nullMonoComp < -140.0, "ALAC 24-bit mono compressed null (\(nullMonoComp) dB) < -140 dB")

        // 5. 24-bit stereo verbatim + compressed M4A (exercises stereo decorrelation + extraBits).
        let m4aStereo24Verb = try ALACEncoder.encodeM4A(
            samples: stereo24Doubles,
            sampleRate: 44_100.0,
            channelCount: 2,
            bitDepth: 24,
            compressed: false
        )
        let decStereo24Verb = try ALACDecoder.decodeM4A(m4aStereo24Verb)
        c.expectEqual(decStereo24Verb.rawIntSamples, stereo24Ints, "ALAC 24-bit stereo verbatim exact integer match")

        let m4aStereo24Comp = try ALACEncoder.encodeM4A(
            samples: stereo24Doubles,
            sampleRate: 44_100.0,
            channelCount: 2,
            bitDepth: 24,
            compressed: true
        )
        let decStereo24Comp = try ALACDecoder.decodeM4A(m4aStereo24Comp)
        c.expectEqual(decStereo24Comp.format, AudioFormat(sampleRate: 44_100.0, channelCount: 2, bitDepth: 24), "ALAC 24-bit stereo compressed format")
        c.expectEqual(decStereo24Comp.rawIntSamples, stereo24Ints, "ALAC 24-bit stereo compressed exact integer match")
        let nullStereo24 = AudioMetrics.nullDifferenceDB(a: decStereo24Comp.samples, b: stereo24Doubles)
        c.expect(nullStereo24 < -140.0, "ALAC 24-bit stereo compressed null (\(nullStereo24) dB) < -140 dB")
        c.expect(m4aStereo24Comp.count < m4aStereo24Verb.count, "ALAC 24-bit stereo compressed is smaller than verbatim")

        // 6. Auto-detection via AudioTrackSource.decode.
        let track = try AudioTrackSource.decode(fromBytes: m4aStereo16Comp, id: "alac-auto")
        c.expectEqual(track.totalFrames, frames, "AudioTrackSource auto-detects ALAC M4A")
        c.expect(AudioMetrics.nullDifferenceDB(a: track.samples, b: stereo16Doubles) < -140.0, "AudioTrackSource ALAC null < -140 dB")

        c.note("ALAC16-comp=\(m4aStereo16Comp.count)B (raw=\(frames * 4)B), ALAC24-comp=\(m4aStereo24Comp.count)B (verb=\(m4aStereo24Verb.count)B)")
    },

    Check("audio.mp3") { c in
        // 1. Build a valid MPEG-1 Layer III stereo stream with ID3v2, ID3v1, and bit reservoir lookback.
        let sr = 44_100
        let targetHz = 1000.0
        let frameCount = 10
        let (_, _, expectedHz) = MP3TestFrameBuilder.nearestMDCTBin(frequencyHz: targetHz, sampleRate: sr)

        let mp3Bytes = MP3TestFrameBuilder.buildStream(MP3TestFrameBuilder.Spec(
            sampleRate: sr,
            bitrateKbps: 128,
            channelMode: .stereo,
            msStereo: false,
            frequencyHz: targetHz,
            frameCount: frameCount,
            includeID3v2: true,
            includeID3v1: true,
            useBitReservoir: true
        ))

        // Verify ID3v2 skip and MPEG-1 Layer III header parsing.
        let bounds = MP3Decoder.locateAudioBounds(in: mp3Bytes)
        c.expect(bounds.start > 10, "skipped leading ID3v2 tag (audio starts at byte \(bounds.start))")
        c.expectEqual(bounds.end, mp3Bytes.count - 128, "trimmed trailing 128-byte ID3v1 tag")

        let header = MP3Decoder.firstFrameHeader(in: mp3Bytes)
        c.expectEqual(header?.version, .mpeg1, "parsed MPEG-1 version")
        c.expectEqual(header?.layer, 3, "parsed Layer III")
        c.expectEqual(header?.bitrateKbps, 128, "parsed 128 kbps bitrate")
        c.expectEqual(header?.sampleRate, sr, "parsed 44100 Hz sample rate")
        c.expectEqual(header?.channelMode, .stereo, "parsed stereo channel mode")
        c.expectEqual(header?.samplesPerFrame, 1152, "MPEG-1 Layer III has 1152 samples/frame")
        c.expectEqual(header?.frameSizeBytes, 417, "44100 Hz 128 kbps frame size is 417 bytes")

        // Decode full stream through bit reservoir -> Huffman -> requant -> IMDCT -> 32-band synthesis.
        let decoded = try MP3Decoder.decode(mp3Bytes)
        c.expectEqual(decoded.format, AudioFormat(sampleRate: Double(sr), channelCount: 2, bitDepth: 64), "decoded MP3 format")
        c.expectEqual(decoded.frames, frameCount * 1152, "decoded exact 1152 frames per MPEG-1 frame")
        c.expectEqual(decoded.samples.count, frameCount * 1152 * 2, "interleaved stereo sample count")

        // Verify zero NaNs / infinities and clean finite PCM energy.
        var nonFinite = 0
        var peak = 0.0
        for s in decoded.samples {
            if !s.isFinite { nonFinite += 1 }
            let a = abs(s)
            if a > peak { peak = a }
        }
        c.expectEqual(nonFinite, 0, "zero NaN or infinite MP3 samples")
        c.expect(peak > 0.05 && peak < 2.0, "decoded MP3 peak (\(peak)) is non-zero and well-scaled")

        // Measure steady-state left channel fundamental frequency and tonal purity (skip filterbank warmup).
        let leftChannel = (0..<decoded.frames).map { decoded.samples[$0 * 2] }
        let thdn = AudioMetrics.measureTHDN(
            signal: leftChannel,
            sampleRate: Double(sr),
            fundamentalHz: expectedHz,
            skipEdgeSamples: 2048
        )
        let offFreqMag = AudioMetrics.toneMagnitude(
            signal: leftChannel,
            sampleRate: Double(sr),
            frequencyHz: expectedHz * 2.37,
            skipEdgeSamples: 2048
        )
        c.expect(thdn.fundamentalAmplitude > 0.05, "strong tonal amplitude at \(expectedHz) Hz (\(thdn.fundamentalAmplitude))")
        c.expect(thdn.fundamentalAmplitude > offFreqMag * 20.0, "fundamental dominates off-frequency energy")
        c.expect(thdn.thdnDB < -30.0, "synthesized MP3 tone is spectrally clean (THD+N = \(thdn.thdnDB) dB)")

        // 2. Verify Joint Stereo (MS stereo) decoding produces identical L & R when Side == 0.
        let msBytes = MP3TestFrameBuilder.buildStream(MP3TestFrameBuilder.Spec(
            sampleRate: 48_000,
            bitrateKbps: 192,
            channelMode: .jointStereo,
            msStereo: true,
            frequencyHz: 1500.0,
            frameCount: 6,
            includeID3v2: false,
            includeID3v1: false,
            useBitReservoir: true
        ))
        let msHdr = MP3Decoder.firstFrameHeader(in: msBytes)
        c.expectEqual(msHdr?.channelMode, .jointStereo, "parsed jointStereo mode")
        c.expectEqual(msHdr?.msStereo, true, "parsed msStereo flag")
        let msDec = try MP3Decoder.decode(msBytes)
        let msL = (0..<msDec.frames).map { msDec.samples[$0 * 2] }
        let msR = (0..<msDec.frames).map { msDec.samples[$0 * 2 + 1] }
        c.expect(AudioMetrics.nullDifferenceDB(a: msL, b: msR) < -140.0, "MS stereo with zero side yields identical L and R")

        // 3. Invalid-stream error handling.
        var threwTruncated = false
        do { _ = try MP3Decoder.decode([0xFF, 0xFB]) } catch { threwTruncated = true }
        c.expect(threwTruncated, "truncated MP3 throws error")

        var threwGarbage = false
        do { _ = try MP3Decoder.decode([UInt8](repeating: 0x33, count: 256)) } catch { threwGarbage = true }
        c.expect(threwGarbage, "garbage bytes without MPEG sync throw error")

        // 4. Auto-detection via AudioTrackSource.decode.
        let mp3Track = try AudioTrackSource.decode(fromBytes: mp3Bytes, id: "mp3-auto")
        c.expectEqual(mp3Track.totalFrames, frameCount * 1152, "AudioTrackSource auto-detects MP3 with ID3v2")

        c.note("MP3 decoded \(decoded.frames) frames at \(expectedHz) Hz: amp=\(thdn.fundamentalAmplitude), THD+N=\(thdn.thdnDB) dB")
    },

    Check("audio.playback-gapless") { c in
        let sr = 48_000.0
        let format = AudioFormat(sampleRate: sr, channelCount: 2, bitDepth: 64)
        let totalFrames = 4096
        // Split mid-cycle at an odd sample index so any 1-sample gap or glitch would be huge!
        let splitFrame = 1777

        var fullSine = [Double](repeating: 0.0, count: totalFrames * 2)
        for i in 0..<totalFrames {
            let phase = 2.0 * Double.pi * 1000.0 * Double(i) / sr
            fullSine[i * 2] = 0.8 * Math.sin(phase)
            fullSine[i * 2 + 1] = 0.8 * Math.cos(phase)
        }

        let partA = Array(fullSine[0..<(splitFrame * 2)])
        let partB = Array(fullSine[(splitFrame * 2)..<(totalFrames * 2)])
        let trackA = AudioTrackSource(id: "sine-part-a", format: format, samples: partA, replayGainDB: -6.0)
        let trackB = AudioTrackSource(id: "sine-part-b", format: format, samples: partB, replayGainDB: -6.0)

        // 1. Bit-exact gapless playback across the mid-cycle split in 256-frame callbacks.
        let engine = GaplessPlaybackEngine(outputFormat: format, readAheadFrames: 2048, maxCallbackFrames: 256)
        engine.enableReplayGain = false
        engine.crossfadeSeconds = 0.0
        engine.setQueue([trackA, trackB])
        engine.play()

        let cbFrames = 256
        let outStorage = AudioBufferStorage(frameCapacity: cbFrames, channelCount: 2)
        var captured: [Double] = []
        captured.reserveCapacity(totalFrames * 2)

        for _ in 0..<(totalFrames / cbFrames) {
            engine.pumpReadAhead()
            engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
            captured.append(contentsOf: outStorage.toArray(frameCount: cbFrames))
        }

        let gaplessNull = AudioMetrics.nullDifferenceDB(a: captured, b: fullSine)
        c.expect(gaplessNull < -140.0, "gapless track boundary null (\(gaplessNull) dB) < -140 dB (zero discontinuity)")
        let snapAfter = engine.snapshot()
        c.expectEqual(snapAfter.trackIndex, 1, "telemetry advanced to track 1 across boundary")
        c.expectEqual(snapAfter.trackChangeCount, 1, "recorded exactly 1 gapless track change")
        c.expectEqual(snapAfter.underrunCount, 0, "zero buffer underruns during gapless playback")
        c.expect(snapAfter.peakL > 0.75 && snapAfter.rmsL > 0.5, "lock-free stereo meters track live signal")

        // One more callback drains EOS and transitions cleanly to `.ended`.
        engine.pumpReadAhead()
        engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
        c.expectEqual(engine.snapshot().state, .ended, "engine transitions to .ended after final track")

        // 2. Pause / Resume preserves exact sample position without skipping or duplicating frames.
        engine.setQueue([trackA, trackB])
        engine.play()
        engine.pumpReadAhead()

        var resumeCaptured: [Double] = []
        engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
        resumeCaptured.append(contentsOf: outStorage.toArray(frameCount: cbFrames))

        engine.pause()
        c.expectEqual(engine.snapshot().state, .paused, "state is .paused")
        engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
        let pausedOut = outStorage.toArray(frameCount: cbFrames)
        let pausedPeak = pausedOut.reduce(0.0) { max($0, abs($1)) }
        c.expectEqual(pausedPeak, 0.0, "paused renderOutput emits pure silence")

        engine.play()
        engine.pumpReadAhead()
        engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
        resumeCaptured.append(contentsOf: outStorage.toArray(frameCount: cbFrames))

        let expected512 = Array(fullSine[0..<(512 * 2)])
        let resumeNull = AudioMetrics.nullDifferenceDB(a: resumeCaptured, b: expected512)
        c.expect(resumeNull < -140.0, "pause/resume is bit-exact continuous (\(resumeNull) dB)")

        // 3. Seek jumps immediately to target frame with zero stale samples.
        let seekFrame = 1000
        engine.seek(toFrame: seekFrame, trackIndex: 0)
        engine.pumpReadAhead()
        engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
        let seekOut = outStorage.toArray(frameCount: cbFrames)
        let expectedSeek = Array(fullSine[(seekFrame * 2)..<((seekFrame + cbFrames) * 2)])
        let seekNull = AudioMetrics.nullDifferenceDB(a: seekOut, b: expectedSeek)
        c.expect(seekNull < -140.0, "seek(toFrame: 1000) is bit-exact (\(seekNull) dB)")
        c.expectEqual(engine.snapshot().framePosition, seekFrame + cbFrames, "telemetry framePosition tracks post-seek cursor")

        // 4. ReplayGain attenuation (-6.0 dB -> ~0.5012x linear gain).
        engine.enableReplayGain = true
        engine.setQueue([trackA])
        engine.play()
        engine.pumpReadAhead()
        engine.renderOutput(into: outStorage.view, frameCount: cbFrames)
        let rgOut = outStorage.toArray(frameCount: cbFrames)
        let rgFactor = AudioMath.dbToLinear(-6.0)
        let expectedRG = Array(fullSine[0..<(cbFrames * 2)]).map { $0 * rgFactor }
        let rgNull = AudioMetrics.nullDifferenceDB(a: rgOut, b: expectedRG)
        c.expect(rgNull < -140.0, "ReplayGain -6 dB attenuation matches exact linear factor (\(rgNull) dB)")

        // 5. Smooth equal-power crossfade mode between two constant DC tracks (verify energy & monotonicity).
        let fadeEngine = GaplessPlaybackEngine(outputFormat: format, readAheadFrames: 4096, maxCallbackFrames: 256)
        fadeEngine.enableReplayGain = false
        fadeEngine.crossfadeSeconds = 0.01 // 480 frames at 48 kHz
        fadeEngine.crossfadeCurve = .equalPower

        let xfLen = 1280
        // Track 1: +1.0 on L, 0.0 on R; Track 2: 0.0 on L, +1.0 on R -> during equal-power crossfade, L^2 + R^2 == 1.0!
        var dcA = [Double](repeating: 0.0, count: xfLen * 2)
        var dcB = [Double](repeating: 0.0, count: xfLen * 2)
        for i in 0..<xfLen {
            dcA[i * 2] = 1.0
            dcB[i * 2 + 1] = 1.0
        }
        fadeEngine.setQueue([
            AudioTrackSource(id: "xf-a", format: format, samples: dcA),
            AudioTrackSource(id: "xf-b", format: format, samples: dcB),
        ])
        fadeEngine.play()

        var xfOut: [Double] = []
        let expectedXFOutputFrames = xfLen + xfLen - 480
        while xfOut.count / 2 < expectedXFOutputFrames {
            fadeEngine.pumpReadAhead()
            fadeEngine.renderOutput(into: outStorage.view, frameCount: cbFrames)
            xfOut.append(contentsOf: outStorage.toArray(frameCount: cbFrames))
        }

        // Verify before fade (L=1, R=0), throughout equal-power crossfade (L^2+R^2==1, L falls, R rises), and after fade (L=0, R=1).
        c.expectClose(xfOut[100 * 2], 1.0, tolerance: 1e-12, "pre-crossfade L == 1")
        c.expectClose(xfOut[100 * 2 + 1], 0.0, tolerance: 1e-12, "pre-crossfade R == 0")

        let fadeStart = xfLen - 480
        var maxEnergyErr = 0.0
        var prevL = 1.0
        var prevR = 0.0
        var monotonic = true
        for f in fadeStart..<xfLen {
            let l = xfOut[f * 2]
            let r = xfOut[f * 2 + 1]
            maxEnergyErr = max(maxEnergyErr, abs(l * l + r * r - 1.0))
            if l > prevL + 1e-12 || r < prevR - 1e-12 { monotonic = false }
            prevL = l
            prevR = r
        }
        c.expect(maxEnergyErr < 1e-12, "equal-power crossfade preserves L^2 + R^2 == 1 (err=\(maxEnergyErr))")
        c.expect(monotonic, "equal-power crossfade ramps L down and R up monotonically")
        c.expectClose(xfOut[(xfLen + 100) * 2], 0.0, tolerance: 1e-12, "post-crossfade L == 0")
        c.expectClose(xfOut[(xfLen + 100) * 2 + 1], 1.0, tolerance: 1e-12, "post-crossfade R == 1")

        // 6. On-the-fly SincResampler conversion (44.1 kHz track into 48 kHz output engine).
        let srcSR = 44_100.0
        let srcFrames = 4410
        var sine44 = [Double](repeating: 0.0, count: srcFrames * 2)
        for i in 0..<srcFrames {
            let v = 0.7 * Math.sin(2.0 * Double.pi * 1000.0 * Double(i) / srcSR)
            sine44[i * 2] = v
            sine44[i * 2 + 1] = v
        }
        let track44 = AudioTrackSource(
            id: "resample-44k",
            format: AudioFormat(sampleRate: srcSR, channelCount: 2, bitDepth: 64),
            samples: sine44
        )
        let rsEngine = GaplessPlaybackEngine(outputFormat: format, readAheadFrames: 8192, maxCallbackFrames: 256)
        rsEngine.setQueue([track44])
        rsEngine.play()
        var rsOut: [Double] = []
        for _ in 0..<18 {
            rsEngine.pumpReadAhead()
            rsEngine.renderOutput(into: outStorage.view, frameCount: cbFrames)
            rsOut.append(contentsOf: outStorage.toArray(frameCount: cbFrames))
        }
        let rsLeft = (0..<(rsOut.count / 2)).map { rsOut[$0 * 2] }
        let rsTHDN = AudioMetrics.measureTHDN(signal: rsLeft, sampleRate: sr, fundamentalHz: 1000.0, skipEdgeSamples: 256)
        c.expect(rsTHDN.thdnDB < -90.0, "engine SincResampler 44.1->48k THD+N (\(rsTHDN.thdnDB) dB) < -90 dB")

        c.note("gaplessNull=\(gaplessNull)dB, resumeNull=\(resumeNull)dB, seekNull=\(seekNull)dB, xfEnergyErr=\(maxEnergyErr), rsTHDN=\(rsTHDN.thdnDB)dB")
    },
]
