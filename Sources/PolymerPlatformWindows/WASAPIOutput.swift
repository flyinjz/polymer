// Audio output through WASAPI in shared mode, event driven, in the device's
// own mix rate and channel count as 32-bit float (Windows converts if the
// mix format is something else). Two threads: a time-critical one that waits
// for the device event and renders straight into the device buffer, and a
// feeder that calls `refill` after every period.
//
// Audioclient.h and mmdeviceapi.h are not in the WinSDK module, so the COM
// interfaces are called through their vtables by slot number (the slots are
// fixed by the Windows ABI) and the GUIDs are written out. ole32 is loaded
// at run time.
#if os(Windows)
import WinSDK
import PolymerBase
import PolymerPlatform
import Synchronization

public struct WASAPIOutputSystem: AudioOutputSystem {
    public init() {}
    public func makeDefaultOutput() throws(PlatformError) -> any AudioOutput { try WASAPIOutput() }
}

private struct OLE32: @unchecked Sendable {
    typealias CoInitializeEx = @convention(c) (UnsafeMutableRawPointer?, DWORD) -> HRESULT
    typealias CoCreateInstance = @convention(c) (UnsafePointer<GUID>, UnsafeMutableRawPointer?, DWORD, UnsafePointer<GUID>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT
    typealias CoTaskMemFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    let initialize: CoInitializeEx
    let create: CoCreateInstance
    let free: CoTaskMemFree

    static let shared: OLE32? = {
        let module = "ole32.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
        guard let module,
              let a = GetProcAddress(module, "CoInitializeEx"),
              let b = GetProcAddress(module, "CoCreateInstance"),
              let c = GetProcAddress(module, "CoTaskMemFree") else { return nil }
        return OLE32(initialize: unsafeBitCast(a, to: CoInitializeEx.self),
                     create: unsafeBitCast(b, to: CoCreateInstance.self),
                     free: unsafeBitCast(c, to: CoTaskMemFree.self))
    }()
}

/// Slot `index` of a COM object's vtable as a C function.
@inline(__always) private func slot<T>(_ object: UnsafeMutableRawPointer, _ index: Int, as: T.Type) -> T {
    let table = object.load(as: UnsafePointer<UnsafeRawPointer>.self)
    return unsafeBitCast(table[index], to: T.self)
}

private func release(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    _ = slot(object, 2, as: (@convention(c) (UnsafeMutableRawPointer) -> ULONG).self)(object)
}

private func makeGUID(_ a: UInt32, _ b: UInt16, _ c: UInt16, _ d: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> GUID {
    GUID(Data1: a, Data2: b, Data3: c, Data4: d)
}

private let CLSID_MMDeviceEnumerator = makeGUID(0xBCDE0395, 0xE52F, 0x467C, (0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E))
private let IID_IMMDeviceEnumerator = makeGUID(0xA95664D2, 0x9614, 0x4F35, (0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6))
private let IID_IAudioClient = makeGUID(0x1CB9AD4C, 0xDBFA, 0x4C32, (0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2))
private let IID_IAudioRenderClient = makeGUID(0xF294ACFC, 0x3146, 0x4483, (0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2))

private func hex(_ hr: HRESULT) -> String { "0x" + String(UInt32(bitPattern: hr), radix: 16, uppercase: true) }

public final class WASAPIOutput: AudioOutput, @unchecked Sendable {
    public let name: String
    public let format: AudioFormat
    public let latencyFrames: Int
    /// Frames in the device buffer.
    public let bufferFrames: Int
    /// Set when the device went away (unplugged, default changed); the output has stopped rendering.
    public var deviceLost: Bool { lost.load(ordering: .relaxed) }

    private let client: UnsafeMutableRawPointer
    private let renderClient: UnsafeMutableRawPointer
    private let deviceEvent: HANDLE
    private let feedEvent: HANDLE
    private let stopping = Atomic<Bool>(false)
    private let lost = Atomic<Bool>(false)
    private var renderer: (any AudioRenderer)?
    private var renderThread: HANDLE?
    private var feedThread: HANDLE?

    // IAudioClient slots.
    private typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Int32, DWORD, Int64, Int64, UnsafeRawPointer, UnsafePointer<GUID>?) -> HRESULT
    private typealias GetUInt32 = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> HRESULT
    private typealias GetInt64 = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int64>) -> HRESULT
    private typealias GetMixFormat = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT
    private typealias NoArgs = @convention(c) (UnsafeMutableRawPointer) -> HRESULT
    private typealias SetEventHandle = @convention(c) (UnsafeMutableRawPointer, HANDLE?) -> HRESULT
    private typealias GetService = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<GUID>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT
    // IAudioRenderClient slots.
    private typealias GetBuffer = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> HRESULT
    private typealias ReleaseBuffer = @convention(c) (UnsafeMutableRawPointer, UInt32, DWORD) -> HRESULT

