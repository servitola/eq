import CoreAudio
import EQCore
import Foundation

/// What eq needs from the HAL plug-in in Driver/; a fake in tests.
protocol DriverPort {
    func health() throws -> [String: Any]
    func write(settings record: Data) throws
    func meter() throws -> DriverMeter
    /// `eqTg`: the real device the plug-in plays on.
    func setTarget(_ uid: String) throws
    /// `eqHd`: kept by the plug-in across coreaudiod restarts.
    func setHidden(_ hidden: Bool) throws
}

/// The plug-in's `eqHl`, typed. A key the plug-in does not send reads as zero, empty or false.
struct DriverHealth: Equatable {
    var target = ""
    var targetName = ""
    var targetAvailable = false
    var ioRunning = false
    var underruns: UInt64 = 0
    var overruns: UInt64 = 0
    var clockPpm = 0.0
    var sampleRate = 0.0
    var latencyFrames = 0.0
    var eqActive = false
    /// nil: a plug-in from before the settings record, which plays no EQ.
    var settingsVersion: Int?
    var settingsSerial: UInt64 = 0
    var settingsError = ""
    var settingsRejected: UInt64 = 0
    var lastWriterPID = 0
    var hidden = false
    var killed = false
    var writerRequirement = ""

    init() {}

    init(_ values: [String: Any]) {
        func text(_ key: String) -> String { values[key] as? String ?? "" }
        func number(_ key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
        func count(_ key: String) -> UInt64 { UInt64(max(number(key), 0)) }
        func flag(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
        target = text("target")
        targetName = text("targetName")
        targetAvailable = flag("targetAvailable")
        ioRunning = flag("ioRunning")
        underruns = count("underruns")
        overruns = count("overruns")
        clockPpm = number("clockCorrectionPpm")
        sampleRate = number("sampleRate")
        latencyFrames = number("latencyFrames")
        eqActive = flag("eqActive")
        settingsVersion = (values["settingsVersion"] as? NSNumber)?.intValue
        settingsSerial = count("settingsSerial")
        settingsError = text("settingsError")
        settingsRejected = count("settingsRejected")
        lastWriterPID = Int(number("lastWriterPID"))
        hidden = flag("hidden")
        killed = flag("killed")
        writerRequirement = text("writerRequirement")
    }

    /// What the device reports to players: the target's latency and safety offset plus the plug-in's own buffering.
    var latencyMs: Double? { sampleRate > 0 ? latencyFrames / sampleRate * 1000 : nil }
}

struct DriverMeter: Equatable {
    var frequencies: [Double]
    var inputDB: [Double]
    var outputDB: [Double]
    var peakDB: Double
    var limiting: Bool
    var compressorReductionDB: Double
    /// The output's third octaves; empty from a plug-in before them.
    var spectrumDB: [Double] = []
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
    static let spectrumSelector = selector("eqMs")
    static let healthSelector = selector("eqHl")
    static let targetSelector = selector("eqTg")
    static let hiddenSelector = selector("eqHd")
    /// The settings record this eq writes; an older plug-in would refuse every record.
    static let requiredVersion = Int(EQC_BLOB_VERSION)

    static func find() -> DriverControl? {
        AudioDeviceManager.deviceID(uid: deviceUID).map(DriverControl.init)
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
        let spectrum = withUnsafeBytes(of: frame.spectrumDB) { Array($0.bindMemory(to: Double.self).prefix(Int(frame.spectrumCount))) }
        return DriverMeter(frequencies: values(frame.frequencies), inputDB: values(frame.inputDB), outputDB: values(frame.outputDB),
                           peakDB: frame.peakDB, limiting: frame.limiting != 0, compressorReductionDB: frame.compressorReductionDB,
                           spectrumDB: spectrum)
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

    func setTarget(_ uid: String) throws {
        try set(Self.targetSelector, uid as CFString, "target")
    }

    func setHidden(_ hidden: Bool) throws {
        try set(Self.hiddenSelector, (hidden ? kCFBooleanTrue : kCFBooleanFalse) as CFBoolean, "hidden flag")
    }

    private func set<T: AnyObject>(_ selector: AudioObjectPropertySelector, _ value: T, _ what: String) throws {
        var address = address(selector)
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw DriverError.failed("writing the \(what)", status) }
    }

    /// `eqMs` where the plug-in has it, else `eqMt`. Asked first rather than read and failed: a
    /// read of a property the plug-in lacks may land in coreaudiod's log, 30 times a second.
    func meter() throws -> DriverMeter {
        var spectrum = address(Self.spectrumSelector)
        let selector = AudioObjectHasProperty(device, &spectrum) ? Self.spectrumSelector : Self.meterSelector
        guard let data = try read(selector, "meter") as? Data, let meter = Self.meter(from: data) else {
            throw DriverError.badReply("meter")
        }
        return meter
    }
}
