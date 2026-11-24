// Real-time gapless playback engine bridging decoded audio tracks into
// lock-free SPSC ring buffers and the 64-bit float AudioGraph.
// Standard library + Synchronization only; renderOutput performs zero heap
// allocations, zero locks, and zero I/O.
import PolymerBase
import Synchronization

// MARK: - Playback State & Codec Hints

/// Transport state of `GaplessPlaybackEngine`.
public enum PlaybackState: Int, Equatable, Hashable, Sendable {
    case stopped = 0
    case playing = 1
    case paused = 2
    case ended = 3
}

/// Optional codec hint for `AudioTrackSource.decode(fromBytes:...)`.
public enum AudioCodecHint: Equatable, Hashable, Sendable {
    case auto
    case wav
    case aiff
    case flac
    case alac
    case mp3
}

/// Lock-free telemetry snapshot read safely from UI or diagnostic threads.
public struct PlaybackSnapshot: Equatable, Sendable {
    public var state: PlaybackState
    public var trackIndex: Int
    public var framePosition: Int
    public var totalFrames: Int
    public var peakL: Double
    public var peakR: Double
    public var rmsL: Double
    public var rmsR: Double
    public var underrunCount: Int
    public var trackChangeCount: Int

    public init(
        state: PlaybackState,
        trackIndex: Int,
        framePosition: Int,
        totalFrames: Int,
        peakL: Double,
        peakR: Double,
        rmsL: Double,
        rmsR: Double,
        underrunCount: Int,
        trackChangeCount: Int = 0
    ) {
        self.state = state
        self.trackIndex = trackIndex
        self.framePosition = framePosition
        self.totalFrames = totalFrames
        self.peakL = peakL
        self.peakR = peakR
        self.rmsL = rmsL
        self.rmsR = rmsR
        self.underrunCount = underrunCount
        self.trackChangeCount = trackChangeCount
    }
}

// MARK: - Audio Track Source

/// Represents a decoded or chunk-streamed PCM track queued for playback.
public struct AudioTrackSource: Sendable {
    public let id: String
    public let format: AudioFormat
    public let totalFrames: Int
    public let replayGainDB: Double?
    public let samples: [Double]

    private let chunkProvider: (@Sendable (Int, Int) -> ArraySlice<Double>)?

    /// Creates a track backed by an in-memory interleaved 64-bit float PCM array.
    public init(
        id: String,
        format: AudioFormat,
        samples: [Double],
        replayGainDB: Double? = nil
    ) {
        self.id = id
        self.format = format
        self.totalFrames = format.channelCount > 0 ? (samples.count / format.channelCount) : 0
        self.replayGainDB = replayGainDB
        self.samples = samples
        self.chunkProvider = nil
    }

    /// Creates a track backed by a chunked PCM provider `(startFrame, frameCount) -> ArraySlice<Double>`.
    public init(
        id: String,
        format: AudioFormat,
        totalFrames: Int,
        replayGainDB: Double? = nil,
        provider: @escaping @Sendable (Int, Int) -> ArraySlice<Double>
    ) {
        self.id = id
        self.format = format
        self.totalFrames = max(0, totalFrames)
        self.replayGainDB = replayGainDB
        self.samples = []
        self.chunkProvider = provider
    }

    /// Reads interleaved PCM samples for `[startFrame ..< startFrame + frameCount]`.
    public func readFrames(startFrame: Int, frameCount: Int) -> ArraySlice<Double> {
        guard startFrame >= 0, frameCount > 0, startFrame < totalFrames else {
            return ArraySlice<Double>()
        }
        let clamped = min(frameCount, totalFrames - startFrame)
        if let provider = chunkProvider {
            return provider(startFrame, clamped)
        }
        let ch = format.channelCount
        let startIdx = startFrame * ch
        let endIdx = min(samples.count, (startFrame + clamped) * ch)
        guard startIdx < endIdx else { return ArraySlice<Double>() }
        return samples[startIdx..<endIdx]
    }

    /// Decodes an audio file byte buffer (WAV, AIFF, FLAC, ALAC/M4A, or MP3) into an `AudioTrackSource`.
    public static func decode(
        fromBytes data: [UInt8],
        id: String = "",
        replayGainDB: Double? = nil,
        formatHint: AudioCodecHint = .auto
    ) throws(AudioDecoderError) -> AudioTrackSource {
        let resolved: AudioCodecHint
        if formatHint == .auto {
            resolved = detectCodec(in: data)
        } else {
            resolved = formatHint
        }

        let decoded: DecodedAudio
        switch resolved {
        case .wav:
            decoded = try WAVDecoder.decode(data)
        case .aiff:
            decoded = try AIFFDecoder.decode(data)
        case .flac:
            decoded = try FLACDecoder.decode(data)
        case .alac:
            decoded = try ALACDecoder.decodeM4A(data)
        case .mp3:
            decoded = try MP3Decoder.decode(data)
        case .auto:
            throw AudioDecoderError.unsupportedFormat("unable to detect audio format from input bytes")
        }

        return AudioTrackSource(
            id: id,
            format: decoded.format,
            samples: decoded.samples,
            replayGainDB: replayGainDB
        )
    }