    public init() throws(PlatformError) {
        guard let ole = OLE32.shared else { throw PlatformError("ole32.dll could not be loaded, so WASAPI audio is unavailable") }
        _ = ole.initialize(nil, 0)   // multithreaded; an existing apartment is fine too

        var enumerator: UnsafeMutableRawPointer?
        var clsid = CLSID_MMDeviceEnumerator, iid = IID_IMMDeviceEnumerator
        var hr = ole.create(&clsid, nil, 23 /* CLSCTX_ALL */, &iid, &enumerator)
        guard hr >= 0, let enumerator else { throw PlatformError("CoCreateInstance(MMDeviceEnumerator) failed with \(hex(hr)); is the Windows Audio service running?") }
        defer { release(enumerator) }

        var device: UnsafeMutableRawPointer?
        typealias GetDefault = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT
        hr = slot(enumerator, 4, as: GetDefault.self)(enumerator, 0 /* eRender */, 0 /* eConsole */, &device)
        guard hr >= 0, let device else { throw PlatformError("there is no default audio output device (\(hex(hr))); connect or enable one in Sound settings") }
        defer { release(device) }

        var rawClient: UnsafeMutableRawPointer?
        var clientIID = IID_IAudioClient
        typealias Activate = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<GUID>, DWORD, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT
        hr = slot(device, 3, as: Activate.self)(device, &clientIID, 23, nil, &rawClient)
        guard hr >= 0, let client = rawClient else { throw PlatformError("IMMDevice.Activate(IAudioClient) failed with \(hex(hr))") }

        var mix: UnsafeMutableRawPointer?
        hr = slot(client, 8, as: GetMixFormat.self)(client, &mix)
        guard hr >= 0, let mix else { release(client); throw PlatformError("IAudioClient.GetMixFormat failed with \(hex(hr))") }
        let mixTag = mix.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
        let channels = Int(mix.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
        let rate = Int(mix.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let mixCbSize = mix.loadUnaligned(fromByteOffset: 16, as: UInt16.self)
        var mask: UInt32 = channels == 1 ? 0x4 : channels == 2 ? 0x3 : 0
        if mixTag == 0xFFFE && mixCbSize >= 22 { mask = mix.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        ole.free(mix)
        guard channels > 0, rate > 0 else { release(client); throw PlatformError("the device's mix format says \(channels) channels at \(rate) Hz") }

        // WAVEFORMATEXTENSIBLE, 32-bit float at the mix rate and channels.
        var wf = [UInt8](repeating: 0, count: 40)
        func put16(_ at: Int, _ v: Int) { wf[at] = UInt8(v & 0xFF); wf[at + 1] = UInt8((v >> 8) & 0xFF) }
        func put32(_ at: Int, _ v: UInt32) { for k in 0..<4 { wf[at + k] = UInt8((v >> UInt32(8 * k)) & 0xFF) } }
        put16(0, 0xFFFE); put16(2, channels); put32(4, UInt32(rate))
        put32(8, UInt32(rate * channels * 4)); put16(12, channels * 4); put16(14, 32); put16(16, 22)
        put16(18, 32); put32(20, mask)
        // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT 00000003-0000-0010-8000-00AA00389B71
        put32(24, 3); put16(28, 0); put16(30, 0x10)
        let tail: [UInt8] = [0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        for k in 0..<8 { wf[32 + k] = tail[k] }

        guard let deviceEvent = CreateEventW(nil, false, false, nil), let feedEvent = CreateEventW(nil, false, false, nil) else {
            release(client); throw PlatformError("CreateEventW failed (\(GetLastError()))")
        }
        let flags: DWORD = 0x0004_0000 | 0x8000_0000 | 0x0800_0000   // event callback, auto-convert PCM, default-quality resampling
        hr = wf.withUnsafeBytes { b in
            slot(client, 3, as: Initialize.self)(client, 0 /* shared */, flags, 200_000 /* 20 ms */, 0, b.baseAddress!, nil)
        }
        guard hr >= 0 else {
            CloseHandle(deviceEvent); CloseHandle(feedEvent); release(client)
            throw PlatformError("IAudioClient.Initialize (shared, float, \(rate) Hz, \(channels) channels) failed with \(hex(hr))")
        }
        hr = slot(client, 13, as: SetEventHandle.self)(client, deviceEvent)
        var size: UInt32 = 0
        if hr >= 0 { hr = slot(client, 4, as: GetUInt32.self)(client, &size) }
        var streamLatency: Int64 = 0
        if hr >= 0 { _ = slot(client, 5, as: GetInt64.self)(client, &streamLatency) }
        var rawRender: UnsafeMutableRawPointer?
        var renderIID = IID_IAudioRenderClient
        if hr >= 0 { hr = slot(client, 14, as: GetService.self)(client, &renderIID, &rawRender) }
        guard hr >= 0, let renderClient = rawRender else {
            CloseHandle(deviceEvent); CloseHandle(feedEvent); release(client)
            throw PlatformError("setting up the WASAPI stream failed with \(hex(hr))")
        }

        self.client = client
        self.renderClient = renderClient
        self.deviceEvent = deviceEvent
        self.feedEvent = feedEvent
        format = AudioFormat(sampleRate: rate, channels: channels)
        bufferFrames = Int(size)
        latencyFrames = Int(size) + Int(streamLatency * Int64(rate) / 10_000_000)
        name = "WASAPI shared, default device, \(format)"
    }

    deinit {
        stop()
        release(renderClient)
        release(client)
        CloseHandle(deviceEvent)
        CloseHandle(feedEvent)
    }

    public func start(_ renderer: any AudioRenderer) throws(PlatformError) {
        stop()
        self.renderer = renderer
        stopping.store(false, ordering: .relaxed)
        lost.store(false, ordering: .relaxed)

        // Fill the whole device buffer before starting, so the first period is not silence.
        while renderer.refill() {}
        var data: UnsafeMutablePointer<UInt8>?
        if slot(renderClient, 3, as: GetBuffer.self)(renderClient, UInt32(bufferFrames), &data) >= 0, let data {
            data.withMemoryRebound(to: Float.self, capacity: bufferFrames * format.channels) {
                renderer.render($0, frames: bufferFrames, channels: format.channels)
            }
            _ = slot(renderClient, 4, as: ReleaseBuffer.self)(renderClient, UInt32(bufferFrames), 0)
        }

        let hr = slot(client, 10, as: NoArgs.self)(client)
        guard hr >= 0 else { throw PlatformError("IAudioClient.Start failed with \(hex(hr))") }

        renderThread = CreateThread(nil, 0, { p -> DWORD in
            let output = Unmanaged<WASAPIOutput>.fromOpaque(p!).takeRetainedValue()
            output.renderLoop()
            return 0
        }, Unmanaged.passRetained(self).toOpaque(), 0, nil)
        feedThread = CreateThread(nil, 0, { p -> DWORD in
            let output = Unmanaged<WASAPIOutput>.fromOpaque(p!).takeRetainedValue()
            output.feedLoop()
            return 0
        }, Unmanaged.passRetained(self).toOpaque(), 0, nil)
        guard renderThread != nil, feedThread != nil else {
            stop()
            throw PlatformError("CreateThread failed (\(GetLastError())) starting audio output")
        }
    }

    public func stop() {
        guard renderThread != nil || feedThread != nil else { return }
        stopping.store(true, ordering: .releasing)
        SetEvent(deviceEvent)
        SetEvent(feedEvent)
        for t in [renderThread, feedThread] {
            if let t { WaitForSingleObject(t, 0xFFFF_FFFF); CloseHandle(t) }
        }
        renderThread = nil
        feedThread = nil
        _ = slot(client, 11, as: NoArgs.self)(client)
        _ = slot(client, 12, as: NoArgs.self)(client)
        renderer = nil
    }

    private func renderLoop() {
        _ = OLE32.shared?.initialize(nil, 0)
        SetThreadPriority(GetCurrentThread(), 15 /* THREAD_PRIORITY_TIME_CRITICAL */)
        guard let renderer else { return }
        let channels = format.channels
        let getPadding = slot(client, 6, as: GetUInt32.self)
        let getBuffer = slot(renderClient, 3, as: GetBuffer.self)
        let releaseBuffer = slot(renderClient, 4, as: ReleaseBuffer.self)
        while !stopping.load(ordering: .acquiring) {
            WaitForSingleObject(deviceEvent, 200)
            if stopping.load(ordering: .acquiring) { break }
            var padding: UInt32 = 0
            var hr = getPadding(client, &padding)
            if hr < 0 { lost.store(true, ordering: .relaxed); break }
            let free = bufferFrames - Int(padding)
            if free <= 0 { continue }
            var data: UnsafeMutablePointer<UInt8>?
            hr = getBuffer(renderClient, UInt32(free), &data)
            if hr < 0 { lost.store(true, ordering: .relaxed); break }
            guard let data else { continue }
            data.withMemoryRebound(to: Float.self, capacity: free * channels) {
                renderer.render($0, frames: free, channels: channels)
            }
            _ = releaseBuffer(renderClient, UInt32(free), 0)
            SetEvent(feedEvent)
        }
        SetEvent(feedEvent)
    }

    private func feedLoop() {
        guard let renderer else { return }
        while !stopping.load(ordering: .acquiring) {
            WaitForSingleObject(feedEvent, 10)
            while !stopping.load(ordering: .acquiring) && renderer.refill() {}
        }
    }
}
#endif
