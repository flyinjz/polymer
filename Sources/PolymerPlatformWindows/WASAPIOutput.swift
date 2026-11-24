// Windows native audio output discovery backend using WinSDK waveOut device enumeration.
#if os(Windows)
import WinSDK
import PolymerPlatform

public struct WindowsAudioOutputBackend: AudioOutputBackend {
    public static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 192_000,
    ]

    public init() {}

    public func listDevices() -> [AudioDeviceInfo] {
        let count = Int(waveOutGetNumDevs())
        guard count > 0 else { return [] }

        var devices: [AudioDeviceInfo] = []
        devices.reserveCapacity(count)

        for idx in 0..<count {
            var caps = WAVEOUTCAPSW()
            let res = waveOutGetDevCapsW(
                UINT_PTR(idx),
                &caps,
                UINT(MemoryLayout<WAVEOUTCAPSW>.size)
            )
            guard res == MMRESULT(MMSYSERR_NOERROR) else { continue }

            let name = withUnsafeBytes(of: caps.szPname) { raw -> String in
                let units = raw.bindMemory(to: UInt16.self)
                let len = units.firstIndex(of: 0) ?? units.count
                return String(decoding: units[0..<len], as: UTF16.self)
            }
            let trimmedName = name.isEmpty ? "Windows Audio Output \(idx)" : name
            let rawChannels = Int(caps.wChannels)
            let channelCount = (rawChannels >= 1 && rawChannels <= 16) ? rawChannels : 2

            devices.append(AudioDeviceInfo(
                id: "win-waveout-\(idx)",
                name: trimmedName,
                isDefault: idx == 0,
                sampleRates: Self.standardSampleRates,
                channelCount: channelCount
            ))
        }

        return devices
    }

    public func defaultDevice() -> AudioDeviceInfo? {
        let devices = listDevices()
        return devices.first(where: \.isDefault) ?? devices.first
    }
}
#endif
