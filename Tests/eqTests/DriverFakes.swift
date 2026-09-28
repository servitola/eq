import CoreAudio
import EQCore
import Foundation
@testable import eq

/// What happened, in order, across the fakes: the escape hatch is about order.
final class Journal {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func clear() { lock.lock(); entries = []; lock.unlock() }
}

/// The HAL plug-in as eq sees it through its custom properties.
final class FakeDriver: DriverPort {
    var state: [String: Any] = ["target": "BUILTIN", "targetName": "MacBook Pro Speakers", "eqActive": false,
                                "settingsSerial": 0, "settingsVersion": 1, "writerRequirement": "identifier \"com.servitola.eq\""]
    var written: [Data] = []
    var refuses = false
    var applies = true
    /// Every call sleeps this long first: a wedged plug-in.
    var hangs: TimeInterval = 0
    var meterReply: DriverMeter?
    var journal: Journal?
    var names: [String: String] = [:]

    private func stall() { if hangs > 0 { Thread.sleep(forTimeInterval: hangs) } }

    func health() throws -> [String: Any] {
        stall()
        return state
    }

    func write(settings record: Data) throws {
        stall()
        if refuses { throw DriverError.refused }
        written.append(record)
        journal?.add("push \(Self.uid(of: record))")
        guard applies else { return }
        state["settingsSerial"] = Self.decode(record).serial
        state["eqActive"] = true
    }

    func meter() throws -> DriverMeter {
        stall()
        guard let meterReply else { throw DriverError.badReply("meter") }
        return meterReply
    }

    func setTarget(_ uid: String) throws {
        stall()
        state["target"] = uid
        state["targetName"] = names[uid] ?? uid
        journal?.add("target \(uid)")
    }

    func setHidden(_ hidden: Bool) throws {
        stall()
        state["hidden"] = hidden
        journal?.add("hidden \(hidden)")
    }

    var pushedUIDs: [String] { written.map(Self.uid(of:)) }

    static func decode(_ record: Data) -> (settings: eqc_settings, uid: String, serial: UInt64) {
        var settings = eqc_settings()
        var uid = [CChar](repeating: 0, count: Int(EQC_BLOB_UID_CAPACITY))
        var serial: UInt64 = 0
        _ = record.withUnsafeBytes { eqc_blob_decode($0.baseAddress!, $0.count, &settings, &uid, &serial) }
        return (settings, String(cString: uid), serial)
    }

    static func uid(of record: Data) -> String { decode(record).uid }
}

/// The system's outputs and default output, never the real ones.
final class FakeAudioSystem: AudioSystem {
    static let builtIn = AudioOutputDevice(id: 1, uid: "BUILTIN", name: "MacBook Pro Speakers", transportType: kAudioDeviceTransportTypeBuiltIn)
    static let speaker = AudioOutputDevice(id: 2, uid: "BT-RCA", name: "BE-RCA", transportType: kAudioDeviceTransportTypeBluetooth)
    static let headphones = AudioOutputDevice(id: 3, uid: "USB-DAC", name: "DAC", transportType: kAudioDeviceTransportTypeUSB)
    static let eq = AudioOutputDevice(id: 9, uid: DriverControl.deviceUID, name: "BE-RCA · EQ", transportType: kAudioDeviceTransportTypeVirtual)
    static let proxy = AudioOutputDevice(id: 10, uid: "ProxyAudioDevice_UID", name: "Proxy Audio Device", transportType: kAudioDeviceTransportTypeVirtual)
    static let aggregate = AudioOutputDevice(id: 11, uid: "agg-1", name: "Multi-Output Device", transportType: kAudioDeviceTransportTypeAggregate)
    static let airplay = AudioOutputDevice(id: 12, uid: "AIRPLAY", name: "Living Room", transportType: kAudioDeviceTransportTypeAirPlay)

    var devices: [AudioOutputDevice] = [builtIn, speaker, headphones, eq, proxy, aggregate, airplay]
    var current: String?
    /// UIDs macOS will not make the default, or will only after this many tries.
    var refuses: Set<String> = []
    var refusesFirst = 0
    var hangs: TimeInterval = 0
    var journal: Journal?
    /// Called after the default changed, as the property listener would be.
    var onChange: (() -> Void)?

    init(current: String? = FakeAudioSystem.speaker.uid) { self.current = current }

    func outputDevices() -> [AudioOutputDevice] {
        if hangs > 0 { Thread.sleep(forTimeInterval: hangs) }
        return devices
    }

    func defaultOutput() -> AudioOutputDevice? {
        if hangs > 0 { Thread.sleep(forTimeInterval: hangs) }
        return devices.first { $0.uid == current }
    }

    func setDefaultOutput(uid: String) -> Bool {
        if hangs > 0 { Thread.sleep(forTimeInterval: hangs) }
        guard !refuses.contains(uid), devices.contains(where: { $0.uid == uid }) else { return false }
        if refusesFirst > 0 {
            refusesFirst -= 1
            return true
        }
        current = uid
        journal?.add("default \(uid)")
        onChange?()
        return true
    }

    /// The user picking a device in the Sound menu.
    func pick(_ device: AudioOutputDevice) {
        current = device.uid
        onChange?()
    }
}

/// Scheduled work runs only when the test moves time on.
final class ManualClock {
    private(set) var now = Date(timeIntervalSince1970: 1_790_000_000)
    private var pending: [(at: Date, order: Int, work: () -> Void)] = []
    private var order = 0

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        order += 1
        pending.append((now.addingTimeInterval(delay), order, work))
    }

    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = pending.filter({ $0.at <= end }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = next.at
            next.work()
        }
        now = end
    }
}
