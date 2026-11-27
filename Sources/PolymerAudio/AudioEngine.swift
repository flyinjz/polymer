// The playback engine: a gapless queue of sources, decoded ahead on the
// output's feeder thread into a lock-free ring, rendered on its real-time
// thread with volume, pause and seek done as short gain ramps (no clicks).
//
// Threads:
// - UI (any thread but the real-time one): play, enqueue, seek, pause,
//   volume, position. Requests go through a Mutex to the feeder, or through
//   atomics to the real-time thread.
// - Feeder (`refill`): owns the sources and resamplers, writes the ring and
//   the track markers.
// - Real-time (`render`): only atomics and preallocated memory; no locks,
//   no allocation, no I/O.
//
// Everything is converted to the engine's format (the output's), so tracks
// of different rates and channel counts follow each other without a gap.
import PolymerBase
import PolymerPlatform
import Synchronization

/// What is being heard: the token the track was queued with and the time in it.
public struct PlaybackPosition: Sendable, Equatable {
    public var token: Int
    public var seconds: Double
}

public final class AudioEngine: AudioRenderer, @unchecked Sendable {
    /// The format rendered (the output's).
    public let format: AudioFormat

    // Decoded samples and where tracks start in them.
    let ring: SampleRing
    let markers = MarkerQueue()

    // UI to real-time.
    let volumeBits = Atomic<UInt32>(Float(1).bitPattern)
    let pausedFlag = Atomic<Bool>(false)
    let latency = Atomic<Int>(0)

    // Feeder to real-time.
    let flushEpoch = Atomic<Int>(0)
    let flushFrame = Atomic<Int>(0)
    /// Ring frame where the queue ends (no underrun is counted past it); Int.max while more is coming.
    let endFrame = Atomic<Int>(0)

    // Real-time to UI: a seqlock over the current and previous marker, plus the read position.
    let clockSeq = Atomic<Int>(0)
    let clockToken = Atomic<Int>(-1), clockStart = Atomic<Int>(0), clockSeconds = Atomic<UInt64>(0)
    let prevToken = Atomic<Int>(-1), prevStart = Atomic<Int>(0), prevSeconds = Atomic<UInt64>(0)
    let readFrame = Atomic<Int>(0)
    let holding = Atomic<Bool>(false)
    let underrunCount = Atomic<Int>(0)

    // Real-time thread only.
    private var rtRead = 0
    private var rtEpoch = 0
    private var rtGain: Float = 0
    private var rtJump = -1
    private var rtFadeOut = 0, rtFadeTotal = 1
    /// Frames for a full-scale gain change: about 5 ms at 48 kHz.
    static let rampFrames = 256
    /// Frames of fade-out before a seek or stop cuts the old audio.
    static let declickFrames = 64

    // UI to feeder.
    struct Entry: @unchecked Sendable { let source: any AudioSource; let token: Int }
    struct Control {
        var queue: [Entry] = []
        var replace = false
        var seek: (token: Int, seconds: Double)?
    }
    let control = Mutex<Control>(Control())

    // Feeder thread only.
    final class Track {
        let source: any AudioSource
        let token: Int
        let resampler: Resampler
        let input: UnsafeMutablePointer<Float>
        let output: UnsafeMutablePointer<Float>
        let mapped: UnsafeMutablePointer<Float>
        /// Source frames decoded at a time: about 512 output frames whatever the ratio.
        let chunk: Int
        let outCapacity: Int
        var finishing = false

        init(_ e: Entry, format: AudioFormat) {
            source = e.source; token = e.token
            let ch = max(1, e.source.format.channels)
            let rate = max(1, e.source.format.sampleRate)
            resampler = Resampler(from: rate, to: format.sampleRate, channels: ch)
            chunk = max(16, min(512, 512 * rate / max(1, format.sampleRate)))
            outCapacity = resampler.outputLength(forInput: chunk) + 2
            input = .allocate(capacity: chunk * ch)
            output = .allocate(capacity: outCapacity * ch)
            mapped = .allocate(capacity: outCapacity * format.channels)
        }
        deinit { input.deallocate(); output.deallocate(); mapped.deallocate() }
    }
    private var current: Track?
    /// The track before `current`, kept so a seek in what is still being heard can go back to it.
    private var recent: Track?

