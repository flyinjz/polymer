// Headless deterministic checks for PolymerAudio and PolymerGPU.
import PolymerBase
import PolymerText
import PolymerRender
import PolymerAudio
import PolymerGPU

@MainActor public let audioAndGPUChecks: [Check] = [
    Check("audio.ringbuffer") { c in
        // Power-of-two capacity rounding.
        let rb = AudioRingBuffer(minimumCapacity: 10)
        c.expectEqual(rb.capacity, 16, "capacity rounds up to next power of two")
        c.expect(rb.isEmpty, "starts empty")
        c.expectEqual(rb.availableToRead, 0, "0 available to read initially")
        c.expectEqual(rb.availableToWrite, 16, "full capacity available to write initially")
        c.expectEqual(rb.pop(), nil, "pop from empty returns nil")

        // Fill to capacity and verify full boundary.
        for i in 0..<16 {
            c.expect(rb.push(Double(i)), "push \(i) succeeds")
        }
        c.expect(rb.isFull, "buffer is full at capacity")
        c.expect(!rb.push(999.0), "push into full buffer returns false")
        c.expectEqual(rb.availableToWrite, 0, "0 free when full")

        // Partial read + wraparound write + full drain.
        var out = [Double](repeating: 0, count: 10)
        let nRead1 = rb.read(into: &out)
        c.expectEqual(nRead1, 10, "partial read returns 10")
        c.expectEqual(out, (0..<10).map(Double.init), "partial read values match")
        c.expectEqual(rb.availableToRead, 6, "6 remain after reading 10")

        // Write across wraparound boundary (slots 0..9).
        let wrapData = (100..<112).map(Double.init)
        let nWrite = rb.write(wrapData)
        c.expectEqual(nWrite, 10, "partial write clamps to 10 free slots")
        c.expect(rb.isFull, "buffer full again after wraparound write")

        var drained = [Double](repeating: 0, count: 20)
        let nDrain = rb.read(into: &drained)
        c.expectEqual(nDrain, 16, "drain reads all 16 elements")
        let expected = (10..<16).map(Double.init) + (100..<110).map(Double.init)
        c.expectEqual(Array(drained[0..<16]), expected, "wraparound order is preserved")
        c.expect(rb.isEmpty, "empty after full drain")

        // Multi-chunk streaming integrity across many wraparounds.
        let total = 2048
        let source = (0..<total).map { Double($0) * 0.25 - 100.0 }
        var received: [Double] = []
        received.reserveCapacity(total)
        var writeCursor = 0
        var chunkBuf = [Double](repeating: 0, count: 7)
        while received.count < total {
            if writeCursor < total {
                let end = min(total, writeCursor + 5)
                let slice = Array(source[writeCursor..<end])
                writeCursor += rb.write(slice)
            }
            let got = rb.read(into: &chunkBuf)
            if got > 0 {
                received.append(contentsOf: chunkBuf[0..<got])
            }
        }
        c.expectEqual(received, source, "multi-chunk wraparound stream is bit-exact")

        // Reset clears buffered data cleanly.
        _ = rb.write([1.0, 2.0, 3.0])
        rb.reset()
        c.expect(rb.isEmpty && rb.availableToWrite == rb.capacity, "reset restores empty state")
    },

    Check("audio.decoders") { c in
        // Deterministic multi-tone stereo test signal.
        let sr = 48_000
        let frames = 1024
        var int16Samples: [Int16] = []
        int16Samples.reserveCapacity(frames * 2)
        var int24Samples: [Int32] = []
        int24Samples.reserveCapacity(frames * 2)
        var floatSamples: [Double] = []
        floatSamples.reserveCapacity(frames * 2)

        for i in 0..<frames {
            let t = Double(i) / Double(sr)
            let l = 0.65 * Math.sin(2.0 * Double.pi * 440.0 * t) + 0.2 * Math.cos(2.0 * Double.pi * 1320.0 * t)
            let r = 0.55 * Math.sin(2.0 * Double.pi * 660.0 * t + 0.4) - 0.15 * Math.sin(2.0 * Double.pi * 220.0 * t)
            int16Samples.append(Int16((l * 32767.0).rounded()))
            int16Samples.append(Int16((r * 32767.0).rounded()))
            int24Samples.append(Int32((l * 8_388_607.0).rounded()))
            int24Samples.append(Int32((r * 8_388_607.0).rounded()))
            floatSamples.append(l)
            floatSamples.append(r)
        }
        let expected16Doubles = int16Samples.map { Double($0) / 32768.0 }
        let expected24Doubles = int24Samples.map { Double($0) / 8_388_608.0 }

        // 1. WAV PCM 16-bit, PCM 24-bit, and IEEE Float 32-bit.
        let wav16 = WAVEncoder.encodePCM16(intSamples: int16Samples, sampleRate: sr, channels: 2)
        let decWav16 = try WAVDecoder.decode(wav16)
        c.expectEqual(decWav16.format, AudioFormat(sampleRate: Double(sr), channelCount: 2, bitDepth: 16), "WAV16 format")
        c.expectEqual(decWav16.frames, frames, "WAV16 frame count")
        c.expectEqual(decWav16.rawIntSamples, int16Samples.map(Int32.init), "WAV16 bit-exact integer round-trip")
        c.expect(AudioMetrics.nullDifferenceDB(a: decWav16.samples, b: expected16Doubles) < -140.0, "WAV16 null < -140 dB")

        // Verify WAV skips unknown JUNK chunk cleanly.
        var wavWithJunk = Array(wav16[0..<12])
        let junkChunk: [UInt8] = [0x4A, 0x55, 0x4E, 0x4B, 4, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF]
        wavWithJunk.append(contentsOf: junkChunk)
        wavWithJunk.append(contentsOf: wav16[12...])
        let decWavJunk = try WAVDecoder.decode(wavWithJunk)
        c.expectEqual(decWavJunk.rawIntSamples, int16Samples.map(Int32.init), "WAV skips JUNK chunk cleanly")

        let wav24 = WAVEncoder.encodePCM24(intSamples: int24Samples, sampleRate: sr, channels: 2)
        let decWav24 = try WAVDecoder.decode(wav24)
        c.expectEqual(decWav24.format.bitDepth, 24, "WAV24 bit depth")
        c.expectEqual(decWav24.rawIntSamples, int24Samples, "WAV24 bit-exact integer round-trip")
        c.expect(AudioMetrics.nullDifferenceDB(a: decWav24.samples, b: expected24Doubles) < -140.0, "WAV24 null < -140 dB")

        let wavF32 = WAVEncoder.encodeFloat32(samples: floatSamples, sampleRate: sr, channels: 2)
        let decWavF32 = try WAVDecoder.decode(wavF32)
        c.expectEqual(decWavF32.format.bitDepth, 32, "WAV float32 bit depth")
        let f32Null = AudioMetrics.nullDifferenceDB(a: decWavF32.samples, b: floatSamples)
        c.expect(f32Null < -130.0, "WAV float32 null (\(f32Null) dB) < -130 dB")

        // 2. AIFF 80-bit extended sample rates + 16-bit & 24-bit big-endian PCM.
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let ext = AIFFEncoder.encodeExtended80(rate)
            let decodedRate = AIFFDecoder.decodeExtended80(ext, at: 0)
            c.expectClose(decodedRate, rate, tolerance: 1e-6, "AIFF 80-bit extended rate \(rate)")
        }

        let aiff16 = AIFFEncoder.encodePCM16(intSamples: int16Samples, sampleRate: 44_100.0, channels: 2)
        let decAiff16 = try AIFFDecoder.decode(aiff16)
        c.expectEqual(decAiff16.format, AudioFormat(sampleRate: 44_100.0, channelCount: 2, bitDepth: 16), "AIFF16 format")
        c.expectEqual(decAiff16.rawIntSamples, int16Samples.map(Int32.init), "AIFF16 bit-exact integer round-trip")
        c.expect(AudioMetrics.nullDifferenceDB(a: decAiff16.samples, b: expected16Doubles) < -140.0, "AIFF16 null < -140 dB")

        let aiff24 = AIFFEncoder.encodePCM24(intSamples: int24Samples, sampleRate: 96_000.0, channels: 2)
        let decAiff24 = try AIFFDecoder.decode(aiff24)
        c.expectEqual(decAiff24.format, AudioFormat(sampleRate: 96_000.0, channelCount: 2, bitDepth: 24), "AIFF24 format")
        c.expectEqual(decAiff24.rawIntSamples, int24Samples, "AIFF24 bit-exact integer round-trip")
        c.expect(AudioMetrics.nullDifferenceDB(a: decAiff24.samples, b: expected24Doubles) < -140.0, "AIFF24 null < -140 dB")

        // 3. FLAC: CONSTANT, VERBATIM, FIXED (mid-side stereo + Rice), LPC (24-bit + Rice2).
        let constSamples = [Int32](repeating: 12345, count: 512)
        let flacConst = try FLACEncoder.encode(
            intSamples: constSamples,
            sampleRate: 44_100,
            channels: 1,
            bitDepth: 16,
            options: FLACEncoder.Options(blockSize: 256, subframeMode: .constant, allowMidSide: false)
        )
        let decFlacConst = try FLACDecoder.decode(flacConst)
        c.expectEqual(decFlacConst.rawIntSamples, constSamples, "FLAC CONSTANT bit-exact round-trip")

        let flacVerb = try FLACEncoder.encode(
            intSamples: int16Samples.map(Int32.init),
            sampleRate: sr,
            channels: 2,
            bitDepth: 16,
            options: FLACEncoder.Options(blockSize: 512, subframeMode: .verbatim, allowMidSide: false)
        )
        let decFlacVerb = try FLACDecoder.decode(flacVerb)
        c.expectEqual(decFlacVerb.rawIntSamples, int16Samples.map(Int32.init), "FLAC VERBATIM bit-exact round-trip")

        let flacFixedMS = try FLACEncoder.encode(
            intSamples: int16Samples.map(Int32.init),
            sampleRate: sr,
            channels: 2,
            bitDepth: 16,
            options: FLACEncoder.Options(blockSize: 512, subframeMode: .fixed(order: 2), allowMidSide: true, useRice2: false)
        )
        let decFlacFixedMS = try FLACDecoder.decode(flacFixedMS)
        c.expectEqual(decFlacFixedMS.rawIntSamples, int16Samples.map(Int32.init), "FLAC FIXED + mid-side + Rice bit-exact")
        c.expect(AudioMetrics.nullDifferenceDB(a: decFlacFixedMS.samples, b: expected16Doubles) < -140.0, "FLAC FIXED null < -140 dB")
        c.expect(flacFixedMS.count < wav16.count, "FLAC FIXED compresses smaller than raw WAV (\(flacFixedMS.count) < \(wav16.count))")

        let flacLPC24 = try FLACEncoder.encode(
            intSamples: int24Samples,
            sampleRate: 96_000,
            channels: 2,
            bitDepth: 24,
            options: FLACEncoder.Options(blockSize: 512, subframeMode: .lpc(order: 4), allowMidSide: true, useRice2: true)
        )
        let decFlacLPC24 = try FLACDecoder.decode(flacLPC24)
        c.expectEqual(decFlacLPC24.format, AudioFormat(sampleRate: 96_000.0, channelCount: 2, bitDepth: 24), "FLAC LPC24 format")
        c.expectEqual(decFlacLPC24.rawIntSamples, int24Samples, "FLAC LPC 24-bit + mid-side + Rice2 bit-exact")
        c.expect(AudioMetrics.nullDifferenceDB(a: decFlacLPC24.samples, b: expected24Doubles) < -140.0, "FLAC LPC24 null < -140 dB")

        c.note("WAV16=\(wav16.count)B, FLAC-FIXED-MS=\(flacFixedMS.count)B, FLAC-LPC24=\(flacLPC24.count)B")
    },

    Check("audio.dsp-quality") { c in
        // 1. Polyphase Windowed-Sinc Resampler: 44.1 -> 48 kHz and 96 -> 44.1 kHz THD+N < -90 dB.
        let sine44 = (0..<4410).map { i in
            0.9 * Math.sin(2.0 * Double.pi * 1000.0 * Double(i) / 44_100.0)
        }
        let up48 = SincResampler.resample(sine44, from: 44_100.0, to: 48_000.0, channels: 1)
        let thdnUp = AudioMetrics.measureTHDN(signal: up48, sampleRate: 48_000.0, fundamentalHz: 1000.0, skipEdgeSamples: 128)
        c.expect(thdnUp.thdnDB < -90.0, "SincResampler 44.1->48k THD+N (\(thdnUp.thdnDB) dB) < -90 dB")
        c.expectClose(thdnUp.fundamentalAmplitude, 0.9, tolerance: 1e-3, "SincResampler 44.1->48k unity gain")

        let sine96 = (0..<9600).map { i in
            0.9 * Math.sin(2.0 * Double.pi * 1000.0 * Double(i) / 96_000.0)
        }
        let down44 = SincResampler.resample(sine96, from: 96_000.0, to: 44_100.0, channels: 1)
        let thdnDown = AudioMetrics.measureTHDN(signal: down44, sampleRate: 44_100.0, fundamentalHz: 1000.0, skipEdgeSamples: 256)
        c.expect(thdnDown.thdnDB < -90.0, "SincResampler 96->44.1k THD+N (\(thdnDown.thdnDB) dB) < -90 dB")
        c.expectClose(thdnDown.fundamentalAmplitude, 0.9, tolerance: 1e-3, "SincResampler 96->44.1k unity gain")

        // Alias rejection: 30 kHz tone at 96 kHz resampled to 44.1 kHz must be strongly attenuated.
        let aliasIn = (0..<9600).map { i in
            Math.sin(2.0 * Double.pi * 30_000.0 * Double(i) / 96_000.0)
        }
        let aliasOut = SincResampler.resample(aliasIn, from: 96_000.0, to: 44_100.0, channels: 1)
        var aliasPeak = 0.0
        for i in 256..<(aliasOut.count - 256) {
            aliasPeak = max(aliasPeak, abs(aliasOut[i]))
        }
        let aliasRejectionDB = AudioMath.linearToDB(aliasPeak)
        c.expect(aliasRejectionDB < -90.0, "SincResampler alias rejection (\(aliasRejectionDB) dB) < -90 dB")

        // 2. BiquadFilter & ParametricEQ frequency response.
        let sr = 48_000.0
        let lp = BiquadFilter(type: .lowPass(frequency: 1000.0, q: 0.70710678), sampleRate: sr, channelCount: 1)
        func measureFilterGainDB(_ node: any AudioNode, freq: Double) -> Double {
            node.reset()
            let n = 4800
            let inStore = AudioBufferStorage(frameCapacity: n, channelCount: 1)
            let outStore = AudioBufferStorage(frameCapacity: n, channelCount: 1)
            var input = [Double](repeating: 0, count: n)
            for i in 0..<n { input[i] = Math.sin(2.0 * Double.pi * freq * Double(i) / sr) }
            inStore.copyFrom(input)
            node.process(input: inStore.view, output: outStore.view, frameCount: n, sampleRate: sr)
            let amp = AudioMetrics.toneMagnitude(signal: outStore.toArray(), sampleRate: sr, frequencyHz: freq, skipEdgeSamples: 1200)
            return AudioMath.linearToDB(amp)
        }
        let lpPass = measureFilterGainDB(lp, freq: 100.0)
        let lpStop = measureFilterGainDB(lp, freq: 10_000.0)
        c.expectClose(lpPass, 0.0, tolerance: 0.1, "LPF unity passband at 100 Hz")
        c.expect(lpStop < -38.0, "LPF strong stopband attenuation at 10 kHz (\(lpStop) dB)")

        let eq = ParametricEQ(
            bands: [
                .peaking(frequency: 1000.0, q: 2.0, gainDB: 6.0),
                .peaking(frequency: 4000.0, q: 2.0, gainDB: -6.0),
            ],
            sampleRate: sr,
            channelCount: 1
        )
        c.expectClose(measureFilterGainDB(eq, freq: 1000.0), 6.0, tolerance: 0.25, "ParametricEQ +6 dB peak at 1 kHz")
        c.expectClose(measureFilterGainDB(eq, freq: 4000.0), -6.0, tolerance: 0.25, "ParametricEQ -6 dB cut at 4 kHz")
        c.expectClose(measureFilterGainDB(eq, freq: 100.0), 0.0, tolerance: 0.2, "ParametricEQ unity away from bands")

        // 3. TPDFDither: distribution, noise floor, and harmonic-free low-level quantization.
        let dither = TPDFDither(targetBitDepth: 16, noiseShaping: false, channelCount: 1)
        var tSum = 0.0, tSq = 0.0
        let tCount = 20_000
        for _ in 0..<tCount {
            let v = dither.nextTriangular()
            tSum += v
            tSq += v * v
        }
        c.expectClose(tSum / Double(tCount), 0.0, tolerance: 0.02, "TPDF mean near 0")
        c.expectClose(tSq / Double(tCount), 1.0 / 6.0, tolerance: 0.02, "TPDF variance near 1/6")

        dither.reset()
        let lowAmp = AudioMath.dbToLinear(-60.0)
        let ditherN = 8192
        var dithered = [Double](repeating: 0, count: ditherN)
        for i in 0..<ditherN {
            let s = lowAmp * Math.sin(2.0 * Double.pi * 1000.0 * Double(i) / sr)
            dithered[i] = dither.ditherSample(s, channel: 0)
        }
        let ditherMetrics = AudioMetrics.measureTHDN(signal: dithered, sampleRate: sr, fundamentalHz: 1000.0)
        let noiseFloorDB = AudioMath.linearToDB(ditherMetrics.residualRMS)
        c.expectClose(ditherMetrics.fundamentalAmplitude, lowAmp, tolerance: lowAmp * 0.05, "TPDF preserves -60 dBFS tone amplitude")
        // Theoretical TPDF 16-bit RMS noise floor: sqrt(1/12 + 1/6) * 2^-15 = 2^-16 = -96.33 dBFS.
        c.expectClose(noiseFloorDB, -96.33, tolerance: 0.5, "TPDF 16-bit noise floor near theoretical -96.33 dBFS")
        // Verify 3rd harmonic (3 kHz) is completely decorrelated below -108 dBFS.
        let thirdHarmonicDB = AudioMath.linearToDB(AudioMetrics.toneMagnitude(signal: dithered, sampleRate: sr, frequencyHz: 3000.0))
        c.expect(thirdHarmonicDB < -108.0, "TPDF eliminates 3rd harmonic distortion (\(thirdHarmonicDB) dBFS)")

        // 4. EBU R128 LoudnessMeter & TruePeakLimiter.
        let meter = LoudnessMeter(sampleRate: sr, channelCount: 2)
        let refAmp = AudioMath.dbToLinear(-23.0) // -23 dBFS peak stereo 1 kHz sine -> -23.0 LUFS
        let durFrames = 48_000 // 1.0 s
        var calSignal = [Double](repeating: 0, count: durFrames * 2)
        for i in 0..<durFrames {
            let v = refAmp * Math.sin(2.0 * Double.pi * 1000.0 * Double(i) / sr)
            calSignal[i * 2] = v
            calSignal[i * 2 + 1] = v
        }
        meter.process(calSignal)
        c.expectClose(meter.integratedLUFS, -23.0, tolerance: 0.2, "EBU R128 calibrated -23 dBFS stereo 1 kHz sine")
        c.expectClose(meter.replayGainDB(targetLUFS: -18.0), 5.0, tolerance: 0.2, "ReplayGain to -18 LUFS")

        // True-peak limiter on hot +4 dBFS inter-sample-peaking 12 kHz signal.
        let limiter = TruePeakLimiter(ceilingDB: -1.0, lookaheadMs: 5.0, releaseMs: 40.0, sampleRate: sr, channelCount: 2)
        let hotFrames = 4800
        let hotIn = AudioBufferStorage(frameCapacity: hotFrames, channelCount: 2)
        let hotOut = AudioBufferStorage(frameCapacity: hotFrames, channelCount: 2)
        var hotArr = [Double](repeating: 0, count: hotFrames * 2)
        let hotGain = AudioMath.dbToLinear(4.0)
        for i in 0..<hotFrames {
            let v = hotGain * Math.sin(2.0 * Double.pi * 12_000.0 * Double(i) / sr + Double.pi * 0.25)
            hotArr[i * 2] = v
            hotArr[i * 2 + 1] = v
        }
        hotIn.copyFrom(hotArr)
        limiter.process(input: hotIn.view, output: hotOut.view, frameCount: hotFrames, sampleRate: sr)
        let limitedTruePeak = TruePeakLimiter.measureTruePeak(hotOut.toArray(), channels: 2)
        let limitedTruePeakDB = AudioMath.linearToDB(limitedTruePeak)
        c.expect(limitedTruePeakDB <= -0.95, "TruePeakLimiter holds output <= -1.0 dBTP (got \(limitedTruePeakDB) dBTP)")

        // 5. Crossfader equal-power energy conservation.
        for step in 0...10 {
            let t = Double(step) / 10.0
            let (gA, gB) = Crossfader.gains(position: t, curve: .equalPower)
            c.expectClose(gA * gA + gB * gB, 1.0, tolerance: 1e-12, "equal-power energy at t=\(t)")
            let (lA, lB) = Crossfader.gains(position: t, curve: .linear)
            c.expectClose(lA + lB, 1.0, tolerance: 1e-12, "linear sum at t=\(t)")
        }

        // 6. HeadphoneCrossfeed: exact mono preservation & frequency-dependent stereo crossfeed.
        let xfeed = HeadphoneCrossfeed(preset: .standard, sampleRate: sr)
        let xfFrames = 4800
        let xfIn = AudioBufferStorage(frameCapacity: xfFrames, channelCount: 2)
        let xfOut = AudioBufferStorage(frameCapacity: xfFrames, channelCount: 2)
        var mono = [Double](repeating: 0, count: xfFrames * 2)
        for i in 0..<xfFrames {
            let v = 0.7 * Math.sin(2.0 * Double.pi * 500.0 * Double(i) / sr) + 0.2 * Math.sin(2.0 * Double.pi * 5000.0 * Double(i) / sr)
            mono[i * 2] = v
            mono[i * 2 + 1] = v
        }
        xfIn.copyFrom(mono)
        xfeed.process(input: xfIn.view, output: xfOut.view, frameCount: xfFrames, sampleRate: sr)
        let monoNull = AudioMetrics.nullDifferenceDB(a: mono, b: xfOut.toArray())
        c.expect(monoNull < -140.0, "HeadphoneCrossfeed preserves mono bit-accurately (\(monoNull) dB)")

        // Hard-panned left-only low (100 Hz) vs high (10 kHz) sine crossfeed into right channel.
        func rightChannelCrossfeedGain(freq: Double) -> Double {
            xfeed.reset()
            var hardLeft = [Double](repeating: 0, count: xfFrames * 2)
            for i in 0..<xfFrames {
                hardLeft[i * 2] = Math.sin(2.0 * Double.pi * freq * Double(i) / sr)
                hardLeft[i * 2 + 1] = 0.0
            }
            xfIn.copyFrom(hardLeft)
            xfeed.process(input: xfIn.view, output: xfOut.view, frameCount: xfFrames, sampleRate: sr)
            let outArr = xfOut.toArray()
            let rightOnly = (0..<xfFrames).map { outArr[$0 * 2 + 1] }
            return AudioMetrics.toneMagnitude(signal: rightOnly, sampleRate: sr, frequencyHz: freq, skipEdgeSamples: 1000)
        }
        let lowCross = rightChannelCrossfeedGain(freq: 100.0)
        let highCross = rightChannelCrossfeedGain(freq: 10_000.0)
        c.expect(lowCross > 0.30 && highCross < 0.05, "crossfeed passes lows (\(lowCross)) and attenuates highs (\(highCross))")

        // 7. AudioGraph end-to-end 64-bit float chain, bypass, gain, and metering.
        let graph = AudioGraph()
        let g1 = GainNode(name: "Boost", gain: 2.0)
        let g2 = GainNode(name: "Cut", gain: 0.5)
        graph.addNode(g1)
        graph.addNode(g2)
        graph.prepare(maxFrames: 512, channelCount: 2, sampleRate: sr)

        let srcBuf = AudioBufferStorage(frameCapacity: 512, channelCount: 2)
        let dstBuf = AudioBufferStorage(frameCapacity: 512, channelCount: 2)
        let testBlock = (0..<1024).map { i in 0.5 * Math.sin(2.0 * Double.pi * 440.0 * Double(i / 2) / sr) }
        srcBuf.copyFrom(testBlock)
        graph.render(source: srcBuf.view, destination: dstBuf.view, frameCount: 512)
        let graphNull = AudioMetrics.nullDifferenceDB(a: testBlock, b: dstBuf.toArray())
        c.expect(graphNull < -140.0, "AudioGraph 2x -> 0.5x chain nulls cleanly (\(graphNull) dB)")
        let meterSnap = graph.meterSnapshot()
        c.expectClose(meterSnap.peakLinear, 0.5, tolerance: 0.01, "AudioGraph peak meter tracks output")

        // Bypass g2 so only g1 (2x) runs -> peak becomes 1.0.
        graph.setBypassed(true, at: 1)
        graph.render(source: srcBuf.view, destination: dstBuf.view, frameCount: 512)
        c.expectClose(graph.meterSnapshot().peakLinear, 1.0, tolerance: 0.01, "AudioGraph bypass disables cut node")

        c.note("Resampler THD+N: up=\(thdnUp.thdnDB)dB, down=\(thdnDown.thdnDB)dB, alias=\(aliasRejectionDB)dB, LUFS=\(meter.integratedLUFS), TPL=\(limitedTruePeakDB)dBTP")
    },

    Check("gpu.atlas") { c in
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let mono = try TextReference.font(root: c.root, "JetBrainsMono-Regular.ttf")
        let atlas = GlyphAtlas(pageWidth: 256, pageHeight: 256, padding: 1, maxPages: 4, subpixelBuckets: 4)
        let device = RecordingGPUDevice(name: "AtlasTestGPU")

        let sampleText = "Polymer GPU Atlas 0123456789 ABCDEFG abcdefg !?@#$"
        var firstPassRegions: [AtlasRegion] = []
        for s in sampleText.unicodeScalars {
            let g1 = inter.glyph(for: s)
            let r1 = atlas.glyph(font: inter, glyphID: g1, pixelSize: 24, fractionalX: 0.25, luminance: 1.0)
            if !r1.isEmpty { firstPassRegions.append(r1) }

            let g2 = mono.glyph(for: s)
            let r2 = atlas.glyph(font: mono, glyphID: g2, pixelSize: 18, fractionalX: 0.0, luminance: 0.8)
            if !r2.isEmpty { firstPassRegions.append(r2) }
        }
        let missesAfterFirst = atlas.misses
        let hitsAfterFirst = atlas.hits
        c.expect(atlas.entryCount > 40, "packed > 40 distinct glyphs (\(atlas.entryCount))")

        // Second pass over exact same glyphs must be 100% cache hits returning identical regions.
        var secondPassRegions: [AtlasRegion] = []
        for s in sampleText.unicodeScalars {
            let r1 = atlas.glyph(font: inter, glyphID: inter.glyph(for: s), pixelSize: 24, fractionalX: 0.25, luminance: 1.0)
            if !r1.isEmpty { secondPassRegions.append(r1) }
            let r2 = atlas.glyph(font: mono, glyphID: mono.glyph(for: s), pixelSize: 18, fractionalX: 0.0, luminance: 0.8)
            if !r2.isEmpty { secondPassRegions.append(r2) }
        }
        c.expectEqual(atlas.misses, missesAfterFirst, "second pass has zero cache misses")
        c.expect(atlas.hits > hitsAfterFirst, "second pass increments cache hits")
        c.expectEqual(secondPassRegions, firstPassRegions, "cached regions match first pass")

        // Verify valid UVs, bounds within page, and NO overlapping rects with >= 1px padding on every page.
        let regions = atlas.allRegions
        for r in regions {
            let page = atlas.pages[r.pageIndex]
            c.expect(r.pixelRect.x >= atlas.padding && r.pixelRect.y >= atlas.padding, "region respects border padding")
            c.expect(r.pixelRect.x + r.pixelRect.width <= page.width && r.pixelRect.y + r.pixelRect.height <= page.height, "region inside page bounds")
            c.expect(r.u0 >= 0 && r.u0 < r.u1 && r.u1 <= 1, "valid U range")
            c.expect(r.v0 >= 0 && r.v0 < r.v1 && r.v1 <= 1, "valid V range")
        }
        var overlapOrPaddingViolations = 0
        for i in 0..<regions.count {
            for j in (i + 1)..<regions.count {
                let a = regions[i], b = regions[j]
                guard a.pageIndex == b.pageIndex else { continue }
                let pad = atlas.padding
                let separatedX = (a.pixelRect.x + a.pixelRect.width + pad <= b.pixelRect.x) ||
                                 (b.pixelRect.x + b.pixelRect.width + pad <= a.pixelRect.x)
                let separatedY = (a.pixelRect.y + a.pixelRect.height + pad <= b.pixelRect.y) ||
                                 (b.pixelRect.y + b.pixelRect.height + pad <= a.pixelRect.y)
                if !separatedX && !separatedY {
                    overlapOrPaddingViolations += 1
                }
            }
        }
        c.expectEqual(overlapOrPaddingViolations, 0, "zero overlapping or padding-violating glyph rects")

        // Flush to RecordingGPUDevice and confirm non-zero uploaded coverage bytes.
        atlas.flush(to: device)
        c.expect(!device.textures.isEmpty, "atlas allocated GPU texture")
        let nonZeroBytes = device.textures.values.reduce(0) { acc, tex in
            acc + tex.pixels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        }
        c.expect(nonZeroBytes > 1000, "uploaded glyph coverage has non-zero pixels (\(nonZeroBytes))")

        // Verify multi-page growth & eviction reset on a tiny atlas.
        let tinyAtlas = GlyphAtlas(pageWidth: 48, pageHeight: 48, padding: 1, maxPages: 2)
        for s in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".unicodeScalars {
            _ = tinyAtlas.glyph(font: inter, glyphID: inter.glyph(for: s), pixelSize: 22, fractionalX: 0, luminance: 1.0)
        }
        c.expectEqual(tinyAtlas.pages.count, 2, "tiny atlas grew to maxPages=2")
        c.expect(tinyAtlas.evictions >= 1, "tiny atlas evicted cleanly when full (\(tinyAtlas.evictions) evictions)")

        c.note("packed \(atlas.entryCount) glyphs across \(atlas.pages.count) page(s), hits=\(atlas.hits), misses=\(atlas.misses), inkBytes=\(nonZeroBytes)")
    },

    Check("gpu.batch-compiler") { c in
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let mono = try TextReference.font(root: c.root, "JetBrainsMono-Regular.ttf")

        // Build a 4x4 synthetic RenderImage.
        var imgBmp = Bitmap(width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let o = (y * 4 + x) * 4
                imgBmp.pixels[o] = UInt8(x * 80)
                imgBmp.pixels[o + 1] = UInt8(y * 80)
                imgBmp.pixels[o + 2] = 200
                imgBmp.pixels[o + 3] = 255
            }
        }
        let img = RenderImage(imgBmp)

        // Rich DisplayList exercising all 5 DisplayItem.Operation variants + clips + opacity + coalescing.
        let bg = Color(hex: 0x101012)
        var list = DisplayList(width: 320, height: 200, scale: 2)
        // Multiple consecutive solid rects -> should coalesce into a single batch!
        list.fill(Rect(x: 4, y: 4, width: 152, height: 92), Color(hex: 0x18181C))
        list.fill(Rect(x: 8, y: 8, width: 40, height: 12), Color(hex: 0x3A82F6))
        list.fill(Rect(x: 52, y: 8, width: 40, height: 12), Color(hex: 0x2A2A32))
        list.fill(Rect(x: 96, y: 8, width: 56, height: 12), Color(hex: 0x2A2A32))

        // Rounded rectangle & ellipse paths.
        list.fill(Path(roundedRect: Rect(x: 10, y: 26, width: 50, height: 24), cornerRadius: 6), Color(hex: 0xE25555))
        list.fill(Path(ellipseIn: Rect(x: 68, y: 26, width: 24, height: 24)), Color(hex: 0x55B87A))

        // Image with opacity modifier.
        list.withOpacity(0.8) { l in
            l.drawImage(img, in: Rect(x: 100, y: 26, width: 24, height: 24), opacity: 0.9, filter: .bilinear)
        }

        // Clipped text + rect sub-region.
        list.clipped(to: Rect(x: 8, y: 54, width: 140, height: 36)) { l in
            l.backdropBlur(Rect(x: 8, y: 54, width: 140, height: 36), radius: 3.0)
            l.fill(Rect(x: 8, y: 54, width: 140, height: 36), Color(white: 0.08, opacity: 0.5))
            let glyphs1 = TextLayout.line("Polymer GPU", font: inter, pixelSize: 13)
            l.drawGlyphs(glyphs1, font: inter, size: 13, at: Point(x: 12, y: 70), color: .white)
            let glyphs2 = TextLayout.line("03:42 96kHz", font: mono, pixelSize: 11)
            l.drawGlyphs(glyphs2, font: mono, size: 11, at: Point(x: 12, y: 84), color: Color(white: 0.78))
        }

        let compiler = DisplayListCompiler()
        let device = RecordingGPUDevice(name: "BatchCompilerTestGPU")
        let compiled = compiler.compile(list, device: device)

        // Encode and submit to RecordingGPUDevice.
        let pass = GPURenderPassDescriptor(
            viewport: PixelRect(x: 0, y: 0, width: list.width, height: list.height),
            loadAction: .clear(bg),
            storeAction: .store
        )
        let encoder = device.makeCommandEncoder(pass: pass)
        compiler.encode(frame: compiled, into: encoder, device: device)
        device.submit()

        // Verify batch coalescing reduces draw calls significantly below instance count.
        c.expect(compiled.totalInstances >= 25, "rich display list produces >= 25 instances (\(compiled.totalInstances))")
        c.expect(compiled.drawCallCount < compiled.totalInstances, "coalescing reduces draw calls (\(compiled.drawCallCount) < \(compiled.totalInstances))")
        c.expectEqual(device.drawCallCount, compiled.drawCallCount, "recorded GPU draw calls match compiled batches")
        c.expectEqual(device.totalInstanceCount, compiled.totalInstances, "recorded GPU instances match compiled instances")

        // Verify first 4 consecutive rects coalesced into 1 solidRect batch of 4 instances.
        c.expectEqual(compiled.batches.first?.kind, .solidRect, "first batch is solidRect")
        c.expectEqual(compiled.batches.first?.instances.count, 4, "4 consecutive rects coalesced into 1 draw call")

        // Verify all 5 quad kinds are present.
        let kinds = Set(compiled.batches.map(\.kind))
        c.expect(kinds.contains(.solidRect), "contains solidRect batch")
        c.expect(kinds.contains(.pathCoverage), "contains pathCoverage batch")
        c.expect(kinds.contains(.image), "contains image batch")
        c.expect(kinds.contains(.backdropBlur), "contains backdropBlur batch")
        c.expect(kinds.contains(.glyph), "contains glyph batch")

        // Verify every non-background pixel rendered by CPU Canvas is covered by the compiled GPU batches!
        let verification = GPUBatchVerifier.verify(displayList: list, compiledFrame: compiled, background: bg)
        c.expect(verification.canvasNonBackgroundPixels > 5000, "CPU Canvas drew substantial content (\(verification.canvasNonBackgroundPixels) px)")
        c.expectEqual(verification.clipViolationCount, 0, "zero clip/scissor mismatches")
        c.expectEqual(verification.uncoveredCanvasPixels, 0, "every CPU Canvas pixel is covered by compiled GPU batches")
        c.expect(verification.allCanvasPixelsCovered, "GPU batches fully cover CPU Canvas reference")

        c.note("instances=\(compiled.totalInstances), drawCalls=\(compiled.drawCallCount), canvasPx=\(verification.canvasNonBackgroundPixels), uncovered=\(verification.uncoveredCanvasPixels)")
    },
]
