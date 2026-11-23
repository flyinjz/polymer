// 64-bit float real-time audio graph.
// Strictly zero heap allocations, zero locks, and zero I/O on the render path.
import PolymerBase
import Synchronization

/// Describes an uncompressed PCM audio stream.
public struct AudioFormat: Equatable, Hashable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var bitDepth: Int

    public init(sampleRate: Double, channelCount: Int, bitDepth: Int = 64) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
    }
}

/// Non-owning, zero-allocation interleaved 64-bit float audio buffer view.
public struct AudioBufferView {
    public let samples: UnsafeMutableBufferPointer<Double>
    public let channelCount: Int
    public let frameCapacity: Int

    @inlinable
    public init(samples: UnsafeMutableBufferPointer<Double>, channelCount: Int, frameCapacity: Int) {
        self.samples = samples
        self.channelCount = channelCount
        self.frameCapacity = frameCapacity
    }

    @inlinable
    public subscript(frame: Int, channel: Int) -> Double {
        get { samples[frame * channelCount + channel] }
        nonmutating set { samples[frame * channelCount + channel] = newValue }
    }

    @inlinable
    public func silence(frameCount: Int) {
        let count = min(frameCount, frameCapacity) * channelCount
        guard count > 0, let base = samples.baseAddress else { return }
        for i in 0..<count {
            base[i] = 0.0
        }
    }

    @inlinable
    public func copy(from source: AudioBufferView, frameCount: Int) {
        let frames = min(frameCount, min(frameCapacity, source.frameCapacity))
        let count = frames * min(channelCount, source.channelCount)
        guard count > 0, let dst = samples.baseAddress, let src = source.samples.baseAddress else { return }
        if dst == src { return }
        if channelCount == source.channelCount {
            for i in 0..<count {
                dst[i] = src[i]
            }
        } else {
            let ch = min(channelCount, source.channelCount)
            for f in 0..<frames {
                let dOff = f * channelCount
                let sOff = f * source.channelCount
                for c in 0..<ch {
                    dst[dOff + c] = src[sOff + c]
                }
            }
        }
    }
}

/// Owning, pre-allocated contiguous 64-bit float audio buffer.
/// Allocate off the audio thread; pass `.view` into `AudioGraph.render`.
public final class AudioBufferStorage: @unchecked Sendable {
    public let channelCount: Int
    public let frameCapacity: Int
    private let buffer: UnsafeMutableBufferPointer<Double>

    public init(frameCapacity: Int, channelCount: Int) {
        precondition(frameCapacity >= 0 && channelCount > 0, "Invalid audio buffer dimensions")
        self.frameCapacity = frameCapacity
        self.channelCount = channelCount
        let total = max(1, frameCapacity * channelCount)
        let ptr = UnsafeMutablePointer<Double>.allocate(capacity: total)
        ptr.initialize(repeating: 0.0, count: total)
        self.buffer = UnsafeMutableBufferPointer(start: ptr, count: frameCapacity * channelCount)
    }

    deinit {
        if let base = buffer.baseAddress {
            base.deallocate()
        }
    }

    public var view: AudioBufferView {
        AudioBufferView(samples: buffer, channelCount: channelCount, frameCapacity: frameCapacity)
    }

    public func clear() {
        view.silence(frameCount: frameCapacity)
    }

    public func copyFrom(_ array: [Double]) {
        let count = min(array.count, buffer.count)
        guard count > 0, let dst = buffer.baseAddress else { return }
        array.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            for i in 0..<count { dst[i] = s[i] }
        }
    }

    public func toArray(frameCount: Int? = nil) -> [Double] {
        let frames = min(frameCount ?? frameCapacity, frameCapacity)
        let count = frames * channelCount
        var out = [Double](repeating: 0.0, count: count)
        guard count > 0, let src = buffer.baseAddress else { return out }
        out.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            for i in 0..<count { d[i] = src[i] }
        }
        return out
    }
}

/// Real-time 64-bit float audio processing node.
///
/// Implementations MUST perform zero heap allocations, zero locks, and zero I/O
/// inside `process(input:output:frameCount:sampleRate:)`.
public protocol AudioNode: AnyObject {
    var name: String { get }
    var isBypassed: Bool { get set }
    func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int)
    func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double)
    func reset()
}

extension AudioNode {
    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {}
}

/// Lock-free metering snapshot read from the UI or diagnostics thread.
public struct AudioMeterSnapshot: Equatable, Sendable {
    public var peakLinear: Double
    public var rmsLinear: Double
    public var peakDB: Double
    public var rmsDB: Double

    public init(peakLinear: Double, rmsLinear: Double) {
        self.peakLinear = peakLinear
        self.rmsLinear = rmsLinear
        self.peakDB = AudioMath.linearToDB(peakLinear)
        self.rmsDB = AudioMath.linearToDB(rmsLinear)
    }
}

/// Simple real-time linear gain node with atomic lock-free parameter updates.
public final class GainNode: AudioNode {
    public let name: String
    public var isBypassed: Bool = false
    private let gainBits: Atomic<UInt64>