    /// - Parameter bufferSeconds: how far ahead the feeder decodes.
    public init(format: AudioFormat, bufferSeconds: Double = 0.5) {
        self.format = format
        let frames = Int(bufferSeconds * Double(format.sampleRate))
        ring = SampleRing(minimumFrames: max(frames, 8192), channels: max(1, format.channels))
    }

    /// Sets the latency from `output` and starts it rendering this engine.
    public func start(on output: any AudioOutput) throws(PlatformError) {
        guard output.format == format else {
            throw PlatformError("the engine renders \(format) but the output wants \(output.format); make the engine with AudioEngine(format: output.format)")
        }
        latency.store(output.latencyFrames, ordering: .relaxed)
        try output.start(self)
    }

    // MARK: Control (UI side)

    /// Replaces everything with `source`, from its start. `token` comes back in `position`.
    public func play(_ source: any AudioSource, token: Int) {
        control.withLock { c in
            c.queue = [Entry(source: source, token: token)]
            c.replace = true
            c.seek = nil
        }
    }

    /// Adds `source` after the last queued track, to follow it without a gap.
    public func enqueue(_ source: any AudioSource, token: Int) {
        control.withLock { c in c.queue.append(Entry(source: source, token: token)) }
    }

    /// Drops the tracks not yet started (the current one plays on).
    public func clearQueue() {
        control.withLock { c in c.queue.removeAll() }
    }

    /// Tracks waiting after the current one.
    public var queuedCount: Int { control.withLock { c in c.queue.count } }

    /// Stops and forgets every track.
    public func stop() {
        control.withLock { c in
            c.queue.removeAll()
            c.replace = true
            c.seek = nil
        }
    }

    /// Moves within the track being heard.
    public func seek(toSeconds seconds: Double) {
        guard let p = position else { return }
        control.withLock { c in c.seek = (p.token, max(0, seconds)) }
    }

    public var isPaused: Bool {
        get { pausedFlag.load(ordering: .relaxed) }
        set { pausedFlag.store(newValue, ordering: .relaxed) }
    }
    public func pause() { isPaused = true }
    public func resume() { isPaused = false }

