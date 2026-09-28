import CoreAudio
import EQCore
import Foundation

/// What `eq driver` needs from the HAL plug-in in Driver/; a fake in tests.
protocol DriverPort {
    func health() throws -> [String: Any]
    func write(settings record: Data) throws
    func meter() throws -> DriverMeter
}

struct DriverMeter: Equatable {
    var frequencies: [Double]
    var inputDB: [Double]
    var outputDB: [Double]
    var peakDB: Double
    var limiting: Bool
    var compressorReductionDB: Double
}

enum DriverError: Error, Equatable, CustomStringConvertible {
    /// The plug-in refused the write: this process does not satisfy its writer requirement.
    case refused
    case failed(String, OSStatus)
    case badReply(String)

    var description: String {
        switch self {
        case .refused: return "the driver refused the write: this eq is not signed the way the driver requires"
        case .failed(let what, let status): return "\(what) failed (Core Audio status \(status))"
        case .badReply(let what): return "the driver sent an unreadable \(what)"
        }
    }
}

/// The plug-in's device, `com.servitola.eq.device`, and its custom properties.
struct DriverControl: DriverPort {
    static let deviceUID = "com.servitola.eq.device"
    let device: AudioObjectID

    private static func selector(_ code: String) -> AudioObjectPropertySelector { code.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static let settingsSelector = selector("eqSt")
    static let meterSelector = selector("eqMt")
    static let healthSelector = selector("eqHl")

    static func find() -> DriverControl? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid = deviceUID as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return DriverControl(device: id)
    }

    /// The record the plug-in takes on `eqSt`; nil when the UID is empty or too long for it.
    static func record(_ settings: eqc_settings, targetUID: String, serial: UInt64) -> Data? {
        var settings = settings
        var blob = eqc_blob()
        guard eqc_blob_encode(&blob, &settings, targetUID, serial) else { return nil }
        return withUnsafeBytes(of: &blob) { Data($0) }
    }

    static func meter(from data: Data) -> DriverMeter? {
        var frame = eqc_meter_frame()
        guard data.withUnsafeBytes({ eqc_meter_frame_decode($0.baseAddress!, $0.count, &frame) }) else { return nil }
        let bands = Int(frame.bandCount)
        func values<T>(_ tuple: T) -> [Double] {
            withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Double.self).prefix(bands)) }
        }
        return DriverMeter(frequencies: values(frame.frequencies), inputDB: values(frame.inputDB), outputDB: values(frame.outputDB),
                           peakDB: frame.peakDB, limiting: frame.limiting != 0, compressorReductionDB: frame.compressorReductionDB)
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func read(_ selector: AudioObjectPropertySelector, _ what: String) throws -> CFPropertyList {
        var address = address(selector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw DriverError.failed("reading the \(what)", status) }
        guard let value = value?.takeRetainedValue() else { throw DriverError.badReply(what) }
        return value
    }

    func health() throws -> [String: Any] {
        guard let health = try read(Self.healthSelector, "health") as? [String: Any] else { throw DriverError.badReply("health") }
        return health
    }

    func write(settings record: Data) throws {
        var address = address(Self.settingsSelector)
        var value = record as CFData
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<CFData>.size), $0)
        }
        if status == kAudioDevicePermissionsError { throw DriverError.refused }
        guard status == noErr else { throw DriverError.failed("writing the settings", status) }
    }

    func meter() throws -> DriverMeter {
        guard let data = try read(Self.meterSelector, "meter") as? Data, let meter = Self.meter(from: data) else {
            throw DriverError.badReply("meter")
        }
        return meter
    }
}