    public var gain: Double {
        get { Double(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    public init(name: String = "Gain", gain: Double = 1.0) {
        self.name = name
        self.gainBits = Atomic<UInt64>(gain.bitPattern)
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        let g = Double(bitPattern: gainBits.load(ordering: .relaxed))
        let count = frameCount * input.channelCount
        guard count > 0, let src = input.samples.baseAddress, let dst = output.samples.baseAddress else { return }
        if g == 1.0 {
            if src != dst {
                for i in 0..<count { dst[i] = src[i] }
            }
            return
        }
        for i in 0..<count {
            dst[i] = src[i] * g
        }
    }

    public func reset() {}
}

/// Pre-allocated serial 64-bit float audio processing graph.
///
/// Configure nodes and call `prepare(maxFrames:channelCount:sampleRate:)` off
/// the audio thread. `render(source:destination:frameCount:)` executes with
/// zero heap allocations, zero locks, and zero I/O.
public final class AudioGraph {
    private var entries: [any AudioNode] = []
    private var scratchA: AudioBufferStorage?
    private var scratchB: AudioBufferStorage?

    public private(set) var maxFrames: Int = 0
    public private(set) var channelCount: Int = 2
    public private(set) var sampleRate: Double = 48_000.0

    private let masterGainBits = Atomic<UInt64>(1.0.bitPattern)
    private let meterPeakBits = Atomic<UInt64>(0.0.bitPattern)
    private let meterRMSBits = Atomic<UInt64>(0.0.bitPattern)

    public init() {}

    /// Master output linear gain (lock-free atomic update).
    public var masterGain: Double {
        get { Double(bitPattern: masterGainBits.load(ordering: .relaxed)) }
        set { masterGainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Number of nodes in the processing chain.
    public var nodeCount: Int { entries.count }

    /// Appends a processing node to the chain. Call off the audio thread.
    public func addNode(_ node: any AudioNode) {
        entries.append(node)
        if maxFrames > 0 {
            node.prepare(sampleRate: sampleRate, channelCount: channelCount, maxFrames: maxFrames)
        }
    }

    /// Removes all nodes from the chain. Call off the audio thread.
    public func removeAllNodes() {
        entries.removeAll()
    }

    /// Sets bypass state for a node by index.
    public func setBypassed(_ bypassed: Bool, at index: Int) {
        guard index >= 0 && index < entries.count else { return }
        entries[index].isBypassed = bypassed
    }

    /// Pre-allocates scratch buffers and prepares all nodes for real-time rendering.
    public func prepare(maxFrames: Int, channelCount: Int, sampleRate: Double) {
        precondition(maxFrames > 0 && channelCount > 0 && sampleRate > 0)
        self.maxFrames = maxFrames
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.scratchA = AudioBufferStorage(frameCapacity: maxFrames, channelCount: channelCount)
        self.scratchB = AudioBufferStorage(frameCapacity: maxFrames, channelCount: channelCount)
        for node in entries {
            node.prepare(sampleRate: sampleRate, channelCount: channelCount, maxFrames: maxFrames)
        }
    }

    /// Resets all node states and clears metering snapshots.
    public func reset() {
        for node in entries {
            node.reset()
        }
        meterPeakBits.store(0.0.bitPattern, ordering: .releasing)
        meterRMSBits.store(0.0.bitPattern, ordering: .releasing)
    }

    /// Reads the latest peak and RMS levels without locking.
    public func meterSnapshot() -> AudioMeterSnapshot {
        let peak = Double(bitPattern: meterPeakBits.load(ordering: .acquiring))
        let rms = Double(bitPattern: meterRMSBits.load(ordering: .acquiring))
        return AudioMeterSnapshot(peakLinear: peak, rmsLinear: rms)
    }

    /// Executes the audio graph for `frameCount` frames in 64-bit float.
    /// Real-time safe: zero heap allocations, zero locks, zero I/O.
    public func render(source: AudioBufferView, destination: AudioBufferView, frameCount: Int) {
        let frames = min(frameCount, min(maxFrames, min(source.frameCapacity, destination.frameCapacity)))
        guard frames > 0 else { return }

        // Count active (non-bypassed) nodes without allocating.
        var activeCount = 0
        for i in 0..<entries.count {
            if !entries[i].isBypassed {
                activeCount += 1
            }
        }

        if activeCount == 0 {
            destination.copy(from: source, frameCount: frames)
        } else if activeCount == 1 {
            for i in 0..<entries.count where !entries[i].isBypassed {
                entries[i].process(input: source, output: destination, frameCount: frames, sampleRate: sampleRate)
                break
            }
        } else {
            guard let bufA = scratchA?.view, let bufB = scratchB?.view else {
                destination.copy(from: source, frameCount: frames)
                return
            }
            var currentInput = source
            var useA = true
            var processed = 0
            for i in 0..<entries.count {
                let node = entries[i]
                if node.isBypassed { continue }
                processed += 1
                let isLast = (processed == activeCount)
                let currentOutput: AudioBufferView
                if isLast {
                    currentOutput = destination
                } else {
                    currentOutput = useA ? bufA : bufB
                    useA.toggle()
                }
                node.process(input: currentInput, output: currentOutput, frameCount: frames, sampleRate: sampleRate)
                currentInput = currentOutput
            }
        }

        // Apply master gain and update peak / RMS meters.
        let gain = Double(bitPattern: masterGainBits.load(ordering: .relaxed))
        let sampleCount = frames * destination.channelCount
        if sampleCount > 0, let dst = destination.samples.baseAddress {
            var peak = 0.0
            var sumSq = 0.0
            if gain == 1.0 {
                for i in 0..<sampleCount {
                    let s = dst[i]
                    let a = abs(s)
                    if a > peak { peak = a }
                    sumSq += s * s
                }
            } else {
                for i in 0..<sampleCount {
                    let s = dst[i] * gain
                    dst[i] = s
                    let a = abs(s)
                    if a > peak { peak = a }
                    sumSq += s * s
                }
            }
            let rms = (sumSq / Double(sampleCount)).squareRoot()
            meterPeakBits.store(peak.bitPattern, ordering: .releasing)
            meterRMSBits.store(rms.bitPattern, ordering: .releasing)
        }
    }
}