    /// Linear gain, 0 to 4 (1 is unchanged). Changes ramp over about 5 ms.
    public var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(max(0, min(4, newValue.isNaN ? 0 : newValue)).bitPattern, ordering: .relaxed) }
    }

    /// Times the device asked for samples the feeder had not decoded yet.
    public var underruns: Int { underrunCount.load(ordering: .relaxed) }

    /// Frames between the engine's read position and the speaker.
    public var latencyFrames: Int {
        get { latency.load(ordering: .relaxed) }
        set { latency.store(max(0, newValue), ordering: .relaxed) }
    }

    /// What is being heard now; nil when nothing is playing.
    public var position: PlaybackPosition? {
        var token = -1, start = 0, seconds = 0.0, pToken = -1, pStart = 0, pSeconds = 0.0, read = 0, held = false
        while true {
            let s1 = clockSeq.load(ordering: .sequentiallyConsistent)
            if s1 & 1 != 0 { continue }
            token = clockToken.load(ordering: .sequentiallyConsistent)
            start = clockStart.load(ordering: .sequentiallyConsistent)
            seconds = Double(bitPattern: clockSeconds.load(ordering: .sequentiallyConsistent))
            pToken = prevToken.load(ordering: .sequentiallyConsistent)
            pStart = prevStart.load(ordering: .sequentiallyConsistent)
            pSeconds = Double(bitPattern: prevSeconds.load(ordering: .sequentiallyConsistent))
            read = readFrame.load(ordering: .sequentiallyConsistent)
            held = holding.load(ordering: .sequentiallyConsistent)
            if clockSeq.load(ordering: .sequentiallyConsistent) == s1 { break }
        }
        let rate = Double(format.sampleRate)
        let heard = held ? read : read - latency.load(ordering: .relaxed)
        if heard >= start || pToken < 0 || pToken == token {
            guard token >= 0 else { return nil }
            return PlaybackPosition(token: token, seconds: seconds + Double(max(0, heard - start)) / rate)
        }
        return PlaybackPosition(token: pToken, seconds: pSeconds + Double(max(0, heard - pStart)) / rate)
    }

    // MARK: Feeder

    public func refill() -> Bool {
        if markers.isFull { return false }
        let idle = current == nil
        let (replace, seek, entry) = control.withLock { c -> (Bool, (token: Int, seconds: Double)?, Entry?) in
            let r = c.replace
            c.replace = false
            let s = c.seek
            c.seek = nil
            var e: Entry?
            if (r || idle) && !c.queue.isEmpty { e = c.queue.removeFirst() }
            return (r, s, e)
        }
        if replace {
            recent = nil
            current = entry.map { Track($0, format: format) }
            flush(token: current?.token ?? -1, seconds: 0)
        } else if let e = entry {
            // Something queued while idle: it follows whatever is still in the ring.
            let t = Track(e, format: format)
            current = t
            endFrame.store(Int.max, ordering: .releasing)
            _ = markers.push(StreamMarker(frame: ring.written, token: t.token, seconds: 0))
        }
        if let s = seek {
            if let t = current, t.token == s.token {
                seekTrack(t, s.seconds)
            } else if let r = recent, r.token == s.token {
                // The heard track is the one before the feeder's: go back to it, and requeue the other from its start.
                if let c = current {
                    try? c.source.seek(toFrame: 0)
                    let back = Entry(source: c.source, token: c.token)
                    control.withLock { $0.queue.insert(back, at: 0) }
                }
                current = r
                recent = nil
                seekTrack(r, s.seconds)
            }
        }
        guard let t = current else { return false }
        if ring.freeFrames < 2 * t.outCapacity || markers.isFull { return false }

        let inCh = max(1, t.source.format.channels)
        if !t.finishing {
            let n = t.source.read(into: t.input, frames: t.chunk)
            if n > 0 {
                var consumed = 0
                while consumed < n {
                    let (c, p) = t.resampler.process(t.input + consumed * inCh, frames: n - consumed, into: t.output, capacity: t.outCapacity)
                    write(t, p)
                    consumed += c
                    if c == 0 && p == 0 { break }
                }
                return ring.freeFrames >= 2 * t.outCapacity
            }
            t.finishing = true
        }
        let m = t.resampler.finish(into: t.output, capacity: t.outCapacity)
        if m > 0 { write(t, m); return true }

        // The track has ended: the next follows at once, else the queue ends here.
        recent = t
        let next = control.withLock { c -> Entry? in c.queue.isEmpty ? nil : c.queue.removeFirst() }
        if let e = next {
            let nt = Track(e, format: format)
            current = nt
            _ = markers.push(StreamMarker(frame: ring.written, token: nt.token, seconds: 0))
            return true
        }
        current = nil
        _ = markers.push(StreamMarker(frame: ring.written, token: -1, seconds: 0))
        endFrame.store(ring.written, ordering: .releasing)
        return false
    }

    private func seekTrack(_ t: Track, _ seconds: Double) {
        let rate = Double(t.source.format.sampleRate)
        try? t.source.seek(toFrame: Int((seconds * rate).rounded()))
        t.resampler.reset()
        t.finishing = false
        flush(token: t.token, seconds: Double(t.source.position) / rate)
    }

    /// Makes the real-time side drop everything decoded so far and continue from here.
    private func flush(token: Int, seconds: Double) {
        let f = ring.written
        _ = markers.push(StreamMarker(frame: f, token: token, seconds: seconds))
        endFrame.store(token < 0 ? f : Int.max, ordering: .releasing)
        flushFrame.store(f, ordering: .releasing)
        flushEpoch.wrappingAdd(1, ordering: .releasing)
    }

    /// Maps `frames` resampled frames to the engine's channels and appends them.
    private func write(_ t: Track, _ frames: Int) {
        if frames == 0 { return }
        let sc = max(1, t.source.format.channels), dc = format.channels
        let src = t.output, dst = t.mapped
        if sc == dc {
            ring.write(src, frames: frames)
            return
        }
        for i in 0..<frames {
            let s = src + i * sc, d = dst + i * dc
            if sc == 1 {
                for c in 0..<dc { d[c] = s[0] }
            } else if dc == 1 {
                var sum: Float = 0
                for c in 0..<sc { sum += s[c] }
                d[0] = sum / Float(sc)
            } else {
                for c in 0..<dc { d[c] = c < sc ? s[c] : 0 }
            }
        }
        ring.write(dst, frames: frames)
    }

    // MARK: Real-time

    public func render(_ out: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let e = flushEpoch.load(ordering: .acquiring)
        if e != rtEpoch {
            rtEpoch = e
            rtJump = flushFrame.load(ordering: .acquiring)
            let stale = min(ring.available(from: rtRead), rtJump - rtRead)
            rtFadeOut = min(AudioEngine.declickFrames, max(0, stale))
            rtFadeTotal = max(1, rtFadeOut)
            // Already silent (paused or not started): no fade needed.
            if rtGain == 0 { rtFadeOut = 0 }
        }
        let paused = pausedFlag.load(ordering: .relaxed)
        let target = paused ? 0 : Float(bitPattern: volumeBits.load(ordering: .relaxed))
        let step = 1 / Float(AudioEngine.rampFrames)
        let rc = ring.channels
        var avail = ring.available(from: rtRead)
        var held = false
        var i = 0
        while i < frames {
            if rtJump >= 0 && rtFadeOut == 0 {
                rtRead = max(rtRead, rtJump)
                rtJump = -1
                rtGain = 0
                applyMarkers(afterJump: true)
                avail = ring.available(from: rtRead)
            }
            if rtJump < 0 && paused && rtGain == 0 { held = true; break }
            if avail <= 0 { break }
            if rtGain < target { rtGain = min(target, rtGain + step) } else if rtGain > target { rtGain = max(target, rtGain - step) }
            var g = rtGain
            if rtJump >= 0 {
                g *= Float(rtFadeOut) / Float(rtFadeTotal)
                rtFadeOut -= 1
            }
            let s = ring.pointer(at: rtRead)
            let d = out + i * channels
            if rc == channels {
                for c in 0..<channels { d[c] = s[c] * g }
            } else if rc == 1 {
                for c in 0..<channels { d[c] = s[0] * g }
            } else {
                for c in 0..<channels { d[c] = c < rc ? s[c] * g : 0 }
            }
            rtRead += 1
            avail -= 1
            i += 1
        }
        if i < frames {
            (out + i * channels).update(repeating: 0, count: (frames - i) * channels)
            if !held && rtJump < 0 && rtRead < endFrame.load(ordering: .acquiring) {
                underrunCount.wrappingAdd(1, ordering: .relaxed)
            }
        }
        ring.release(to: rtRead)
        if rtJump < 0 { applyMarkers(afterJump: false) }
        readFrame.store(rtRead, ordering: .sequentiallyConsistent)
        holding.store(held, ordering: .relaxed)
    }

    /// Takes every marker at or before the read position; the last one is the clock.
    private func applyMarkers(afterJump: Bool) {
        var changed = false
        var last = StreamMarker(frame: 0, token: -1, seconds: 0)
        var before = StreamMarker(frame: clockStart.load(ordering: .relaxed), token: clockToken.load(ordering: .relaxed),
                                  seconds: Double(bitPattern: clockSeconds.load(ordering: .relaxed)))
        while let m = markers.peek(), m.frame <= rtRead {
            if changed { before = last }
            last = m
            changed = true
            markers.pop()
        }
        guard changed else { return }
        // After a jump nothing of the old track is still to be heard.
        if afterJump { before = last }
        let s = clockSeq.load(ordering: .relaxed)
        clockSeq.store(s &+ 1, ordering: .sequentiallyConsistent)
        prevToken.store(before.token, ordering: .sequentiallyConsistent)
        prevStart.store(before.frame, ordering: .sequentiallyConsistent)
        prevSeconds.store(before.seconds.bitPattern, ordering: .sequentiallyConsistent)
        clockToken.store(last.token, ordering: .sequentiallyConsistent)
        clockStart.store(last.frame, ordering: .sequentiallyConsistent)
        clockSeconds.store(last.seconds.bitPattern, ordering: .sequentiallyConsistent)
        clockSeq.store(s &+ 2, ordering: .sequentiallyConsistent)
    }
}