    private static func detectCodec(in data: [UInt8]) -> AudioCodecHint {
        guard data.count >= 4 else { return .auto }
        let tag = String(decoding: data[0..<4], as: UTF8.self)
        if tag == "RIFF" && data.count >= 12 && String(decoding: data[8..<12], as: UTF8.self) == "WAVE" {
            return .wav
        }
        if tag == "FORM" && data.count >= 12 {
            let form = String(decoding: data[8..<12], as: UTF8.self)
            if form == "AIFF" || form == "AIFC" { return .aiff }
        }
        if tag == "fLaC" {
            return .flac
        }
        if data.count >= 8 && String(decoding: data[4..<8], as: UTF8.self) == "ftyp" {
            return .alac
        }
        if data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 { // "ID3"
            return .mp3
        }
        if MP3FrameHeader.parse(from: data, at: 0) != nil {
            return .mp3
        }
        return .auto
    }
}

// MARK: - Internal Boundary Telemetry Event

private struct TrackBoundaryEvent: Sendable {
    var streamFrame: Int
    var trackIndex: Int
    var totalFrames: Int
    var initialTrackFrame: Int
}

// MARK: - Gapless Playback Engine

/// Real-time gapless playback controller bridging a playlist of `AudioTrackSource`s
/// into pre-allocated lock-free `SPSCRingBuffer<Double>` read-ahead queues and `AudioGraph`.
///
/// Threading contract:
/// - Control & decode methods (`setQueue`, `enqueue`, `play`, `pause`, `stop`, `seek`,
///   `nextTrack`, `previousTrack`, `pumpReadAhead`) are called off the audio thread.
/// - `renderOutput(into:frameCount:)` is real-time safe (zero heap allocations, zero locks,
///   zero I/O) and may execute concurrently on a real-time audio callback thread.
/// - `snapshot()` is lock-free and safe to call from any thread.
public final class GaplessPlaybackEngine: @unchecked Sendable {
    public let outputFormat: AudioFormat
    public let maxCallbackFrames: Int
    public let audioGraph: AudioGraph

    public var enableReplayGain: Bool = false
    public var replayGainPreampDB: Double = 0.0
    public var crossfadeSeconds: Double = 0.0
    public var crossfadeCurve: CrossfadeCurve = .equalPower

    // Playlist & producer-side cursor (control/decode thread only).
    public private(set) var queue: [AudioTrackSource] = []
    private var producerTrackIndex: Int = 0
    private var producerFrameCursor: Int = 0
    private var producerStreamFramesWritten: Int = 0
    private var activeResampler: SincResampler?
    private var resamplerTrackIndex: Int = -1
    private var resamplerPendingOut: [Double] = []
    private var resamplerPendingOffset: Int = 0
    private var producerChunkScratch: [Double] = []
    private var resamplerInScratch: [Double] = []
    private var resamplerOutScratch: [Double] = []

    // Ping-pong pre-allocated SPSC ring buffers so seek/reset never race with renderOutput.
    private let ringBuffers: (SPSCRingBuffer<Double>, SPSCRingBuffer<Double>)
    private let boundaryRings: (SPSCRingBuffer<TrackBoundaryEvent>, SPSCRingBuffer<TrackBoundaryEvent>)
    private let activeRingIndex = Atomic<Int>(0)
    private let activeRingGeneration = Atomic<Int>(0)
    private let consumerReadingRing = Atomic<Int>(-1)
    private let producerEndOfStream = Atomic<Bool>(false)
    private let seekInitialTrackFrame = Atomic<Int>(0)

    // Pre-allocated audio-thread scratch buffer and audio-thread-only consumer cursors.
    private let pullScratch: AudioBufferStorage
    private var consumerGeneration: Int = 0
    private var consumedStreamFrames: Int = 0
    private var consumerTrackFrame: Int = 0
    private var pendingBoundary: TrackBoundaryEvent? = nil

    // Lock-free atomic transport & telemetry state.
    private let stateRaw = Atomic<Int>(PlaybackState.stopped.rawValue)
    private let atomicSeekTarget = Atomic<Int>(-1)
    private let currentTrackIndexAtomic = Atomic<Int>(0)
    private let currentFramePositionAtomic = Atomic<Int>(0)
    private let currentTotalFramesAtomic = Atomic<Int>(0)
    private let trackChangeCounter = Atomic<Int>(0)
    private let underrunCounter = Atomic<Int>(0)
    private let peakLBits = Atomic<UInt64>(0.0.bitPattern)
    private let peakRBits = Atomic<UInt64>(0.0.bitPattern)
    private let rmsLBits = Atomic<UInt64>(0.0.bitPattern)
    private let rmsRBits = Atomic<UInt64>(0.0.bitPattern)

