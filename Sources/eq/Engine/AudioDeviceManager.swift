// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation
import CoreAudio

struct AudioOutputDevice: Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transportType: UInt32

    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        default: return "other"
        }
    }
}

/// Core Audio device enumeration and default-output lookup.
enum AudioDeviceManager {
    static let aggregateUIDPrefix = "com.servitola.eq.aggregate-"

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func outputDevices() -> [AudioOutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard outputChannelCount(id) > 0 else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            // Skip our own private aggregates.
            if uid.hasPrefix(aggregateUIDPrefix) { return nil }
            guard !uid.isEmpty, let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, transportType: transportType(id))
        }
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) -> OSStatus {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    // MARK: - Device properties

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func transportType(_ id: AudioObjectID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func outputChannelCount(_ id: AudioObjectID) -> Int {
        channelCount(id, scope: kAudioDevicePropertyScopeOutput) ?? 0
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard propertyDataSize(id, &addr, 0, nil, &size), size > 0 else { return nil }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 48000 }
        // A driver's value reaches Int conversions and filter design; anything no real device runs
        // at reads as 0, which every caller already treats as "not settled yet".
        return value.isFinite && value > 0 && value <= maxSampleRate ? value : 0
    }

    static let maxSampleRate = 1_536_000.0

    static func tapFormat(_ id: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = address(kAudioTapPropertyFormat)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setNominalSampleRate(_ id: AudioObjectID, _ rate: Double) -> OSStatus {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    static func bufferFrameSize(_ id: AudioObjectID) -> Int? {
        uint32Property(id, kAudioDevicePropertyBufferFrameSize).flatMap { $0 > 0 ? Int($0) : nil }
    }

    /// Other apps keep their own buffer size: the HAL holds it per client process. Checked on macOS 26
    /// with a second process, which kept reading 512 frames while the first had 96. eq's own cost is
    /// two IO threads waking about 345 times a second each at 128 frames and 44.1 kHz.
    /// Some devices refuse or clamp the request; `bufferFrameSize` then reports what was granted.
    static func requestBufferFrameSize(_ id: AudioObjectID, _ frames: Int) {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = UInt32(clamping: frames)
        _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Which streams of `id` in `scope` run for `ioProc`, one flag per stream; nil when unreadable.
    static func streamUsage(_ id: AudioObjectID, scope: AudioObjectPropertyScope, for ioProc: AudioDeviceIOProcID) -> [Bool]? {
        guard let count = streams(id, scope: scope)?.count else { return nil }
        return withStreamUsage(count: count, ioProc: ioProc) { usage, size, flags in
            var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
            var size = UInt32(size)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, usage) == noErr else { return nil }
            return (0..<min(Int(usage.pointee.mNumberStreams), count)).map { flags[$0] != 0 }
        }
    }

    /// Returns the status of the write; read `streamUsage` back to know what took.
    @discardableResult
    static func setStreamUsage(_ id: AudioObjectID, scope: AudioObjectPropertyScope, for ioProc: AudioDeviceIOProcID, _ on: [Bool]) -> OSStatus {
        withStreamUsage(count: on.count, ioProc: ioProc) { usage, size, flags in
            for (index, isOn) in on.enumerated() { flags[index] = isOn ? 1 : 0 }
            var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
            return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(size), usage)
        }
    }

    /// An AudioHardwareIOProcStreamUsage for `count` streams: its flags are a variable-length array.
    private static func withStreamUsage<T>(count: Int, ioProc: AudioDeviceIOProcID,
                                           _ body: (UnsafeMutablePointer<AudioHardwareIOProcStreamUsage>, Int, UnsafeMutablePointer<UInt32>) -> T) -> T {
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = max(offset + count * MemoryLayout<UInt32>.size, MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        return body(usage, size, (storage + offset).assumingMemoryBound(to: UInt32.self))
    }

    static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        streams(id, scope: scope)?.count
    }

    static func outputStreamCount(_ id: AudioObjectID) -> Int? {
        streams(id, scope: kAudioDevicePropertyScopeOutput)?.count
    }

    /// Frames, not seconds: every latency property Core Audio reports is in frames at the nominal rate.
    static func latencyFrames(device id: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        (uint32Property(id, kAudioDevicePropertyLatency, scope: scope) ?? 0)
            &+ (uint32Property(id, kAudioDevicePropertySafetyOffset, scope: scope) ?? 0)
    }

    static func firstOutputStreamLatencyFrames(_ id: AudioObjectID) -> UInt32 {
        guard let stream = streams(id, scope: kAudioDevicePropertyScopeOutput)?.first else { return 0 }
        return uint32Property(stream, kAudioStreamPropertyLatency) ?? 0
    }

    private static func streams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID]? {
        var streamAddress = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &size) == noErr else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &size, &streams) == noErr else { return nil }
        return streams
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func inputStreamChannelCounts(_ id: AudioObjectID) -> [UInt32]? {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, storage) == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }

    // MARK: - Process translation (for tap exclusion)

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processObject = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var pidValue = pid
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &processObject)
        return status == noErr && processObject != 0 ? processObject : nil
    }

    // MARK: - Device lookup

    static func device(_ id: AudioObjectID) -> AudioOutputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioOutputDevice(id: id, uid: uid, name: name, transportType: transportType(id))
    }

    static func builtInOutputDevice() -> AudioOutputDevice? {
        outputDevices().first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
    }

    /// An aggregate left behind by a crashed daemon would otherwise be offered as an output
    /// device and could even become the default, feeding the new tap its own output.
    static func destroyStaleAggregates() {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard propertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return }
        for id in ids where (stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "").hasPrefix(aggregateUIDPrefix) {
            Log.write("destroying stale aggregate \(id)")
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
}

private func propertyDataSize(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress,
                              _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: inout UInt32) -> Bool {
    CoreAudio.AudioObjectGetPropertyDataSize(id, &addr, qualifierSize, qualifier, &size) == noErr
}
