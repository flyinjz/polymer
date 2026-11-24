// macOS native audio output discovery backend using CoreAudio HAL properties.
#if os(macOS)
import CoreAudio
import AudioToolbox
import PolymerPlatform

public struct MacAudioOutputBackend: AudioOutputBackend {
    private static let candidateSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]

    public init() {}

    public func listDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        var readSize = dataSize
        let status = deviceIDs.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &readSize,
                base
            )
        }
        guard status == noErr else { return [] }

        let defaultID = defaultOutputDeviceID()
        var out: [AudioDeviceInfo] = []
        out.reserveCapacity(count)

        for deviceID in deviceIDs {
            guard hasOutputStreams(deviceID) else { continue }
            let name = deviceName(deviceID)
            let rates = availableSampleRates(deviceID)
            let channels = outputChannelCount(deviceID)
            out.append(AudioDeviceInfo(
                id: "coreaudio-\(deviceID)",
                name: name,
                isDefault: deviceID == defaultID,
                sampleRates: rates,
                channelCount: channels
            ))
        }

        return out
    }

    public func defaultDevice() -> AudioDeviceInfo? {
        let devices = listDevices()
        return devices.first(where: \.isDefault) ?? devices.first
    }

    private func defaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 2
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        var readSize = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &readSize, rawPtr) == noErr else {
            return 2
        }

        let listPtr = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        var total = 0
        for buffer in buffers {
            total += Int(buffer.mNumberChannels)
        }
        return max(1, total)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = cfName?.takeRetainedValue() else {
            return "CoreAudio Output \(deviceID)"
        }
        return Self.swiftString(from: cfStr) ?? "CoreAudio Output \(deviceID)"
    }

    private func availableSampleRates(_ deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.stride
        guard count > 0 else {
            return [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        }

        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        var readSize = size
        let status = ranges.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &readSize, base)
        }
        guard status == noErr else {
            return [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        }

        var rates: Set<Double> = []
        for range in ranges {
            if range.mMinimum > 0, range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else if range.mMaximum >= range.mMinimum {
                for candidate in Self.candidateSampleRates {
                    if candidate >= range.mMinimum && candidate <= range.mMaximum {
                        rates.insert(candidate)
                    }
                }
            }
        }
        let sorted = rates.sorted()
        return sorted.isEmpty ? [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] : sorted
    }

    private static func swiftString(from cfString: CFString) -> String? {
        let encoding = CFStringBuiltInEncodings.UTF8.rawValue
        if let cPtr = CFStringGetCStringPtr(cfString, encoding) {
            return String(cString: cPtr)
        }
        let length = CFStringGetLength(cfString)
        let maxBytes = CFStringGetMaximumSizeForEncoding(length, encoding) + 1
        guard maxBytes > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: maxBytes)
        guard CFStringGetCString(cfString, &buf, maxBytes, encoding) else {
            return nil
        }
        let utf8 = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}
#endif