    public init(
        outputFormat: AudioFormat = AudioFormat(sampleRate: 48_000.0, channelCount: 2, bitDepth: 64),
        readAheadFrames: Int = 16_384,
        maxCallbackFrames: Int = 4096,
        audioGraph: AudioGraph = AudioGraph()
    ) {
        precondition(outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 && maxCallbackFrames > 0)
        self.outputFormat = outputFormat
        self.maxCallbackFrames = maxCallbackFrames
        self.audioGraph = audioGraph
        self.audioGraph.prepare(
            maxFrames: maxCallbackFrames,
            channelCount: outputFormat.channelCount,
            sampleRate: outputFormat.sampleRate
        )

        let ringSamples = max(maxCallbackFrames * 2, readAheadFrames) * outputFormat.channelCount
        self.ringBuffers = (
            SPSCRingBuffer<Double>(minimumCapacity: ringSamples),
            SPSCRingBuffer<Double>(minimumCapacity: ringSamples)
        )
        self.boundaryRings = (
            SPSCRingBuffer<TrackBoundaryEvent>(minimumCapacity: 64),
            SPSCRingBuffer<TrackBoundaryEvent>(minimumCapacity: 64)
        )
        self.pullScratch = AudioBufferStorage(frameCapacity: maxCallbackFrames, channelCount: outputFormat.channelCount)
        self.producerChunkScratch = [Double](repeating: 0.0, count: 1024 * outputFormat.channelCount)
        self.resamplerInScratch = [Double](repeating: 0.0, count: 512 * outputFormat.channelCount)
        self.resamplerOutScratch = [Double](repeating: 0.0, count: 2048 * outputFormat.channelCount)
    }

    /// Current transport state (lock-free atomic load).
    public var state: PlaybackState {
        PlaybackState(rawValue: stateRaw.load(ordering: .acquiring)) ?? .stopped
    }

    /// Current track index (lock-free atomic load).
    public var currentTrackIndex: Int {
        currentTrackIndexAtomic.load(ordering: .acquiring)
    }

    /// Number of gapless/crossfaded track transitions observed so far.
    public var trackChangeCount: Int {
        trackChangeCounter.load(ordering: .acquiring)
    }

    /// Number of buffer underruns observed during playback.
    public var underrunCount: Int {
        underrunCounter.load(ordering: .acquiring)
    }

    /// Number of frames currently buffered in the active read-ahead ring buffer.
    public var bufferedFrames: Int {
        let ring = activeRing()
        return ring.availableToRead / outputFormat.channelCount
    }

    /// Replaces the playlist queue and resets playback position to the start of `startIndex`.
    public func setQueue(_ tracks: [AudioTrackSource], startIndex: Int = 0) {
        queue = tracks
        let clampedIdx = tracks.isEmpty ? 0 : min(max(0, startIndex), tracks.count - 1)
        resetStreamPosition(trackIndex: clampedIdx, frame: 0, prefill: false)
    }

    /// Appends a track to the end of the playlist queue.
    public func enqueue(_ track: AudioTrackSource) {
        let wasEmpty = queue.isEmpty
        queue.append(track)
        if wasEmpty {
            resetStreamPosition(trackIndex: 0, frame: 0, prefill: false)
        } else {
            producerEndOfStream.store(false, ordering: .releasing)
        }
    }

    /// Starts or resumes playback.
    public func play() {
        guard !queue.isEmpty else { return }
        if state == .ended {
            resetStreamPosition(trackIndex: 0, frame: 0, prefill: true)
        }
        stateRaw.store(PlaybackState.playing.rawValue, ordering: .releasing)
    }

    /// Pauses playback while preserving buffered position for instantaneous resume.
    public func pause() {
        if state == .playing {
            stateRaw.store(PlaybackState.paused.rawValue, ordering: .releasing)
        }
    }

    /// Stops playback and rewinds to frame 0 of the current track.
    public func stop() {
        stateRaw.store(PlaybackState.stopped.rawValue, ordering: .releasing)
        resetStreamPosition(trackIndex: min(currentTrackIndex, max(0, queue.count - 1)), frame: 0, prefill: false)
        audioGraph.reset()
        clearMeters()
    }

    /// Seeks to `frame` within `trackIndex` (or the current track if `nil`).
    /// Swaps the ping-pong read-ahead ring buffer lock-free so the very next `renderOutput`
    /// begins immediately at the seek target without racing the audio thread.
    public func seek(toFrame frame: Int, trackIndex: Int? = nil) {
        guard !queue.isEmpty else { return }
        let targetTrack = min(max(0, trackIndex ?? currentTrackIndex), queue.count - 1)
        let clampedFrame = min(max(0, frame), queue[targetTrack].totalFrames)
        atomicSeekTarget.store(clampedFrame, ordering: .releasing)
        resetStreamPosition(trackIndex: targetTrack, frame: clampedFrame, prefill: true)
        atomicSeekTarget.store(-1, ordering: .releasing)
    }

    /// Advances to the next queued track (if available).
    public func nextTrack() {
        let next = currentTrackIndex + 1
        guard next < queue.count else { return }
        trackChangeCounter.wrappingAdd(1, ordering: .relaxed)
        seek(toFrame: 0, trackIndex: next)
    }

    /// Returns to the previous queued track (if available).
    public func previousTrack() {
        let prev = max(0, currentTrackIndex - 1)
        if prev != currentTrackIndex {
            trackChangeCounter.wrappingAdd(1, ordering: .relaxed)
        }
        seek(toFrame: 0, trackIndex: prev)
    }

    /// Returns a lock-free snapshot of transport state, position, metering, and underrun telemetry.
    public func snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            state: state,
            trackIndex: currentTrackIndexAtomic.load(ordering: .acquiring),
            framePosition: currentFramePositionAtomic.load(ordering: .acquiring),
            totalFrames: currentTotalFramesAtomic.load(ordering: .acquiring),
            peakL: Double(bitPattern: peakLBits.load(ordering: .acquiring)),
            peakR: Double(bitPattern: peakRBits.load(ordering: .acquiring)),
            rmsL: Double(bitPattern: rmsLBits.load(ordering: .acquiring)),
            rmsR: Double(bitPattern: rmsRBits.load(ordering: .acquiring)),
            underrunCount: underrunCounter.load(ordering: .acquiring),
            trackChangeCount: trackChangeCounter.load(ordering: .acquiring)
        )
    }

    // MARK: Producer Read-Ahead (Off Audio Thread)

    /// Pumps decoded audio from the playlist into the read-ahead `SPSCRingBuffer<Double>`.
    /// Call periodically off the audio thread (or before `renderOutput` in deterministic tests).
    /// Returns the number of output frames written during this call.
    @discardableResult
    public func pumpReadAhead(maxFrames: Int = .max) -> Int {
        let idx = activeRingIndex.load(ordering: .acquiring)
        return pump(into: ring(at: idx), boundaries: boundaryRing(at: idx), maxFrames: maxFrames)
    }

    private func resetStreamPosition(trackIndex: Int, frame: Int, prefill: Bool) {
        let currentIdx = activeRingIndex.load(ordering: .acquiring)
        let nextIdx = 1 - currentIdx
        // Wait only if an active audio callback is currently reading the inactive ring.
        while consumerReadingRing.load(ordering: .acquiring) == nextIdx {}

        let nextRing = ring(at: nextIdx)
        let nextBoundaries = boundaryRing(at: nextIdx)
        nextRing.reset()
        nextBoundaries.reset()

        producerTrackIndex = trackIndex
        producerFrameCursor = frame
        producerStreamFramesWritten = 0
        activeResampler = nil
        resamplerTrackIndex = -1
        resamplerPendingOut.removeAll(keepingCapacity: true)
        resamplerPendingOffset = 0
        producerEndOfStream.store(queue.isEmpty, ordering: .releasing)

        let total = (trackIndex >= 0 && trackIndex < queue.count) ? outputFrameCount(for: queue[trackIndex]) : 0
        currentTrackIndexAtomic.store(trackIndex, ordering: .releasing)
        currentFramePositionAtomic.store(frame, ordering: .releasing)
        currentTotalFramesAtomic.store(total, ordering: .releasing)
        seekInitialTrackFrame.store(frame, ordering: .releasing)

        if prefill && !queue.isEmpty {
            _ = pump(into: nextRing, boundaries: nextBoundaries, maxFrames: .max)
        }

        activeRingIndex.store(nextIdx, ordering: .releasing)
        activeRingGeneration.wrappingAdd(1, ordering: .releasing)
    }

    private func pump(
        into ring: SPSCRingBuffer<Double>,
        boundaries: SPSCRingBuffer<TrackBoundaryEvent>,
        maxFrames: Int
    ) -> Int {
        let ch = outputFormat.channelCount
        guard ch > 0, maxFrames > 0 else { return 0 }
        if queue.isEmpty {
            producerEndOfStream.store(true, ordering: .releasing)
            return 0
        }

        var framesWrittenTotal = 0

        // First flush any previously resampled overflow frames.
        if resamplerPendingOffset < resamplerPendingOut.count {
            let remainingSamples = resamplerPendingOut.count - resamplerPendingOffset
            let maxSamples = min(remainingSamples, min(ring.availableToWrite, (maxFrames - framesWrittenTotal) * ch))
            let alignedSamples = (maxSamples / ch) * ch
            if alignedSamples > 0 {
                let written = resamplerPendingOut.withUnsafeBufferPointer { buf in
                    let slice = UnsafeBufferPointer(
                        start: buf.baseAddress?.advanced(by: resamplerPendingOffset),
                        count: alignedSamples
                    )
                    return ring.write(from: slice)
                }
                resamplerPendingOffset += written
                let wf = written / ch
                framesWrittenTotal += wf
                producerStreamFramesWritten += wf
            }
            if resamplerPendingOffset < resamplerPendingOut.count {
                return framesWrittenTotal
            }
            resamplerPendingOut.removeAll(keepingCapacity: true)
            resamplerPendingOffset = 0
        }

        while framesWrittenTotal < maxFrames {
            let freeFrames = min(ring.availableToWrite / ch, maxFrames - framesWrittenTotal)
            if freeFrames <= 0 { break }

            guard producerTrackIndex < queue.count else {
                producerEndOfStream.store(true, ordering: .releasing)
                break
            }

            let track = queue[producerTrackIndex]
            let needsResample = abs(track.format.sampleRate - outputFormat.sampleRate) > 1e-6

            if needsResample {
                let written = pumpResampled(track: track, freeFrames: freeFrames, into: ring, boundaries: boundaries)
                framesWrittenTotal += written
                if written == 0 && producerTrackIndex < queue.count && ring.availableToWrite < ch {
                    break
                }
            } else {
                let written = pumpNativeRate(track: track, freeFrames: freeFrames, into: ring, boundaries: boundaries)
                framesWrittenTotal += written
                if written == 0 && producerTrackIndex < queue.count && ring.availableToWrite < ch {
                    break
                }
            }
        }

        return framesWrittenTotal
    }

    private func gainLinear(for track: AudioTrackSource) -> Double {
        guard enableReplayGain, let rgDB = track.replayGainDB else { return 1.0 }
        return AudioMath.dbToLinear(rgDB + replayGainPreampDB)
    }

    private func outputFrameCount(for track: AudioTrackSource) -> Int {
        if abs(track.format.sampleRate - outputFormat.sampleRate) <= 1e-6 {
            return track.totalFrames
        }
        return Int((Double(track.totalFrames) * outputFormat.sampleRate / track.format.sampleRate).rounded())
    }

    private func effectiveCrossfadeFrames(trackA: AudioTrackSource, trackB: AudioTrackSource) -> Int {
        guard crossfadeSeconds > 0.0 else { return 0 }
        // Crossfade requires matching native sample rates on both tracks.
        guard abs(trackA.format.sampleRate - outputFormat.sampleRate) <= 1e-6,
              abs(trackB.format.sampleRate - outputFormat.sampleRate) <= 1e-6 else {
            return 0
        }
        let requested = Int((crossfadeSeconds * outputFormat.sampleRate).rounded())
        guard requested > 0 else { return 0 }
        return min(requested, min(trackA.totalFrames / 2, trackB.totalFrames / 2))
    }

    private func pumpNativeRate(
        track: AudioTrackSource,
        freeFrames: Int,
        into ring: SPSCRingBuffer<Double>,
        boundaries: SPSCRingBuffer<TrackBoundaryEvent>
    ) -> Int {
        let ch = outputFormat.channelCount
        let nextTrack: AudioTrackSource? = (producerTrackIndex + 1 < queue.count) ? queue[producerTrackIndex + 1] : nil
        let fadeFrames = nextTrack.map { effectiveCrossfadeFrames(trackA: track, trackB: $0) } ?? 0
        let fadeStartFrame = track.totalFrames - fadeFrames

        // Handle empty tracks seamlessly.
        if producerFrameCursor >= track.totalFrames {
            advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
            return 0
        }

        let gainA = gainLinear(for: track)
        let chunkLimit = min(freeFrames, producerChunkScratch.count / ch)
        guard chunkLimit > 0 else { return 0 }

        if producerFrameCursor < fadeStartFrame {
            // Normal gapless segment before crossfade region (or entire track when fadeFrames == 0).
            let toRead = min(chunkLimit, fadeStartFrame - producerFrameCursor)
            let srcSlice = track.readFrames(startFrame: producerFrameCursor, frameCount: toRead)
            let srcCh = track.format.channelCount
            let actualFrames = srcCh > 0 ? min(toRead, srcSlice.count / srcCh) : 0
            guard actualFrames > 0 else {
                advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
                return 0
            }

            adaptAndGain(
                source: srcSlice,
                sourceChannels: srcCh,
                destination: &producerChunkScratch,
                destChannels: ch,
                frames: actualFrames,
                gain: gainA
            )
            let writtenSamples = producerChunkScratch.withUnsafeBufferPointer { buf in
                ring.write(from: UnsafeBufferPointer(start: buf.baseAddress, count: actualFrames * ch))
            }
            let writtenFrames = writtenSamples / ch
            producerFrameCursor += writtenFrames
            producerStreamFramesWritten += writtenFrames

            if fadeFrames == 0 && producerFrameCursor >= track.totalFrames {
                advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
            }
            return writtenFrames
        } else if let next = nextTrack, fadeFrames > 0 {
            // Active equal-power / linear crossfade region between `track` tail and `next` head.
            let remainingFade = track.totalFrames - producerFrameCursor
            let toMix = min(chunkLimit, remainingFade)
            let fadeStartOffset = producerFrameCursor - fadeStartFrame

            let sliceA = track.readFrames(startFrame: producerFrameCursor, frameCount: toMix)
            let sliceB = next.readFrames(startFrame: fadeStartOffset, frameCount: toMix)
            let chA = track.format.channelCount
            let chB = next.format.channelCount
            let framesA = chA > 0 ? (sliceA.count / chA) : 0
            let framesB = chB > 0 ? (sliceB.count / chB) : 0
            let actualFrames = min(toMix, min(framesA, framesB))
            guard actualFrames > 0 else {
                advanceProducerTrack(initialNextFrame: fadeFrames, boundaries: boundaries)
                return 0
            }

            let gainB = gainLinear(for: next)
            let invDen = fadeFrames > 1 ? (1.0 / Double(fadeFrames - 1)) : 0.0
            let baseA = sliceA.startIndex
            let baseB = sliceB.startIndex

            for f in 0..<actualFrames {
                let t = fadeFrames > 1 ? Double(fadeStartOffset + f) * invDen : 1.0
                let (gA, gB) = Crossfader.gains(position: t, curve: crossfadeCurve)
                let wA = gainA * gA
                let wB = gainB * gB
                let dstBase = f * ch
                for c in 0..<ch {
                    let sA = sampleAt(sliceA, base: baseA, frame: f, channel: c, srcChannels: chA, dstChannels: ch)
                    let sB = sampleAt(sliceB, base: baseB, frame: f, channel: c, srcChannels: chB, dstChannels: ch)
                    producerChunkScratch[dstBase + c] = sA * wA + sB * wB
                }
            }

            let writtenSamples = producerChunkScratch.withUnsafeBufferPointer { buf in
                ring.write(from: UnsafeBufferPointer(start: buf.baseAddress, count: actualFrames * ch))
            }
            let writtenFrames = writtenSamples / ch
            producerFrameCursor += writtenFrames
            producerStreamFramesWritten += writtenFrames

            if producerFrameCursor >= track.totalFrames {
                advanceProducerTrack(initialNextFrame: fadeFrames, boundaries: boundaries)
            }
            return writtenFrames
        } else {
            advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
            return 0
        }
    }

    private func pumpResampled(
        track: AudioTrackSource,
        freeFrames: Int,
        into ring: SPSCRingBuffer<Double>,
        boundaries: SPSCRingBuffer<TrackBoundaryEvent>
    ) -> Int {
        let ch = outputFormat.channelCount
        if resamplerTrackIndex != producerTrackIndex || activeResampler == nil {
            activeResampler = SincResampler(
                sourceRate: track.format.sampleRate,
                targetRate: outputFormat.sampleRate,
                channelCount: ch
            )
            resamplerTrackIndex = producerTrackIndex
        }
        guard let resampler = activeResampler else { return 0 }

        let gain = gainLinear(for: track)
        let inChunkFrames = min(512, max(0, track.totalFrames - producerFrameCursor))
        if inChunkFrames == 0 {
            activeResampler = nil
            resamplerTrackIndex = -1
            advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
            return 0
        }

        let srcSlice = track.readFrames(startFrame: producerFrameCursor, frameCount: inChunkFrames)
        let srcCh = track.format.channelCount
        let actualIn = srcCh > 0 ? min(inChunkFrames, srcSlice.count / srcCh) : 0
        guard actualIn > 0 else {
            activeResampler = nil
            resamplerTrackIndex = -1
            advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
            return 0
        }

        adaptAndGain(
            source: srcSlice,
            sourceChannels: srcCh,
            destination: &resamplerInScratch,
            destChannels: ch,
            frames: actualIn,
            gain: gain
        )

        let outCapFrames = resamplerOutScratch.count / ch
        let (consumed, produced) = resamplerInScratch.withUnsafeBufferPointer { inBuf in
            resamplerOutScratch.withUnsafeMutableBufferPointer { outBuf in
                resampler.process(
                    input: inBuf,
                    inputFrames: actualIn,
                    output: outBuf,
                    outputFrameCapacity: outCapFrames
                )
            }
        }
        producerFrameCursor += consumed

        let toWriteFrames = min(produced, freeFrames)
        var writtenFrames = 0
        if toWriteFrames > 0 {
            let writtenSamples = resamplerOutScratch.withUnsafeBufferPointer { buf in
                ring.write(from: UnsafeBufferPointer(start: buf.baseAddress, count: toWriteFrames * ch))
            }
            writtenFrames = writtenSamples / ch
            producerStreamFramesWritten += writtenFrames
        }

        if produced > writtenFrames {
            let leftoverStart = writtenFrames * ch
            let leftoverEnd = produced * ch
            resamplerPendingOut = Array(resamplerOutScratch[leftoverStart..<leftoverEnd])
            resamplerPendingOffset = 0
        }

        if producerFrameCursor >= track.totalFrames && resamplerPendingOut.isEmpty {
            activeResampler = nil
            resamplerTrackIndex = -1
            advanceProducerTrack(initialNextFrame: 0, boundaries: boundaries)
        }
        return writtenFrames
    }

    private func advanceProducerTrack(initialNextFrame: Int, boundaries: SPSCRingBuffer<TrackBoundaryEvent>) {
        producerTrackIndex += 1
        producerFrameCursor = initialNextFrame
        if producerTrackIndex < queue.count {
            let nextTotal = outputFrameCount(for: queue[producerTrackIndex])
            _ = boundaries.push(TrackBoundaryEvent(
                streamFrame: producerStreamFramesWritten,
                trackIndex: producerTrackIndex,
                totalFrames: nextTotal,
                initialTrackFrame: initialNextFrame
            ))
        } else {
            producerEndOfStream.store(true, ordering: .releasing)
        }
    }

    @inline(__always)
    private func sampleAt(
        _ slice: ArraySlice<Double>,
        base: Int,
        frame: Int,
        channel: Int,
        srcChannels: Int,
        dstChannels: Int
    ) -> Double {
        if srcChannels == dstChannels {
            return slice[base + frame * srcChannels + channel]
        } else if srcChannels == 1 {
            return slice[base + frame]
        } else if dstChannels == 1 {
            var sum = 0.0
            let off = base + frame * srcChannels
            for c in 0..<srcChannels { sum += slice[off + c] }
            return sum / Double(srcChannels)
        } else {
            return slice[base + frame * srcChannels + min(channel, srcChannels - 1)]
        }
    }

    private func adaptAndGain(
        source: ArraySlice<Double>,
        sourceChannels: Int,
        destination: inout [Double],
        destChannels: Int,
        frames: Int,
        gain: Double
    ) {
        let srcBase = source.startIndex
        if sourceChannels == destChannels {
            let total = frames * destChannels
            if gain == 1.0 {
                for i in 0..<total {
                    destination[i] = source[srcBase + i]
                }
            } else {
                for i in 0..<total {
                    destination[i] = source[srcBase + i] * gain
                }
            }
        } else {
            for f in 0..<frames {
                let dOff = f * destChannels
                for c in 0..<destChannels {
                    destination[dOff + c] = sampleAt(
                        source,
                        base: srcBase,
                        frame: f,
                        channel: c,
                        srcChannels: sourceChannels,
                        dstChannels: destChannels
                    ) * gain
                }
            }
        }
    }

    // MARK: Real-Time Audio Pull Path (ZERO Allocations, ZERO Locks, ZERO I/O)

    /// Real-time audio callback pull method.
    ///
    /// Pulls `frameCount` frames from the pre-allocated SPSC ring buffer into a pre-allocated
    /// scratch buffer, runs `audioGraph`, writes the result into `output`, and updates lock-free
    /// transport telemetry and per-channel peak/RMS meters.
    ///
    /// Strictly zero heap allocations, zero locks, and zero I/O.
    public func renderOutput(into output: AudioBufferView, frameCount: Int) {
        let frames = min(frameCount, min(maxCallbackFrames, output.frameCapacity))
        guard frames > 0 else { return }

        let currentState = stateRaw.load(ordering: .acquiring)
        if currentState != PlaybackState.playing.rawValue {
            output.silence(frameCount: frames)
            clearMeters()
            return
        }

        // Pin active ping-pong ring index so a concurrent seek cannot reset it mid-read.
        var idx = activeRingIndex.load(ordering: .acquiring)
        consumerReadingRing.store(idx, ordering: .releasing)
        let confirmedIdx = activeRingIndex.load(ordering: .acquiring)
        if confirmedIdx != idx {
            idx = confirmedIdx
            consumerReadingRing.store(idx, ordering: .releasing)
        }

        let gen = activeRingGeneration.load(ordering: .acquiring)
        if gen != consumerGeneration {
            consumerGeneration = gen
            consumedStreamFrames = 0
            consumerTrackFrame = seekInitialTrackFrame.load(ordering: .acquiring)
            pendingBoundary = nil
        }

        let ring = ring(at: idx)
        let boundaries = boundaryRing(at: idx)
        let ch = outputFormat.channelCount
        let neededSamples = frames * ch

        let scratchView = pullScratch.view
        var samplesRead = 0
        if let scratchBase = scratchView.samples.baseAddress {
            let slice = UnsafeMutableBufferPointer(start: scratchBase, count: neededSamples)
            samplesRead = ring.read(into: slice)
            if samplesRead < neededSamples {
                for i in samplesRead..<neededSamples {
                    scratchBase[i] = 0.0
                }
            }
        }

        let framesRead = ch > 0 ? (samplesRead / ch) : 0
        consumedStreamFrames += framesRead
        consumerTrackFrame += framesRead

        // Advance lock-free track boundary telemetry without allocating.
        while true {
            if pendingBoundary == nil {
                pendingBoundary = boundaries.pop()
            }
            guard let ev = pendingBoundary else { break }
            if ev.streamFrame <= consumedStreamFrames {
                currentTrackIndexAtomic.store(ev.trackIndex, ordering: .releasing)
                currentTotalFramesAtomic.store(ev.totalFrames, ordering: .releasing)
                trackChangeCounter.wrappingAdd(1, ordering: .relaxed)
                consumerTrackFrame = ev.initialTrackFrame + (consumedStreamFrames - ev.streamFrame)
                pendingBoundary = nil
            } else {
                break
            }
        }
        currentFramePositionAtomic.store(consumerTrackFrame, ordering: .releasing)

        // Distinguish true end-of-stream from real-time buffer underrun.
        if samplesRead < neededSamples {
            if producerEndOfStream.load(ordering: .acquiring) && ring.isEmpty {
                _ = stateRaw.compareExchange(
                    expected: PlaybackState.playing.rawValue,
                    desired: PlaybackState.ended.rawValue,
                    ordering: .acquiringAndReleasing
                )
            } else {
                underrunCounter.wrappingAdd(1, ordering: .relaxed)
            }
        }

        consumerReadingRing.store(-1, ordering: .releasing)

        // Run the 64-bit float AudioGraph (EQ / crossfeed / limiter / master gain).
        audioGraph.render(source: scratchView, destination: output, frameCount: frames)

        // Update lock-free stereo peak & RMS meters directly from output view.
        if let dst = output.samples.baseAddress {
            let outCh = output.channelCount
            var pL = 0.0
            var pR = 0.0
            var sumSqL = 0.0
            var sumSqR = 0.0
            if outCh >= 2 {
                for f in 0..<frames {
                    let base = f * outCh
                    let l = dst[base]
                    let r = dst[base + 1]
                    let al = abs(l)
                    let ar = abs(r)
                    if al > pL { pL = al }
                    if ar > pR { pR = ar }
                    sumSqL += l * l
                    sumSqR += r * r
                }
            } else {
                for f in 0..<frames {
                    let l = dst[f]
                    let al = abs(l)
                    if al > pL { pL = al }
                    sumSqL += l * l
                }
                pR = pL
                sumSqR = sumSqL
            }
            let invFrames = 1.0 / Double(frames)
            peakLBits.store(pL.bitPattern, ordering: .releasing)
            peakRBits.store(pR.bitPattern, ordering: .releasing)
            rmsLBits.store((sumSqL * invFrames).squareRoot().bitPattern, ordering: .releasing)
            rmsRBits.store((sumSqR * invFrames).squareRoot().bitPattern, ordering: .releasing)
        }
    }

    // MARK: Ring Access Helpers

    @inline(__always)
    private func ring(at index: Int) -> SPSCRingBuffer<Double> {
        index == 0 ? ringBuffers.0 : ringBuffers.1
    }

    @inline(__always)
    private func boundaryRing(at index: Int) -> SPSCRingBuffer<TrackBoundaryEvent> {
        index == 0 ? boundaryRings.0 : boundaryRings.1
    }

    @inline(__always)
    private func activeRing() -> SPSCRingBuffer<Double> {
        ring(at: activeRingIndex.load(ordering: .acquiring))
    }

    @inline(__always)
    private func clearMeters() {
        let z = 0.0.bitPattern
        peakLBits.store(z, ordering: .releasing)
        peakRBits.store(z, ordering: .releasing)
        rmsLBits.store(z, ordering: .releasing)
        rmsRBits.store(z, ordering: .releasing)
    }
}
